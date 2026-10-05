//! Launch requests shared by the desktop prompt and command line. Text is
//! borrowed; the CLI owns its copies and the prompt consumes before clearing.
const std = @import("std");
pub const Kind = enum { profile, term, attach };
pub const Spec = struct {
    kind: Kind = .profile,
    profile_name: []const u8,
    extra_args: []const []const u8 = &.{},
};

pub fn prompt(text: []const u8) !Spec {
    if (text.len == 0) return error.EmptyLaunch;
    if (text[0] == '!') return .{ .kind = .term, .profile_name = std.mem.trim(u8, text[1..], " ") };
    if (text[0] == '@') return attachment(text[1..]);
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const word = text[0..end];
    const rest = std.mem.trim(u8, text[end..], " ");
    if (std.mem.eql(u8, word, "term")) return .{ .kind = .term, .profile_name = rest };
    if (std.mem.eql(u8, word, "attach")) return attachment(rest);
    for (text) |byte| if (!profileByte(byte)) return error.InvalidProfileName;
    return .{ .profile_name = text };
}
fn attachment(text: []const u8) !Spec {
    const id = std.mem.trim(u8, text, " ");
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, ' ') != null) return error.InvalidSessionId;
    return .{ .kind = .attach, .profile_name = id };
}
pub fn profileByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
}

// #119: both prompt spellings describe the same request, including the shell,
// commands with spaces and punctuation, ids, and reserved profile names.
test "prompt word and sigil forms agree" {
    for ([_][]const u8{ "", "echo hello", "printf '%s' @foo; pwd", "term" }) |command| {
        const word = try std.fmt.allocPrint(std.testing.allocator, "term {s}", .{command});
        defer std.testing.allocator.free(word);
        const sigil = try std.fmt.allocPrint(std.testing.allocator, "!{s}", .{command});
        defer std.testing.allocator.free(sigil);
        const a = try prompt(word);
        const b = try prompt(sigil);
        try std.testing.expectEqual(Kind.term, a.kind);
        try std.testing.expectEqualDeep(a, b);
        try std.testing.expectEqualStrings(command, a.profile_name);
    }
    try std.testing.expectEqual(Kind.term, (try prompt("term")).kind);
    for ([_][]const u8{ "a", "session-123", "term", "attach" }) |id| {
        const word = try std.fmt.allocPrint(std.testing.allocator, "attach {s}", .{id});
        defer std.testing.allocator.free(word);
        const sigil = try std.fmt.allocPrint(std.testing.allocator, "@{s}", .{id});
        defer std.testing.allocator.free(sigil);
        try std.testing.expectEqualDeep(try prompt(word), try prompt(sigil));
        try std.testing.expectEqual(Kind.attach, (try prompt(word)).kind);
    }
    for ([_][]const u8{ "a", "term-probe", "attach_probe", "probe.input" }) |name| {
        try std.testing.expectEqual(Kind.profile, (try prompt(name)).kind);
        try std.testing.expectEqualStrings(name, (try prompt(name)).profile_name);
    }
    for ([_][]const u8{ "@", "attach", "attach ", "@a b" }) |invalid|
        try std.testing.expectError(error.InvalidSessionId, prompt(invalid));
    try std.testing.expectError(error.EmptyLaunch, prompt(""));
    try std.testing.expectError(error.InvalidProfileName, prompt("profile args"));
}
