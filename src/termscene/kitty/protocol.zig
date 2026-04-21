const std = @import("std");

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

/// Upload raw RGBA pixel data for a specific image id.
/// Spec mapping: a=t (transmit), f=32 (raw RGBA), s/v = width/height, i = image id.
pub fn writeTransmitRgba(out: std.fs.File.DeprecatedWriter, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=t,f=32,s={d},v={d},i={d}", .{ w, h, image_id });
    try chunkedApc(out, prefix, rgba);
}

/// Create or replace a placement for a specific (image_id, placement_id) pair.
/// Spec mapping: sending a=p with the same image id and placement id replaces the prior placement.
pub fn writePlace(out: std.fs.File.DeprecatedWriter, row: i32, col: i32, placement: Placement) !void {
    try moveCursor(out, row, col);
    try out.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{
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
pub fn writeDeleteExactPlacement(out: std.fs.File.DeprecatedWriter, target: ExactPlacement) !void {
    try out.print("\x1b_Gq=2,a=d,d=i,i={d},p={d};\x1b\\", .{ target.image_id, target.placement_id });
}

pub fn moveCursor(out: std.fs.File.DeprecatedWriter, row: i32, col: i32) !void {
    try out.print("\x1b[{d};{d}H", .{ row, col });
}

fn chunkedApc(out: std.fs.File.DeprecatedWriter, prefix: []const u8, payload: []const u8) !void {
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
