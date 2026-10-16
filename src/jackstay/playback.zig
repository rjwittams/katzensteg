//! The published playback track (jackstay_audio.h): one ring the app's audio
//! thread writes directly. The track belongs to the process, not to a
//! publisher or consumer: after each consumer's handshake the publisher
//! announces its add, updates and removal (`version`) on that consumer's
//! notices.
//!
//! `open` and `quit` run on app threads and `write` on the audio thread of the
//! one stream being published, never concurrently with `open`. `write` never
//! allocates, blocks or takes the lock.
const std = @import("std");
const os = @import("platform");
const c = @import("media.zig").c;

pub const Sample = enum(u8) { u8 = c.FT_AUDIO_SAMPLE_U8, s16 = c.FT_AUDIO_SAMPLE_S16, s32 = c.FT_AUDIO_SAMPLE_S32, f32 = c.FT_AUDIO_SAMPLE_F32 };

pub const Format = struct {
    rate: u32,
    channels: u16,
    sample: Sample,

    fn toC(self: Format) c.ft_audio_format {
        // SDL's positioned layouts, in its channel order.
        const layout: u8 = switch (self.channels) {
            1 => c.FT_AUDIO_LAYOUT_MONO,
            2 => c.FT_AUDIO_LAYOUT_STEREO,
            3 => c.FT_AUDIO_LAYOUT_2_1,
            4 => c.FT_AUDIO_LAYOUT_QUAD,
            6 => c.FT_AUDIO_LAYOUT_5_1,
            8 => c.FT_AUDIO_LAYOUT_7_1,
            else => c.FT_AUDIO_LAYOUT_DISCRETE,
        };
        return .{ .rate = self.rate, .channels = self.channels, .layout = layout, .sample = @intFromEnum(self.sample) };
    }
};

/// After the video (1) and input (2) tracks.
const first_id: u64 = 3;
/// A device period longer than a block is written as several blocks.
const block_frames = 1024;

pub const Track = struct {
    /// App threads and the publisher; never the audio thread.
    mutex: os.Mutex = .{},
    writer: ?*c.ft_playback_writer = null,
    playback: ?*c.ft_playback = null,
    /// The offered track, 0 when none is.
    id: u64 = 0,
    next_id: u64 = first_id,
    label: [128:0]u8 = @splat(0),
    descriptor: c.ft_audio_descriptor = undefined,
    /// Advances at each add, update and removal.
    version: u64 = 0,
    /// The audio thread reads these; `open` sets them before the stream starts.
    frame_bytes: usize = 0,
    rate: u32 = 0,

    /// Adds the track, or on a reopen updates it with a discontinuity and,
    /// when the format changed, a reconfiguration. After `quit` a new track
    /// replaces the removed one.
    pub fn open(self: *Track, label: []const u8, format: Format) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const wanted = format.toC();
        // Every C call succeeds before any state changes, so a failure leaves
        // the track as it was.
        var descriptor: c.ft_audio_descriptor = undefined;
        if (self.id == 0) {
            var writer: ?*c.ft_playback_writer = null;
            var playback: ?*c.ft_playback = null;
            try check(c.ft_playback_writer_create(self.next_id, &wanted, block_frames, c.FT_AUDIO_MIN_DEPTH_NS, &writer, &playback));
            errdefer c.ft_playback_writer_destroy(&writer);
            errdefer c.ft_playback_destroy(&playback);
            try check(c.ft_playback_writer_descriptor(writer, &descriptor));
            c.ft_playback_writer_destroy(&self.writer);
            c.ft_playback_destroy(&self.playback);
            self.writer = writer;
            self.playback = playback;
            self.id = self.next_id;
            self.next_id += 1;
        } else {
            if (!std.meta.eql(wanted, self.descriptor.format)) try check(c.ft_playback_writer_reconfigure(self.writer, &wanted));
            try check(c.ft_playback_writer_discontinuity(self.writer));
            try check(c.ft_playback_writer_descriptor(self.writer, &descriptor));
        }
        self.descriptor = descriptor;
        const len = @min(label.len, self.label.len);
        @memcpy(self.label[0..len], label[0..len]);
        self.label[len] = 0;
        self.frame_bytes = @as(usize, format.channels) * @as(usize, switch (format.sample) {
            .u8 => 1,
            .s16 => 2,
            .s32, .f32 => 4,
        });
        self.rate = format.rate;
        self.version += 1;
    }

    /// The app quit audio: withdraws the track.
    pub fn quit(self: *Track) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.id == 0) return;
        self.id = 0;
        self.version += 1;
    }

    /// Audio thread: publishes `bytes` (whole frames, its first played at
    /// `time_ns`) in blocks of at most the ring's block size.
    pub fn write(self: *Track, bytes: []const u8, time_ns: u64, discontinuity: bool) void {
        if (discontinuity) _ = c.ft_playback_writer_discontinuity(self.writer);
        const chunk = @as(usize, self.descriptor.block_frames) * self.frame_bytes;
        var offset: usize = 0;
        while (bytes.len - offset >= self.frame_bytes) {
            const len = @min(chunk, (bytes.len - offset) / self.frame_bytes * self.frame_bytes);
            const frames: u64 = offset / self.frame_bytes;
            _ = c.ft_playback_writer_write(self.writer, bytes[offset..].ptr, len, time_ns + frames * std.time.ns_per_s / self.rate, null);
            offset += len;
        }
    }

    /// The current offer, under the lock; its label borrows the track.
    pub fn offer(self: *const Track) c.ft_track_offer {
        return std.mem.zeroInit(c.ft_track_offer, .{ .id = self.id, .kind = c.FT_TRACK_KIND_PLAYBACK, .label = &self.label, .direction = c.FT_TRACK_FROM_SOURCE, .audio = self.descriptor });
    }
};

/// The process's one published track.
pub var track: Track = .{};

fn check(status: c.ft_status) !void {
    if (status != c.FT_STATUS_OK) return error.JackstayFailure;
}
