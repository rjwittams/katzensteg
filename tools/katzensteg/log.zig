const std = @import("std");

pub const Logger = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    file: ?std.fs.File = null,
    once: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{ .allocator = allocator, .once = std.AutoHashMap(u64, void).init(allocator) };
    }

    pub fn deinit(self: *Logger) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.file) |f| f.close();
        self.once.deinit();
    }

    pub fn write(self: *Logger, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writeLocked(message);
    }

    fn writeLocked(self: *Logger, message: []const u8) void {
        const file = self.ensureFileLocked() catch return;
        var writer = file.writerStreaming(&.{});
        writer.interface.writeAll(message) catch return;
        writer.interface.writeAll("\n") catch return;
        writer.interface.flush() catch return;
    }

    pub fn writeFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(msg);
    }

    pub fn writeOnce(self: *Logger, message: []const u8) void {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(message);
        const key = hasher.final();
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.once.getOrPut(key) catch return;
        if (!gop.found_existing) self.writeLocked(message);
    }

    fn ensureFileLocked(self: *Logger) !*std.fs.File {
        if (self.file == null) {
            var path_buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "/tmp/katzensteg-{d}.log", .{std.c.getpid()});
            self.file = try std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false });
        }
        return &self.file.?;
    }
};
