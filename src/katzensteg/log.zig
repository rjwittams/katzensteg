const std = @import("std");

var file_mutex: std.Thread.Mutex = .{};
var file: ?std.fs.File = null;
var logger_ref_count: usize = 0;

fn levelName(comptime level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "err",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn formatStdLogLineInto(buffer: []u8, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), message: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "katzensteg: " ++ levelName(level) ++ "(" ++ @tagName(scope) ++ "): {s}", .{message});
}

pub fn formatStdLogLineForTest(allocator: std.mem.Allocator, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), message: []const u8) ![]u8 {
    var line_buf: [1280]u8 = undefined;
    const line = try formatStdLogLineInto(&line_buf, level, scope, message);
    return allocator.dupe(u8, line);
}

pub fn formatStdLogMessageForTest(allocator: std.mem.Allocator, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) ![]u8 {
    const message = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(message);
    return formatStdLogLineForTest(allocator, level, scope, message);
}

pub fn stdLogFn(comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
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
    if (std.mem.eql(u8, scope, "darwin_rebinder")) return writeCLogScoped(.darwin_rebinder, message);
    writeCLogScoped(.c, message);
}

fn writeCLogScoped(comptime scope: @Type(.enum_literal), message: []const u8) void {
    var line_buf: [1280]u8 = undefined;
    const line = formatStdLogLineInto(&line_buf, .warn, scope, message) catch return;
    writeLine(line);
}

fn writeLine(message: []const u8) void {
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

fn retainLoggerFileUser() void {
    file_mutex.lock();
    defer file_mutex.unlock();
    logger_ref_count += 1;
}

fn releaseLoggerFileUser() void {
    file_mutex.lock();
    defer file_mutex.unlock();
    if (logger_ref_count > 0) logger_ref_count -= 1;
    if (logger_ref_count == 0) closeFile();
}

fn ensureFileLocked() !*std.fs.File {
    if (file == null) {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/katzensteg-{d}.log", .{std.c.getpid()});
        file = try std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false });
    }
    return &file.?;
}

pub const Logger = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    once: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator) Logger {
        retainLoggerFileUser();
        return .{ .allocator = allocator, .once = std.AutoHashMap(u64, void).init(allocator) };
    }

    pub fn deinit(self: *Logger) void {
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

    pub fn writeScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), message: []const u8) void {
        _ = self;
        var line_buf: [1280]u8 = undefined;
        const line = formatStdLogLineInto(&line_buf, level, scope, message) catch return;
        writeLine(line);
    }

    pub fn writeFmtScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), comptime fmt: []const u8, args: anytype) void {
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

    pub fn writeOnceScoped(self: *Logger, comptime level: std.log.Level, comptime scope: @Type(.enum_literal), message: []const u8) void {
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
