const std = @import("std");
const ClientChannel = @import("client.zig").ClientChannel;
const control = @import("producer_control.zig");

// Process and transport ownership shared by the desktop and external frontends.
// External producers have no child: closing one only closes its connection.
pub const Producer = struct {
    child: ?std.process.Child = null,
    channel: ClientChannel = .{ .stdio = .{} },

    pub fn spawn(allocator: std.mem.Allocator, executable: []const u8, profile: []const u8, args: []const []const u8) !Producer {
        const argv = try buildArgv(allocator, executable, profile, args);
        defer allocator.free(argv);
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        errdefer _ = child.kill() catch {};
        try child.waitForSpawn();
        var channel = ClientChannel{ .stdio = .{ .control = child.stdin, .presentation = child.stdout, .allocator = allocator } };
        child.stdin = null;
        child.stdout = null;
        errdefer channel.deinit();
        if (channel.controlFile()) |file| try nonblocking(file.handle);
        if (channel.presentationFile()) |file| try nonblocking(file.handle);
        return .{ .child = child, .channel = channel };
    }

    pub fn shutdown(self: *Producer) void {
        control.writeShutdownControl(self.channel.writer()) catch {};
        self.channel.closeControl();
    }

    pub fn pollExit(self: *Producer) !?std.process.Child.Term {
        const child = if (self.child) |*child| child else return null;
        if (child.term) |term| return try term;
        try child.waitForSpawn();
        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid == 0) return null;
        const term = termFromStatus(result.status);
        child.term = term;
        return term;
    }

    pub fn deinit(self: *Producer) void {
        self.channel.deinit();
        if (self.child) |*child| {
            if (child.term == null) _ = child.kill() catch {};
        }
        self.child = null;
    }
};

pub fn buildArgv(allocator: std.mem.Allocator, executable: []const u8, profile: []const u8, args: []const []const u8) ![]const []const u8 {
    const argv = try allocator.alloc([]const u8, 3 + args.len);
    argv[0] = executable;
    argv[1] = "--embed-jsonl";
    argv[2] = profile;
    @memcpy(argv[3..], args);
    return argv;
}

pub fn nonblocking(fd: std.posix.fd_t) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    var typed: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    typed.NONBLOCK = true;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed)));
}

pub fn termFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

test "failed executable does not become a producer session" {
    try std.testing.expectError(error.FileNotFound, Producer.spawn(std.testing.allocator, "/nonexistent/katzensteg", "sonic", &.{}));
}
