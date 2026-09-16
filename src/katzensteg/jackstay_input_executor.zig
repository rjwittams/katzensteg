//! Authorized Jackstay source -> canonical KS input model. No SDL calls or
//! presentation work here. The app's adapter resolves bindings and delivers work.
const std = @import("std");
const os = @import("platform");
const js = @import("jackstay");
const wire = js.input;
const input = @import("input.zig");

pub const Executor = struct {
    allocator: std.mem.Allocator,
    target: wire.Target,
    listener: ?js.endpoint.Listener = null,
    stopped: std.atomic.Value(bool) = .init(false),
    disconnect_requested: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    servers: [8]?wire.Server = @splat(null),
    pending: ?wire.Work = null,
    geometry: wire.Geometry = .{ .width = 640, .height = 480 },

    pub fn init(allocator: std.mem.Allocator) !Executor {
        return .{
            .allocator = allocator,
            .target = try wire.Target.init(.{
                .capabilities = .{ .physical = true, .logical = true, .text = true, .pointer = true, .scroll = true },
                .geometry = .{ .width = 640, .height = 480 },
                // SDL apps can interpret an ordinary button-up as a drop. We cannot
                // undo that, or promise independent application-level native holds.
                .independent_contributions = false,
                .interaction_cancel = false,
            }),
        };
    }

    pub fn create(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*Executor {
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        self.* = try init(allocator);
        errdefer self.target.deinit() catch {};
        self.listener = try js.endpoint.Listener.init(io, allocator, path);
        errdefer self.listener.?.deinit();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn serve(self: *Executor) void {
        while (!self.stopped.load(.acquire)) {
            if (self.disconnect_requested.load(.acquire)) {
                // ABI 0.7 has no target-side overflow command. Disconnect on the
                // transport thread: dropping servers ends assignment and asks
                // Jackstay for cleanup, without claiming execution was uncertain.
                for (&self.servers) |*slot| {
                    if (slot.*) |*server| server.deinit();
                    slot.* = null;
                }
                self.disconnect_requested.store(false, .release);
            }
            for (&self.servers) |*slot| if (slot.*) |*server| {
                if (server.finished() catch true) {
                    server.deinit();
                    slot.* = null;
                }
            };
            if (self.listener.?.accept() catch null) |accepted| {
                var fd = accepted;
                defer if (fd >= 0) os.posix.close(fd);
                for (&self.servers) |*slot| if (slot.* == null) {
                    slot.* = self.target.serve(&fd) catch null;
                    break;
                };
            }
            os.time.sleep(5 * std.time.ns_per_ms);
        }
        for (&self.servers) |*slot| {
            if (slot.*) |*server| server.deinit();
            slot.* = null;
        }
    }

    pub fn setSize(self: *Executor, w: i32, h: i32) !void {
        const width: f64 = @floatFromInt(@max(1, w));
        const height: f64 = @floatFromInt(@max(1, h));
        if (self.geometry.width == width and self.geometry.height == height) return;
        const next = wire.Geometry{ .revision = try std.math.add(u64, self.geometry.revision, 1), .width = width, .height = height };
        try self.target.setGeometry(next);
        self.geometry = next;
    }

    /// Called with the input-model lock, from app input APIs, never the renderer.
    /// bind resolves a down into the current app binding. Repeat/up use that
    /// stored binding even when layout, modifiers, or key meaning have changed.
    pub fn pump(self: *Executor, model: *input.InputModel, bind: anytype) !void {
        // Do not dispatch more work while the network owner ends assignment.
        if (self.disconnect_requested.load(.acquire)) return;
        if (self.pending) |item| {
            if (!model.deliveryFinished()) return;
            model.finishDelivery();
            self.pending = null;
            var work = item;
            try work.complete(.executed);
        }
        // Bound per-call work even if a peer sends nothing but rejected mappings.
        for (0..16) |_| {
            var work = (try self.target.next()) orelse return;
            self.apply(model, &work, bind) catch |err| {
                const outcome: wire.Outcome = if ((work.cleanup() catch null) != null) .uncertain else switch (err) {
                    error.Unsupported => .unsupported,
                    else => .rejected,
                };
                const exhausted = outcome == .rejected and (err == error.Capacity or err == error.OutOfMemory);
                if (exhausted) {
                    std.log.warn("Jackstay executor input capacity exhausted; disconnecting controller", .{});
                    self.disconnect_requested.store(true, .release);
                }
                try work.complete(outcome);
                if (exhausted) return;
                continue;
            };
            if (model.deliveryFinished()) {
                model.finishDelivery();
                try work.complete(.executed);
            } else {
                self.pending = work;
                return;
            }
        }
    }

    fn apply(self: *Executor, model: *input.InputModel, work: *const wire.Work, bind: anytype) !void {
        if (try work.mode() != .cooperative) return error.Unsupported;
        const controller = work.controller();
        if (try work.cleanup()) |cleanup| {
            try self.cleanupModel(model, controller, cleanup.scope);
            return;
        }
        const event = try work.event();
        switch (event) {
            .key => |key| {
                if (key.action == .down) {
                    if (model.pressSlot(controller, key.press) != null) return error.InvalidPress;
                    const slot = model.vacantPress() orelse return error.Capacity;
                    var binding = try bind(key);
                    binding.mods = modifiers(key.modifiers);
                    binding.repeat = false;
                    try model.beginDelivery(.keyboard, 1);
                    slot.* = .{ .controller = controller, .identity = key.press, .binding = binding };
                    model.appendRemote(controller, .{ .key_down = binding });
                } else {
                    const slot = model.pressSlot(controller, key.press) orelse return error.InvalidPress;
                    var binding = slot.*.?.binding;
                    binding.mods = modifiers(key.modifiers);
                    binding.repeat = key.action == .repeat;
                    try model.beginDelivery(.keyboard, 1);
                    if (key.action == .up) {
                        if (!model.keyHeldElsewhere(binding.scancode, controller, key.press)) model.appendRemote(controller, .{ .key_up = binding });
                        slot.* = null;
                    } else model.appendRemote(controller, .{ .key_down = binding });
                }
            },
            .text => |text| {
                // SDL's NUL-terminated text API cannot represent embedded NUL.
                // Reject the whole operation rather than silently truncate it.
                if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Unsupported;
                try model.beginDelivery(.text, 1);
                if (text.len > 0) model.appendRemote(controller, .{ .text_commit = text });
            },
            .motion => |position| {
                const mapped = try self.point(position);
                try model.beginDelivery(.pointer, 1);
                model.appendRemote(controller, .{ .mouse_motion = .{
                    .x = mapped.x,
                    .y = mapped.y,
                    .precise_x = mapped.precise_x,
                    .precise_y = mapped.precise_y,
                    .precise_xrel = mapped.precise_x.? - (model.precise_mouse_x orelse @as(f32, @floatFromInt(model.last_mouse_x))),
                    .precise_yrel = mapped.precise_y.? - (model.precise_mouse_y orelse @as(f32, @floatFromInt(model.last_mouse_y))),
                    .xrel = mapped.x - model.last_mouse_x,
                    .yrel = mapped.y - model.last_mouse_y,
                    .buttons = model.mouse_buttons | model.remote_buttons | model.native_buttons,
                } });
                move(model, mapped);
            },
            .button => |button| {
                if (button.action == .repeat) return error.Unsupported;
                const releasing = button.action == .up;
                const point_value = if (releasing) Point{ .x = model.last_mouse_x, .y = model.last_mouse_y, .precise_x = model.precise_mouse_x, .precise_y = model.precise_mouse_y } else try self.point(button.position);
                const number = sdlButton(button.button);
                const mask = @as(u32, 1) << @as(u5, @intCast(number - 1));
                try model.beginDelivery(.pointer, 1);
                model.remote_controller = controller;
                if (releasing) model.remote_buttons &= ~mask else model.remote_buttons |= mask;
                if (!releasing or (model.native_buttons | model.mouse_buttons) & mask == 0) model.appendRemote(controller, .{ .mouse_button = .{
                    .x = point_value.x,
                    .y = point_value.y,
                    .precise_x = point_value.precise_x,
                    .precise_y = point_value.precise_y,
                    .button = number,
                    .pressed = !releasing,
                    .buttons = model.mouse_buttons | model.remote_buttons | model.native_buttons,
                } });
                move(model, point_value);
            },
            .scroll => |scroll| {
                // SDL scroll is in lines. There is no honest generic pixel/page
                // conversion without app-specific metrics.
                if (scroll.unit != .line or @abs(scroll.x) > std.math.maxInt(i32) or @abs(scroll.y) > std.math.maxInt(i32)) return error.Unsupported;
                const point_value = try self.point(scroll.position);
                try model.beginDelivery(.scroll, 1);
                model.appendRemote(controller, .{ .mouse_wheel = .{
                    .x = @intFromFloat(scroll.x),
                    .y = @intFromFloat(-scroll.y),
                    .precise_x = @floatCast(scroll.x),
                    .precise_y = @floatCast(-scroll.y),
                    .mouse_x = point_value.x,
                    .mouse_y = point_value.y,
                    .precise_mouse_x = point_value.precise_x,
                    .precise_mouse_y = point_value.precise_y,
                } });
                move(model, point_value);
            },
        }
    }

    fn cleanupModel(_: *Executor, model: *input.InputModel, controller: u64, scope: wire.Scope) !void {
        // In-flight delivery settled before Jackstay issued this barrier. Remove
        // older events already acknowledged by state reads before releasing.
        model.discardControllerEvents(controller, scope == .pointer);
        try model.beginDelivery(.cleanup, model.remote_presses.len + 5);
        if (scope == .all) {
            for (&model.remote_presses) |*slot| if (slot.*) |press| {
                if (press.controller != controller) continue;
                var binding = press.binding;
                binding.mods = 0;
                binding.repeat = false;
                if (!model.keyHeldElsewhere(binding.scancode, controller, press.identity)) model.appendRemote(controller, .{ .key_up = binding });
                slot.* = null;
            };
        }
        if (model.remote_controller == controller) {
            for (1..6) |number| {
                const mask = @as(u32, 1) << @as(u5, @intCast(number - 1));
                if (model.remote_buttons & mask == 0) continue;
                model.remote_buttons &= ~mask;
                if ((model.native_buttons | model.mouse_buttons) & mask == 0) model.appendRemote(controller, .{ .mouse_button = .{
                    .x = model.last_mouse_x,
                    .y = model.last_mouse_y,
                    .precise_x = model.precise_mouse_x,
                    .precise_y = model.precise_mouse_y,
                    .button = @intCast(number),
                    .pressed = false,
                    .buttons = model.mouse_buttons | model.remote_buttons | model.native_buttons,
                } });
            }
            model.remote_controller = 0;
        }
    }

    const Point = struct { x: i32, y: i32, precise_x: ?f32 = null, precise_y: ?f32 = null };
    fn point(self: *const Executor, position: wire.Position) !Point {
        if (position.revision != self.geometry.revision) return error.StaleGeometry;
        if (!std.math.isFinite(position.x) or !std.math.isFinite(position.y) or position.x < 0 or position.y < 0 or position.x >= self.geometry.width or position.y >= self.geometry.height) return error.InvalidPosition;
        return .{ .x = @intFromFloat(position.x), .y = @intFromFloat(position.y), .precise_x = @floatCast(position.x), .precise_y = @floatCast(position.y) };
    }
    fn move(model: *input.InputModel, point_value: Point) void {
        model.last_mouse_x = point_value.x;
        model.last_mouse_y = point_value.y;
        model.precise_mouse_x = point_value.precise_x;
        model.precise_mouse_y = point_value.precise_y;
        model.mouse_activity = true;
    }

    pub fn stopTransport(self: *Executor) void {
        if (self.thread) |thread| {
            self.stopped.store(true, .release);
            thread.join();
            self.thread = null;
            self.listener.?.deinit();
            self.listener = null;
        }
    }

    /// App teardown cannot deliver further SDL events. Never call that confirmed
    /// cleanup: close transport, settle uncertain work, retain a quarantined target.
    pub fn close(self: *Executor) !void {
        self.stopTransport();
        if (self.pending) |item| {
            self.pending = null;
            var work = item;
            try work.complete(.uncertain);
        }
        // Stopping the servers invalidates queued input. ABI 0.7 serializes
        // the remaining cleanup behind the in-flight work settled above, so
        // there is at most one cleanup item here. Failure retains the target.
        if (try self.target.next()) |item| {
            var work = item;
            try work.complete(.uncertain);
        }
        try self.target.deinit();
        self.allocator.destroy(self);
    }
};

pub fn modifiers(value: wire.Modifiers) u16 {
    var result: u16 = 0;
    if (value.shift) result |= 0x0001;
    if (value.control) result |= 0x0040;
    if (value.alt) result |= 0x0100;
    if (value.super or value.meta) result |= 0x0400;
    if (value.alt_graph) result |= 0x4000;
    if (value.caps_lock) result |= 0x2000;
    if (value.num_lock) result |= 0x1000;
    return result;
}

fn sdlButton(button: wire.Button) u8 {
    return switch (button) {
        .primary => 1,
        .secondary => 3,
        .auxiliary => 2,
        .back => 4,
        .forward => 5,
    };
}
