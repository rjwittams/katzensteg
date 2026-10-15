//! The virtual paced device: when nothing plays locally, Katzensteg's own
//! clock paces the app instead of a real device.
//!
//! A thread per device renders one block of exactly `samples` frames at each
//! absolute deadline origin + frames * 10^9 / rate on the model's clock, so the
//! long-run drain rate is exactly nominal. A block up to 2 periods late runs at
//! once, so overdue blocks run back to back; later than that, the deadlines
//! rebase to now with a discontinuity. Unpausing restarts the clock with a
//! discontinuity, and a reopened device starts its own clock.
//!
//! Each block renders under the device lock, which the app takes with
//! `SDL_LockAudioDevice`; the thread takes no other lock and never allocates.

const std = @import("std");
const system_io = @import("platform");
const audio_model = @import("audio_model.zig");

pub const max_late_periods = 2;
/// The longest single sleep, so a stop request is seen within this long even
/// when a period is long or the device is paused.
pub const max_sleep_ns = 5 * std.time.ns_per_ms;

/// SDL's device lock is recursive: an app may nest it, or take it inside its
/// own callback.
pub const Lock = struct {
    mutex: system_io.Mutex = .{},
    /// Monotonic suffices: only the owning thread ever stores its own ID, and
    /// the mutex orders everything the lock protects.
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    depth: u32 = 0,

    pub fn lock(self: *Lock) void {
        const me = std.Thread.getCurrentId();
        if (self.owner.load(.monotonic) != me) {
            self.mutex.lock();
            self.owner.store(me, .monotonic);
        }
        self.depth += 1;
    }

    pub fn unlock(self: *Lock) void {
        self.depth -= 1;
        if (self.depth > 0) return;
        self.owner.store(0, .monotonic);
        self.mutex.unlock();
    }
};

pub const VirtualDevice = struct {
    clock: audio_model.Clock,
    rate: u32,
    samples: u32,
    buffer: []u8,
    context: *anyopaque,
    /// Fills `buffer` from the app and hands it to the model.
    render: *const fn (context: *anyopaque, buffer: []u8, discontinuity: bool) void,

    lock: Lock = .{},
    /// SDL opens devices paused.
    paused: std.atomic.Value(bool) = .init(true),
    restart: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    // Device thread only.
    origin_ns: u64 = 0,
    frames: u64 = 0,
    discontinuity: bool = false,

    /// App thread. The device must not move until `stop` returns.
    pub fn start(self: *VirtualDevice) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// App thread: returns once no further block can render.
    pub fn stop(self: *VirtualDevice) void {
        self.requestStop();
        self.join();
    }

    /// App thread: asks the device thread to exit within `max_sleep_ns` or
    /// one block. Safe under a lock the device thread never takes.
    pub fn requestStop(self: *VirtualDevice) void {
        self.stopping.store(true, .release);
    }

    /// App thread, after `requestStop`: waits for the device thread to exit.
    /// Call it without any lock the app's callback might take.
    pub fn join(self: *VirtualDevice) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// App thread.
    pub fn pause(self: *VirtualDevice, on: bool) void {
        if (self.paused.swap(on, .acq_rel) and !on) self.restart.store(true, .release);
    }

    fn run(self: *VirtualDevice) void {
        while (!self.stopping.load(.acquire)) self.step();
    }

    /// One pass of the device thread: sleeps toward the next deadline, or
    /// renders the block that is due.
    pub fn step(self: *VirtualDevice) void {
        const now = self.clock.now();
        if (self.paused.load(.acquire)) return self.clock.sleepUntil(now + @min(self.framesNs(self.samples), max_sleep_ns));
        if (self.restart.swap(false, .acq_rel)) self.rebase(now);
        const deadline = self.origin_ns + self.framesNs(self.frames);
        if (now < deadline) return self.clock.sleepUntil(@min(deadline, now + max_sleep_ns));
        if (now - deadline > max_late_periods * self.framesNs(self.samples)) self.rebase(now);
        self.lock.lock();
        self.render(self.context, self.buffer, self.discontinuity);
        self.lock.unlock();
        self.discontinuity = false;
        self.frames += self.samples;
    }

    fn rebase(self: *VirtualDevice, now: u64) void {
        self.origin_ns = now;
        self.frames = 0;
        self.discontinuity = true;
    }

    fn framesNs(self: *const VirtualDevice, frames: u64) u64 {
        return @intCast(@as(u128, frames) * std.time.ns_per_s / self.rate);
    }
};

// Tests: an injected clock whose sleeps jump straight to the deadline, and a
// render that records when each block ran.

const testing = std.testing;

/// Shared with the adapters' tests, which drive their render through `step`.
pub const FakeClock = struct {
    now_ns: u64 = 5_000,

    pub fn clock(self: *FakeClock) audio_model.Clock {
        return .{ .context = self, .now_fn = now, .sleep_until_fn = sleepUntil };
    }

    fn now(context: ?*anyopaque) u64 {
        return @as(*FakeClock, @ptrCast(@alignCast(context.?))).now_ns;
    }

    fn sleepUntil(context: ?*anyopaque, deadline_ns: u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(context.?));
        self.now_ns = @max(self.now_ns, deadline_ns);
    }
};

const Recorder = struct {
    clock: *FakeClock,
    times: [64]u64 = undefined,
    discontinuities: [64]bool = undefined,
    count: usize = 0,
    buffer: [4]u8 = undefined,

    fn open(self: *Recorder, rate: u32, samples: u32) VirtualDevice {
        return .{ .clock = self.clock.clock(), .rate = rate, .samples = samples, .buffer = &self.buffer, .context = self, .render = render };
    }

    fn render(context: *anyopaque, _: []u8, discontinuity: bool) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.times[self.count] = self.clock.now_ns;
        self.discontinuities[self.count] = discontinuity;
        self.count += 1;
    }

    /// Steps the device until it renders `blocks` more blocks.
    fn renderBlocks(self: *Recorder, device: *VirtualDevice, blocks: usize) void {
        const target = self.count + blocks;
        while (self.count < target) device.step();
    }
};

fn deadlineOf(origin: u64, block: u64, samples: u64, rate: u64) u64 {
    return origin + block * samples * std.time.ns_per_s / rate;
}

test "blocks run at absolute deadlines without drift" {
    var clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &clock };
    // 512 frames at 44.1 kHz is 11609977.32 ns: a relative sleep would drift.
    var device = recorder.open(44100, 512);
    device.pause(false);
    for (0..40) |block| {
        recorder.renderBlocks(&device, 1);
        try testing.expectEqual(deadlineOf(5_000, block, 512, 44100), recorder.times[block]);
        try testing.expectEqual(block == 0, recorder.discontinuities[block]);
    }
    // Waking late within a period does not move later deadlines.
    const late = deadlineOf(5_000, 40, 512, 44100) + 3_000_000;
    clock.now_ns = late;
    recorder.renderBlocks(&device, 2);
    try testing.expectEqualSlices(u64, &.{ late, deadlineOf(5_000, 41, 512, 44100) }, recorder.times[40..42]);
}

test "overdue blocks up to two periods late run back to back" {
    var clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &clock };
    var device = recorder.open(48000, 480); // 10 ms
    device.pause(false);
    recorder.renderBlocks(&device, 2);
    // Block 2 was due at 20 ms; a stall leaves the thread exactly two periods late.
    clock.now_ns = deadlineOf(5_000, 4, 480, 48000);
    recorder.renderBlocks(&device, 3);
    try testing.expectEqualSlices(u64, &.{ clock.now_ns, clock.now_ns, clock.now_ns }, recorder.times[2..5]);
    recorder.renderBlocks(&device, 1);
    try testing.expectEqual(deadlineOf(5_000, 5, 480, 48000), recorder.times[5]);
    try testing.expect(std.mem.allEqual(bool, recorder.discontinuities[1..6], false));
}

test "a block more than two periods late rebases the deadlines with a discontinuity" {
    var clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &clock };
    var device = recorder.open(48000, 480);
    device.pause(false);
    recorder.renderBlocks(&device, 2);
    const stalled = deadlineOf(5_000, 4, 480, 48000) + 1;
    clock.now_ns = stalled;
    recorder.renderBlocks(&device, 2);
    try testing.expectEqualSlices(u64, &.{ stalled, deadlineOf(stalled, 1, 480, 48000) }, recorder.times[2..4]);
    try testing.expectEqualSlices(bool, &.{ true, false }, recorder.discontinuities[2..4]);
}

test "pause stops the blocks and resuming restarts the clock" {
    var clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &clock };
    var device = recorder.open(48000, 480);
    for (0..3) |_| device.step();
    try testing.expectEqual(@as(usize, 0), recorder.count);
    device.pause(false);
    recorder.renderBlocks(&device, 2);
    device.pause(true);
    for (0..10) |_| device.step();
    try testing.expectEqual(@as(usize, 2), recorder.count);
    const resumed = clock.now_ns + 123;
    clock.now_ns = resumed;
    device.pause(false);
    recorder.renderBlocks(&device, 2);
    try testing.expectEqualSlices(u64, &.{ resumed, deadlineOf(resumed, 1, 480, 48000) }, recorder.times[2..4]);
    try testing.expectEqualSlices(bool, &.{ true, true, false }, &.{ recorder.discontinuities[0], recorder.discontinuities[2], recorder.discontinuities[3] });
}

test "a reopened device starts its own clock at its new period" {
    var clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &clock };
    var first = recorder.open(48000, 480);
    first.pause(false);
    recorder.renderBlocks(&first, 3);
    // Flycast reopens with half the period.
    clock.now_ns += 7;
    const reopened = clock.now_ns;
    var second = recorder.open(48000, 240);
    second.pause(false);
    recorder.renderBlocks(&second, 3);
    try testing.expectEqualSlices(u64, &.{ reopened, deadlineOf(reopened, 1, 240, 48000), deadlineOf(reopened, 2, 240, 48000) }, recorder.times[3..6]);
    try testing.expect(recorder.discontinuities[3]);
}

test "the device lock nests on one thread" {
    var lock: Lock = .{};
    lock.lock();
    lock.lock();
    lock.unlock();
    try testing.expectEqual(std.Thread.getCurrentId(), lock.owner.load(.monotonic));
    lock.unlock();
    const Other = struct {
        fn run(shared: *Lock) void {
            shared.lock();
            shared.unlock();
        }
    };
    const thread = try std.Thread.spawn(.{}, Other.run, .{&lock});
    thread.join();
}

test "a running device thread renders blocks and stops" {
    var recorder_clock: FakeClock = .{};
    var recorder: Recorder = .{ .clock = &recorder_clock };
    var device = recorder.open(48000, 48);
    device.clock = .monotonic;
    device.render = struct {
        fn render(context: *anyopaque, _: []u8, _: bool) void {
            const self: *Recorder = @ptrCast(@alignCast(context));
            _ = @atomicRmw(usize, &self.count, .Add, 1, .release);
        }
    }.render;
    try device.start();
    device.pause(false);
    while (@atomicLoad(usize, &recorder.count, .acquire) < 3) system_io.time.sleep(std.time.ns_per_ms);
    device.stop();
}
