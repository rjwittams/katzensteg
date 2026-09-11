const std = @import("std");

pub const Destination = union(enum) {
    standalone,
    stdio,
    jsonl: []const u8,

    pub fn resolve(allocator: std.mem.Allocator, explicit_stdio: bool, target: ?[]const u8, home: ?[]const u8) !Destination {
        if (explicit_stdio) return .stdio;
        const value = target orelse return .standalone;
        if (!std.mem.startsWith(u8, value, "jsonl:")) return error.UnsupportedTarget;
        const address = value[6..];
        if (address.len == 0 or std.mem.indexOfScalar(u8, address, 0) != null) return error.InvalidTargetAddress;
        const path = if (std.mem.startsWith(u8, address, "~/"))
            try std.fs.path.join(allocator, &.{ home orelse return error.MissingHome, address[2..] })
        else
            try allocator.dupe(u8, address);
        return .{ .jsonl = path };
    }

    pub fn deinit(self: Destination, allocator: std.mem.Allocator) void {
        if (self == .jsonl) allocator.free(self.jsonl);
    }
};

// Destination discovery is independent of this terminal-specific transport.
// Consume only registration acknowledgement: hello/attach stay in the socket
// for the normal runtime control reader. No app is spawned until acceptance.
pub fn connectJsonl(allocator: std.mem.Allocator, path: []const u8, title: []const u8) !std.fs.File {
    const address = try std.net.Address.initUnix(path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
    errdefer std.posix.close(fd);
    var timer = try std.time.Timer.start();
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            try awaitReady(fd, std.posix.POLL.OUT, &timer);
            try std.posix.getsockoptError(fd);
        },
        else => return err,
    };
    const message = try std.json.Stringify.valueAlloc(allocator, .{ .type = "register", .version = @as(u32, 1), .title = title }, .{});
    defer allocator.free(message);
    if (message.len >= 1024) return error.RegistrationTooLong;
    try writeTimed(fd, message, &timer);
    try writeTimed(fd, "\n", &timer);
    var line: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < line.len) {
        try awaitReady(fd, std.posix.POLL.IN, &timer);
        const n = std.posix.read(fd, line[len..][0..1]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.HostRejected;
        if (line[len] == '\n') break;
        len += 1;
    }
    if (len == line.len) return error.InvalidRegistrationReply;
    const Reply = struct { type: []const u8, version: u32, session_id: u64 };
    const parsed = std.json.parseFromSlice(Reply, allocator, line[0..len], .{}) catch return error.InvalidRegistrationReply;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, "registered") or parsed.value.version != 1 or parsed.value.session_id == 0) return error.InvalidRegistrationReply;
    // Relay workers use blocking I/O on their own threads.
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    var typed: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    typed.NONBLOCK = false;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed)));
    return .{ .handle = fd };
}

fn awaitReady(fd: std.posix.fd_t, events: i16, timer: *std.time.Timer) !void {
    const elapsed = timer.read() / std.time.ns_per_ms;
    if (elapsed >= 5000) return error.HostTimeout;
    var poll = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    if (try std.posix.poll(&poll, @intCast(5000 - elapsed)) == 0) return error.HostTimeout;
}

fn writeTimed(fd: std.posix.fd_t, bytes: []const u8, timer: *std.time.Timer) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try awaitReady(fd, std.posix.POLL.OUT, timer);
        offset += std.posix.write(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

test "destination selection preserves standalone and explicit stdio precedence" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Destination.standalone, try Destination.resolve(a, false, null, null));
    try std.testing.expectEqual(Destination.stdio, try Destination.resolve(a, true, "bad:address", null));
    const remote = try Destination.resolve(a, false, "jsonl:~/wm.sock", "/home/test");
    defer remote.deinit(a);
    try std.testing.expectEqualStrings("/home/test/wm.sock", remote.jsonl);
    try std.testing.expectError(error.UnsupportedTarget, Destination.resolve(a, false, "jackstay:/tmp/s", null));
    try std.testing.expectError(error.UnsupportedTarget, Destination.resolve(a, false, "", null));
    try std.testing.expectError(error.InvalidTargetAddress, Destination.resolve(a, false, "jsonl:", null));
}
