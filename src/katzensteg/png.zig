const std = @import("std");

// RGBA8 PNG with filter 0 and stored DEFLATE blocks. Observation is on demand;
// avoid a codec dependency and preserve source pixels exactly.
pub fn write(allocator: std.mem.Allocator, writer: anytype, width: i32, height: i32, rgba: []const u8) !void {
    if (width <= 0 or height <= 0) return error.InvalidFrame;
    const stride = @as(usize, @intCast(width)) * 4;
    if (@as(u64, @intCast(height)) * stride != rgba.len or rgba.len > 64 * 1024 * 1024) return error.InvalidFrame;
    try writer.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(height), .big);
    header[8..].* = .{ 8, 6, 0, 0, 0 };
    try chunk(writer, "IHDR", &header);
    var data = std.ArrayList(u8).empty;
    defer data.deinit(allocator);
    try data.appendSlice(allocator, &.{ 0x78, 0x01 }); // zlib, no compression
    const total = (@as(usize, @intCast(height))) * (stride + 1);
    var offset: usize = 0;
    var adler_a: u32 = 1;
    var adler_b: u32 = 0;
    while (offset < total) {
        const count: u16 = @intCast(@min(total - offset, 65535));
        try data.append(allocator, if (offset + count == total) 1 else 0);
        var lengths: [4]u8 = undefined;
        std.mem.writeInt(u16, lengths[0..2], count, .little);
        std.mem.writeInt(u16, lengths[2..4], ~count, .little);
        try data.appendSlice(allocator, &lengths);
        for (offset..offset + count) |pos| {
            const col = pos % (stride + 1);
            const pixel: u8 = if (col == 0) 0 else rgba[(pos / (stride + 1)) * stride + col - 1];
            try data.append(allocator, pixel);
            adler_a = (adler_a + pixel) % 65521;
            adler_b = (adler_b + adler_a) % 65521;
        }
        offset += count;
    }
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, (adler_b << 16) | adler_a, .big);
    try data.appendSlice(allocator, &checksum);
    try chunk(writer, "IDAT", data.items);
    try chunk(writer, "IEND", "");
}

fn chunk(writer: anytype, kind: *const [4]u8, bytes: []const u8) !void {
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, @intCast(bytes.len), .big);
    try writer.writeAll(&number);
    try writer.writeAll(kind);
    try writer.writeAll(bytes);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    std.mem.writeInt(u32, &number, crc.final(), .big);
    try writer.writeAll(&number);
}
