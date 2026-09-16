//! PTY relay owned by the headless host's event loop. No input interpretation.
const std = @import("std");
const os = @import("platform");
const Boundary = @import("output_boundary.zig").Boundary;
extern "c" fn forkpty(*c_int, ?[*]u8, ?*const std.posix.termios, ?*const std.posix.winsize) c_int;
extern "c" fn cfmakeraw(*std.posix.termios) void;

const Buffer = struct {
    bytes: [65536]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    fn empty(self: *const Buffer) bool {
        return self.start == self.end;
    }
    fn flush(self: *Buffer, fd: i32) !void {
        if (self.empty()) return;
        const n = os.posix.write(fd, self.bytes[self.start..self.end]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        self.start += n;
        if (self.empty()) {
            self.start = 0;
            self.end = 0;
        }
    }
};

pub const Relay = struct {
    outer: i32,
    master: i32,
    child: std.posix.pid_t,
    original: std.posix.termios,
    size: std.posix.winsize,
    output: Buffer = .{},
    input: Buffer = .{},
    boundary: Boundary = .{},
    eof: bool = false,
    exit_code: ?u8 = null,
    exited_at: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, argv: []const []const u8, descriptor: []const u8) !Relay {
        // A separate open description avoids changing the calling shell's flags.
        const outer = try os.posix.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        errdefer os.posix.close(outer);
        const original = try os.posix.tcgetattr(outer);
        var size = try windowSize(outer);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var env = try os.process.getEnvMap(alloc);
        try env.put("KATZENSTEG_WM_HOST", descriptor);
        var envp = try alloc.allocSentinel(?[*:0]const u8, env.count(), null);
        var it = env.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) envp[i] = try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0);
        var args = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |arg, n| args[n] = try alloc.dupeZ(u8, arg);
        // Expand PATH before fork. The child only makes async-signal-safe calls.
        var candidates: std.ArrayList([*:0]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
            try candidates.append(alloc, args[0].?);
        } else {
            var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "/usr/bin:/bin", ':');
            while (paths.next()) |dir| try candidates.append(alloc, try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ if (dir.len == 0) "." else dir, argv[0] }, 0));
        }
        var master: c_int = undefined;
        const pid = forkpty(&master, null, &original, &size);
        if (pid < 0) return error.PtySpawnFailed;
        if (pid == 0) {
            const default = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
            for ([_]std.posix.SIG{ .INT, .TERM, .HUP, .PIPE, .QUIT, .TSTP, .TTIN, .TTOU, .WINCH }) |sig| std.posix.sigaction(sig, &default, null);
            for (candidates.items) |candidate| {
                _ = std.c.execve(candidate, args.ptr, envp.ptr);
            }
            const message = "katzensteg-wm: cannot execute wrapped command\r\n";
            _ = std.c.write(2, message, message.len);
            std.c._exit(127);
        }
        errdefer {
            std.posix.kill(-pid, .KILL) catch {};
            _ = os.posix.waitpid(pid, 0) catch {};
            os.posix.close(master);
        }
        try @import("producer.zig").nonblocking(master);
        _ = try os.posix.fcntl(master, std.posix.F.SETFD, std.posix.FD_CLOEXEC);
        var raw = original;
        cfmakeraw(&raw);
        try os.posix.tcsetattr(outer, .NOW, raw);
        return .{ .outer = outer, .master = master, .child = pid, .original = original, .size = size };
    }
    pub fn deinit(self: *Relay) void {
        // Closing the PTY hangs up descendants too. Reap the direct child if
        // shutdown came from a wrapper signal or a terminal/transport error.
        const deadline = os.time.milliTimestamp() + 250;
        while (!self.output.empty() and os.time.milliTimestamp() < deadline) {
            self.output.flush(self.outer) catch break;
            if (!self.output.empty()) os.time.sleep(std.time.ns_per_ms);
        }
        std.posix.kill(-self.child, .HUP) catch {};
        os.posix.close(self.master);
        if (self.exit_code == null) {
            std.posix.kill(self.child, .KILL) catch {};
            _ = os.posix.waitpid(self.child, 0) catch {};
        }
        os.posix.tcsetattr(self.outer, .NOW, self.original) catch {};
        os.posix.close(self.outer);
    }
    fn windowSize(fd: i32) !std.posix.winsize {
        var size: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) return error.TerminalSizeUnavailable;
        return size;
    }
    pub fn canInject(self: *const Relay) bool {
        return self.output.empty() and self.boundary.safe();
    }
    pub fn graphics(self: *Relay, bytes: []const u8) !void {
        if (!self.canInject()) return error.OutputDeferred;
        if (bytes.len > self.output.bytes.len) return error.GraphicsBatchTooLarge;
        @memcpy(self.output.bytes[0..bytes.len], bytes);
        self.output.end = bytes.len;
    }
    pub fn done(self: *const Relay) bool {
        // Descendants retaining the slave cannot keep a finished command alive.
        return self.exit_code != null and self.output.empty() and (self.eof or os.time.milliTimestamp() - self.exited_at >= 1000);
    }
    pub fn tick(self: *Relay) !void {
        var outer_poll = [_]std.posix.pollfd{.{ .fd = self.outer, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = try os.posix.poll(&outer_poll, 0);
        if (outer_poll[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return error.TerminalDisconnected;
        const size = try windowSize(self.outer);
        if (!std.meta.eql(size, self.size)) {
            if (std.posix.system.ioctl(self.master, (if (@import("builtin").os.tag == .macos) @as(i32, @bitCast(@as(u32, 0x80087467))) else std.posix.T.IOCSWINSZ), @intFromPtr(&size)) != 0) return error.PtyResizeFailed;
            self.size = size;
        }
        if (self.exit_code == null) {
            const result = try os.posix.waitpid(self.child, std.posix.W.NOHANG);
            if (result.pid != 0) {
                self.exit_code = if (std.posix.W.IFEXITED(result.status)) std.posix.W.EXITSTATUS(result.status) else @intCast(@min(255, 128 + @as(u32, @intFromEnum(std.posix.W.TERMSIG(result.status)))));
                self.exited_at = os.time.milliTimestamp();
            }
        }
        try self.output.flush(self.outer);
        if (self.output.empty() and !self.eof) {
            const n = os.posix.read(self.master, &self.output.bytes) catch |err| switch (err) {
                error.WouldBlock => 0,
                error.InputOutput => blk: {
                    self.eof = true;
                    break :blk 0;
                }, // Linux PTY EOF
                else => return err,
            };
            if (n > 0) {
                self.output.end = n;
                self.boundary.feed(self.output.bytes[0..n]);
                try self.output.flush(self.outer);
            } else {
                // Distinguish a quiet master from EOF without treating EAGAIN as exit.
                var fd = [_]std.posix.pollfd{.{ .fd = self.master, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = try os.posix.poll(&fd, 0);
                if (fd[0].revents & std.posix.POLL.HUP != 0) self.eof = true;
            }
        }
        if (self.exit_code == null and !self.eof) {
            try self.input.flush(self.master);
            if (self.input.empty()) {
                const n = os.posix.read(self.outer, &self.input.bytes) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                self.input.end = n;
                try self.input.flush(self.master);
            }
        }
    }
    pub fn pollDescriptors(self: *const Relay, fds: []std.posix.pollfd) usize {
        fds[0] = .{ .fd = self.outer, .events = (if (!self.output.empty()) @as(i16, std.posix.POLL.OUT) else 0) | (if (self.input.empty() and self.exit_code == null) @as(i16, std.posix.POLL.IN) else 0), .revents = 0 };
        fds[1] = .{ .fd = self.master, .events = (if (self.output.empty() and !self.eof) @as(i16, std.posix.POLL.IN) else 0) | (if (!self.input.empty()) @as(i16, std.posix.POLL.OUT) else 0), .revents = 0 };
        return 2;
    }
};

test {
    _ = @import("output_boundary.zig");
}
