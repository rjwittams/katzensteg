const std = @import("std");
const native = @import("native_key.zig");
const keys = @import("terminal_keys.zig");
const binding = @import("command_key.zig");

pub const PointerRoute = enum { application, window, consume };

pub const Event = union(enum) {
    forward: []u8,
    pointer: []u8,
    focus: bool,
    command: binding.Command,
    prompt_key: native.Key,
};

/// Desktop input ownership, independent of SDL and presentation. Raw bytes are
/// retained only for forwarding; all command decisions use native keys.
pub const Model = struct {
    allocator: std.mem.Allocator,
    attention: ?u8,
    armed: bool = false,
    hint: bool = false,
    prompt: bool = false,
    keyboard_flags: u32 = 0,
    pending: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    paste: bool = false,
    mouse_buttons: u32 = 0,
    window_pointer: bool = false,
    blocked_buttons: u32 = 0,
    menu_press: ?@import("command_menu.zig").Action = null,
    drop_paste: bool = false,
    consumed: [128]?native.Key = @splat(null),
    held: [128]?native.Key = @splat(null),
    events: [3]Event = undefined,
    event_len: usize = 0,
    event_offset: usize = 0,
    literal: [64]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, attention: ?u8) Model {
        return .{ .allocator = allocator, .attention = attention };
    }
    pub fn deinit(self: *Model) void {
        self.pending.deinit(self.allocator);
    }
    pub fn feed(self: *Model, bytes: []const u8) !void {
        const rest = self.pending.items[self.offset..];
        std.mem.copyForwards(u8, self.pending.items, rest);
        self.pending.items.len = rest.len;
        self.offset = 0;
        if (self.pending.items.len + bytes.len > 65536) return error.InputTooLong;
        try self.pending.appendSlice(self.allocator, bytes);
    }
    fn push(self: *Model, event: Event) void {
        self.events[self.event_len] = event;
        self.event_len += 1;
    }
    fn slot(presses: *[128]?native.Key, key: native.Key) ?*?native.Key {
        for (presses) |*entry| if (entry.*) |held| {
            if (held.sameKey(&key)) return entry;
        };
        return null;
    }
    fn remember(presses: *[128]?native.Key, key: native.Key) void {
        if (key.action == .tap or slot(presses, key) != null) return;
        for (presses) |*entry| if (entry.* == null) {
            entry.* = key;
            return;
        };
    }
    fn blurKeys(self: *Model) void {
        for (&self.held) |*entry| if (entry.*) |key| {
            remember(&self.consumed, key);
            entry.* = null;
        };
    }

    pub fn blur(self: *Model) void {
        self.blurKeys();
        self.blocked_buttons |= self.mouse_buttons;
        if (self.window_pointer) self.blocked_buttons |= 1;
        self.window_pointer = false;
        self.mouse_buttons = 0;
        self.menu_press = null;
    }

    pub fn focusByClick(self: *Model) void {
        self.blurKeys();
        // The current left press is being delivered to the newly focused
        // window. Keep its release paired there; retire any older buttons.
        self.blocked_buttons |= self.mouse_buttons & ~@as(u32, 1);
        self.mouse_buttons &= 1;
    }

    pub fn routePointer(self: *Model, button: i32, pressed: bool, hit: ?@import("command_menu.zig").Action, chrome: bool) PointerRoute {
        // Own the entire chrome gesture, even when it crosses content or the
        // menu. A press held before a focus change cannot start a new drag.
        if (self.window_pointer) {
            if (button & 64 != 0) return .consume;
            if (!pressed and (button & 3 == 0 or button & 3 == 3)) {
                self.window_pointer = false;
                return .window;
            }
            return if (button & 3 == 0) .window else .consume;
        }
        if (chrome and hit == null and pressed and button & (32 | 64 | 3) == 0 and (self.blocked_buttons | self.mouse_buttons) & 1 == 0) {
            self.window_pointer = true;
            return .window;
        }
        if (button & (32 | 64) != 0) return if (self.armed or self.prompt or self.blocked_buttons != 0) .consume else .application;
        const index: u5 = @intCast(button & 3);
        const mask: u32 = @as(u32, 1) << index;
        const consumed = self.armed or self.prompt or self.blocked_buttons & mask != 0 or (index == 3 and self.blocked_buttons != 0);
        if (pressed and index != 3) {
            if (consumed) self.blocked_buttons |= mask else self.mouse_buttons |= mask;
            if (self.armed and index == 0) self.menu_press = hit;
        } else {
            if (index == 3) {
                self.blocked_buttons = 0;
                self.mouse_buttons = 0;
            } else {
                self.blocked_buttons &= ~mask;
                self.mouse_buttons &= ~mask;
            }
            if (index == 0 or index == 3) {
                const action = self.menu_press;
                self.menu_press = null;
                if (self.armed and action != null and action == hit) {
                    self.armed = false;
                    self.hint = false;
                    if (action.? == .quit) self.push(.{ .command = .quit });
                    self.push(.{ .focus = true });
                }
            }
        }
        return if (consumed) .consume else .application;
    }

    pub fn finishPrompt(self: *Model) void {
        self.prompt = false;
        self.push(.{ .focus = true });
    }
    pub fn next(self: *Model, flush_escape: bool) ?Event {
        while (true) {
            if (self.event_offset < self.event_len) {
                const event = self.events[self.event_offset];
                self.event_offset += 1;
                return event;
            }
            self.event_len = 0;
            self.event_offset = 0;
            const bytes = self.pending.items[self.offset..];
            if (bytes.len == 0) return null;
            if (self.paste) {
                const end = "\x1b[201~";
                if (bytes.len < end.len and std.mem.startsWith(u8, end, bytes)) return null;
                const len: usize = if (std.mem.startsWith(u8, bytes, end)) end.len else 1;
                self.offset += len;
                if (len == end.len) self.paste = false;
                if (!self.drop_paste) return .{ .forward = bytes[0..len] };
                continue;
            }
            const len = tokenLen(bytes, flush_escape) orelse return null;
            const token = bytes[0..len];
            self.offset += len;
            if (std.mem.eql(u8, token, "\x1b[200~")) {
                self.paste = true;
                self.drop_paste = self.armed or self.prompt;
                if (!self.drop_paste) return .{ .forward = token };
                continue;
            }
            if (std.mem.startsWith(u8, token, "\x1b[<")) return .{ .pointer = token };
            if (decode(token, self.keyboard_flags & 2 != 0)) |report| switch (report) {
                .protocol_flags => |flags| {
                    self.keyboard_flags = flags;
                    return .{ .forward = token };
                },
                .mouse_units => return .{ .forward = token },
                .key => |decoded| self.route(decoded.key, token),
            } else if (!self.armed and !self.prompt) return .{ .forward = token };
        }
    }
    fn route(self: *Model, key: native.Key, bytes: []u8) void {
        if (slot(&self.consumed, key)) |held| {
            if (key.action == .up) held.* = null;
            return;
        }
        if (self.prompt) {
            if (key.action == .up or key.action == .repeat) return;
            remember(&self.consumed, key);
            self.push(.{ .prompt_key = key });
            return;
        }
        const attention = if (self.attention) |prefix| binding.matches(prefix, key) else false;
        if (!self.armed and !attention) {
            if (key.action == .up) {
                const held = slot(&self.held, key) orelse return;
                held.* = null;
            } else if (key.action == .repeat and slot(&self.held, key) == null) return else remember(&self.held, key);
            self.push(.{ .forward = bytes });
            return;
        }
        if (key.action == .up or key.action == .repeat) return;
        remember(&self.consumed, key);
        if (!self.armed) {
            self.blur();
            self.armed = true;
            self.hint = false;
            self.push(.{ .focus = false });
            return;
        }
        const action = binding.decode(self.attention.?, key, .desktop);
        if (action == .unknown) {
            self.hint = true;
            return;
        }
        self.armed = false;
        self.hint = false;
        if (action == .literal) {
            self.push(.{ .focus = true });
            const literal = if (self.keyboard_flags & 2 != 0)
                std.fmt.bufPrint(&self.literal, "\x1b[{d};5:1u\x1b[{d};5:3u", .{ std.ascii.toLower(self.attention.?), std.ascii.toLower(self.attention.?) }) catch unreachable
            else blk: {
                self.literal[0] = self.attention.? & 0x1f;
                break :blk self.literal[0..1];
            };
            self.push(.{ .forward = literal });
        } else {
            if (action != .cancel) self.push(.{ .command = action });
            if (action == .launch) self.prompt = true else self.push(.{ .focus = true });
        }
    }
};

/// Frame complete terminal reports before routing, including split reads. A
/// standalone Escape is resolved by the host's idle tick; no prefix timeout.
fn tokenLen(bytes: []const u8, flush_escape: bool) ?usize {
    if (bytes[0] == 0x1b) {
        if (bytes.len == 1) return if (flush_escape) 1 else null;
        switch (bytes[1]) {
            '[' => {
                if (bytes.len >= 3 and bytes[2] == 'M') return if (bytes.len >= 6) 6 else null;
                for (bytes[2..], 2..) |byte, i| if (byte >= 0x40 and byte <= 0x7e) return i + 1;
                return null;
            },
            'O' => return if (bytes.len >= 3) 3 else null,
            '_', ']', 'P', '^' => {
                for (bytes[2..], 2..) |byte, i| {
                    if (byte == 7) return i + 1;
                    if (byte == '\\' and bytes[i - 1] == 0x1b) return i + 1;
                }
                return null;
            },
            else => return 2,
        }
    }
    if (bytes[0] == 0x9b) {
        for (bytes[1..], 1..) |byte, i| if (byte >= 0x40 and byte <= 0x7e) return i + 1;
        return null;
    }
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 1;
    return if (bytes.len >= len) len else null;
}

fn decode(bytes: []const u8, reports_events: bool) ?keys.Report {
    if (std.mem.startsWith(u8, bytes, "\x1b[") or bytes[0] == 0x9b) {
        const start: usize = if (bytes[0] == 0x9b) 1 else 2;
        return keys.decodeCsi(bytes[start .. bytes.len - 1], bytes[bytes.len - 1], reports_events);
    }
    if (std.mem.startsWith(u8, bytes, "\x1bO")) return keys.decodeCsi("", bytes[2], reports_events);
    var alt = false;
    var text = bytes;
    if (bytes[0] == 0x1b and bytes.len > 1) {
        alt = true;
        text = bytes[1..];
    }
    const first = text[0];
    var key = switch (first) {
        0x1b => native.Key.logical("Escape") catch unreachable,
        '\r', '\n' => native.Key.logical("Enter") catch unreachable,
        '\t' => native.Key.logical("Tab") catch unreachable,
        8, 127 => native.Key.logical("Backspace") catch unreachable,
        else => native.Key.character(if (first < 32) (if (first >= 1 and first <= 26) @as(u21, 'a') + first - 1 else @as(u21, first) + 64) else std.unicode.utf8Decode(text) catch return null),
    };
    key.action = .tap;
    key.modifiers.alt = alt;
    key.modifiers.control = first < 32 and first != 27 and first != 9 and first != 10 and first != 13 and first != 8;
    key.modifiers.shift = first >= 'A' and first <= 'Z';
    return .{ .key = .{ .key = key } };
}

test "desktop commands require attention and retain fragmented reports" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("qn\t");
    try std.testing.expectEqualStrings("q", model.next(false).?.forward);
    try std.testing.expectEqualStrings("n", model.next(false).?.forward);
    try std.testing.expectEqualStrings("\t", model.next(false).?.forward);
    try model.feed("\x1b[93;5:");
    try std.testing.expect(model.next(false) == null);
    try model.feed("1u\x1b[93;5:2u\x1b[93;5:3u\x1b[113u");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expectEqual(binding.Command.quit, model.next(false).?.command);
    try std.testing.expect(model.next(false).?.focus);
    try std.testing.expect(model.next(false) == null);
}

test "desktop doubled attention is a literal tap and command paste is discarded" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("\x1d\x1b[200~q\x1d\x1b\x1b[201~\x1d");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expect(model.next(false).?.focus);
    try std.testing.expectEqualStrings("\x1d", model.next(false).?.forward);
    try std.testing.expect(model.next(false) == null);
}

test "desktop binding override, disable, unknown hint and standalone Escape" {
    var model = Model.init(std.testing.allocator, 'A');
    defer model.deinit();
    try model.feed("\x1dq\x01x\x1b");
    try std.testing.expectEqualStrings("\x1d", model.next(false).?.forward);
    try std.testing.expectEqualStrings("q", model.next(false).?.forward);
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expect(model.next(false) == null);
    try std.testing.expect(model.armed and model.hint);
    try std.testing.expect(model.next(true).?.focus);
    model.attention = null;
    try model.feed("\x01q");
    try std.testing.expectEqualStrings("\x01", model.next(false).?.forward);
    try std.testing.expectEqualStrings("q", model.next(false).?.forward);
}

test "desktop focus barrier drops held repeats and releases after cancel" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("\x1b[119;1:1u\x1d\x1b[27u\x1b[119;1:2u\x1b[119;1:3u");
    try std.testing.expectEqualStrings("\x1b[119;1:1u", model.next(false).?.forward);
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expect(model.next(false).?.focus);
    try std.testing.expect(model.next(false) == null);
}

test "desktop launch prompt receives native kitty keys and consumes their releases" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("\x1dn\x1b[115;1:1u\x1b[115;1:3u\x1b[13;1:1u\x1b[13;1:3u");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expectEqual(binding.Command.launch, model.next(false).?.command);
    try std.testing.expectEqual(@as(?u21, 's'), model.next(false).?.prompt_key.codepoint());
    try std.testing.expectEqualStrings("Enter", model.next(false).?.prompt_key.name.slice());
    model.finishPrompt();
    try std.testing.expect(model.next(false).?.focus);
    try std.testing.expect(model.next(false) == null);
}

test "desktop mouse menu consumes releases across keyboard cancellation" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("\x1d");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, true, .cancel, false));
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, false, .cancel, false));
    try std.testing.expect(model.next(false).?.focus);
    try model.feed("\x1d");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, true, .quit, false));
    try model.feed("\x1b[27u");
    try std.testing.expect(model.next(false).?.focus);
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, false, .quit, false));
    try std.testing.expect(model.next(false) == null);
}

test "desktop click focus keeps the new click paired while retiring old keys" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try std.testing.expectEqual(PointerRoute.application, model.routePointer(0, true, null, false));
    model.focusByClick();
    try std.testing.expectEqual(PointerRoute.application, model.routePointer(0, false, null, false));
    try std.testing.expectEqual(@as(u32, 0), model.mouse_buttons);
}

test "desktop chrome owns drags through menu and content without resuming the application" {
    var model = Model.init(std.testing.allocator, ']');
    defer model.deinit();
    try model.feed("\x1d");
    try std.testing.expect(!model.next(false).?.focus);
    try std.testing.expectEqual(PointerRoute.window, model.routePointer(0, true, null, true));
    model.focusByClick();
    try std.testing.expectEqual(PointerRoute.window, model.routePointer(32, true, .quit, false));
    try std.testing.expectEqual(PointerRoute.window, model.routePointer(0, false, .quit, false));
    try std.testing.expect(model.armed);
    try std.testing.expect(model.next(false) == null);
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, true, null, false));
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(32, true, null, true));
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, false, null, true));
    // A drag interrupted by command entry is blocked until release.
    try std.testing.expectEqual(PointerRoute.window, model.routePointer(0, true, null, true));
    model.blur();
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(32, true, null, true));
    try std.testing.expectEqual(PointerRoute.consume, model.routePointer(0, false, null, true));
    try std.testing.expectEqual(PointerRoute.window, model.routePointer(0, true, null, true));
}
