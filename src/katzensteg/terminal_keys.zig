//! Terminal keyboard reports decoded into native keys. One decoder covers the
//! legacy xterm forms (`CSI 1;5A`, `CSI 15~`, `CSI 27u`) and the kitty keyboard
//! protocol (`CSI code:shifted:base;mods:event;text u`); the protocol only
//! changes which attributes a key carries. Real press/release actions, the
//! base-layout position and associated text appear when the terminal reports
//! them. Nothing here is guessed: a key the terminal does not name is dropped.
const std = @import("std");
const native_key = @import("native_key.zig");

pub const max_text_bytes = 15;

pub const Decoded = struct {
    key: native_key.Key,
    text_buf: [max_text_bytes + 1]u8 = undefined,
    text_len: u8 = 0,

    pub fn text(self: *const Decoded) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

pub const Report = union(enum) {
    key: Decoded,
    /// Reply to the kitty keyboard protocol query (`CSI ? flags u`).
    protocol_flags: u32,
};

/// Decode a CSI key report from its parameter bytes and final byte. When the
/// terminal reports event types, a report without one is a press; otherwise it
/// is a whole tap. Returns null for sequences that are not key reports.
pub fn decodeCsi(params: []const u8, final: u8, reports_events: bool) ?Report {
    var fields = Fields.split(params);
    switch (final) {
        'u' => {
            if (params.len > 0 and params[0] == '?') {
                return .{ .protocol_flags = std.fmt.parseInt(u32, params[1..], 10) catch return null };
            }
            if (params.len > 0 and !std.ascii.isDigit(params[0])) return null;
            return decodeUnicode(&fields, reports_events);
        },
        '~' => {
            const number = fields.number(0, 0) orelse return null;
            const named = tildeKey(number) orelse return null;
            return finish(named, &fields, reports_events);
        },
        'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'R', 'S' => {
            if (params.len > 0 and !std.ascii.isDigit(params[0])) return null;
            // The first parameter is 1 or absent for these keys.
            if (fields.number(0, 0)) |first| if (first != 1) return null;
            return finish(letterKey(final).?, &fields, reports_events);
        },
        else => return null,
    }
}

const Named = struct { name: []const u8, kind: native_key.Kind = .logical, code: ?[]const u8 = null };

fn finish(named: Named, fields: *const Fields, reports_events: bool) ?Report {
    var decoded = Decoded{ .key = .{ .kind = named.kind, .name = native_key.Name.init(named.name) catch return null } };
    decoded.key.code = native_key.Name.init(named.code orelse named.name) catch return null;
    if (native_key.domUsage(decoded.key.code.slice()) == null) decoded.key.code = .{};
    decoded.key.modifiers = modifiers(fields.number(1, 0) orelse 1);
    decoded.key.action = action(fields.number(1, 1), reports_events);
    fillText(&decoded, fields, null);
    return .{ .key = decoded };
}

fn decodeUnicode(fields: *const Fields, reports_events: bool) ?Report {
    const code = fields.number(0, 0) orelse return null;
    if (functionalKey(code)) |named| return finish(named, fields, reports_events);
    // Other private-use codes are functional keys without a DOM name.
    if (code >= 0xe000 and code <= 0xf8ff) return null;
    if (code < 0x20 or code == 0x7f or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return null;
    const mods = modifiers(fields.number(1, 0) orelse 1);
    // The logical key is the shifted character when Shift is held.
    var logical: u21 = @intCast(code);
    if (mods.shift) {
        if (fields.number(0, 1)) |shifted| {
            if (shifted >= 0x20 and shifted <= 0x10ffff) logical = @intCast(shifted);
        } else if (logical < 0x80 and std.ascii.isLower(@intCast(logical))) logical = std.ascii.toUpper(@intCast(logical));
    }
    var decoded = Decoded{ .key = native_key.Key.character(logical) };
    decoded.key.modifiers = mods;
    decoded.key.action = action(fields.number(1, 1), reports_events);
    // The position comes from the base-layout key, else from the key itself
    // when it is a US-layout character.
    const base = fields.number(0, 2) orelse code;
    if (base < 0x80) {
        if (native_key.usLayoutCode(@intCast(base))) |dom| decoded.key.code = native_key.Name.init(dom) catch unreachable;
    }
    fillText(&decoded, fields, logical);
    return .{ .key = decoded };
}

/// Text from the report's text field, else the key's own character for a
/// printable key that is not a shortcut.
fn fillText(decoded: *Decoded, fields: *const Fields, fallback: ?u21) void {
    if (fields.count > 2 and fields.raw[2].len > 0) {
        var parts = std.mem.splitScalar(u8, fields.raw[2], ':');
        while (parts.next()) |part| {
            const cp = std.fmt.parseInt(u21, part, 10) catch return;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return;
            if (decoded.text_len + len > max_text_bytes) return;
            @memcpy(decoded.text_buf[decoded.text_len .. decoded.text_len + len], buf[0..len]);
            decoded.text_len += @intCast(len);
        }
        return;
    }
    const cp = fallback orelse return;
    if (decoded.key.action == .up or decoded.key.modifiers.suppressText()) return;
    decoded.text_len = @intCast(std.unicode.utf8Encode(cp, decoded.text_buf[0..4]) catch return);
}

fn modifiers(value: u32) native_key.Modifiers {
    const bits = if (value == 0) 0 else value - 1;
    return .{
        .shift = bits & 1 != 0,
        .alt = bits & 2 != 0,
        .control = bits & 4 != 0,
        .super = bits & 8 != 0,
        // Bit 16 is Hyper, which has no Jackstay counterpart.
        .meta = bits & 32 != 0,
        .caps_lock = bits & 64 != 0,
        .num_lock = bits & 128 != 0,
    };
}

fn action(event: ?u32, reports_events: bool) native_key.Action {
    return switch (event orelse 1) {
        2 => .repeat,
        3 => .up,
        else => if (reports_events) .down else .tap,
    };
}

fn tildeKey(number: u32) ?Named {
    return switch (number) {
        2 => .{ .name = "Insert" },
        3 => .{ .name = "Delete" },
        5 => .{ .name = "PageUp" },
        6 => .{ .name = "PageDown" },
        7 => .{ .name = "Home" },
        8 => .{ .name = "End" },
        11 => .{ .name = "F1" },
        12 => .{ .name = "F2" },
        13 => .{ .name = "F3" },
        14 => .{ .name = "F4" },
        15 => .{ .name = "F5" },
        17 => .{ .name = "F6" },
        18 => .{ .name = "F7" },
        19 => .{ .name = "F8" },
        20 => .{ .name = "F9" },
        21 => .{ .name = "F10" },
        23 => .{ .name = "F11" },
        24 => .{ .name = "F12" },
        25 => .{ .name = "F13" },
        26 => .{ .name = "F14" },
        28 => .{ .name = "F15" },
        29 => .{ .name = "F16" },
        31 => .{ .name = "F17" },
        32 => .{ .name = "F18" },
        33 => .{ .name = "F19" },
        34 => .{ .name = "F20" },
        else => null,
    };
}

fn letterKey(final: u8) ?Named {
    return switch (final) {
        'A' => .{ .name = "ArrowUp" },
        'B' => .{ .name = "ArrowDown" },
        'C' => .{ .name = "ArrowRight" },
        'D' => .{ .name = "ArrowLeft" },
        'H' => .{ .name = "Home" },
        'F' => .{ .name = "End" },
        'P' => .{ .name = "F1" },
        'Q' => .{ .name = "F2" },
        'R' => .{ .name = "F3" },
        'S' => .{ .name = "F4" },
        'E' => .{ .name = "Numpad5", .kind = .physical },
        else => null,
    };
}

/// Kitty functional key codes, plus the C0 keys the protocol reports as
/// their character codes. Keys without a DOM name are not reported.
fn functionalKey(code: u32) ?Named {
    return switch (code) {
        8, 127 => .{ .name = "Backspace" },
        9 => .{ .name = "Tab" },
        13 => .{ .name = "Enter" },
        27 => .{ .name = "Escape" },
        57358 => .{ .name = "CapsLock", .kind = .physical },
        57359 => .{ .name = "ScrollLock", .kind = .physical },
        57360 => .{ .name = "NumLock", .kind = .physical },
        57361 => .{ .name = "PrintScreen", .kind = .physical },
        57362 => .{ .name = "Pause", .kind = .physical },
        57363 => .{ .name = "ContextMenu", .kind = .physical },
        57376...57387 => .{ .name = function_names[code - 57376 + 12] },
        57399...57408 => .{ .name = numpad_names[code - 57399], .kind = .physical },
        57409 => .{ .name = "NumpadDecimal", .kind = .physical },
        57410 => .{ .name = "NumpadDivide", .kind = .physical },
        57411 => .{ .name = "NumpadMultiply", .kind = .physical },
        57412 => .{ .name = "NumpadSubtract", .kind = .physical },
        57413 => .{ .name = "NumpadAdd", .kind = .physical },
        57414 => .{ .name = "NumpadEnter", .kind = .physical },
        57415 => .{ .name = "NumpadEqual", .kind = .physical },
        57417 => .{ .name = "ArrowLeft", .code = "Numpad4" },
        57418 => .{ .name = "ArrowRight", .code = "Numpad6" },
        57419 => .{ .name = "ArrowUp", .code = "Numpad8" },
        57420 => .{ .name = "ArrowDown", .code = "Numpad2" },
        57421 => .{ .name = "PageUp", .code = "Numpad9" },
        57422 => .{ .name = "PageDown", .code = "Numpad3" },
        57423 => .{ .name = "Home", .code = "Numpad7" },
        57424 => .{ .name = "End", .code = "Numpad1" },
        57425 => .{ .name = "Insert", .code = "Numpad0" },
        57426 => .{ .name = "Delete", .code = "NumpadDecimal" },
        57427 => .{ .name = "Numpad5", .kind = .physical },
        57441 => .{ .name = "ShiftLeft", .kind = .physical },
        57442 => .{ .name = "ControlLeft", .kind = .physical },
        57443 => .{ .name = "AltLeft", .kind = .physical },
        57444, 57446 => .{ .name = "MetaLeft", .kind = .physical },
        57447 => .{ .name = "ShiftRight", .kind = .physical },
        57448 => .{ .name = "ControlRight", .kind = .physical },
        57449, 57453 => .{ .name = "AltRight", .kind = .physical },
        57450, 57452 => .{ .name = "MetaRight", .kind = .physical },
        else => null,
    };
}

const function_names = [_][]const u8{
    "F1",  "F2",  "F3",  "F4",  "F5",  "F6",  "F7",  "F8",  "F9",  "F10", "F11", "F12",
    "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
};
const numpad_names = [_][]const u8{ "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9" };

/// Up to three `;`-separated parameters, each with `:`-separated sub-parameters.
const Fields = struct {
    raw: [3][]const u8 = .{ "", "", "" },
    count: usize = 0,

    fn split(params: []const u8) Fields {
        var fields = Fields{};
        var parts = std.mem.splitScalar(u8, params, ';');
        while (parts.next()) |part| {
            if (fields.count == fields.raw.len) break;
            fields.raw[fields.count] = part;
            fields.count += 1;
        }
        return fields;
    }

    /// Sub-parameter `sub` of parameter `index`; null when absent or empty.
    fn number(self: *const Fields, index: usize, sub: usize) ?u32 {
        if (index >= self.count) return null;
        var parts = std.mem.splitScalar(u8, self.raw[index], ':');
        var i: usize = 0;
        while (parts.next()) |part| : (i += 1) {
            if (i == sub) return if (part.len == 0) null else std.fmt.parseInt(u32, part, 10) catch null;
        }
        return null;
    }
};

fn key(params: []const u8, final: u8, reports_events: bool) Decoded {
    return decodeCsi(params, final, reports_events).?.key;
}

test "legacy forms decode modified arrows, tilde keys and CSI u escape as taps" {
    const up = key("1;5", 'A', false);
    try std.testing.expectEqualStrings("ArrowUp", up.key.name.slice());
    try std.testing.expectEqualStrings("ArrowUp", up.key.code.slice());
    try std.testing.expect(up.key.modifiers.control);
    try std.testing.expectEqual(native_key.Action.tap, up.key.action);
    try std.testing.expectEqualStrings("ArrowDown", key("", 'B', false).key.name.slice());
    const f5 = key("15;2", '~', false);
    try std.testing.expectEqualStrings("F5", f5.key.name.slice());
    try std.testing.expect(f5.key.modifiers.shift);
    try std.testing.expectEqualStrings("Delete", key("3", '~', false).key.name.slice());
    try std.testing.expectEqualStrings("Escape", key("27", 'u', false).key.name.slice());
    try std.testing.expectEqualStrings("Escape", key("27;1", 'u', false).key.name.slice());
    try std.testing.expectEqualStrings("Numpad5", key("1", 'E', false).key.name.slice());
    try std.testing.expectEqual(native_key.Kind.physical, key("1", 'E', false).key.kind);
    try std.testing.expectEqual(@as(?Report, null), decodeCsi("200", '~', false));
    try std.testing.expectEqual(@as(?Report, null), decodeCsi("?1006", 'h', false));
    try std.testing.expectEqual(@as(?Report, null), decodeCsi("2", 'A', false));
}

test "kitty reports carry event types, base-layout positions, shifted keys and text" {
    const press = key("97", 'u', true);
    try std.testing.expectEqual(native_key.Action.down, press.key.action);
    try std.testing.expectEqualStrings("a", press.key.name.slice());
    try std.testing.expectEqualStrings("KeyA", press.key.code.slice());
    try std.testing.expectEqualStrings("a", press.text());
    const repeat = key("97;1:2", 'u', true);
    try std.testing.expectEqual(native_key.Action.repeat, repeat.key.action);
    const release = key("97;1:3", 'u', true);
    try std.testing.expectEqual(native_key.Action.up, release.key.action);
    try std.testing.expectEqual(@as(usize, 0), release.text().len);
    // AZERTY: the key at the US Q position produces 'a'.
    const azerty = key("97::113;2;65", 'u', true);
    try std.testing.expectEqualStrings("A", azerty.key.name.slice());
    try std.testing.expectEqualStrings("KeyQ", azerty.key.code.slice());
    try std.testing.expectEqualStrings("A", azerty.text());
    try std.testing.expect(azerty.key.modifiers.shift);
    // Shifted alternate without a text field still names the shifted key.
    const shifted = key("49:33;2", 'u', true);
    try std.testing.expectEqualStrings("!", shifted.key.name.slice());
    try std.testing.expectEqualStrings("Digit1", shifted.key.code.slice());
    try std.testing.expectEqualStrings("!", shifted.text());
    const control = key("99;5", 'u', true);
    try std.testing.expect(control.key.modifiers.control);
    try std.testing.expectEqual(@as(usize, 0), control.text().len);
    const mods = key("57441;2", 'u', true);
    try std.testing.expectEqual(native_key.Kind.physical, mods.key.kind);
    try std.testing.expectEqualStrings("ShiftLeft", mods.key.name.slice());
    const keypad_left = key("57417;129", 'u', true);
    try std.testing.expectEqualStrings("ArrowLeft", keypad_left.key.name.slice());
    try std.testing.expectEqualStrings("Numpad4", keypad_left.key.code.slice());
    try std.testing.expect(keypad_left.key.modifiers.num_lock);
    const e_acute = key("233;1;233", 'u', true);
    try std.testing.expectEqualStrings("é", e_acute.key.name.slice());
    try std.testing.expect(e_acute.key.code.isEmpty());
    try std.testing.expectEqualStrings("é", e_acute.text());
    const f13 = key("57376", 'u', true);
    try std.testing.expectEqualStrings("F13", f13.key.name.slice());
    try std.testing.expectEqual(@as(?Report, null), decodeCsi("57428", 'u', true));
    try std.testing.expectEqual(@as(?Report, null), decodeCsi("57445", 'u', true));
    try std.testing.expectEqual(@as(?Report, null), decodeCsi(">31", 'u', true));
    try std.testing.expectEqual(Report{ .protocol_flags = 31 }, decodeCsi("?31", 'u', false).?);
}

test "kitty text fields are bounded and hyper is dropped" {
    const long = key("97;1;128512:128512:128512:128512", 'u', true);
    try std.testing.expectEqual(@as(usize, 12), long.text().len);
    const hyper = key("97;17", 'u', true);
    try std.testing.expectEqual(native_key.Modifiers{}, hyper.key.modifiers);
}
