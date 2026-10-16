//! The published track sink: the first playback stream the app opens goes to
//! the Jackstay playback track (src/jackstay/playback.zig), unscaled, in the
//! stream's own format and stamped at each block's play time. The track is
//! added on the first open, updated on a reopen, idle while no stream is open
//! and withdrawn when the app quits audio. Other streams are not published.

const std = @import("std");
const jackstay = @import("jackstay");
const audio_model = @import("audio_model.zig");

const log = std.log.scoped(.audio);

const none = std.math.maxInt(audio_model.StreamId);

/// The stream being published, `none` while the track is idle.
var published: std.atomic.Value(audio_model.StreamId) = .init(none);

pub const sink: audio_model.TapSink = .{ .context = &published, .opened = opened, .consume = consume, .closed = closed, .quit = quit };

fn opened(_: *anyopaque, stream: audio_model.StreamInfo, label: []const u8) void {
    if (published.load(.acquire) != none) return log.warn("sequence={d}: another device is already published; not publishing this one", .{stream.sequence});
    const spec = stream.spec;
    const sample: jackstay.playback.Sample = switch (spec.format) {
        .u8 => .u8,
        .s16 => .s16,
        .s32 => .s32,
        .f32 => .f32,
        .other => return log.warn("sequence={d}: Jackstay has no track format for this sample format; not publishing it", .{stream.sequence}),
    };
    jackstay.playback.track.open(label, .{ .rate = spec.rate, .channels = spec.channels, .sample = sample }) catch |err| {
        return log.err("sequence={d}: publishing the playback track failed: {any}", .{ stream.sequence, err });
    };
    published.store(stream.id, .release);
    log.info("publishing sequence={d} label={s} rate={d} channels={d} sample={s}", .{ stream.sequence, label, spec.rate, spec.channels, @tagName(sample) });
}

fn consume(_: *anyopaque, block: *const audio_model.Block) void {
    if (published.load(.acquire) != block.stream.id) return;
    jackstay.playback.track.write(block.bytes, block.time_ns, block.discontinuity);
}

fn closed(_: *anyopaque, stream: audio_model.StreamInfo) void {
    _ = published.cmpxchgStrong(stream.id, none, .acq_rel, .acquire);
}

fn quit(_: *anyopaque) void {
    jackstay.playback.track.quit();
}
