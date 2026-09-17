//! Source-neutral keyboard vocabulary shared by every input source and both
//! Jackstay ends. It mirrors the Jackstay input contract: physical keys are
//! DOM code names, logical keys are DOM key names or one Unicode character,
//! a press has an identity fixed at its down, and modifiers are source
//! metadata rather than held state. No SDL numbers appear here; the SDL
//! binding is resolved once by the input model or the app adapter.
const std = @import("std");

/// Matches the Jackstay wire limit (`char key[64]`).
pub const max_name_bytes = 63;

pub const Kind = enum { physical, logical };

/// `tap` is a best-effort source's whole press: it becomes a down and an up
/// that share one press identity. Sources that observe releases use the
/// other three.
pub const Action = enum { down, repeat, up, tap };

/// Same bit layout as the Jackstay wire modifiers, so conversion is a cast.
pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    alt_graph: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    reserved: u24 = 0,

    /// Modifiers that turn a printable key into a shortcut rather than text.
    pub fn suppressText(self: Modifiers) bool {
        return self.control or self.alt or self.super or self.meta;
    }
};

pub const Name = struct {
    buf: [max_name_bytes + 1]u8 = @splat(0),

    pub fn init(bytes: []const u8) error{NameTooLong}!Name {
        if (bytes.len > max_name_bytes) return error.NameTooLong;
        var name = Name{};
        @memcpy(name.buf[0..bytes.len], bytes);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return std.mem.sliceTo(&self.buf, 0);
    }

    pub fn isEmpty(self: *const Name) bool {
        return self.buf[0] == 0;
    }

    pub fn eql(self: *const Name, other: *const Name) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const Key = struct {
    kind: Kind = .logical,
    name: Name = .{},
    /// DOM code of the key's position when the source reports it (a kitty
    /// base-layout key, for example). A logical key may carry it alongside
    /// its meaning; a physical key repeats its name here. Empty when the
    /// source only knows the meaning.
    code: Name = .{},
    /// Assigned by the input model when the key enters it. Zero until then.
    press: u64 = 0,
    action: Action = .tap,
    modifiers: Modifiers = .{},

    pub fn logical(name: []const u8) error{NameTooLong}!Key {
        return .{ .kind = .logical, .name = try Name.init(name) };
    }

    pub fn physical(name: []const u8) error{NameTooLong}!Key {
        return .{ .kind = .physical, .name = try Name.init(name) };
    }

    /// A logical key that is one Unicode character.
    pub fn character(value: u21) Key {
        var key = Key{};
        const len = std.unicode.utf8Encode(value, key.name.buf[0..4]) catch unreachable;
        key.name.buf[len] = 0;
        return key;
    }

    /// The character when the name is exactly one Unicode scalar value.
    pub fn codepoint(self: *const Key) ?u21 {
        const bytes = self.name.slice();
        if (bytes.len == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
        if (len != bytes.len) return null;
        return std.unicode.utf8Decode(bytes) catch null;
    }

    /// Whether two reports are the same key for press tracking. Positions win
    /// when both are known: a release may arrive with different modifiers and
    /// therefore a different logical name.
    pub fn sameKey(self: *const Key, other: *const Key) bool {
        if (!self.code.isEmpty() and !other.code.isEmpty()) return self.code.eql(&other.code);
        return self.kind == other.kind and self.name.eql(&other.name);
    }
};

/// DOM `KeyboardEvent.code` to USB HID keyboard usage. SDL scancodes use the
/// same numbering, so this is also the physical SDL binding of a DOM code.
pub fn domUsage(name: []const u8) ?i32 {
    if (name.len == 4 and std.mem.startsWith(u8, name, "Key") and name[3] >= 'A' and name[3] <= 'Z') return 4 + @as(i32, name[3] - 'A');
    if (name.len == 6 and std.mem.startsWith(u8, name, "Digit") and std.ascii.isDigit(name[5])) return if (name[5] == '0') 39 else 30 + @as(i32, name[5] - '1');
    if (name.len >= 2 and name[0] == 'F') {
        const n = std.fmt.parseInt(i32, name[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 57 + n;
        if (n >= 13 and n <= 24) return 91 + n;
    }
    for (named_usages) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

/// Inverse of `domUsage` for the positions it names. Letters, digits and
/// function keys are covered as well as the named table.
pub fn domCode(usage: i32) ?[]const u8 {
    if (usage >= 4 and usage <= 29) return letter_codes[@intCast(usage - 4)];
    if (usage >= 30 and usage <= 39) return digit_codes[@intCast(usage - 30)];
    if (usage >= 58 and usage <= 69) return function_codes[@intCast(usage - 58)];
    if (usage >= 104 and usage <= 115) return function_codes[@intCast(usage - 104 + 12)];
    for (named_usages) |entry| if (entry[1] == usage) return entry[0];
    return null;
}

/// US-layout position of a printable ASCII character, or 0 when SDL has no
/// scancode for it (a shifted symbol, for example).
pub fn usLayoutUsage(byte: u8) i32 {
    if (byte >= 'a' and byte <= 'z') return 4 + @as(i32, byte - 'a');
    if (byte >= 'A' and byte <= 'Z') return 4 + @as(i32, byte - 'A');
    if (byte >= '1' and byte <= '9') return 30 + @as(i32, byte - '1');
    return switch (byte) {
        '0' => 39,
        ' ' => 44,
        '-' => 45,
        '=' => 46,
        '[' => 47,
        ']' => 48,
        '\\' => 49,
        ';' => 51,
        '\'' => 52,
        '`' => 53,
        ',' => 54,
        '.' => 55,
        '/' => 56,
        else => 0,
    };
}

/// DOM code of the US-layout key that produces a printable ASCII character.
pub fn usLayoutCode(byte: u8) ?[]const u8 {
    const usage = usLayoutUsage(byte);
    return if (usage == 0) null else domCode(usage);
}

/// Whether a DOM name describes a key position rather than a key meaning.
/// Such names are physical-only; they must not be used as logical keys.
pub fn isPositionalName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "Arrow")) return false;
    return std.mem.startsWith(u8, name, "Key") or std.mem.startsWith(u8, name, "Digit") or
        std.mem.startsWith(u8, name, "Numpad") or std.mem.endsWith(u8, name, "Left") or std.mem.endsWith(u8, name, "Right");
}

const Entry = struct { []const u8, i32 };
const named_usages = [_]Entry{
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

const letter_codes = [_][]const u8{
    "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM",
    "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ",
};
const digit_codes = [_][]const u8{ "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Digit0" };
const function_codes = [_][]const u8{
    "F1",  "F2",  "F3",  "F4",  "F5",  "F6",  "F7",  "F8",  "F9",  "F10", "F11", "F12",
    "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
};

test "DOM physical mapping rejects logical text and unknown positions" {
    try std.testing.expectEqual(@as(?i32, 4), domUsage("KeyA"));
    try std.testing.expectEqual(@as(?i32, 229), domUsage("ShiftRight"));
    try std.testing.expectEqual(@as(?i32, 104), domUsage("F13"));
    try std.testing.expectEqual(@as(?i32, null), domUsage("a"));
    try std.testing.expectEqual(@as(?i32, null), domUsage("Unknown"));
}

test "DOM codes round trip through HID usages" {
    for ([_][]const u8{ "KeyQ", "Digit0", "F1", "F24", "ArrowUp", "NumpadEnter", "MetaRight", "Space" }) |name| {
        try std.testing.expectEqualStrings(name, domCode(domUsage(name).?).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), domCode(0));
    try std.testing.expectEqual(@as(?[]const u8, null), domCode(500));
}

test "positional names are physical only" {
    try std.testing.expect(isPositionalName("KeyA"));
    try std.testing.expect(isPositionalName("Digit1"));
    try std.testing.expect(isPositionalName("ShiftLeft"));
    try std.testing.expect(isPositionalName("Numpad5"));
    try std.testing.expect(!isPositionalName("ArrowLeft"));
    try std.testing.expect(!isPositionalName("Enter"));
    try std.testing.expect(!isPositionalName("F3"));
}

test "keys carry one character or a DOM name and bound their length" {
    const e_acute = Key.character(0xe9);
    try std.testing.expectEqualStrings("é", e_acute.name.slice());
    try std.testing.expectEqual(@as(?u21, 0xe9), e_acute.codepoint());
    const enter = try Key.logical("Enter");
    try std.testing.expectEqual(@as(?u21, null), enter.codepoint());
    try std.testing.expect(!enter.sameKey(&e_acute));
    try std.testing.expect(enter.sameKey(&(try Key.logical("Enter"))));
    try std.testing.expect(!enter.sameKey(&(try Key.physical("Enter"))));
    var lower = Key.character('a');
    lower.code = try Name.init("KeyQ");
    var upper = Key.character('A');
    upper.code = try Name.init("KeyQ");
    try std.testing.expect(lower.sameKey(&upper));
    try std.testing.expect(lower.sameKey(&Key.character('a')));
    try std.testing.expect(!lower.sameKey(&Key.character('b')));
    try std.testing.expectEqualStrings("KeyQ", usLayoutCode('q').?);
    try std.testing.expectEqualStrings("Semicolon", usLayoutCode(';').?);
    try std.testing.expectEqual(@as(?[]const u8, null), usLayoutCode('!'));
    try std.testing.expectError(error.NameTooLong, Key.logical("x" ** (max_name_bytes + 1)));
    try std.testing.expect((Key{}).name.isEmpty());
    try std.testing.expect((Modifiers{ .control = true }).suppressText());
    try std.testing.expect(!(Modifiers{ .shift = true, .caps_lock = true }).suppressText());
}
