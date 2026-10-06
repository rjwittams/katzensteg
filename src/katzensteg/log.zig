const std = @import("std");
const system_io = @import("platform");

// Preload libraries share the core library's file and lifetime state. Hosts
// and unit tests have their own process and keep the local backend.
const shared_file = if (@hasDecl(@import("root"), "katzensteg_shared_log")) @import("root").katzensteg_shared_log else false;
const CoreLog = struct {
    extern fn ks_katzensteg_log_write_line(message: [*]const u8, len: usize) callconv(.c) void;
    extern fn ks_katzensteg_log_retain() callconv(.c) void;
    extern fn ks_katzensteg_log_release() callconv(.c) void;
};

var file_io: std.Io.Threaded = .init_single_threaded;
var file_mutex: system_io.Mutex = .{};
var file: ?system_io.fs.File = null;
var logger_ref_count: usize = 0;
var opened_once: bool = false;
var test_path: ?[]const u8 = null;

fn levelName(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "err",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn formatStdLogLineInto(buffer: []u8, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), message: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "katzensteg: " ++ levelName(level) ++ "(" ++ @tagName(scope) ++ "): {s}", .{message});
}

pub fn formatStdLogLineForTest(allocator: std.mem.Allocator, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), message: []const u8) ![]u8 {
    var line_buf: [1280]u8 = undefined;
    const line = try formatStdLogLineInto(&line_buf, level, scope, message);
    return allocator.dupe(u8, line);
}

pub fn formatStdLogMessageForTest(allocator: std.mem.Allocator, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) ![]u8 {
    const message = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(message);
    return formatStdLogLineForTest(allocator, level, scope, message);
}

pub fn stdLogFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var message_buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, format, args) catch return;
    var line_buf: [1280]u8 = undefined;
    const line = formatStdLogLineInto(&line_buf, level, scope, message) catch return;
    writeLine(line);
}

pub fn writeCLog(scope: []const u8, message: []const u8) void {
    if (std.mem.eql(u8, scope, "real_sdl")) return writeCLogScoped(.real_sdl, message);
    if (std.mem.eql(u8, scope, "real_gl")) return writeCLogScoped(.real_gl, message);
    if (std.mem.eql(u8, scope, "vulkan")) return writeCLogScoped(.vulkan, message);
    if (std.mem.eql(u8, scope, "metal")) return writeCLogScoped(.metal, message);
    if (std.mem.eql(u8, scope, "darwin_rebinder")) return writeCLogScoped(.darwin_rebinder, message);
    writeCLogScoped(.c, message);
}

fn writeCLogScoped(comptime scope: @TypeOf(.enum_literal), message: []const u8) void {
    var line_buf: [1280]u8 = undefined;
    const line = formatStdLogLineInto(&line_buf, .warn, scope, message) catch return;
    writeLine(line);
}

pub fn writeLine(message: []const u8) void {
    if (shared_file) return CoreLog.ks_katzensteg_log_write_line(message.ptr, message.len);
    file_mutex.lock();
    defer file_mutex.unlock();
    writeLineLocked(message);
}

fn writeLineLocked(message: []const u8) void {
    const output = ensureFileLocked() catch return;
    var writer = output.writerStreaming(&.{});
    writer.interface.writeAll(message) catch return;
    writer.interface.writeAll("\n") catch return;
    writer.interface.flush() catch return;
}

fn closeFile() void {
    if (file) |f| {
        f.close();
        file = null;
    }
}

pub fn retainLoggerFileUser() void {
    if (shared_file) return CoreLog.ks_katzensteg_log_retain();
    file_mutex.lock();
    defer file_mutex.unlock();
    logger_ref_count += 1;
}

pub fn releaseLoggerFileUser() void {
    if (shared_file) return CoreLog.ks_katzensteg_log_release();
    file_mutex.lock();
    defer file_mutex.unlock();
    if (logger_ref_count > 0) logger_ref_count -= 1;
    if (logger_ref_count == 0) closeFile();
}

fn ensureFileLocked() !*system_io.fs.File {
    // Opening a file by path can need more stack than the application thread
    // that logs first has (see runOnLargeStack).
    if (file == null) system_io.runOnLargeStack(openFileLocked, .{});
    if (file) |*f| return f;
    return error.LogFileUnavailable;
}

/// Leaves `file` null on failure; `ensureFileLocked` reports that and
/// logging is then dropped, since the runtime must not write to stdout or
/// stderr.
fn openFileLocked() void {
    var path_buf: [512]u8 = undefined;
    const path = if (@import("builtin").is_test and test_path != null) test_path.? else std.fmt.bufPrint(&path_buf, "{s}/katzensteg-{d}.log", .{ system_io.fs.logDir(), system_io.process.id() }) catch return;
    const opened = system_io.fs.createFileAbsolute(file_io.io(), path, .{ .truncate = !opened_once, .read = false }) catch return;
    // The shared mutex serializes all module writers. A fresh handle starts
    // at zero, so a reopen must explicitly resume at the end of this run.
    if (opened_once) opened.seekFromEnd(0) catch {
        opened.close();
        return;
    };
    file = opened;
    opened_once = true;
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    mutex: system_io.Mutex = .{},
    once: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator) Logger {
        retainLoggerFileUser();
        return .{ .allocator = allocator, .once = std.AutoHashMap(u64, void).init(allocator) };
    }

    pub fn deinit(self: *Logger) void {
        defer self.mutex.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.once.deinit();
        releaseLoggerFileUser();
    }

    pub fn write(self: *Logger, message: []const u8) void {
        _ = self;
        writeLine(message);
    }

    pub fn writeFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(msg);
    }

    pub fn writeScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), message: []const u8) void {
        _ = self;
        var line_buf: [1280]u8 = undefined;
        const line = formatStdLogLineInto(&line_buf, level, scope, message) catch return;
        writeLine(line);
    }

    pub fn writeFmtScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
        var message_buf: [1024]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, fmt, args) catch return;
        self.writeScoped(level, scope, message);
    }

    pub fn writeOnce(self: *Logger, message: []const u8) void {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(message);
        const key = hasher.final();
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.once.getOrPut(key) catch return;
        if (!gop.found_existing) writeLine(message);
    }

    pub fn writeOnceScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), message: []const u8) void {
        var line_buf: [1280]u8 = undefined;
        const line = formatStdLogLineInto(&line_buf, level, scope, message) catch return;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(line);
        const key = hasher.final();
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.once.getOrPut(key) catch return;
        if (!gop.found_existing) writeLine(line);
    }
};

test "std log line formatting includes level and scope" {
    const line = try formatStdLogLineForTest(std.testing.allocator, .warn, .config, "unknown field");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("katzensteg: warn(config): unknown field", line);
}

test "std log format adapter applies central prefix" {
    const line = try formatStdLogMessageForTest(std.testing.allocator, .info, .runtime, "loaded {s}", .{"config"});
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("katzensteg: info(runtime): loaded config", line);
}

test "scoped once formatting uses central prefix" {
    const line = try formatStdLogLineForTest(std.testing.allocator, .warn, .frame_builder, "unsupported geometry");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("katzensteg: warn(frame_builder): unsupported geometry", line);
}

test "C log adapter uses central file prefix" {
    const line = try formatStdLogLineForTest(std.testing.allocator, .warn, .real_sdl, "failed");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("katzensteg: warn(real_sdl): failed", line);
}

test "C log adapter maps unknown scopes to static fallback scope" {
    const line = try formatStdLogLineForTest(std.testing.allocator, .warn, .c, "failed");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("katzensteg: warn(c): failed", line);
}

// Real file operations exercise the public logger lifecycle without touching
// another process's /tmp log. Only unit tests can override the destination.
const LogTest = struct {
    tmp: system_io.fs.TmpDir,
    path: [:0]u8,

    fn init(stale: []const u8) !LogTest {
        var tmp = system_io.fs.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "runtime.log", .data = stale });
        const path = try tmp.dir.value.realPathFileAlloc(std.testing.io, "runtime.log", std.testing.allocator);
        file_mutex.lock();
        defer file_mutex.unlock();
        std.debug.assert(logger_ref_count == 0);
        closeFile();
        opened_once = false;
        test_path = path;
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *LogTest) void {
        file_mutex.lock();
        std.debug.assert(logger_ref_count == 0);
        closeFile();
        opened_once = false;
        test_path = null;
        file_mutex.unlock();
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn expect(self: *LogTest, expected: []const u8) !void {
        const actual = try self.tmp.dir.readFileAlloc(std.testing.allocator, "runtime.log", 65536);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
};

test "first log open removes a reused PID file's stale tail" {
    // A new process's first write replaces all old content, even when its
    // first line is shorter than the previous run's file.
    var fixture = try LogTest.init("old run\nstale queued replay worker exiting\n");
    defer fixture.deinit();
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();
    logger.write("new");
    try fixture.expect("new\n");
}

test "reopen after the last logger closes preserves this run's lines" {
    // Every reopen resumes at EOF rather than erasing earlier output.
    var fixture = try LogTest.init("");
    defer fixture.deinit();
    for (0..3) |_| {
        var logger = Logger.init(std.testing.allocator);
        logger.write("line");
        logger.deinit();
    }
    try fixture.expect("line\nline\nline\n");
}

test "two openers share one file and closing one preserves the other" {
    // Interleaved logger lifetimes preserve all lines; only the last close
    // closes the shared handle, and a later opener continues this run.
    var fixture = try LogTest.init("stale contents");
    defer fixture.deinit();
    var first = Logger.init(std.testing.allocator);
    var second = Logger.init(std.testing.allocator);
    first.write("first");
    second.write("second");
    first.deinit();
    second.write("still open");
    second.deinit();
    var third = Logger.init(std.testing.allocator);
    defer third.deinit();
    third.write("");
    try fixture.expect("first\nsecond\nstill open\n\n");
}

test "an unavailable first destination does not consume the fresh open" {
    // Failed logging is silent, and the first successful open still removes
    // old PID content rather than treating a failed attempt as initialization.
    var fixture = try LogTest.init("stale contents");
    defer fixture.deinit();
    const invalid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing", .{fixture.path});
    defer std.testing.allocator.free(invalid_path);
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();
    file_mutex.lock();
    test_path = invalid_path;
    file_mutex.unlock();
    logger.write("dropped");
    try fixture.expect("stale contents");
    file_mutex.lock();
    test_path = fixture.path;
    file_mutex.unlock();
    logger.write("successful");
    try fixture.expect("successful\n");
}
