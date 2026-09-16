//! Source-presenter adapter. Terminal-derived keys are logical, never guessed
//! physical positions. Admission and execution completion remain separate.
const std = @import("std");
const os = @import("platform");
const wire = @import("jackstay").input;
const input = @import("input.zig");

pub const Controller = struct {
    client: wire.Client,
    admission: wire.Admission,
    resetting: bool = false,
    closed: bool = false,
    closing: bool = false,
    clean: bool = false,
    focus_generation: u64 = 0,
    mapping_generation: ?u64 = null,
    next_press: u64 = 1,
    presses: [256]?Press = @splat(null),
    buttons: u8 = 0,
    pointer: wire.Position = .{ .x = 0, .y = 0, .revision = 1 },
    outstanding: std.ArrayList(Pending) = .empty,
    const Press = struct { code: i32, id: u64, confirmed: bool = false, releasing: bool = false };
    const Pending = struct { sequence: u64, press: ?u64 = null, action: wire.Action = .down };
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
                for (0..5) |i| if (self.buttons & (@as(u8, 1) << @intCast(i)) != 0) {
                    try self.send(.{ .button = .{ .button = @enumFromInt(i + 1), .action = .up, .position = self.pointer } });
                };
                self.buttons = 0;
                model.discardStalePointerInput();
            }
        }
        self.mapping_generation = model.mapping_generation;
        // Bound work in the transport by actual results, without waiting here.
        while (self.outstanding.items.len < 32) {
            const event = model.pop() orelse break;
            self.forward(event, model.target) catch |err| {
                std.log.warn("Jackstay input mapping/send failed: {any}", .{err});
                if (err != error.Unsupported) try self.reset(model);
                if (self.resetting) break;
            };
        }
    }
    fn forward(self: *Controller, event: input.InputEvent, target: input.Target) !void {
        const caps = self.admission.capabilities;
        switch (event) {
            .key_down, .key_up => |key| {
                if (!caps.logical) return error.Unsupported;
                var buf: [4]u8 = undefined;
                const name = try logicalName(key.keycode, &buf);
                var slot: ?*?Press = null;
                for (&self.presses) |*entry| if (entry.* != null and entry.*.?.code == key.keycode and !entry.*.?.releasing) {
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
                    if (self.next_press == std.math.maxInt(u64)) return error.Capacity;
                    slot.?.* = .{ .code = key.keycode, .id = self.next_press };
                    self.next_press += 1;
                }
                try self.send(.{ .key = .{ .kind = .logical, .name = name, .press = slot.?.*.?.id, .action = action, .modifiers = modifiers(key.mods) } });
                const pending = &self.outstanding.items[self.outstanding.items.len - 1];
                pending.press = slot.?.*.?.id;
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
                const mask = @as(u8, 1) << @as(u3, @intCast(@intFromEnum(number) - 1));
                if (!button.pressed and self.buttons & mask == 0) return;
                self.pointer = self.position(button.x, button.y, target);
                try self.send(.{ .button = .{ .button = number, .action = if (button.pressed) .down else .up, .position = self.pointer } });
                if (button.pressed) self.buttons |= mask else self.buttons &= ~mask;
            },
            .mouse_wheel => |wheel| {
                if (!caps.scroll) return error.Unsupported;
                self.pointer = self.position(wheel.mouse_x, wheel.mouse_y, target);
                try self.send(.{ .scroll = .{ .x = wheel.precise_x orelse @as(f32, @floatFromInt(wheel.x)), .y = -(wheel.precise_y orelse @as(f32, @floatFromInt(wheel.y))), .unit = .line, .position = self.pointer } });
            },
        }
    }
    fn position(self: *const Controller, x: i32, y: i32, target: input.Target) wire.Position {
        const g = self.admission.geometry;
        return .{ .x = @as(f64, @floatFromInt(std.math.clamp(x, 0, target.w - 1))) * g.width / @as(f64, @floatFromInt(target.w)), .y = @as(f64, @floatFromInt(std.math.clamp(y, 0, target.h - 1))) * g.height / @as(f64, @floatFromInt(target.h)), .revision = g.revision };
    }
};

fn modifiers(mods: u16) wire.Modifiers {
    return .{ .shift = mods & 0x3 != 0, .control = mods & 0xc0 != 0, .alt = mods & 0x300 != 0, .super = mods & 0xc00 != 0, .caps_lock = mods & 0x2000 != 0, .num_lock = mods & 0x1000 != 0 };
}
fn logicalName(code: i32, buf: *[4]u8) ![]const u8 {
    return switch (code) {
        13 => "Enter",
        27 => "Escape",
        8 => "Backspace",
        9 => "Tab",
        127 => "Delete",
        (1 << 30) | 73 => "Insert",
        (1 << 30) | 74 => "Home",
        (1 << 30) | 77 => "End",
        (1 << 30) | 75 => "PageUp",
        (1 << 30) | 78 => "PageDown",
        (1 << 30) | 79 => "ArrowRight",
        (1 << 30) | 80 => "ArrowLeft",
        (1 << 30) | 81 => "ArrowDown",
        (1 << 30) | 82 => "ArrowUp",
        else => blk: {
            if (code >= (1 << 30) + 58 and code <= (1 << 30) + 69) {
                const names = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };
                break :blk names[@intCast(code - (1 << 30) - 58)];
            }
            if (code < 32 or code > 0x10ffff) return error.Unsupported;
            const len = std.unicode.utf8Encode(@intCast(code), buf) catch return error.Unsupported;
            break :blk buf[0..len];
        },
    };
}
