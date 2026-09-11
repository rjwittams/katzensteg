const std = @import("std");

pub const SessionSpec = struct {
    profile_name: []const u8,
    extra_args: []const []const u8,
};

pub const Parsed = struct {
    allocator: std.mem.Allocator,
    sessions: []SessionSpec,
    listen_path: ?[]const u8 = null,

    pub fn deinit(self: *Parsed) void {
        for (self.sessions) |session| freeSession(self.allocator, session);
        self.allocator.free(self.sessions);
        if (self.listen_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    var args = if (argv.len > 0) argv[1..] else argv;
    var listen_path: ?[]const u8 = null;
    errdefer if (listen_path) |path| allocator.free(path);
    // Host options precede profiles; arguments after a session's -- belong to
    // that application and are never interpreted as host options.
    if (args.len > 0 and std.mem.eql(u8, args[0], "--listen")) {
        if (args.len < 2 or args[1].len == 0 or std.mem.startsWith(u8, args[1], "--")) return error.MissingListenerPath;
        listen_path = try allocator.dupe(u8, args[1]);
        args = args[2..];
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "--listen")) return error.DuplicateListener;
    const uses_session_syntax = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--session")) break true;
    } else false;

    var sessions = std.ArrayList(SessionSpec).empty;
    errdefer {
        for (sessions.items) |session| freeSession(allocator, session);
        sessions.deinit(allocator);
    }

    if (!uses_session_syntax) {
        for (args) |profile_name| {
            try sessions.append(allocator, .{
                .profile_name = try allocator.dupe(u8, profile_name),
                .extra_args = &.{},
            });
        }
        return .{ .allocator = allocator, .sessions = try sessions.toOwnedSlice(allocator), .listen_path = listen_path };
    }

    if (args.len > 0 and !std.mem.eql(u8, args[0], "--session")) return error.MixedSessionSyntax;

    var i: usize = 0;
    while (i < args.len) {
        if (!std.mem.eql(u8, args[i], "--session")) return error.MixedSessionSyntax;
        i += 1;
        if (i >= args.len) return error.MissingSessionProfile;
        const profile_name = args[i];
        i += 1;

        var extra = std.ArrayList([]const u8).empty;
        errdefer {
            for (extra.items) |arg| allocator.free(arg);
            extra.deinit(allocator);
        }

        if (i < args.len and std.mem.eql(u8, args[i], "--")) {
            i += 1;
            while (i < args.len and !std.mem.eql(u8, args[i], "--session")) : (i += 1) {
                try extra.append(allocator, try allocator.dupe(u8, args[i]));
            }
        } else if (i < args.len and !std.mem.eql(u8, args[i], "--session")) {
            return error.MissingSessionArgsSeparator;
        }

        try sessions.append(allocator, .{
            .profile_name = try allocator.dupe(u8, profile_name),
            .extra_args = try extra.toOwnedSlice(allocator),
        });
    }

    return .{ .allocator = allocator, .sessions = try sessions.toOwnedSlice(allocator), .listen_path = listen_path };
}

fn freeSession(allocator: std.mem.Allocator, session: SessionSpec) void {
    allocator.free(session.profile_name);
    for (session.extra_args) |arg| allocator.free(arg);
    allocator.free(session.extra_args);
}

test "wm cli parses one session with extra args" {
    var parsed = try parse(std.testing.allocator, &.{ "katzensteg-wm", "--session", "retroarch", "--", "rom.sfc" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.sessions.len);
    try std.testing.expectEqualStrings("retroarch", parsed.sessions[0].profile_name);
    try std.testing.expectEqualStrings("rom.sfc", parsed.sessions[0].extra_args[0]);
}

test "wm cli parses multiple sessions" {
    var parsed = try parse(std.testing.allocator, &.{ "katzensteg-wm", "--session", "a", "--", "one", "--session", "b", "--", "two" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.sessions.len);
    try std.testing.expectEqualStrings("a", parsed.sessions[0].profile_name);
    try std.testing.expectEqualStrings("one", parsed.sessions[0].extra_args[0]);
    try std.testing.expectEqualStrings("b", parsed.sessions[1].profile_name);
    try std.testing.expectEqualStrings("two", parsed.sessions[1].extra_args[0]);
}

test "wm cli preserves positional compatibility for no arg sessions" {
    var parsed = try parse(std.testing.allocator, &.{ "katzensteg-wm", "sonic", "mi2" });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.sessions.len);
    try std.testing.expectEqualStrings("sonic", parsed.sessions[0].profile_name);
    try std.testing.expectEqual(@as(usize, 0), parsed.sessions[0].extra_args.len);
}

test "wm cli rejects mixed positional and session syntax" {
    try std.testing.expectError(error.MixedSessionSyntax, parse(std.testing.allocator, &.{ "katzensteg-wm", "sonic", "--session", "mi2" }));
}

test "wm listener option precedes either session syntax" {
    var empty = try parse(std.testing.allocator, &.{ "wm", "--listen", "/tmp/wm.sock" });
    defer empty.deinit();
    try std.testing.expectEqualStrings("/tmp/wm.sock", empty.listen_path.?);
    try std.testing.expectEqual(@as(usize, 0), empty.sessions.len);
    var mixed = try parse(std.testing.allocator, &.{ "wm", "--listen", "~/wm.sock", "--session", "mi2", "--", "--listen", "app-option" });
    defer mixed.deinit();
    try std.testing.expectEqualStrings("--listen", mixed.sessions[0].extra_args[0]);
    try std.testing.expectError(error.MissingListenerPath, parse(std.testing.allocator, &.{ "wm", "--listen" }));
}
