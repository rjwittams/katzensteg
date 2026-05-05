const std = @import("std");
const protocol = @import("protocol.zig");

pub fn readReplies(allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    return readRepliesFromFile(allocator, std.fs.File.stdin(), timeout_ms);
}

pub fn readRepliesFromFile(allocator: std.mem.Allocator, file: std.fs.File, timeout_ms: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var reader = file.deprecatedReader();
    const start = std.time.milliTimestamp();
    var buf: [512]u8 = undefined;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try list.appendSlice(allocator, buf[0..n]);
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn detectGraphicsSupport(allocator: std.mem.Allocator, writer: anytype) !bool {
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readReplies(allocator, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

pub fn detectGraphicsSupportOnTty(allocator: std.mem.Allocator, tty: std.fs.File) !bool {
    const writer = tty.deprecatedWriter();
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readRepliesFromFile(allocator, tty, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

pub fn detectFileTransmissionSupport(allocator: std.mem.Allocator, tty: std.fs.File, path: []const u8) !bool {
    return detectFileTransmissionSupportOffset(allocator, tty, path);
}

pub fn detectFileTransmissionSupportWhole(allocator: std.mem.Allocator, tty: std.fs.File, path: []const u8) !bool {
    const writer = tty.deprecatedWriter();
    try protocol.writeQueryFileRgbaWhole(writer, path, 1, 1);
    const reply = try readRepliesFromFile(allocator, tty, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

pub fn detectFileTransmissionSupportOffset(allocator: std.mem.Allocator, tty: std.fs.File, path: []const u8) !bool {
    try prepareFileOffsetProbeData(path);
    if (!try detectFileTransmissionSupportOffsetAt(allocator, tty, path, 0)) return false;
    return detectFileTransmissionSupportOffsetAt(allocator, tty, path, 1);
}

fn detectFileTransmissionSupportOffsetAt(allocator: std.mem.Allocator, tty: std.fs.File, path: []const u8, offset: u64) !bool {
    const writer = tty.deprecatedWriter();
    try protocol.writeQueryFileRgbaRegion(writer, path, offset, 4, 1, 1);
    const reply = try readRepliesFromFile(allocator, tty, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

fn prepareFileOffsetProbeData(path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();
    const bytes = [_]u8{
        0, 0, 0, 255,
        255, 0, 0, 255,
    };
    try file.pwriteAll(&bytes, 0);
    try file.setEndPos(bytes.len);
    try file.sync();
}

test "file offset probe data is long enough for unaligned region query" {
    const path = "/tmp/katzensteg-file-offset-probe-test.rgba";
    {
        const file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        file.close();
    }
    defer std.fs.deleteFileAbsolute(path) catch {};

    try prepareFileOffsetProbeData(path);

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();
    try std.testing.expectEqual(@as(u64, 8), try file.getEndPos());
}
