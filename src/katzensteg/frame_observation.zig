const std = @import("std");

// Owned pixels: upload buffers and compositor storage may be reused immediately.
// Accessed only while the runtime holds its presentation mutex.
pub const FrameObservation = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: i32 = 0,
    height: i32 = 0,
    frame_id: u64 = 0,
    timestamp_ms: i64 = 0,

    pub fn deinit(self: *FrameObservation, allocator: std.mem.Allocator) void {
        self.pixels.deinit(allocator);
        self.* = .{};
    }

    pub fn retain(self: *FrameObservation, allocator: std.mem.Allocator, width: i32, height: i32, rgba: []const u8) !void {
        if (width <= 0 or height <= 0) return error.InvalidFrame;
        const len = @as(u64, @intCast(width)) * @as(u64, @intCast(height)) * 4;
        if (len > 64 * 1024 * 1024 or len != rgba.len) return error.InvalidFrame;
        try self.pixels.resize(allocator, rgba.len);
        @memcpy(self.pixels.items, rgba);
        self.width = width;
        self.height = height;
        self.frame_id += 1;
        self.timestamp_ms = std.time.milliTimestamp();
    }

    pub fn writePng(self: *const FrameObservation, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.pixels.items.len == 0) return error.NoFrame;
        const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        defer allocator.free(temporary);
        defer std.fs.deleteFileAbsolute(temporary) catch {};
        const file = try std.fs.createFileAbsolute(temporary, .{ .mode = 0o600 });
        {
            defer file.close();
            var output_writer = file.writerStreaming(&.{});
            try @import("png.zig").write(allocator, &output_writer.interface, self.width, self.height, self.pixels.items);
        }
        try std.fs.renameAbsolute(temporary, path);
    }

    pub fn write(self: *const FrameObservation, path: []const u8) !void {
        if (self.pixels.items.len == 0) return error.NoFrame;
        var file = try std.fs.createFileAbsolute(path, .{ .mode = 0o600 });
        defer file.close();
        try file.writeAll(self.pixels.items);
    }
};

test "observation owns its pixels and retains the most recent complete frame" {
    var observation: FrameObservation = .{};
    defer observation.deinit(std.testing.allocator);
    var pixels = [_]u8{ 1, 2, 3, 255 };
    try observation.retain(std.testing.allocator, 1, 1, &pixels);
    pixels[0] = 9;
    try std.testing.expectEqual(@as(u8, 1), observation.pixels.items[0]);
    try observation.retain(std.testing.allocator, 1, 1, &pixels);
    try std.testing.expectEqual(@as(u64, 2), observation.frame_id);
    try std.testing.expectEqual(@as(u8, 9), observation.pixels.items[0]);
    try std.testing.expectError(error.InvalidFrame, observation.retain(std.testing.allocator, 2, 1, &pixels));
    try std.testing.expectEqual(@as(u64, 2), observation.frame_id);
}
