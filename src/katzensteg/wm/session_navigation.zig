//! Per-window navigation policy; cleat owns all history and viewport state.
const std = @import("std");
const c = @import("cleat").c;
const input = @import("../cleat_input_adapter.zig");

pub const Navigation = struct {
    scrolling: [2]bool = .{ false, false },

    pub fn send(self: *Navigation, event: c.cleat_input_event, alternate: bool, rows: u16, sink: anytype) !void {
        if (event.kind == c.CLEAT_INPUT_KEY) {
            const page: ?usize = if (event.key_kind == c.CLEAT_KEY_NAMED and event.key_code == c.CLEAT_KEY_PAGE_UP) 0 else if (event.key_kind == c.CLEAT_KEY_NAMED and event.key_code == c.CLEAT_KEY_PAGE_DOWN) 1 else null;
            if (page) |index| {
                // A consumed down must never leak its release to the program,
                // even if modifiers or the active screen changed meanwhile.
                if (event.key_action == c.CLEAT_KEY_ACTION_RELEASE and self.scrolling[index]) {
                    self.scrolling[index] = false;
                    return;
                }
                const binding_mods = event.modifiers & (c.CLEAT_MOD_SHIFT | c.CLEAT_MOD_CTRL | c.CLEAT_MOD_ALT | c.CLEAT_MOD_SUPER);
                if (!alternate and binding_mods == c.CLEAT_MOD_SHIFT and event.key_action != c.CLEAT_KEY_ACTION_RELEASE) {
                    try sink.scrollViewport(c.CLEAT_VIEWPORT_COMMAND_DELTA_ROWS, if (index == 0) -@as(i32, rows) else @as(i32, rows));
                    self.scrolling[index] = true;
                    return;
                }
                if (event.key_action != c.CLEAT_KEY_ACTION_RELEASE) self.scrolling[index] = false;
            }
            // Always send bottom before the key: the mirror may still describe
            // the previous update when typing immediately follows scrolling.
            try sink.scrollViewport(c.CLEAT_VIEWPORT_COMMAND_BOTTOM, 0);
        }
        try sink.sendInput(event);
    }

    pub fn pointer(_: *Navigation, pointer_event: input.Pointer, sink: anytype) !void {
        const button = pointer_event.button & 3;
        if (pointer_event.pressed and pointer_event.button & 64 != 0 and button < 2)
            try sink.scrollViewport(c.CLEAT_VIEWPORT_COMMAND_DELTA_ROWS, if (button == 0) -3 else 3);
    }
};

const Recorder = struct {
    commands: [16]struct { kind: u32, delta: i32 } = undefined,
    count: usize = 0,
    inputs: usize = 0,
    pub fn scrollViewport(self: *@This(), kind: u32, delta: i32) !void {
        self.commands[self.count] = .{ .kind = kind, .delta = delta };
        self.count += 1;
    }
    pub fn sendInput(self: *@This(), _: c.cleat_input_event) !void {
        self.inputs += 1;
    }
};

// Enumerate screens, page directions, modifiers and reported actions. Only
// Shift+Page keys on the normal screen navigate; every forwarded key snaps back.
test "page bindings and program keys preserve viewport routing" {
    for ([_]bool{ false, true }) |alternate| for ([_]u16{ 0, c.CLEAT_MOD_SHIFT, c.CLEAT_MOD_SHIFT | c.CLEAT_MOD_CTRL, c.CLEAT_MOD_ALT }) |mods| for ([_]u32{ c.CLEAT_KEY_PAGE_UP, c.CLEAT_KEY_PAGE_DOWN, c.CLEAT_KEY_ENTER }) |code| for ([_]u32{ c.CLEAT_KEY_ACTION_PRESS, c.CLEAT_KEY_ACTION_REPEAT, c.CLEAT_KEY_ACTION_RELEASE }) |action| {
        var navigation = Navigation{};
        var recorder = Recorder{};
        var event = std.mem.zeroes(c.cleat_input_event);
        event.kind = c.CLEAT_INPUT_KEY;
        event.key_kind = c.CLEAT_KEY_NAMED;
        event.key_code = code;
        event.modifiers = mods;
        event.key_action = action;
        try navigation.send(event, alternate, 24, &recorder);
        const scroll = !alternate and mods == c.CLEAT_MOD_SHIFT and code != c.CLEAT_KEY_ENTER and action != c.CLEAT_KEY_ACTION_RELEASE;
        try std.testing.expectEqual(@as(usize, 1), recorder.count);
        try std.testing.expectEqual(@as(usize, if (scroll) 0 else 1), recorder.inputs);
        try std.testing.expectEqual(@as(u32, if (scroll) c.CLEAT_VIEWPORT_COMMAND_DELTA_ROWS else c.CLEAT_VIEWPORT_COMMAND_BOTTOM), recorder.commands[0].kind);
        try std.testing.expectEqual(@as(i32, if (scroll) (if (code == c.CLEAT_KEY_PAGE_UP) -24 else 24) else 0), recorder.commands[0].delta);
    };
}

// Consumed presses release locally after modifiers/screen changes; focus
// events and paste must retain their existing structured-input meaning.
test "navigation releases and non-key input" {
    var navigation = Navigation{};
    var recorder = Recorder{};
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_KEY;
    event.key_kind = c.CLEAT_KEY_NAMED;
    event.key_code = c.CLEAT_KEY_PAGE_UP;
    event.key_action = c.CLEAT_KEY_ACTION_PRESS;
    event.modifiers = c.CLEAT_MOD_SHIFT;
    try navigation.send(event, false, 1, &recorder);
    event.key_action = c.CLEAT_KEY_ACTION_RELEASE;
    event.modifiers = 0;
    try navigation.send(event, true, 1, &recorder);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(usize, 0), recorder.inputs);
    for ([_]u32{ c.CLEAT_INPUT_FOCUS, c.CLEAT_INPUT_PASTE }) |kind| {
        event.kind = kind;
        try navigation.send(event, false, 0, &recorder);
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqual(@as(usize, 2), recorder.inputs);
}

// Untracked vertical wheels move three rows regardless of modifiers; pointer
// buttons, motion, releases and horizontal wheels never navigate history.
test "untracked wheel directions and modifiers" {
    for (0..128) |button| for ([_]bool{ false, true }) |pressed| {
        var navigation = Navigation{};
        var recorder = Recorder{};
        try navigation.pointer(.{ .button = @intCast(button), .pressed = pressed, .col = 0, .row = 0, .x = 0, .y = 0 }, &recorder);
        const scroll = pressed and button & 64 != 0 and button & 3 < 2;
        try std.testing.expectEqual(@as(usize, if (scroll) 1 else 0), recorder.count);
        if (scroll) try std.testing.expectEqual(@as(i32, if (button & 3 == 0) -3 else 3), recorder.commands[0].delta);
    };
}
