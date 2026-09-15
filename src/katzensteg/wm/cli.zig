const std = @import("std");

pub const SessionSpec = struct {
    profile_name: []const u8,
    extra_args: []const []const u8,
};

pub const PresentationMode = enum { positioned, placeholder };

pub const Parsed = struct {
    presentation: PresentationMode = .positioned,
    allocator: std.mem.Allocator,
    sessions: []SessionSpec,
    listen_path: ?[]const u8 = null,
    headless: bool = false,
    background: bool = false,
    http_address: ?[]const u8 = null,
    tty_path: ?[]const u8 = null,
    host_file: ?[]const u8 = null,
    parent_pid: ?i32 = null,
    idle_refresh_ms: u32 = 500,

    pub fn deinit(self: *Parsed) void {
        for (self.sessions) |session| freeSession(self.allocator, session);
        self.allocator.free(self.sessions);
        if (self.listen_path) |path| self.allocator.free(path);
        if (self.http_address) |value| self.allocator.free(value);
        if (self.tty_path) |value| self.allocator.free(value);
        if (self.host_file) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Parsed {
    var args = if (argv.len > 0) argv[1..] else argv;
    var listen_path: ?[]const u8 = null;
    errdefer if (listen_path) |path| allocator.free(path);
    var presentation: PresentationMode = .positioned;
    var presentation_set = false;
    var headless = false;
    var background = false;
    var http_address: ?[]const u8 = null;
    errdefer if (http_address) |value| allocator.free(value);
    var tty_path: ?[]const u8 = null;
    errdefer if (tty_path) |value| allocator.free(value);
    var host_file: ?[]const u8 = null;
    errdefer if (host_file) |value| allocator.free(value);
    var parent_pid: ?i32 = null;
    var idle_refresh_ms: ?u32 = null;
    // Options after a session's -- belong to the application.
    while (args.len > 0) {
        if (std.mem.eql(u8, args[0], "--listen")) {
            if (listen_path != null) return error.DuplicateListener;
            if (args.len < 2 or args[1].len == 0 or std.mem.startsWith(u8, args[1], "--")) return error.MissingListenerPath;
            listen_path = try allocator.dupe(u8, args[1]);
            args = args[2..];
        } else if (std.mem.eql(u8, args[0], "--presentation")) {
            if (presentation_set or args.len < 2) return error.InvalidPresentationMode;
            presentation = std.meta.stringToEnum(PresentationMode, args[1]) orelse return error.InvalidPresentationMode;
            presentation_set = true;
            args = args[2..];
        } else if (std.mem.eql(u8, args[0], "--headless")) {
            if (headless) return error.DuplicateHeadless;
            headless = true;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "--background")) {
            if (background) return error.DuplicateBackground;
            background = true;
            args = args[1..];
        } else if (std.mem.eql(u8, args[0], "--http") or std.mem.eql(u8, args[0], "--tty") or std.mem.eql(u8, args[0], "--host-file")) {
            if (args.len < 2 or args[1].len == 0 or std.mem.startsWith(u8, args[1], "--")) return error.MissingHostOptionValue;
            const slot = if (std.mem.eql(u8, args[0], "--http")) &http_address else if (std.mem.eql(u8, args[0], "--tty")) &tty_path else &host_file;
            if (slot.* != null) return error.DuplicateHostOption;
            slot.* = try allocator.dupe(u8, args[1]);
            args = args[2..];
        } else if (std.mem.eql(u8, args[0], "--idle-refresh-ms")) {
            if (args.len < 2 or idle_refresh_ms != null) return error.InvalidIdleRefresh;
            idle_refresh_ms = std.fmt.parseInt(u32, args[1], 10) catch return error.InvalidIdleRefresh;
            args = args[2..];
        } else if (std.mem.eql(u8, args[0], "--parent-pid")) {
            if (args.len < 2 or parent_pid != null) return error.InvalidParentPid;
            parent_pid = std.fmt.parseInt(i32, args[1], 10) catch return error.InvalidParentPid;
            if (parent_pid.? <= 1) return error.InvalidParentPid;
            args = args[2..];
        } else if (std.mem.eql(u8, args[0], "--placeholder") or std.mem.eql(u8, args[0], "--control-stdin")) {
            return error.UnsupportedHostOption;
        } else break;
    }
    if (headless) {
        if (args.len != 0 or listen_path != null) return error.HeadlessClientsOwnSessions;
        if (presentation_set and presentation != .placeholder) return error.HeadlessRequiresPlaceholder;
        return .{ .allocator = allocator, .sessions = try allocator.alloc(SessionSpec, 0), .presentation = .placeholder, .headless = true, .background = background, .http_address = http_address, .tty_path = tty_path, .host_file = host_file, .parent_pid = parent_pid, .idle_refresh_ms = idle_refresh_ms orelse 500 };
    }
    if (background or http_address != null or tty_path != null or host_file != null or parent_pid != null or idle_refresh_ms != null) return error.HeadlessRequired;
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
        return .{ .allocator = allocator, .sessions = try sessions.toOwnedSlice(allocator), .listen_path = listen_path, .presentation = presentation };
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

    return .{ .allocator = allocator, .sessions = try sessions.toOwnedSlice(allocator), .listen_path = listen_path, .presentation = presentation };
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

test "wm presentation mode applies to normal multiple sessions and listener" {
    var parsed = try parse(std.testing.allocator, &.{ "wm", "--presentation", "placeholder", "--listen", "/tmp/wm.sock", "sonic", "mi2" });
    defer parsed.deinit();
    try std.testing.expectEqual(PresentationMode.placeholder, parsed.presentation);
    try std.testing.expectEqual(@as(usize, 2), parsed.sessions.len);
    try std.testing.expectEqualStrings("/tmp/wm.sock", parsed.listen_path.?);
    try std.testing.expectError(error.InvalidPresentationMode, parse(std.testing.allocator, &.{ "wm", "--presentation", "bad" }));
    try std.testing.expectError(error.UnsupportedHostOption, parse(std.testing.allocator, &.{ "wm", "--placeholder", "777", "60", "20", "mi2" }));
}

test "headless cli keeps external client ownership separate from desktop sessions" {
    var parsed = try parse(std.testing.allocator, &.{ "wm", "--headless", "--background", "--tty", "/dev/ttys001", "--http", "127.0.0.1:0" });
    defer parsed.deinit();
    try std.testing.expect(parsed.headless and parsed.background);
    try std.testing.expectEqual(PresentationMode.placeholder, parsed.presentation);
    try std.testing.expectError(error.HeadlessRequiresPlaceholder, parse(std.testing.allocator, &.{ "wm", "--headless", "--presentation", "positioned" }));
    try std.testing.expectError(error.HeadlessClientsOwnSessions, parse(std.testing.allocator, &.{ "wm", "--headless", "sonic" }));
    try std.testing.expectError(error.HeadlessRequired, parse(std.testing.allocator, &.{ "wm", "--tty", "/dev/tty" }));
}

test "idle refresh defaults to 500 ms and can be disabled for headless hosts" {
    var defaults = try parse(std.testing.allocator, &.{ "wm", "--headless" });
    defer defaults.deinit();
    try std.testing.expectEqual(@as(u32, 500), defaults.idle_refresh_ms);
    var disabled = try parse(std.testing.allocator, &.{ "wm", "--headless", "--idle-refresh-ms", "0" });
    defer disabled.deinit();
    try std.testing.expectEqual(@as(u32, 0), disabled.idle_refresh_ms);
    try std.testing.expectError(error.InvalidIdleRefresh, parse(std.testing.allocator, &.{ "wm", "--headless", "--idle-refresh-ms", "-1" }));
    try std.testing.expectError(error.HeadlessRequired, parse(std.testing.allocator, &.{ "wm", "--idle-refresh-ms", "500" }));
}
