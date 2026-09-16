//! Resolve shared input at the SDL adapter boundary. Wire identities are DOM
//! codes/logical keys; SDL numbers never travel over the connection.
const std = @import("std");
const js = @import("jackstay");
const input = @import("input.zig");
const sdl = @import("katzensteg_sdl");
const is_sdl3 = @hasDecl(sdl, "SDL_PropertiesID");
const real_sdl = if (is_sdl3) @import("real_sdl3.zig") else @import("real_sdl.zig");

pub fn bind(key: js.input.Key) !input.KeyEvent {
    const mods = @import("jackstay_input_executor.zig").modifiers(key.modifiers);
    if (key.kind == .physical) {
        const scan = domScancode(key.name) orelse return error.Unsupported;
        const code = if (is_sdl3) real_sdl.SDL_GetKeyFromScancode(scan, mods, true) else real_sdl.SDL_GetKeyFromScancode(scan);
        return .{ .scancode = scan, .keycode = code, .mods = mods };
    }
    const code = try logicalKeycode(key.name);
    var implicit_mods: u16 = 0;
    const scan = if (is_sdl3) real_sdl.SDL_GetScancodeFromKey(code, &implicit_mods) else real_sdl.SDL_GetScancodeFromKey(code);
    // A logical character with no target binding is not a physical key or paste.
    if (scan == 0) return error.Unsupported;
    return .{ .scancode = scan, .keycode = code, .mods = mods };
}

pub fn domScancode(name: []const u8) ?i32 {
    if (name.len == 4 and std.mem.startsWith(u8, name, "Key") and name[3] >= 'A' and name[3] <= 'Z') return 4 + @as(i32, name[3] - 'A');
    if (name.len == 6 and std.mem.startsWith(u8, name, "Digit") and std.ascii.isDigit(name[5])) return if (name[5] == '0') 39 else 30 + @as(i32, name[5] - '1');
    if (name.len >= 2 and name[0] == 'F') {
        const n = std.fmt.parseInt(i32, name[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 57 + n;
        if (n >= 13 and n <= 24) return 91 + n;
    }
    const Entry = struct { []const u8, i32 };
    const table = [_]Entry{
        .{ "Enter", 40 },        .{ "Escape", 41 },        .{ "Backspace", 42 },      .{ "Tab", 43 },            .{ "Space", 44 },
        .{ "Minus", 45 },        .{ "Equal", 46 },         .{ "BracketLeft", 47 },    .{ "BracketRight", 48 },   .{ "Backslash", 49 },
        .{ "Semicolon", 51 },    .{ "Quote", 52 },         .{ "Backquote", 53 },      .{ "Comma", 54 },          .{ "Period", 55 },
        .{ "Slash", 56 },        .{ "CapsLock", 57 },      .{ "PrintScreen", 70 },    .{ "ScrollLock", 71 },     .{ "Pause", 72 },
        .{ "Insert", 73 },       .{ "Home", 74 },          .{ "PageUp", 75 },         .{ "Delete", 76 },         .{ "End", 77 },
        .{ "PageDown", 78 },     .{ "ArrowRight", 79 },    .{ "ArrowLeft", 80 },      .{ "ArrowDown", 81 },      .{ "ArrowUp", 82 },
        .{ "NumLock", 83 },      .{ "NumpadDivide", 84 },  .{ "NumpadMultiply", 85 }, .{ "NumpadSubtract", 86 }, .{ "NumpadAdd", 87 },
        .{ "NumpadEnter", 88 },  .{ "Numpad1", 89 },       .{ "Numpad2", 90 },        .{ "Numpad3", 91 },        .{ "Numpad4", 92 },
        .{ "Numpad5", 93 },      .{ "Numpad6", 94 },       .{ "Numpad7", 95 },        .{ "Numpad8", 96 },        .{ "Numpad9", 97 },
        .{ "Numpad0", 98 },      .{ "NumpadDecimal", 99 }, .{ "IntlBackslash", 100 }, .{ "ContextMenu", 101 },   .{ "NumpadEqual", 103 },
        .{ "ControlLeft", 224 }, .{ "ShiftLeft", 225 },    .{ "AltLeft", 226 },       .{ "MetaLeft", 227 },      .{ "ControlRight", 228 },
        .{ "ShiftRight", 229 },  .{ "AltRight", 230 },     .{ "MetaRight", 231 },
    };
    for (table) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

fn logicalKeycode(name: []const u8) !i32 {
    if ((std.unicode.utf8CountCodepoints(name) catch return error.Unsupported) == 1) return @intCast(try std.unicode.utf8Decode(name));
    const scan = domScancode(name) orelse return error.Unsupported;
    // Logical named keys have the same non-character meaning at every layout.
    // Physical-only spellings such as KeyA must not become logical aliases.
    if (std.mem.startsWith(u8, name, "Key") or std.mem.startsWith(u8, name, "Digit") or std.mem.startsWith(u8, name, "Numpad") or std.mem.endsWith(u8, name, "Left") or std.mem.endsWith(u8, name, "Right")) {
        if (!std.mem.startsWith(u8, name, "Arrow")) return error.Unsupported;
    }
    return switch (scan) {
        40 => 13,
        41 => 27,
        42 => 8,
        43 => 9,
        44 => 32,
        76 => 127,
        else => (1 << 30) | scan,
    };
}

test "DOM physical mapping rejects logical text and unknown positions" {
    try std.testing.expectEqual(@as(?i32, 4), domScancode("KeyA"));
    try std.testing.expectEqual(@as(?i32, 229), domScancode("ShiftRight"));
    try std.testing.expectEqual(@as(?i32, null), domScancode("a"));
    try std.testing.expectEqual(@as(?i32, null), domScancode("Unknown"));
    try std.testing.expectError(error.Unsupported, logicalKeycode("KeyA"));
}
