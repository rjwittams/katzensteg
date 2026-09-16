const std = @import("std");
const system_io = @import("platform");
extern "c" fn ttyname_r(fd: std.c.fd_t, buf: [*]u8, len: usize) c_int;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    file: system_io.fs.File,
    path: []const u8,

    pub fn open(io: std.Io, allocator: std.mem.Allocator, explicit: ?[]const u8, parent: ?i32) !Terminal {
        if (explicit) |path| {
            if (!std.mem.eql(u8, path, "/dev/tty")) return openPath(io, allocator, path);
        }
        // /dev/tty is a controlling-terminal alias, not a stable device fd.
        // Resolve the real device before setsid, even for explicit /dev/tty.
        if (try openForProcess(io, allocator, std.c.getpid(), 1)) |terminal| return terminal;
        return (try openForProcess(io, allocator, parent orelse std.c.getppid(), 32)) orelse error.TerminalNotFound;
    }

    fn openForProcess(io: std.Io, allocator: std.mem.Allocator, initial_pid: i32, depth: usize) !?Terminal {
        var pid = initial_pid;
        for (0..depth) |_| {
            if (pid <= 1) break;
            const number = try std.fmt.allocPrint(allocator, "{d}", .{pid});
            defer allocator.free(number);
            const result = try system_io.process.Child.run(io, .{ .allocator = allocator, .argv = &.{ "/bin/ps", "-o", "ppid=,tty=", "-p", number }, .max_output_bytes = 4096 });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            var words = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
            pid = std.fmt.parseInt(i32, words.next() orelse break, 10) catch break;
            const tty = words.next() orelse break;
            if (std.mem.eql(u8, tty, "??") or std.mem.eql(u8, tty, "?") or std.mem.eql(u8, tty, "-")) continue;
            const path = if (std.mem.startsWith(u8, tty, "/dev/")) try allocator.dupe(u8, tty) else try std.fmt.allocPrint(allocator, "/dev/{s}", .{tty});
            defer allocator.free(path);
            return try openPath(io, allocator, path);
        }
        return null;
    }

    fn openPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Terminal {
        const file = system_io.fs.File{ .io = io, .handle = try system_io.posix.open(path, .{ .ACCMODE = .WRONLY, .NOCTTY = true, .CLOEXEC = true }, 0) };
        errdefer file.close();
        var name: [std.fs.max_path_bytes]u8 = undefined;
        if (ttyname_r(file.handle, &name, name.len) != 0) return error.NotATerminal;
        const resolved = std.mem.sliceTo(&name, 0);
        if (std.mem.eql(u8, resolved, "/dev/tty")) return error.ControllingTerminalAlias;
        return .{ .allocator = allocator, .file = file, .path = try allocator.dupe(u8, resolved) };
    }

    pub fn deinit(self: *Terminal) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    // This is a scheduling hint, not a lock against another terminal writer.
    // Some PTY implementations cannot report pending output; keep the existing
    // small-write behavior there instead of starving presentation indefinitely.
    pub fn outputQueued(self: *const Terminal) bool {
        // Darwin's _IOR('t', 115, int) is absent from Zig 0.15's std.c.T.
        const request = if (@import("builtin").os.tag == .macos) 0x40047473 else if (@hasDecl(std.posix.T, "IOCOUTQ")) std.posix.T.IOCOUTQ else return false;
        var pending: c_int = 0;
        if (std.posix.system.ioctl(self.file.handle, request, @intFromPtr(&pending)) != 0) return false;
        return pending > 0;
    }

    pub fn cellPixels(self: *const Terminal) ?struct { w: f64, h: f64 } {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        if (std.posix.system.ioctl(self.file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0 or size.col == 0 or size.row == 0 or size.xpixel == 0 or size.ypixel == 0) return null;
        return .{ .w = @as(f64, @floatFromInt(size.xpixel)) / @as(f64, @floatFromInt(size.col)), .h = @as(f64, @floatFromInt(size.ypixel)) / @as(f64, @floatFromInt(size.row)) };
    }
};

pub fn privateRoot(allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/katzensteg-wm-{d}", .{std.c.getuid()});
    errdefer allocator.free(path);
    system_io.posix.mkdir(path, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const stat = try system_io.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW);
    if (stat.uid != std.c.getuid() or stat.mode & 0o777 != 0o700 or stat.mode & std.posix.S.IFMT != std.posix.S.IFDIR) return error.UnsafeRuntimeDirectory;
    return path;
}

pub fn randomId(io: std.Io) [32]u8 {
    var random: [16]u8 = undefined;
    io.random(&random);
    return std.fmt.bytesToHex(random, .lower);
}
