const std = @import("std");
const system_io = @import("platform");
const protocol = @import("protocol.zig");

pub fn readReplies(io: std.Io, allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    return readRepliesFromFile(allocator, system_io.fs.File.stdin(io), timeout_ms);
}

pub fn readRepliesFromFile(allocator: std.mem.Allocator, file: system_io.fs.File, timeout_ms: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var reader = file;
    const start = system_io.time.milliTimestamp();
    var buf: [512]u8 = undefined;
    while (@as(u64, @intCast(system_io.time.milliTimestamp() - start)) < timeout_ms) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try list.appendSlice(allocator, buf[0..n]);
        } else {
            system_io.time.sleep(10 * std.time.ns_per_ms);
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn detectGraphicsSupport(io: std.Io, allocator: std.mem.Allocator, writer: anytype) !bool {
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readReplies(io, allocator, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

/// The terminal the probes below write queries to and read replies from.
pub const Tty = system_io.terminal.Tty;

pub fn detectGraphicsSupportOnTty(allocator: std.mem.Allocator, tty: Tty) !bool {
    var writer_state = tty.output.writerStreaming(&.{});
    const writer = &writer_state.interface;
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readRepliesFromFile(allocator, tty.input, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

pub fn detectSharedMemorySupport(allocator: std.mem.Allocator, tty: Tty) !bool {
    const object = @import("shared_memory.zig").Object.create(&.{ 0, 0, 0, 255 }) catch return false;
    defer object.unlink();
    var output = tty.output.writerStreaming(&.{});
    try protocol.writeQueryShmRgba(&output.interface, object.name());
    const reply = try readRepliesFromFile(allocator, tty.input, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "\x1b_Gi=33;OK\x1b\\") != null;
}

pub fn detectFileTransmissionSupport(allocator: std.mem.Allocator, tty: Tty, path: []const u8) !bool {
    return detectFileTransmissionSupportOffset(allocator, tty, path);
}

pub fn detectFileTransmissionSupportWhole(allocator: std.mem.Allocator, tty: Tty, path: []const u8) !bool {
    var writer_state = tty.output.writerStreaming(&.{});
    const writer = &writer_state.interface;
    try protocol.writeQueryFileRgbaWhole(writer, path, 1, 1);
    const reply = try readRepliesFromFile(allocator, tty.input, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

pub fn detectFileTransmissionSupportOffset(allocator: std.mem.Allocator, tty: Tty, path: []const u8) !bool {
    const io = tty.output.io;
    try prepareFileOffsetProbeData(io, path);
    if (!try detectFileTransmissionSupportOffsetAt(allocator, tty, path, 0)) return false;
    return detectFileTransmissionSupportOffsetAt(allocator, tty, path, 1);
}

fn detectFileTransmissionSupportOffsetAt(allocator: std.mem.Allocator, tty: Tty, path: []const u8, offset: u64) !bool {
    var writer_state = tty.output.writerStreaming(&.{});
    const writer = &writer_state.interface;
    try protocol.writeQueryFileRgbaRegion(writer, path, offset, 4, 1, 1);
    const reply = try readRepliesFromFile(allocator, tty.input, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "OK") != null;
}

fn prepareFileOffsetProbeData(io: std.Io, path: []const u8) !void {
    const file = try system_io.fs.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer file.close();
    const bytes = [_]u8{
        0,   0, 0, 255,
        255, 0, 0, 255,
    };
    try file.pwriteAll(&bytes, 0);
    try file.setEndPos(bytes.len);
    try file.sync();
}

test "file offset probe data is long enough for unaligned region query" {
    const io = std.testing.io;
    const path = "/tmp/katzensteg-file-offset-probe-test.rgba";
    {
        const file = try system_io.fs.createFileAbsolute(io, path, .{ .read = true, .truncate = true });
        file.close();
    }
    defer system_io.fs.deleteFileAbsolute(io, path) catch {};

    try prepareFileOffsetProbeData(io, path);

    const file = try system_io.fs.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close();
    try std.testing.expectEqual(@as(u64, 8), try file.getEndPos());
}
