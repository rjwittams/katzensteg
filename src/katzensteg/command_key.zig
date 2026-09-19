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

pub fn label(binding: ?u8, buf: *[2]u8) []const u8 {
    const key = binding orelse return "none";
    buf.* = .{ '^', key };
    return buf;
}
