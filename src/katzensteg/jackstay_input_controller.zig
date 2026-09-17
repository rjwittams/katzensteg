//! Source-presenter adapter. Keys leave the model in the native vocabulary and
//! go on the wire unchanged, with the press identity the model assigned.
//! Admission and execution completion remain separate.
const std = @import("std");
const os = @import("platform");
const wire = @import("jackstay").input;
const input = @import("input.zig");
const native_key = @import("native_key.zig");

pub const Controller = struct {
    client: wire.Client,
    admission: wire.Admission,
    resetting: bool = false,
    closed: bool = false,
    closing: bool = false,
    clean: bool = false,
    focus_generation: u64 = 0,
    overflow_generation: u64 = 0,
    pointer_generation: u64 = 0,
    mapping_generation: ?u64 = null,
    presses: [256]?Press = @splat(null),
    buttons: u8 = 0,
    pointer: wire.Position = .{ .x = 0, .y = 0, .revision = 1 },
    outstanding: std.ArrayList(Pending) = .empty,
    const Press = struct { id: u64, confirmed: bool = false, releasing: bool = false };
    const Pending = struct { sequence: u64, press: ?u64 = null, button: ?wire.Button = null, pointer_generation: u64 = 0, action: wire.Action = .down };
    const allocator = std.heap.c_allocator;

    pub fn init(client: wire.Client) !Controller {
        return .{ .client = client, .admission = try client.describe() };
    }
    pub fn deinit(self: *Controller) void {
        self.client.deinit();
        self.outstanding.deinit(allocator);
    }
    pub fn close(self: *Controller) void {
        if (!self.closing and !self.closed) self.client.close();
        self.closing = true;
    }
    pub fn poll(self: *Controller, model: *input.InputModel) !void {
        while (try self.client.poll()) |status| switch (status) {
            .completed => |result| {
                const release_failed = self.completed(result.sequence, result.outcome == .executed);
                if (result.outcome != .executed) {
                    std.log.warn("Jackstay input sequence={d} outcome={s}", .{ result.sequence, @tagName(result.outcome) });
                    if (result.outcome == .partial or result.outcome == .uncertain) {
                        model.discardLocalInput(false);
                        // Jackstay already initiated an execution-failure close.
                        // Wait for its cleanup result; do not send a second close.
                        self.closing = true;
                    } else if (release_failed) try self.reset(model);
                }
            },
            .refused => |result| {
                const release_failed = self.completed(result.sequence, false);
                std.log.warn("Jackstay input sequence={d} refused={d}", .{ result.sequence, result.result });
                if (release_failed) try self.reset(model);
            },
            .reset => |result| {
                const all = self.resetting;
                self.admission.epoch = result.epoch;
                self.admission.geometry = result.geometry;
                self.resetting = false;
                self.buttons = 0;
                self.pointer_generation +%= 1;
                self.pointer.revision = result.geometry.revision;
                model.discardLocalInput(!all);
                if (all) {
                    self.presses = @splat(null);
                    self.outstanding.clearRetainingCapacity();
                }
                // Geometry preserves queued keyboard work. Keep its result
                // ledger, including releases that have not settled yet. A stale
                // refused release triggers recovery cleanup, never key replay.

            },
            .closed => |result| {
                self.closed = true;
                self.clean = result.clean;
                model.discardLocalInput(false);
                std.log.info("Jackstay input closed clean={any} reason={s}", .{ result.clean, @tagName(result.reason) });
            },
        };
    }
    fn completed(self: *Controller, sequence: u64, executed: bool) bool {
        var release_failed = false;
        for (self.outstanding.items, 0..) |item, i| if (item.sequence == sequence) {
            if (item.press) |id| for (&self.presses) |*entry| {
                if (entry.*) |*press| if (press.id == id) {
                    if (item.action == .down) {
                        if (executed) press.confirmed = true else entry.* = null;
                    } else if (item.action == .up) {
                        if (executed) entry.* = null else release_failed = press.confirmed;
                    }
                    break;
                };
            };
            if (item.button) |button| {
                if (item.pointer_generation == self.pointer_generation) {
                    const mask = buttonMask(button);
                    if (executed) {
                        if (item.action == .down) self.buttons |= mask else self.buttons &= ~mask;
                    } else if (item.action == .up) release_failed = self.buttons & mask != 0;
                }
            }
            _ = self.outstanding.swapRemove(i);
            return release_failed;
        };
        return false;
    }
    fn send(self: *Controller, event: wire.Event) !void {
        try self.outstanding.ensureUnusedCapacity(allocator, 1);
        const sequence = try self.client.send(event);
        self.outstanding.appendAssumeCapacity(.{ .sequence = sequence });
    }
    fn reset(self: *Controller, model: *input.InputModel) !void {
        model.discardLocalInput(false);
        self.presses = @splat(null);
        self.buttons = 0;
        self.pointer_generation +%= 1;
        if (!self.resetting and !self.closed) {
            self.client.reset() catch |err| switch (err) {
                error.Closed => {
                    self.close();
                    return;
                },
                else => return err,
            };
            self.resetting = true;
        }
    }
    pub fn pump(self: *Controller, model: *input.InputModel) !void {
        try self.poll(model);
        if (self.closed or self.closing) {
            model.discardLocalInput(false);
            return;
        }
        if (model.overflow_generation != self.overflow_generation) {
            self.overflow_generation = model.overflow_generation;
            model.discardLocalInput(false);
            std.log.warn("Jackstay presenter input capacity exhausted; ending controller", .{});
            self.close();
            return;
        }
        if (model.focus_generation != self.focus_generation) {
            self.focus_generation = model.focus_generation;
            try self.reset(model);
        }
        if (self.resetting) {
            model.discardLocalInput(false);
            return;
        }
        if (self.mapping_generation) |previous| {
            if (previous != model.mapping_generation) {
                // A viewer mapping change releases pointer contributions only.
                // This is an ordinary release, not application drag cancellation.
                // Settle prior button transitions before releasing, and reserve
                // room for all five possible releases within the transport bound.
                if (self.pendingButtons() != 0 or self.outstanding.items.len > 27) return;
                for (0..5) |i| if (self.buttons & (@as(u8, 1) << @intCast(i)) != 0) {
                    try self.sendButton(@enumFromInt(i + 1), .up);
                };
                model.discardStalePointerInput();
            }
        }
        self.mapping_generation = model.mapping_generation;
        // Bound work in the transport by actual results, without waiting here.
        while (self.outstanding.items.len < 32) {
            const next = model.peek() orelse break;
            // Serialize transitions for a button until its execution result is
            // known. A later down must not hide a failed release of the same hold.
            if (next == .mouse_button and self.pendingButtons() != 0) break;
            const event = model.pop().?;
            self.forward(event, model.target) catch |err| {
                std.log.warn("Jackstay input mapping/send failed: {any}", .{err});
                if (err == error.Capacity or err == error.OutOfMemory) {
                    model.discardLocalInput(false);
                    self.close();
                } else if (err != error.Unsupported) try self.reset(model);
                if (self.resetting or self.closing) break;
            };
        }
    }
    fn forward(self: *Controller, event: input.InputEvent, target: input.Target) !void {
        const caps = self.admission.capabilities;
        switch (event) {
            .key_down, .key_up => |key| {
                const native = &key.native;
                if (native.name.isEmpty() or native.press == 0) return error.Unsupported;
                const supported = switch (native.kind) {
                    .physical => caps.physical,
                    .logical => caps.logical,
                };
                if (!supported) return error.Unsupported;
                var slot: ?*?Press = null;
                for (&self.presses) |*entry| if (entry.* != null and entry.*.?.id == native.press and !entry.*.?.releasing) {
                    slot = entry;
                    break;
                };
                const down = event == .key_down;
                if (!down and slot == null) return; // old release after reset
                const action: wire.Action = if (!down) .up else if (slot != null) .repeat else .down;
                if (slot == null) {
                    for (&self.presses) |*entry| if (entry.* == null) {
                        slot = entry;
                        break;
                    };
                    if (slot == null) return error.Capacity;
                    slot.?.* = .{ .id = native.press };
                }
                try self.send(.{ .key = .{ .kind = wireKind(native.kind), .name = native.name.slice(), .press = native.press, .action = action, .modifiers = @bitCast(native.modifiers) } });
                const pending = &self.outstanding.items[self.outstanding.items.len - 1];
                pending.press = native.press;
                pending.action = action;
                if (!down) slot.?.*.?.releasing = true;
            },
            .text => |text| {
                if (!caps.text) return error.Unsupported;
                try self.send(.{ .text = text.bytes() });
            },
            .text_commit => |text| {
                if (!caps.text) return error.Unsupported;
                try self.send(.{ .text = text });
            },
            .mouse_motion => |motion| {
                if (!caps.pointer) return error.Unsupported;
                self.pointer = self.position(motion.x, motion.y, target);
                try self.send(.{ .motion = self.pointer });
            },
            .mouse_button => |button| {
                if (!caps.pointer) return error.Unsupported;
                const number: wire.Button = switch (button.button) {
                    1 => .primary,
                    2 => .auxiliary,
                    3 => .secondary,
                    4 => .back,
                    5 => .forward,
                    else => return error.Unsupported,
                };
                const mask = buttonMask(number);
                if (!button.pressed and self.buttons & mask == 0) return;
                self.pointer = self.position(button.x, button.y, target);
                try self.sendButton(number, if (button.pressed) .down else .up);
            },
            .mouse_wheel => |wheel| {
                if (!caps.scroll) return error.Unsupported;
                self.pointer = self.position(wheel.mouse_x, wheel.mouse_y, target);
                try self.send(.{ .scroll = .{ .x = wheel.precise_x orelse @as(f32, @floatFromInt(wheel.x)), .y = -(wheel.precise_y orelse @as(f32, @floatFromInt(wheel.y))), .unit = .line, .position = self.pointer } });
            },
        }
    }
    fn buttonMask(button: wire.Button) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(button) - 1));
    }
    fn pendingButtons(self: *const Controller) u8 {
        var mask: u8 = 0;
        for (self.outstanding.items) |item| {
            if (item.button) |button| if (item.pointer_generation == self.pointer_generation) {
                mask |= buttonMask(button);
            };
        }
        return mask;
    }
    fn sendButton(self: *Controller, button: wire.Button, action: wire.Action) !void {
        try self.send(.{ .button = .{ .button = button, .action = action, .position = self.pointer } });
        const pending = &self.outstanding.items[self.outstanding.items.len - 1];
        pending.button = button;
        pending.action = action;
        pending.pointer_generation = self.pointer_generation;
    }
    fn position(self: *const Controller, x: i32, y: i32, target: input.Target) wire.Position {
        const g = self.admission.geometry;
        return .{ .x = @as(f64, @floatFromInt(std.math.clamp(x, 0, target.w - 1))) * g.width / @as(f64, @floatFromInt(target.w)), .y = @as(f64, @floatFromInt(std.math.clamp(y, 0, target.h - 1))) * g.height / @as(f64, @floatFromInt(target.h)), .revision = g.revision };
    }
};

fn wireKind(kind: native_key.Kind) wire.KeyKind {
    return switch (kind) {
        .physical => .physical,
        .logical => .logical,
    };
}
