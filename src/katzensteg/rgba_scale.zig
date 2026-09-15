const std = @import("std");
const builtin = @import("builtin");
extern fn ks_fast_scale_rgba(dst: [*]u8, dst_w: c_int, dst_h: c_int, src: [*]const u8, src_w: c_int, src_h: c_int) callconv(.c) c_int;

pub fn into(dst: []u8, dst_w: i32, dst_h: i32, src: []const u8, src_w: i32, src_h: i32) void {
    if (comptime !builtin.is_test and (builtin.os.tag == .macos or builtin.os.tag == .linux)) {
        if (ks_fast_scale_rgba(dst.ptr, dst_w, dst_h, src.ptr, src_w, src_h) != 0) return;
    }
    for (0..@intCast(dst_h)) |y| {
        const sy = y * @as(usize, @intCast(src_h)) / @as(usize, @intCast(dst_h));
        for (0..@intCast(dst_w)) |x| {
            const sx = x * @as(usize, @intCast(src_w)) / @as(usize, @intCast(dst_w));
            const si = (sy * @as(usize, @intCast(src_w)) + sx) * 4;
            const di = (y * @as(usize, @intCast(dst_w)) + x) * 4;
            @memcpy(dst[di..][0..4], src[si..][0..4]);
        }
    }
}
