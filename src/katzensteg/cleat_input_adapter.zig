//! Native input projection for cleat. State belongs to one session window;
//! the tty source and canonical input model remain unchanged.
const std = @import("std");
const native = @import("native_key.zig");
const keys = @import("terminal_keys.zig");
const framing = @import("wm_command_input.zig");
const c = @import("cleat").c;

pub fn modifiers(m: native.Modifiers) u16 {
    return (if (m.shift) @as(u16, c.CLEAT_MOD_SHIFT) else 0) |
        (if (m.control) @as(u16, c.CLEAT_MOD_CTRL) else 0) |
        (if (m.alt) @as(u16, c.CLEAT_MOD_ALT) else 0) |
        (if (m.super or m.meta) @as(u16, c.CLEAT_MOD_SUPER) else 0) |
        (if (m.caps_lock) @as(u16, c.CLEAT_MOD_CAPS_LOCK) else 0) |
        (if (m.num_lock) @as(u16, c.CLEAT_MOD_NUM_LOCK) else 0);
}

/// Event strings borrow decoded until the synchronous send completes.
pub fn keyEvent(decoded: *const keys.Decoded) c.cleat_input_event {
    const key = &decoded.key;
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_KEY;
    event.key_action = switch (key.action) {
        .down, .tap => c.CLEAT_KEY_ACTION_PRESS,
        .repeat => c.CLEAT_KEY_ACTION_REPEAT,
        .up => c.CLEAT_KEY_ACTION_RELEASE,
    };
    event.modifiers = modifiers(key.modifiers);
    event.physical_key = key.code.slice().ptr;
    event.physical_key_len = key.code.slice().len;
    if (key.kind == .logical and key.codepoint() != null) {
        event.key_kind = c.CLEAT_KEY_UNICODE_SCALAR;
        event.key_code = key.codepoint().?;
    } else {
        event.key_kind = c.CLEAT_KEY_CODE;
        event.text = key.name.slice().ptr;
        event.text_len = key.name.slice().len;
        for (named) |entry| if (std.mem.eql(u8, key.name.slice(), entry[0])) {
            event.key_kind = c.CLEAT_KEY_NAMED;
            event.key_code = entry[1];
            break;
        };
        if (key.name.slice().len > 1 and key.name.buf[0] == 'F') {
            const number = std.fmt.parseInt(u32, key.name.slice()[1..], 10) catch 0;
            if (number >= 1 and number <= 25) {
                event.key_kind = c.CLEAT_KEY_NAMED;
                event.key_code = c.CLEAT_KEY_FUNCTION_BASE + number;
            }
        }
    }
    if (key.action != .up) {
        const text = if (decoded.text_len != 0) decoded.text() else if (key.codepoint() != null and !key.modifiers.suppressText()) key.name.slice() else "";
        event.generated_text = text.ptr;
        event.generated_text_len = text.len;
    }
    return event;
}
const named = [_]struct { []const u8, u32 }{
    .{ "Enter", c.CLEAT_KEY_ENTER },          .{ "Escape", c.CLEAT_KEY_ESCAPE },
    .{ "Backspace", c.CLEAT_KEY_BACKSPACE },  .{ "Tab", c.CLEAT_KEY_TAB },
    .{ "Delete", c.CLEAT_KEY_DELETE },        .{ "Insert", c.CLEAT_KEY_INSERT },
    .{ "Home", c.CLEAT_KEY_HOME },            .{ "End", c.CLEAT_KEY_END },
    .{ "PageUp", c.CLEAT_KEY_PAGE_UP },       .{ "PageDown", c.CLEAT_KEY_PAGE_DOWN },
    .{ "ArrowUp", c.CLEAT_KEY_ARROW_UP },     .{ "ArrowDown", c.CLEAT_KEY_ARROW_DOWN },
    .{ "ArrowLeft", c.CLEAT_KEY_ARROW_LEFT }, .{ "ArrowRight", c.CLEAT_KEY_ARROW_RIGHT },
};

pub const Adapter = struct {
    held: [128]?native.Key = @splat(null),
    pasting: bool = false,
    paste: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Adapter, allocator: std.mem.Allocator) void {
        self.paste.deinit(allocator);
    }
    pub fn key(self: *Adapter, decoded: keys.Decoded, sink: anytype) !void {
        try sink.sendInput(keyEvent(&decoded));
        for (&self.held) |*entry| if (entry.*) |held| {
            if (held.sameKey(&decoded.key)) {
                if (decoded.key.action == .up) entry.* = null;
                return;
            }
        };
        if (decoded.key.action == .down or decoded.key.action == .repeat) {
            for (&self.held) |*entry| if (entry.* == null) {
                entry.* = decoded.key;
                return;
            };
            // Never send a press we cannot subsequently release.
            var release = decoded;
            release.key.action = .up;
            try sink.sendInput(keyEvent(&release));
        }
    }
    pub fn focus(self: *Adapter, active: bool, sink: anytype) !void {
        var event = std.mem.zeroes(c.cleat_input_event);
        event.kind = c.CLEAT_INPUT_FOCUS;
        event.focused = active;
        try sink.sendInput(event);
        if (!active) {
            for (&self.held) |*entry| if (entry.*) |held| {
                const decoded = keys.Decoded{ .key = blk: {
                    var released = held;
                    released.action = .up;
                    break :blk released;
                } };
                try sink.sendInput(keyEvent(&decoded));
                entry.* = null;
            };
            self.pasting = false;
            self.paste.clearRetainingCapacity();
        }
    }
    /// The WM already frames input. Paste body chunks can be single bytes;
    /// retain them until the terminator so cleat receives one paste event.
    pub fn bytes(self: *Adapter, allocator: std.mem.Allocator, input: []const u8, reports_events: bool, sink: anytype) !void {
        if (std.mem.eql(u8, input, "\x1b[200~")) {
            self.pasting = true;
            self.paste.clearRetainingCapacity();
            return;
        }
        if (self.pasting) {
            if (std.mem.eql(u8, input, "\x1b[201~")) {
                var event = std.mem.zeroes(c.cleat_input_event);
                event.kind = c.CLEAT_INPUT_PASTE;
                event.text = self.paste.items.ptr;
                event.text_len = self.paste.items.len;
                try sink.sendInput(event);
                self.pasting = false;
                self.paste.clearRetainingCapacity();
            } else try self.paste.appendSlice(allocator, input);
            return;
        }
        var offset: usize = 0;
        while (offset < input.len) {
            const len = framing.tokenLen(input[offset..], true) orelse return;
            if (framing.decode(input[offset..][0..len], reports_events)) |report| {
                if (report == .key) try self.key(report.key, sink);
            }
            offset += len;
        }
    }
};

const Recorder = struct {
    events: [300]c.cleat_input_event = undefined,
    count: usize = 0,
    text: [300][128]u8 = undefined,
    fn sendInput(self: *Recorder, event: c.cleat_input_event) !void {
        self.events[self.count] = event;
        if (event.text_len > 0) {
            @memcpy(self.text[self.count][0..event.text_len], event.text[0..event.text_len]);
            self.events[self.count].text = &self.text[self.count];
        }
        self.count += 1;
    }
};

// The input design requires printable and named native keys, all reported
// actions, modifiers, position and text. Enumerate each action and named key.
test "native keys preserve meaning position modifiers action and text" {
    var decoded = keys.Decoded{ .key = native.Key.character('é') };
    decoded.key.code = try native.Name.init("KeyE");
    decoded.key.modifiers = .{ .shift = true, .control = true, .alt = true, .super = true, .caps_lock = true, .num_lock = true };
    for ([_]native.Action{ .tap, .down, .repeat, .up }, [_]u32{ c.CLEAT_KEY_ACTION_PRESS, c.CLEAT_KEY_ACTION_PRESS, c.CLEAT_KEY_ACTION_REPEAT, c.CLEAT_KEY_ACTION_RELEASE }) |action, expected| {
        decoded.key.action = action;
        const event = keyEvent(&decoded);
        try std.testing.expectEqual(expected, event.key_action);
        try std.testing.expectEqual(@as(u32, 'é'), event.key_code);
        try std.testing.expectEqual(@as(u16, 63), event.modifiers);
        try std.testing.expectEqualStrings("KeyE", event.physical_key[0..event.physical_key_len]);
        try std.testing.expectEqual(@as(usize, 0), event.generated_text_len);
    }
    decoded.key.modifiers = .{};
    decoded.key.action = .tap;
    try std.testing.expectEqualStrings("é", keyEvent(&decoded).generated_text[0..keyEvent(&decoded).generated_text_len]);
    for (named) |entry| {
        decoded.key = try native.Key.logical(entry[0]);
        try std.testing.expectEqual(entry[1], keyEvent(&decoded).key_code);
        try std.testing.expectEqual(@as(u32, c.CLEAT_KEY_NAMED), keyEvent(&decoded).key_kind);
    }
    decoded.key = try native.Key.physical("ShiftLeft");
    try std.testing.expectEqual(@as(u32, c.CLEAT_KEY_CODE), keyEvent(&decoded).key_kind);
}

// Whole taps send one press and are never held. Focus loss releases every
// down once, with the original identity, even after modifiers have changed.
test "focus loss releases held keys but never whole taps or already released keys" {
    var adapter = Adapter{};
    defer adapter.deinit(std.testing.allocator);
    var recorder = Recorder{};
    try adapter.bytes(std.testing.allocator, "a\x1b[A", false, &recorder);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try adapter.focus(false, &recorder);
    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    for (0..26) |i| {
        var key = native.Key.character(@intCast('a' + i));
        key.action = .down;
        try adapter.key(.{ .key = key }, &recorder);
        key.action = .repeat;
        try adapter.key(.{ .key = key }, &recorder);
        if (i % 2 == 0) {
            key.action = .up;
            try adapter.key(.{ .key = key }, &recorder);
        }
    }
    const before = recorder.count;
    try adapter.focus(false, &recorder);
    try std.testing.expectEqual(before + 14, recorder.count);
    for (recorder.events[before + 1 .. recorder.count], 0..) |event, i| {
        try std.testing.expectEqual(@as(u32, c.CLEAT_KEY_ACTION_RELEASE), event.key_action);
        try std.testing.expectEqual(@as(u32, @intCast('b' + i * 2)), event.key_code);
    }
    try adapter.focus(false, &recorder);
    try std.testing.expectEqual(before + 15, recorder.count);
}

pub const Pointer = struct { button: i32, pressed: bool, col: u16, row: u16, x: f32, y: f32 };
pub fn mouseEvent(pointer: Pointer) c.cleat_input_event {
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_MOUSE;
    event.cell_col = pointer.col;
    event.cell_row = pointer.row;
    event.x_px = pointer.x;
    event.y_px = pointer.y;
    event.modifiers = (if (pointer.button & 4 != 0) @as(u16, c.CLEAT_MOD_SHIFT) else 0) |
        (if (pointer.button & 8 != 0) @as(u16, c.CLEAT_MOD_ALT) else 0) |
        (if (pointer.button & 16 != 0) @as(u16, c.CLEAT_MOD_CTRL) else 0);
    const button = pointer.button & 3;
    if (pointer.button & 64 != 0) {
        event.mouse_kind = c.CLEAT_MOUSE_WHEEL;
        if (button < 2) event.wheel_delta_y = if (button == 0) 1 else -1 else event.wheel_delta_x = if (button == 2) 1 else -1;
    } else {
        event.mouse_kind = if (pointer.button & 32 != 0) c.CLEAT_MOUSE_MOVE else if (pointer.pressed and button != 3) c.CLEAT_MOUSE_PRESS else c.CLEAT_MOUSE_RELEASE;
        event.mouse_button = if (button == 3) c.CLEAT_MOUSE_BUTTON_NONE else @intCast(button + 1);
        if (button != 3 and pointer.pressed) event.mouse_buttons = @as(u16, 1) << @as(u4, @intCast(button));
    }
    return event;
}

// Paste preserves literal bytes (including attention, escapes and UTF-8) as
// one structured paste; a blur discards an unfinished paste.
test "paste is one event and unfinished paste is discarded on blur" {
    var adapter = Adapter{};
    defer adapter.deinit(std.testing.allocator);
    var recorder = Recorder{};
    try adapter.bytes(std.testing.allocator, "\x1b[200~", false, &recorder);
    const body = "a\x1d\x1béc";
    for (body) |byte| try adapter.bytes(std.testing.allocator, &.{byte}, false, &recorder);
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
    try adapter.bytes(std.testing.allocator, "\x1b[201~", false, &recorder);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(u32, c.CLEAT_INPUT_PASTE), recorder.events[0].kind);
    try std.testing.expectEqualStrings(body, recorder.events[0].text[0..recorder.events[0].text_len]);
    try adapter.bytes(std.testing.allocator, "\x1b[200~", false, &recorder);
    try adapter.bytes(std.testing.allocator, "discard", false, &recorder);
    try adapter.focus(false, &recorder);
    try adapter.bytes(std.testing.allocator, "\x1b[201~", false, &recorder);
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
}

// Content coordinates stay zero-based in cells and pixels. Generate every
// SGR button/action/modifier combination, including wheel and no-button move.
test "pointer projection preserves coordinates modifiers and actions" {
    for (0..128) |button| {
        for ([_]bool{ false, true }) |pressed| {
            const event = mouseEvent(.{ .button = @intCast(button), .pressed = pressed, .col = 3, .row = 4, .x = 31.5, .y = 82.25 });
            try std.testing.expectEqual(@as(u16, 3), event.cell_col);
            try std.testing.expectEqual(@as(u16, 4), event.cell_row);
            try std.testing.expectEqual(@as(f32, 31.5), event.x_px);
            try std.testing.expectEqual(@as(f32, 82.25), event.y_px);
            try std.testing.expectEqual(@as(u16, @intCast(((button & 4) >> 2) | ((button & 8) >> 1) | ((button & 16) >> 3))), event.modifiers);
            const expected: u32 = if (button & 64 != 0) c.CLEAT_MOUSE_WHEEL else if (button & 32 != 0) c.CLEAT_MOUSE_MOVE else if (pressed and button & 3 != 3) c.CLEAT_MOUSE_PRESS else c.CLEAT_MOUSE_RELEASE;
            try std.testing.expectEqual(expected, event.mouse_kind);
        }
    }
}

// Associated text and physical position are independent of logical meaning.
// A release may report a different shifted meaning; position pairs the press.
test "associated text survives projection and releases pair by position" {
    var adapter = Adapter{};
    defer adapter.deinit(std.testing.allocator);
    var recorder = Recorder{};
    var decoded = keys.Decoded{ .key = native.Key.character('z'), .text_len = 1 };
    decoded.text_buf[0] = 'Z';
    decoded.key.code = try native.Name.init("KeyW");
    decoded.key.modifiers.shift = true;
    decoded.key.action = .down;
    const event = keyEvent(&decoded);
    try std.testing.expectEqualStrings("Z", event.generated_text[0..event.generated_text_len]);
    try std.testing.expectEqualStrings("KeyW", event.physical_key[0..event.physical_key_len]);
    try adapter.key(decoded, &recorder);
    try adapter.key(decoded, &recorder); // Duplicate down must not add another held key.
    decoded.key = native.Key.character('Z');
    decoded.key.code = try native.Name.init("KeyW");
    decoded.key.action = .up;
    try adapter.key(decoded, &recorder);
    try adapter.focus(false, &recorder);
    try std.testing.expectEqual(@as(usize, 4), recorder.count);
    try std.testing.expectEqual(@as(usize, 0), keyEvent(&decoded).generated_text_len);
}
