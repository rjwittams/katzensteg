//! Katzensteg's audio model: adapter -> model -> sinks (see CONTEXT.md and the
//! audio boundary in CLAUDE.md).
//!
//! An adapter opens a stream per playback device and, on the device's audio
//! thread, hands each block the app produced to `processBlock`. The tap sink
//! sees the block unscaled, then the local device sink scales the device
//! buffer in place: gain and mute reach only the local device sink. Gain, mute
//! and routing are atomics read once at the start of a block, so a change
//! lands on a block boundary. The model knows nothing about SDL or Jackstay.
//! `processBlock` never allocates, blocks or takes a lock.

const std = @import("std");
const system_io = @import("platform");

pub const max_streams = 8;

pub const StreamId = u8;

/// The model scales `s16` and `f32` (native endian). Other formats play at
/// unity gain, and gain 0 writes their silence byte.
pub const SampleFormat = enum { s16, f32, other };

pub const Spec = struct {
    format: SampleFormat,
    silence: u8,
    frame_bytes: u32,
    rate: u32,
};

pub const StreamInfo = struct {
    id: StreamId,
    /// 1 for the first stream the process opens, counting up across reopens.
    sequence: u32,
    spec: Spec,
};

pub const Block = struct {
    stream: StreamInfo,
    /// Unscaled samples, valid only during the sink call.
    bytes: []const u8,
    /// Injected clock at the start of the block.
    time_ns: u64,
    /// The pacing clock restarted or rebased before this block: it does not
    /// follow the previous block in time.
    discontinuity: bool = false,
};

pub const Clock = struct {
    context: ?*anyopaque = null,
    now_fn: *const fn (?*anyopaque) u64,
    /// Returns at or after the absolute time `deadline_ns`.
    sleep_until_fn: *const fn (?*anyopaque, deadline_ns: u64) void = hostSleepUntil,

    pub const monotonic: Clock = .{ .now_fn = hostNow };

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.context);
    }

    pub fn sleepUntil(self: Clock, deadline_ns: u64) void {
        self.sleep_until_fn(self.context, deadline_ns);
    }

    fn hostNow(_: ?*anyopaque) u64 {
        return system_io.time.hostTimeNs();
    }

    fn hostSleepUntil(_: ?*anyopaque, deadline_ns: u64) void {
        const now_ns = system_io.time.hostTimeNs();
        if (deadline_ns > now_ns) system_io.time.sleep(deadline_ns - now_ns);
    }
};

/// What paces the app's audio, fixed when the model is composed: the app's
/// real device, or the virtual paced device on the model's clock when nothing
/// plays locally.
pub const Pacing = enum { local_device, virtual_device };

/// Sees every block unscaled: where later sinks (a published track) attach.
/// `opened` and `closed` run on an app thread; `consume` on the audio thread.
pub const TapSink = struct {
    context: *anyopaque,
    opened: *const fn (context: *anyopaque, stream: StreamInfo) void,
    consume: *const fn (context: *anyopaque, block: *const Block) void,
    closed: *const fn (context: *anyopaque, stream: StreamInfo) void,
};

/// Plays through the app's real device: scales the device's buffer in place.
pub const LocalSink = struct {
    context: ?*anyopaque = null,
    play: *const fn (context: ?*anyopaque, block: *const Block, buffer: []u8, gain: f32) void,
};

const Stream = struct {
    open: std.atomic.Value(bool) = .init(false),
    info: StreamInfo = undefined,
};

pub const Model = struct {
    clock: Clock,
    local: LocalSink,
    tap: ?TapSink = null,
    pacing: Pacing = .local_device,

    gain_bits: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0))),
    muted: std.atomic.Value(bool) = .init(false),
    /// Routing: play through the real device (otherwise it plays silence and
    /// keeps its pacing), and hand blocks to the tap.
    route_local_device: std.atomic.Value(bool) = .init(true),
    route_tap: std.atomic.Value(bool) = .init(true),

    streams: [max_streams]Stream = [_]Stream{.{}} ** max_streams,
    next_sequence: u32 = 1,

    pub fn setGain(self: *Model, value: f32) void {
        self.gain_bits.store(@bitCast(if (value >= 0) value else 0), .release);
    }

    pub fn gain(self: *const Model) f32 {
        return @bitCast(self.gain_bits.load(.acquire));
    }

    /// The control path for command mode and the WM, on app threads that the
    /// caller serializes; the audio thread only loads the atomics. Volume steps
    /// by 10% within 0 to 100%, and mute is gain 0 at the local device sink.
    pub const Control = enum { toggle_mute, volume_up, volume_down };

    pub fn control(self: *Model, command: Control) void {
        switch (command) {
            .toggle_mute => self.muted.store(!self.muted.load(.acquire), .release),
            .volume_up, .volume_down => {
                const step = @round(self.gain() * 10) + @as(f32, if (command == .volume_up) 1 else -1);
                self.setGain(std.math.clamp(step, 0, 10) / 10);
            },
        }
    }

    pub fn volumePercent(self: *const Model) u8 {
        return @intFromFloat(@round(std.math.clamp(self.gain(), 0, 1) * 100));
    }

    /// Whether the app has a playback stream open.
    pub fn playing(self: *const Model) bool {
        for (&self.streams) |*stream| if (stream.open.load(.acquire)) return true;
        return false;
    }

    /// App thread; the caller serializes opens and closes. Null when every
    /// stream slot is in use.
    pub fn openStream(self: *Model, spec: Spec) ?StreamInfo {
        for (&self.streams, 0..) |*stream, index| {
            if (stream.open.load(.acquire)) continue;
            stream.info = .{ .id = @intCast(index), .sequence = self.next_sequence, .spec = spec };
            self.next_sequence += 1;
            if (self.tap) |tap| tap.opened(tap.context, stream.info);
            stream.open.store(true, .release);
            return stream.info;
        }
        return null;
    }

    /// App thread, once no further block for the stream can arrive.
    pub fn closeStream(self: *Model, id: StreamId) void {
        const stream = &self.streams[id];
        if (!stream.open.swap(false, .acq_rel)) return;
        if (self.tap) |tap| tap.closed(tap.context, stream.info);
    }

    /// Audio thread. `buffer` holds a block the app just produced; on return
    /// it holds what the device should play.
    pub fn processBlock(self: *Model, id: StreamId, buffer: []u8, discontinuity: bool) void {
        const stream = &self.streams[id];
        if (!stream.open.load(.acquire)) return;
        const to_tap = self.route_tap.load(.acquire);
        const silent = !self.route_local_device.load(.acquire) or self.muted.load(.acquire);
        const local_gain: f32 = if (silent) 0 else self.gain();

        const block: Block = .{ .stream = stream.info, .bytes = buffer, .time_ns = self.clock.now(), .discontinuity = discontinuity };
        if (to_tap) if (self.tap) |tap| tap.consume(tap.context, &block);
        self.local.play(self.local.context, &block, buffer, local_gain);
    }
};

// Tests: a fake adapter drives the model as an SDL callback does, with fake
// sinks and an injected clock.

const testing = std.testing;
const local_device_sink = @import("audio_local_device_sink.zig");

const FakeClock = struct {
    now_ns: u64 = 1_000,

    fn clock(self: *FakeClock) Clock {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: ?*anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(context.?));
        self.now_ns += 10;
        return self.now_ns;
    }
};

const FakeTap = struct {
    blocks: [8][8]u8 = undefined,
    times: [8]u64 = undefined,
    count: usize = 0,
    /// Posted from inside `consume`, as a concurrent poster would mid-block.
    route_local_device_mid_block: ?struct { model: *Model, value: bool } = null,

    fn sink(self: *FakeTap) TapSink {
        return .{ .context = self, .opened = ignore, .consume = consume, .closed = ignore };
    }

    fn ignore(_: *anyopaque, _: StreamInfo) void {}

    fn consume(context: *anyopaque, block: *const Block) void {
        const self: *FakeTap = @ptrCast(@alignCast(context));
        @memcpy(&self.blocks[self.count], block.bytes);
        self.times[self.count] = block.time_ns;
        self.count += 1;
        if (self.route_local_device_mid_block) |post| post.model.route_local_device.store(post.value, .release);
    }
};

/// Wraps the real local device sink and records each block's gain.
const RecordingLocalSink = struct {
    gains: [8]f32 = undefined,
    count: usize = 0,

    fn sink(self: *RecordingLocalSink) LocalSink {
        return .{ .context = self, .play = play };
    }

    fn play(context: ?*anyopaque, block: *const Block, buffer: []u8, gain_value: f32) void {
        const self: *RecordingLocalSink = @ptrCast(@alignCast(context.?));
        self.gains[self.count] = gain_value;
        self.count += 1;
        local_device_sink.sink.play(null, block, buffer, gain_value);
    }
};

/// Stands in for the SDL2 adapter: fills each block as an app callback would
/// and hands it to the model.
const FakeAdapter = struct {
    model: *Model,
    stream: StreamInfo,
    device: [8]u8 = undefined,

    fn open(model: *Model) FakeAdapter {
        return .{ .model = model, .stream = model.openStream(.{ .format = .s16, .silence = 0, .frame_bytes = 4, .rate = 48000 }).? };
    }

    /// Returns what the app produced; `self.device` holds what plays.
    fn callback(self: *FakeAdapter) [8]u8 {
        for (0..4) |i| std.mem.writeInt(i16, self.device[i * 2 ..][0..2], @intCast(1000 * (i + 1)), .little);
        const produced = self.device;
        self.model.processBlock(self.stream.id, &self.device, false);
        return produced;
    }
};

fn sampleAt(bytes: []const u8, index: usize) i16 {
    return std.mem.readInt(i16, bytes[index * 2 ..][0..2], .little);
}

test "gain and mute reach only the local device sink, and the tap stays unscaled" {
    var clock: FakeClock = .{};
    var local: RecordingLocalSink = .{};
    var tap: FakeTap = .{};
    var model: Model = .{ .clock = clock.clock(), .local = local.sink(), .tap = tap.sink() };
    var adapter = FakeAdapter.open(&model);

    model.setGain(0.5);
    var produced = adapter.callback();
    try testing.expectEqualSlices(u8, &produced, &tap.blocks[0]);
    for (0..4) |i| try testing.expectEqual(@divTrunc(sampleAt(&produced, i), 2), sampleAt(&adapter.device, i));

    model.muted.store(true, .release);
    produced = adapter.callback();
    try testing.expectEqualSlices(u8, &produced, &tap.blocks[1]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &adapter.device);

    model.muted.store(false, .release);
    model.setGain(0);
    produced = adapter.callback();
    try testing.expectEqualSlices(u8, &produced, &tap.blocks[2]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &adapter.device);

    try testing.expectEqualSlices(f32, &.{ 0.5, 0, 0 }, local.gains[0..local.count]);
    try testing.expectEqualSlices(u64, &.{ 1_010, 1_020, 1_030 }, tap.times[0..tap.count]);
}

test "routing changes apply at a block boundary" {
    var clock: FakeClock = .{};
    var local: RecordingLocalSink = .{};
    var tap: FakeTap = .{};
    var model: Model = .{ .clock = clock.clock(), .local = local.sink(), .tap = tap.sink() };
    var adapter = FakeAdapter.open(&model);

    // Posted mid-block: the block in flight keeps the routing it started
    // with, the next block picks up the new one.
    tap.route_local_device_mid_block = .{ .model = &model, .value = false };
    var produced = adapter.callback();
    tap.route_local_device_mid_block = null;
    try testing.expectEqualSlices(u8, &produced, &adapter.device);
    _ = adapter.callback();
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &adapter.device);
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, local.gains[0..local.count]);

    model.route_local_device.store(true, .release);
    model.route_tap.store(false, .release);
    produced = adapter.callback();
    try testing.expectEqual(@as(usize, 2), tap.count);
    try testing.expectEqualSlices(u8, &produced, &adapter.device);
}

test "the control path steps volume by 10% within 0 to 100% and toggles mute" {
    var clock: FakeClock = .{};
    var model: Model = .{ .clock = clock.clock(), .local = local_device_sink.sink };
    try testing.expect(!model.playing());
    const stream = model.openStream(.{ .format = .s16, .silence = 0, .frame_bytes = 4, .rate = 48000 }).?;
    try testing.expect(model.playing());

    model.setGain(0.34);
    model.control(.volume_up);
    try testing.expectEqual(@as(u8, 40), model.volumePercent());
    for (0..8) |_| model.control(.volume_up);
    try testing.expectEqual(@as(f32, 1), model.gain());
    for (0..12) |_| model.control(.volume_down);
    try testing.expectEqual(@as(f32, 0), model.gain());

    model.control(.toggle_mute);
    try testing.expect(model.muted.load(.acquire));
    model.control(.toggle_mute);
    try testing.expect(!model.muted.load(.acquire));
    model.closeStream(stream.id);
    try testing.expect(!model.playing());
}
