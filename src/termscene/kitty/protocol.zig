const std = @import("std");

pub const Quiet = enum(u2) {
    none = 0,
    suppress_ok = 1,
    suppress_fail = 2,
};

pub const Placement = struct {
    image_id: u32,
    placement_id: u32,
    cols: i32,
    rows: i32,
    src_x: i32,
    src_y: i32,
    src_w: i32,
    src_h: i32,
    z: i32,
};

pub const ExactPlacement = struct {
    image_id: u32,
    placement_id: u32,
};

pub const ImageDeleteMode = enum(u8) {
    keep_data = 'i',
    free_data = 'I',
};

/// Upload raw RGBA pixel data for a specific image id.
/// Spec mapping: a=t (transmit), f=32 (raw RGBA), s/v = width/height, i = image id.
pub fn writeTransmitRgba(out: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    try writeTransmitRgbaWithQuiet(out, .suppress_fail, image_id, rgba, w, h);
}

pub fn writeTransmitRgbaWithQuiet(out: anytype, quiet: Quiet, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q={d},a=t,f=32,s={d},v={d},i={d}", .{ @intFromEnum(quiet), w, h, image_id });
    try chunkedApc(out, prefix, rgba);
}

/// The payload is only the POSIX SHM name. The terminal consumes and unlinks it.
pub fn writeTransmitRgbaShm(out: anytype, quiet: Quiet, image_id: u32, name: []const u8, w: i32, h: i32) !void {
    var buf: [160]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&buf, "q={d},a=t,t=s,f=32,s={d},v={d},i={d},S={d}", .{ @intFromEnum(quiet), w, h, image_id, @as(u64, @intCast(w)) * @as(u64, @intCast(h)) * 4 });
    try writeEncodedPayloadApc(out, prefix, name);
}

pub fn writeQueryShmRgba(out: anytype, name: []const u8) !void {
    try writeEncodedPayloadApc(out, "i=33,a=q,t=s,f=32,s=1,v=1,S=4", name);
}

/// Upload raw RGBA pixel data by asking the terminal to read the entire contents
/// of a regular file.
pub fn writeTransmitRgbaFileWhole(out: anytype, image_id: u32, path: []const u8, w: i32, h: i32) !void {
    try writeTransmitRgbaFileWholeWithQuiet(out, .suppress_fail, image_id, path, w, h);
}

pub fn writeTransmitRgbaFileWholeWithQuiet(out: anytype, quiet: Quiet, image_id: u32, path: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [160]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q={d},a=t,t=f,f=32,s={d},v={d},i={d}", .{ @intFromEnum(quiet), w, h, image_id });
    try writeEncodedPayloadApc(out, prefix, path);
}

/// Upload raw RGBA pixel data by asking the terminal to read a region from a regular file.
pub fn writeTransmitRgbaFileRegion(out: anytype, image_id: u32, path: []const u8, file_offset: u64, byte_len: usize, w: i32, h: i32) !void {
    try writeTransmitRgbaFileRegionWithQuiet(out, .suppress_fail, image_id, path, file_offset, byte_len, w, h);
}

pub fn writeTransmitRgbaFileRegionWithQuiet(out: anytype, quiet: Quiet, image_id: u32, path: []const u8, file_offset: u64, byte_len: usize, w: i32, h: i32) !void {
    var prefix_buf: [192]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q={d},a=t,t=f,f=32,s={d},v={d},i={d},S={d},O={d}", .{ @intFromEnum(quiet), w, h, image_id, byte_len, file_offset });
    try writeEncodedPayloadApc(out, prefix, path);
}

pub fn writeQueryFileRgbaWhole(out: anytype, path: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [160]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "i=32,a=q,t=f,f=32,s={d},v={d}", .{ w, h });
    try writeEncodedPayloadApc(out, prefix, path);
}

pub fn writeQueryFileRgbaRegion(out: anytype, path: []const u8, file_offset: u64, byte_len: usize, w: i32, h: i32) !void {
    var prefix_buf: [192]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "i=32,a=q,t=f,f=32,s={d},v={d},S={d},O={d}", .{ w, h, byte_len, file_offset });
    try writeEncodedPayloadApc(out, prefix, path);
}

// Virtual placement: no cursor addressing, source crop, offset, or z-order.
// The placement id matters: a placement without one is anonymous, and terminals
// keep every anonymous placement (ghostty assigns each an internal id), so a
// re-place after a grid change adds a second placement and placeholder cells may
// keep resolving to the old grid. With the same (image id, placement id) pair
// the new placement replaces the old one.
pub fn writeVirtualPlace(out: anytype, image_id: u32, placement_id: u32, cols: i32, rows: i32) !void {
    try out.print("\x1b_Ga=p,U=1,i={d},p={d},c={d},r={d},q=2;\x1b\\", .{ image_id, placement_id, cols, rows });
}

/// Create or replace a placement for a specific (image_id, placement_id) pair.
/// Spec mapping: sending a=p with the same image id and placement id replaces the prior placement.
pub fn writePlace(out: anytype, row: i32, col: i32, placement: Placement) !void {
    try writePlaceWithQuiet(out, .suppress_fail, row, col, placement);
}

pub fn writePlaceWithQuiet(out: anytype, quiet: Quiet, row: i32, col: i32, placement: Placement) !void {
    try moveCursor(out, row, col);
    try out.print("\x1b_Gq={d},a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{
        @intFromEnum(quiet),
        placement.image_id,
        placement.placement_id,
        placement.cols,
        placement.rows,
        placement.src_x,
        placement.src_y,
        placement.src_w,
        placement.src_h,
        placement.z,
    });
}

/// Delete one exact placement, identified by the pair (image_id, placement_id).
/// Spec mapping: a=d,d=i,i=<image_id>,p=<placement_id>
pub fn writeDeleteExactPlacement(out: anytype, target: ExactPlacement) !void {
    try writeDeleteExactPlacementWithQuiet(out, .suppress_fail, target);
}

pub fn writeDeleteExactPlacementWithQuiet(out: anytype, quiet: Quiet, target: ExactPlacement) !void {
    try out.print("\x1b_Gq={d},a=d,d=i,i={d},p={d};\x1b\\", .{ @intFromEnum(quiet), target.image_id, target.placement_id });
}

pub fn writeDeleteImageWithQuiet(out: anytype, quiet: Quiet, mode: ImageDeleteMode, image_id: u32) !void {
    try out.print("\x1b_Gq={d},a=d,d={c},i={d};\x1b\\", .{ @intFromEnum(quiet), @intFromEnum(mode), image_id });
}

pub fn moveCursor(out: anytype, row: i32, col: i32) !void {
    try out.print("\x1b[{d};{d}H", .{ row, col });
}

fn chunkedApc(out: anytype, prefix: []const u8, payload: []const u8) !void {
    const enc_len = std.base64.standard.Encoder.calcSize(payload.len);
    const b64 = try std.heap.page_allocator.alloc(u8, enc_len);
    defer std.heap.page_allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, payload);

    var offset: usize = 0;
    const chunk: usize = 3072;
    while (offset < b64.len) {
        const end = @min(offset + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        if (offset == 0) {
            try out.writeAll("\x1b_G");
            try out.writeAll(prefix);
            try out.print(",m={c};", .{more});
        } else {
            try out.print("\x1b_Gm={c};", .{more});
        }
        try out.writeAll(b64[offset..end]);
        try out.writeAll("\x1b\\");
        offset = end;
    }
}

fn writeEncodedPayloadApc(out: anytype, prefix: []const u8, payload: []const u8) !void {
    const enc_len = std.base64.standard.Encoder.calcSize(payload.len);
    const b64 = try std.heap.page_allocator.alloc(u8, enc_len);
    defer std.heap.page_allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, payload);

    try out.writeAll("\x1b_G");
    try out.writeAll(prefix);
    try out.writeAll(";");
    try out.writeAll(b64);
    try out.writeAll("\x1b\\");
}

test "protocol writers support memory writers" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writePlace(&out.writer, 4, 1, .{
        .image_id = 10,
        .placement_id = 20,
        .cols = 5,
        .rows = 3,
        .src_x = 0,
        .src_y = 0,
        .src_w = 16,
        .src_h = 16,
        .z = 100,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[4;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=p") != null);
}

test "SHM upload is a single APC carrying only the encoded name" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeTransmitRgbaShm(&out.writer, .suppress_fail, 42, "/ks-test", 1920, 1080);
    try std.testing.expectEqualStrings("\x1b_Gq=2,a=t,t=s,f=32,s=1920,v=1080,i=42,S=8294400;L2tzLXRlc3Q=\x1b\\", out.written());
}
