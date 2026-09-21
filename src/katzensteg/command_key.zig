//! Native attention-key binding. Hosts can use the same vocabulary without SDL.
const std = @import("std");
const native = @import("native_key.zig");

pub fn parse(value: []const u8) error{InvalidCommandKey}!?u8 {
    if (std.mem.eql(u8, value, "none")) return null;
    if (value.len != 2 or value[0] != '^') return error.InvalidCommandKey;
    const key = std.ascii.toUpper(value[1]);
    if (key < '@' or key > '_') return error.InvalidCommandKey;
    return key;
}

pub fn matches(binding: u8, key: native.Key) bool {
    const mods = key.modifiers;
    if (!mods.control or mods.shift or mods.alt or mods.super or mods.meta or mods.alt_graph) return false;
    const character = std.ascii.toLower(binding);
    const code = native.usLayoutCode(character) orelse return false;
    if (!key.code.isEmpty()) return std.mem.eql(u8, code, key.code.slice());
    if (key.kind == .physical) return std.mem.eql(u8, code, key.name.slice());
    return key.codepoint() == character;
}

/// The returned label borrows the caller's buffer.
pub fn label(binding: ?u8, buf: *[2]u8) []const u8 {
    const key = binding orelse return "none";
    buf.* = .{ '^', key };
    return buf;
}

pub const Context = enum { direct, desktop };
pub const Command = enum {
    literal,
    cancel,
    quit,
    quit_host,
    launch,
    focus_next,
    move_left,
    move_down,
    move_up,
    move_right,
    resize_narrower,
    resize_shorter,
    resize_taller,
    resize_wider,
    cascade,
    tile,
    unknown,
};

/// Command vocabulary shared by direct takeover and the desktop input model.
/// Callers own press tracking and only decode a fresh press while armed.
pub fn decode(binding: u8, key: native.Key, context: Context) Command {
    if (matches(binding, key)) return .literal;
    if (std.mem.eql(u8, key.name.slice(), "Escape")) return .cancel;
    if (key.modifiers.suppressText()) return .unknown;
    if (key.codepoint() == 'q') return .quit;
    if (context == .direct) return .unknown;
    if (std.mem.eql(u8, key.name.slice(), "Tab")) return .focus_next;
    return switch (key.codepoint() orelse return .unknown) {
        'Q' => .quit_host,
        'n' => .launch,
        'h' => .move_left,
        'j' => .move_down,
        'k' => .move_up,
        'l' => .move_right,
        'H' => .resize_narrower,
        'J' => .resize_shorter,
        'K' => .resize_taller,
        'L' => .resize_wider,
        'c' => .cascade,
        't' => .tile,
        else => .unknown,
    };
}
