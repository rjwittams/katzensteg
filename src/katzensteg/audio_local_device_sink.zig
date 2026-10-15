//! The local device sink: the buffer the adapter handed the model is what the
//! app's real SDL device plays, so playing means scaling it in place by the
//! gain (0 when muted or not routed locally). Gain 1 leaves the bytes alone
//! and gain 0 writes the format's silence byte; S16 and F32 scale, rounding
//! and saturating, and other formats play at unity gain.

const std = @import("std");
const audio_model = @import("audio_model.zig");

pub const sink: audio_model.LocalSink = .{ .play = play };

fn play(_: ?*anyopaque, block: *const audio_model.Block, buffer: []u8, gain: f32) void {
    if (gain == 1.0) return;
    if (gain <= 0.0) return @memset(buffer, block.stream.spec.silence);
    switch (block.stream.spec.format) {
        .s16 => for (std.mem.bytesAsSlice(i16, buffer[0 .. buffer.len & ~@as(usize, 1)])) |*sample| {
            sample.* = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(sample.*)) * gain), -32768, 32767));
        },
        .f32 => for (std.mem.bytesAsSlice(f32, buffer[0 .. buffer.len & ~@as(usize, 3)])) |*sample| {
            sample.* *= gain;
        },
        .u8, .s32, .other => {},
    }
}

test "S16 and F32 scale, other formats play at unity, gain 0 is the silence byte" {
    const block = struct {
        fn of(format: audio_model.SampleFormat, silence: u8) audio_model.Block {
            return .{ .stream = .{ .id = 0, .sequence = 1, .spec = .{ .format = format, .silence = silence, .channels = 2, .frame_bytes = 4, .rate = 48000 } }, .bytes = &.{}, .time_ns = 0 };
        }
    }.of;
    var s16 align(2) = [_]u8{0} ** 4;
    @as(*[2]i16, @ptrCast(&s16)).* = .{ 30000, -1001 };
    play(null, &block(.s16, 0), &s16, 0.5);
    try std.testing.expectEqual([2]i16{ 15000, -501 }, @as(*[2]i16, @ptrCast(&s16)).*);
    play(null, &block(.s16, 0), &s16, 4);
    try std.testing.expectEqual([2]i16{ 32767, -2004 }, @as(*[2]i16, @ptrCast(&s16)).*);

    var f32s = [_]f32{ 0.5, -0.25 };
    play(null, &block(.f32, 0), std.mem.sliceAsBytes(&f32s), 0.5);
    try std.testing.expectEqual([2]f32{ 0.25, -0.125 }, f32s);

    var u8s = [_]u8{ 0xc0, 0x40 };
    play(null, &block(.other, 0x80), &u8s, 0.5);
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x40 }, &u8s);
    play(null, &block(.other, 0x80), &u8s, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80 }, &u8s);
}
