const std = @import("std");

// Host-neutral structured keyboard input. Terminal sources may still use bytes.
pub const KeyInput = struct {
    key: []const u8,
    action: enum { tap, down, up } = .tap,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,

    pub fn valid(self: KeyInput) bool {
        if (std.unicode.utf8ValidateSlice(self.key) and (std.unicode.utf8CountCodepoints(self.key) catch 0) == 1) return true;
        return namedScancode(self.key) != null;
    }
};

pub fn namedScancode(key: []const u8) ?i32 {
    const names = .{ "enter", "return", "escape", "backspace", "tab", "space", "delete", "home", "end", "pageup", "pagedown", "left", "right", "up", "down", "insert" };
    const scans = [_]i32{ 40, 40, 41, 42, 43, 44, 76, 74, 77, 75, 78, 80, 79, 82, 81, 73 };
    inline for (names, scans) |name, scan| if (std.mem.eql(u8, key, name)) return scan;
    if (key.len >= 2 and key[0] == 'f') {
        const n = std.fmt.parseInt(i32, key[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 57 + n;
    }
    return null;
}
