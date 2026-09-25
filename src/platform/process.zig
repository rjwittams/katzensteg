const std = @import("std");
const Io = std.Io;
const File = @import("fs.zig").File;
const raw = @import("posix.zig");
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" var environ: [*:null]?[*:0]u8;
const is_windows = @import("builtin").os.tag == .windows;
fn environment() std.process.Environ {
    // Windows reads the process environment block afresh on each query.
    if (is_windows) return .{ .block = .global };
    const entries = if (@import("builtin").os.tag == .macos) _NSGetEnviron().* else environ;
    return .{ .block = .{ .slice = std.mem.span(entries) } };
}
pub fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (is_windows) return environment().getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => error.EnvironmentVariableNotFound,
        else => |e| e,
    };
    const value = environment().getPosix(key) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, value);
}
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// This process's numeric identifier, for naming per-process files.
pub fn id() u32 {
    if (is_windows) return GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return environment().createMap(allocator);
}
pub fn getCwdAlloc(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return std.process.currentPathAlloc(io, allocator);
}
pub fn execve(io: Io, _: std.mem.Allocator, argv: []const []const u8, env: *const std.process.Environ.Map) anyerror {
    return std.process.replace(io, .{ .argv = argv, .environ_map = env, .expand_arg0 = .expand });
}
pub const Child = struct {
    io: Io,
    argv: []const []const u8,
    allocator: std.mem.Allocator,
    env_map: ?*const std.process.Environ.Map = null,
    cwd: ?[]const u8 = null,
    pgid: ?std.posix.pid_t = null,
    stdin_behavior: StdIo = .Inherit,
    stdout_behavior: StdIo = .Inherit,
    stderr_behavior: StdIo = .Inherit,
    stdin: ?File = null,
    stdout: ?File = null,
    stderr: ?File = null,
    id: std.posix.pid_t = undefined,
    term: ?anyerror!Term = null,
    child: ?std.process.Child = null,
    pub const StdIo = enum { Inherit, Ignore, Pipe, Close };
    pub const Term = union(enum) { Exited: u8, Signal: u32, Stopped: u32, Unknown: u32 };
    pub fn init(io: Io, argv: []const []const u8, allocator: std.mem.Allocator) Child {
        return .{ .io = io, .argv = argv, .allocator = allocator };
    }
    fn stdio(value: StdIo) std.process.SpawnOptions.StdIo {
        return switch (value) {
            .Inherit => .inherit,
            .Ignore => .ignore,
            .Pipe => .pipe,
            .Close => .close,
        };
    }
    fn termFromNative(value: std.process.Child.Term) Term {
        return switch (value) {
            .exited => |v| .{ .Exited = v },
            .signal => |v| .{ .Signal = @intFromEnum(v) },
            .stopped => |v| .{ .Stopped = @intFromEnum(v) },
            .unknown => |v| .{ .Unknown = v },
        };
    }
    pub fn spawn(self: *Child) !void {
        self.child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .environ_map = self.env_map,
            .pgid = self.pgid,
            .cwd = if (self.cwd) |path| .{ .path = path } else .inherit,
            .stdin = stdio(self.stdin_behavior),
            .stdout = stdio(self.stdout_behavior),
            .stderr = stdio(self.stderr_behavior),
        });
        const child = &self.child.?;
        self.id = child.id.?;
        self.stdin = if (child.stdin) |f| File.fromNative(self.io, f) else null;
        self.stdout = if (child.stdout) |f| File.fromNative(self.io, f) else null;
        self.stderr = if (child.stderr) |f| File.fromNative(self.io, f) else null;
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
    }
    pub fn spawnAndWait(self: *Child) !Term {
        try self.spawn();
        return self.wait();
    }
    pub fn waitForSpawn(self: *Child) !void {
        if (self.child == null) return error.NotSpawned;
    }
    pub fn wait(self: *Child) !Term {
        defer self.closeStreams();
        if (self.term) |term| return term;
        const term = termFromNative(self.child.?.wait(self.io) catch |err| {
            self.term = err;
            return err;
        });
        self.term = term;
        return term;
    }
    fn closeStreams(self: *Child) void {
        inline for (.{ "stdin", "stdout", "stderr" }) |name| {
            if (@field(self, name)) |file| file.close();
            @field(self, name) = null;
        }
    }
    pub fn kill(self: *Child) !Term {
        if (self.term) |term| {
            self.closeStreams();
            return term;
        }
        if (is_windows) {
            // TerminateProcess, then the handle is reaped with the process.
            self.child.?.kill(self.io);
            self.closeStreams();
            const term: Term = .{ .Unknown = 1 };
            self.term = term;
            return term;
        }
        std.posix.kill(self.id, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
        return self.wait();
    }
    pub fn run(io: Io, options: struct { allocator: std.mem.Allocator, argv: []const []const u8, max_output_bytes: usize }) !struct { stdout: []u8, stderr: []u8, term: Term } {
        const result = try std.process.run(options.allocator, io, .{ .argv = options.argv, .stdout_limit = .limited(options.max_output_bytes), .stderr_limit = .limited(options.max_output_bytes) });
        return .{ .stdout = result.stdout, .stderr = result.stderr, .term = termFromNative(result.term) };
    }
};

extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;
pub fn argsAlloc(io: Io, allocator: std.mem.Allocator) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    if (@import("builtin").os.tag == .macos) {
        const count: usize = @intCast(_NSGetArgc().*);
        for (_NSGetArgv().*[0..count]) |arg| {
            const copy = try allocator.dupe(u8, std.mem.span(arg));
            errdefer allocator.free(copy);
            try args.append(allocator, copy);
        }
    } else {
        const file = try @import("fs.zig").openFileAbsolute(io, "/proc/self/cmdline", .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
        defer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = std.mem.indexOfScalarPos(u8, bytes, offset, 0) orelse bytes.len;
            const copy = try allocator.dupe(u8, bytes[offset..end]);
            errdefer allocator.free(copy);
            try args.append(allocator, copy);
            offset = end + 1;
        }
    }
    return args.toOwnedSlice(allocator);
}
pub fn argsFree(allocator: std.mem.Allocator, args: [][]const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}
