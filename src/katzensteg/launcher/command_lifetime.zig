//! Private producer-to-launcher quit notification. The launcher owns deadlines;
//! the injected runtime only queues SDL quit and sends one byte.
const std = @import("std");
const builtin = @import("builtin");
const os = @import("platform");

pub const Supervisor = struct {
    parent_fd: std.posix.fd_t,
    child_fd: ?std.posix.fd_t,
    stop: std.atomic.Value(bool) = .init(false),
    // Set before TERM (not just KILL): either escalation may bypass tty cleanup.
    escalated: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    tty: ?os.fs.File = null,
    termios: ?std.posix.termios = null,

    pub fn init(io: std.Io) !Supervisor {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        defer os.posix.close(fds[1]);
        errdefer os.posix.close(fds[0]);
        _ = try os.posix.fcntl(fds[0], std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC));
        const child_fd: std.posix.fd_t = @intCast(try os.posix.fcntl(fds[1], std.posix.F.DUPFD, 100));
        var result = Supervisor{ .parent_fd = fds[0], .child_fd = child_fd };
        if (os.fs.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write })) |tty| {
            result.tty = tty;
            result.termios = os.posix.tcgetattr(tty.handle) catch null;
        } else |_| {}
        return result;
    }

    pub fn started(self: *Supervisor, pid: std.posix.pid_t) !void {
        os.posix.close(self.child_fd.?);
        self.child_fd = null;
        self.thread = try std.Thread.spawn(.{}, watch, .{ self, pid });
    }

    pub fn deinit(self: *Supervisor) void {
        self.stop.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        if (self.child_fd) |fd| os.posix.close(fd);
        os.posix.close(self.parent_fd);
        if (self.tty) |tty| {
            if (self.escalated.load(.seq_cst)) if (self.termios) |original| {
                os.posix.tcsetattr(tty.handle, .FLUSH, original) catch {};
            };
            tty.close();
        }
    }

    fn watch(self: *Supervisor, pid: std.posix.pid_t) void {
        while (!self.stop.load(.seq_cst)) {
            var poll = [_]std.posix.pollfd{.{ .fd = self.parent_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((os.posix.poll(&poll, 25) catch return) == 0) continue;
            var byte: [1]u8 = undefined;
            if ((os.posix.read(self.parent_fd, &byte) catch return) != 1) return;
            if (byte[0] == 'q') {
                // Direct apps share the caller's foreground process group.
                // Signal only our child, never the shell or terminal host.
                terminateAfterGrace(pid, &self.stop, &self.escalated);
                return;
            }
        }
    }
};

/// A negative target is a hosted process group; a positive one a direct child.
pub fn terminateAfterGrace(target: std.posix.pid_t, stop: ?*std.atomic.Value(bool), escalated: ?*std.atomic.Value(bool)) void {
    if (target == 0) return;
    for (0..60) |_| {
        if (stop) |flag| if (flag.load(.seq_cst)) return;
        os.time.sleep(25 * std.time.ns_per_ms);
    }
    if (stop) |flag| if (flag.load(.seq_cst)) return;
    if (escalated) |flag| flag.store(true, .seq_cst);
    std.posix.kill(target, std.posix.SIG.TERM) catch {};
    for (0..10) |_| {
        if (stop) |flag| if (flag.load(.seq_cst)) return;
        os.time.sleep(25 * std.time.ns_per_ms);
    }
    if (stop) |flag| if (flag.load(.seq_cst)) return;
    std.posix.kill(target, std.posix.SIG.KILL) catch {};
}

/// The inherited descriptor number the launcher passes in the runtime config.
pub const NotifyFd = i32;

/// Takes ownership of the configured notification descriptor. The launcher
/// supervises commands only on POSIX so far; Windows runtimes ignore it and
/// command quit relies on the SDL quit event alone.
pub fn adoptNotifier(configured: ?NotifyFd) ?NotifyFd {
    if (builtin.os.tag == .windows) return null;
    const fd = configured orelse return null;
    _ = os.posix.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)) catch {};
    return fd;
}

pub fn releaseNotifier(fd: NotifyFd) void {
    if (builtin.os.tag == .windows) return;
    os.posix.close(fd);
}

pub fn notify(fd: NotifyFd) bool {
    if (builtin.os.tag == .windows) return false;
    // Never block an input pump or change the injected app's SIGPIPE handler.
    while (true) {
        const sent = std.c.send(fd, "q", 1, std.c.MSG.NOSIGNAL | std.c.MSG.DONTWAIT);
        if (sent == 1) return true;
        if (std.posix.errno(sent) != .INTR) return false;
    }
}

test "quit notification is one byte and a closed launcher cannot raise SIGPIPE" {
    // The launcher supervises commands through a socketpair on POSIX only.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer os.posix.close(fds[1]);
    var parent_open = true;
    defer if (parent_open) os.posix.close(fds[0]);
    try std.testing.expect(notify(fds[1]));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try os.posix.read(fds[0], &byte));
    try std.testing.expectEqual(@as(u8, 'q'), byte[0]);
    os.posix.close(fds[0]);
    parent_open = false;
    try std.testing.expect(!notify(fds[1]));
}
