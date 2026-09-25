const std = @import("std");
const platform = @import("platform");
const is_windows = @import("builtin").os.tag == .windows;

test "directory creation follows directory symlinks but rejects files and dangling links" {
    // Creating symlinks on Windows needs a privilege test hosts may lack.
    if (is_windows) return error.SkipZigTest;
    var tmp = platform.fs.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.makePath("real");
    try tmp.dir.value.symLink(io, "real", "link", .{});
    try tmp.dir.makePath("link");
    try tmp.dir.makePath("link/child");
    try std.testing.expectEqual(.directory, (try tmp.dir.statFile("real/child")).kind);
    try tmp.dir.writeFile(.{ .sub_path = "file", .data = "x" });
    try std.testing.expectError(error.NotDir, tmp.dir.makePath("file"));
    try tmp.dir.value.symLink(io, "missing", "dangling", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.makePath("dangling"));
}

test "file offsets and bounded reads preserve content and allocation ownership" {
    var tmp = platform.fs.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("image", .{ .read = true });
    defer file.close();
    try file.writeAll("abcdef");
    try file.pwriteAll("XY", 2);
    var bytes: [6]u8 = undefined;
    try std.testing.expectEqual(6, try file.preadAll(&bytes, 0));
    try std.testing.expectEqualStrings("abXYef", &bytes);
    try file.seekTo(0);
    try std.testing.expectError(error.FileTooBig, file.readToEndAlloc(std.testing.allocator, 5));
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
}

test "buffered writer retains unsent data after nonblocking backpressure" {
    // Nonblocking pipes are a POSIX descriptor contract.
    if (is_windows) return error.SkipZigTest;
    const fds = try platform.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
    const input = platform.fs.File{ .handle = fds[0], .io = std.testing.io };
    defer input.close();
    const output = platform.fs.File{ .handle = fds[1], .io = std.testing.io };
    defer output.close();
    var block: [4096]u8 = @splat(7);
    try std.testing.expectError(error.WouldBlock, input.read(&block));
    while (true) {
        _ = output.write(&block) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    var buffer: [32]u8 = undefined;
    var writer = output.writer(&buffer);
    try writer.interface.writeAll("pending");
    try std.testing.expectError(error.WriteFailed, writer.interface.flush());
    try std.testing.expectEqual(error.WouldBlock, writer.err.?);
    try std.testing.expectEqualStrings("pending", writer.interface.buffer[0..writer.interface.end]);
    while (true) {
        _ = input.read(&block) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
    }
    try writer.interface.flush();
    const n = try input.read(&block);
    try std.testing.expectEqualStrings("pending", block[0..n]);
}

test "child reports spawn failure and transfers pipe ownership" {
    // Process control still uses POSIX signals and /bin/sh.
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var missing = platform.process.Child.init(io, &.{"/no/such/katzensteg-test-program"}, std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, missing.spawn());
    var child = platform.process.Child.init(io, &.{ "/bin/sh", "-c", "printf hello; exit 7" }, std.testing.allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    defer _ = child.kill() catch {};
    const output = child.stdout.?;
    child.stdout = null;
    defer output.close();
    const bytes = try output.readToEndAlloc(std.testing.allocator, 100);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello", bytes);
    try std.testing.expectEqual(@as(u8, 7), (try child.wait()).Exited);
    try std.testing.expectEqual(@as(u8, 7), (try child.wait()).Exited);
}

test "condition supports cross-thread wakeup and timeout" {
    const State = struct {
        mutex: platform.Mutex = .{},
        condition: platform.Condition = .{},
        ready: bool = false,
        fn run(self: *@This()) void {
            self.mutex.lock();
            self.ready = true;
            self.condition.signal();
            self.mutex.unlock();
        }
    };
    var state: State = .{};
    defer state.mutex.deinit();
    defer state.condition.deinit();
    state.mutex.lock();
    const thread = try std.Thread.spawn(.{}, State.run, .{&state});
    while (!state.ready) state.condition.wait(&state.mutex);
    try std.testing.expectError(error.Timeout, state.condition.timedWait(&state.mutex, std.time.ns_per_ms));
    state.mutex.unlock();
    thread.join();
}

test "pixel size replies prefer the text area and fall back to cells times the grid" {
    const PixelSize = platform.terminal.PixelSize;
    const parse = platform.terminal.parsePixelReply;
    try std.testing.expectEqual(PixelSize{ .width = 800, .height = 600 }, parse("\x1b[6;20;10t\x1b[4;600;800t", 80, 24).?);
    try std.testing.expectEqual(PixelSize{ .width = 800, .height = 480 }, parse("\x1b[?1;2c\x1b[6;20;10t", 80, 24).?);
    try std.testing.expectEqual(@as(?PixelSize, null), parse("\x1b[4;600", 80, 24));
    try std.testing.expectEqual(@as(?PixelSize, null), parse("\x1b[8;24;80t", 80, 24));
}

fn testLookup(comptime home: ?[]const u8, comptime profile: ?[]const u8) fn (std.mem.Allocator, []const u8) anyerror![]u8 {
    return struct {
        fn get(allocator: std.mem.Allocator, key: []const u8) anyerror![]u8 {
            const value = if (std.mem.eql(u8, key, "HOME")) home else profile;
            return allocator.dupe(u8, value orelse return error.EnvironmentVariableNotFound);
        }
    }.get;
}

test "homeDirOwned prefers HOME and falls back to USERPROFILE only on Windows" {
    const a = std.testing.allocator;
    const cases = .{
        .{ "/home/u", "C:\\Users\\u", false, "/home/u" },
        .{ "/home/u", "C:\\Users\\u", true, "/home/u" },
        .{ null, "C:\\Users\\u", true, "C:\\Users\\u" },
        .{ "", "C:\\Users\\u", true, "C:\\Users\\u" },
        .{ "", "C:\\Users\\u", false, "" },
    };
    inline for (cases) |case| {
        const got = try platform.process.homeDirFrom(a, case[2], testLookup(case[0], case[1]));
        defer a.free(got);
        try std.testing.expectEqualStrings(case[3], got);
    }
    try std.testing.expectError(error.EnvironmentVariableNotFound, platform.process.homeDirFrom(a, false, testLookup(null, "C:\\Users\\u")));
    try std.testing.expectError(error.EnvironmentVariableNotFound, platform.process.homeDirFrom(a, true, testLookup(null, null)));
}

fn recordThread(out: *std.Thread.Id) void {
    out.* = std.Thread.getCurrentId();
}

test "runOnLargeStack runs on a helper thread only on Windows and waits for it" {
    var ran_on: std.Thread.Id = 0;
    platform.runOnLargeStack(recordThread, .{&ran_on});
    try std.testing.expect(ran_on != 0);
    if (is_windows) {
        try std.testing.expect(ran_on != std.Thread.getCurrentId());
    } else {
        try std.testing.expectEqual(std.Thread.getCurrentId(), ran_on);
    }
}
