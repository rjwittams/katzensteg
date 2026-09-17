const std = @import("std");
const native_key = @import("native_key.zig");

// Host-neutral structured keyboard input for embed-jsonl and HTTP hosts. The
// wire keeps its lowercase names; `toNative` converts them into the native
// key vocabulary at this edge. Terminal sources may still use bytes.
pub const KeyInput = struct {
    key: []const u8,
    action: enum { tap, down, up } = .tap,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,

    pub fn valid(self: KeyInput) bool {
        if (std.unicode.utf8ValidateSlice(self.key) and (std.unicode.utf8CountCodepoints(self.key) catch 0) == 1) return true;
        return namedLogical(self.key) != null;
    }

    pub const Native = struct {
        key: native_key.Key,
        text_buf: [4]u8 = undefined,
        text_len: u8 = 0,

        pub fn text(self: *const Native) []const u8 {
            return self.text_buf[0..self.text_len];
        }
    };

    pub fn toNative(self: KeyInput) !Native {
        var result = Native{ .key = .{} };
        if (namedLogical(self.key)) |name| {
            if (std.mem.eql(u8, name, " ")) {
                result.key = native_key.Key.character(' ');
                result.text_buf[0] = ' ';
                result.text_len = 1;
            } else {
                result.key = try native_key.Key.logical(name);
            }
        } else {
            var codepoint: u21 = std.unicode.utf8Decode(self.key) catch return error.InvalidKey;
            if (self.shift and codepoint < 0x80 and std.ascii.isLower(@intCast(codepoint))) codepoint = std.ascii.toUpper(@intCast(codepoint));
            result.key = native_key.Key.character(codepoint);
            result.text_len = std.unicode.utf8Encode(codepoint, &result.text_buf) catch return error.InvalidKey;
        }
        result.key.action = switch (self.action) {
            .tap => .tap,
            .down => .down,
            .up => .up,
        };
        result.key.modifiers = .{ .shift = self.shift, .control = self.ctrl, .alt = self.alt, .meta = self.meta };
        return result;
    }
};

/// The DOM logical key name for a host key name, or " " for the space bar.
pub fn namedLogical(key: []const u8) ?[]const u8 {
    const Entry = struct { []const u8, []const u8 };
    const names = [_]Entry{
        .{ "enter", "Enter" },       .{ "return", "Enter" },   .{ "escape", "Escape" },    .{ "backspace", "Backspace" }, .{ "tab", "Tab" },
        .{ "space", " " },           .{ "delete", "Delete" },  .{ "home", "Home" },        .{ "end", "End" },             .{ "pageup", "PageUp" },
        .{ "pagedown", "PageDown" }, .{ "left", "ArrowLeft" }, .{ "right", "ArrowRight" }, .{ "up", "ArrowUp" },          .{ "down", "ArrowDown" },
        .{ "insert", "Insert" },
    };
    for (names) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    if (key.len >= 2 and key[0] == 'f') {
        const n = std.fmt.parseInt(usize, key[1..], 10) catch return null;
        const function_names = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };
        if (n >= 1 and n <= function_names.len) return function_names[n - 1];
    }
    return null;
}

test "host key names convert to native keys with text and modifiers" {
    const up = try (KeyInput{ .key = "up", .action = .down, .ctrl = true }).toNative();
    try std.testing.expectEqualStrings("ArrowUp", up.key.name.slice());
    try std.testing.expectEqual(native_key.Action.down, up.key.action);
    try std.testing.expect(up.key.modifiers.control);
    try std.testing.expectEqual(@as(usize, 0), up.text().len);
    const shifted = try (KeyInput{ .key = "a", .shift = true }).toNative();
    try std.testing.expectEqualStrings("A", shifted.key.name.slice());
    try std.testing.expectEqualStrings("A", shifted.text());
    try std.testing.expect(shifted.key.modifiers.shift);
    const space = try (KeyInput{ .key = "space" }).toNative();
    try std.testing.expectEqualStrings(" ", space.text());
    const f10 = try (KeyInput{ .key = "f10", .action = .up }).toNative();
    try std.testing.expectEqualStrings("F10", f10.key.name.slice());
    try std.testing.expectEqual(native_key.Action.up, f10.key.action);
    const e_acute = try (KeyInput{ .key = "é" }).toNative();
    try std.testing.expectEqualStrings("é", e_acute.text());
    try std.testing.expect((KeyInput{ .key = "return" }).valid());
    try std.testing.expect(!(KeyInput{ .key = "not-a-key" }).valid());
    try std.testing.expect(!(KeyInput{ .key = "f13" }).valid());
}
