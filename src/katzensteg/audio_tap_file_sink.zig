//! Diagnostic tap sink for tests, composed only when `KATZENSTEG_AUDIO_TAP_FILE`
//! names a base path. Each stream's unscaled bytes and block start times are
//! copied into buffers allocated when the stream opens (blocks past them are
//! dropped), then written on the closing app thread as `<base>.<sequence>.raw`
//! and `<base>.<sequence>.times` (one native-endian u64 nanosecond time per
//! block). Nothing goes to stdout or stderr.

const std = @import("std");
const audio_model = @import("audio_model.zig");

const seconds = 30;
const allocator = std.heap.c_allocator;

const Capture = struct {
    bytes: []u8 = &.{},
    bytes_len: usize = 0,
    times: []u64 = &.{},
    times_len: usize = 0,
};

pub const TapFileSink = struct {
    base_path: []const u8,
    captures: [audio_model.max_streams]Capture = [_]Capture{.{}} ** audio_model.max_streams,

    pub fn sink(self: *TapFileSink) audio_model.TapSink {
        return .{ .context = self, .opened = opened, .consume = consume, .closed = closed };
    }

    fn opened(context: *anyopaque, stream: audio_model.StreamInfo) void {
        const self: *TapFileSink = @ptrCast(@alignCast(context));
        self.captures[stream.id] = .{
            .bytes = allocator.alloc(u8, @as(usize, seconds) * stream.spec.rate * stream.spec.frame_bytes) catch &.{},
            .times = allocator.alloc(u64, seconds * 1000) catch &.{},
        };
    }

    fn consume(context: *anyopaque, block: *const audio_model.Block) void {
        const capture = &@as(*TapFileSink, @ptrCast(@alignCast(context))).captures[block.stream.id];
        if (capture.times_len == capture.times.len or capture.bytes_len + block.bytes.len > capture.bytes.len) return;
        @memcpy(capture.bytes[capture.bytes_len..][0..block.bytes.len], block.bytes);
        capture.bytes_len += block.bytes.len;
        capture.times[capture.times_len] = block.time_ns;
        capture.times_len += 1;
    }

    fn closed(context: *anyopaque, stream: audio_model.StreamInfo) void {
        const self: *TapFileSink = @ptrCast(@alignCast(context));
        const capture = &self.captures[stream.id];
        self.write(stream.sequence, "raw", capture.bytes[0..capture.bytes_len]);
        self.write(stream.sequence, "times", std.mem.sliceAsBytes(capture.times[0..capture.times_len]));
        allocator.free(capture.bytes);
        allocator.free(capture.times);
        capture.* = .{};
    }

    fn write(self: *TapFileSink, sequence: u32, suffix: []const u8, data: []const u8) void {
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}.{d}.{s}", .{ self.base_path, sequence, suffix }) catch return;
        const file = std.c.fopen(path.ptr, "wb") orelse return;
        _ = std.c.fwrite(data.ptr, 1, data.len, file);
        _ = std.c.fclose(file);
    }
};
