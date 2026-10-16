//! SDL3 audio adapter: maps SDL3's device semantics onto the audio model,
//! through preload and SDL3_DYNAMIC_API.
//!
//! - `SDL_OpenAudioDevice`, `SDL_OpenAudioDeviceStream`: each playback logical
//!   device gets a Katzensteg postmix callback, which hands the F32 mix of the
//!   device's streams to the model.
//! - `SDL_SetAudioPostmixCallback`: on those devices the app's postmix is
//!   recorded and runs first, inside Katzensteg's.
//! - `SDL_CloseAudioDevice`, `SDL_DestroyAudioStream` (of a device stream) and
//!   `noteAudioQuit` close the model stream once SDL has closed the device.
//!
//! When the model is paced by the virtual device, SDL's logical device stays
//! paused, so SDL never pulls its streams, and a virtual paced device
//! (audio_virtual_device.zig) pulls them with `SDL_GetAudioStreamData` and
//! runs the same postmix on its own thread. The streams stay real SDL objects
//! bound to SDL's device; the adapter tracks them through the bind, unbind
//! and destroy wrappers and serves pause, resume and paused for the device.
//!
//! Recording devices pass through. The postmix runs on SDL's audio thread
//! under SDL's device lock (or the virtual device's thread under its lock)
//! and never allocates, blocks or takes a Katzensteg lock.

const std = @import("std");
const system_io = @import("platform");
const sdl = @import("katzensteg_sdl");
const real_sdl = @import("real_sdl3.zig");
const audio_model = @import("audio_model.zig");
const audio_process = @import("audio_process.zig");
const VirtualDevice = @import("audio_virtual_device.zig").VirtualDevice;

const log = std.log.scoped(.audio);

/// Streams the app may bind to one virtual device.
const max_bound_streams = 64;

const AppPostmix = struct { callback: sdl.SDL_AudioPostmixCallback = null, userdata: ?*anyopaque = null };

const Device = struct {
    /// SDL's logical device ID; 0 for a free record.
    id: sdl.SDL_AudioDeviceID = 0,
    /// From `SDL_OpenAudioDeviceStream`: destroying it closes the device.
    device_stream: ?*sdl.SDL_AudioStream = null,
    model: *audio_model.Model = undefined,
    stream: audio_model.StreamInfo = undefined,
    /// The app's postmix, double-buffered: a set writes the slot the audio
    /// thread is not reading, then flips `app_index`.
    app: [2]AppPostmix = .{ .{}, .{} },
    app_index: std.atomic.Value(u8) = .init(0),
    virtual: ?VirtualDevice = null,
    /// The virtual device's F32 mix block, then one stream's pull.
    scratch: []f32 = &.{},
    /// The streams the virtual device pulls, under its lock.
    bound: [max_bound_streams]*sdl.SDL_AudioStream = undefined,
    bound_len: usize = 0,

    fn setApp(self: *Device, app: AppPostmix) void {
        const next = 1 - self.app_index.load(.acquire);
        self.app[next] = app;
        self.app_index.store(next, .release);
    }
};

var devices: [audio_model.max_streams]Device = [_]Device{.{}} ** audio_model.max_streams;
/// App threads only, and never held across a call into SDL.
var devices_mutex: system_io.Mutex = .{};
/// Serializes app postmix sets until SDL's device lock has retired the old slot.
var postmix_mutex: system_io.Mutex = .{};

/// Audio thread, under SDL's device lock.
fn postmix(userdata: ?*anyopaque, spec: ?*const sdl.SDL_AudioSpec, buffer: ?[*]f32, buflen: c_int) callconv(.c) void {
    finishBlock(@ptrCast(@alignCast(userdata.?)), spec, buffer, buflen, false);
}

/// Runs the app's postmix, then hands the block to the model.
fn finishBlock(device: *Device, spec: ?*const sdl.SDL_AudioSpec, buffer: ?[*]f32, buflen: c_int, discontinuity: bool) void {
    const app = device.app[device.app_index.load(.acquire)];
    if (app.callback) |callback| callback(app.userdata, spec, buffer, buflen);
    const samples = buffer orelse return;
    if (buflen > 0) device.model.processBlock(device.stream.id, @as([*]u8, @ptrCast(samples))[0..@intCast(buflen)], discontinuity);
}

/// The virtual device's thread, under its lock: mixes the bound streams as
/// SDL's audio thread does, then finishes the block as a postmix.
fn render(context: *anyopaque, buffer: []u8, discontinuity: bool) void {
    const device: *Device = @ptrCast(@alignCast(context));
    const mix = device.scratch[0 .. buffer.len / 4];
    const pulled = device.scratch[mix.len..];
    @memset(mix, 0);
    for (device.bound[0..device.bound_len]) |stream| {
        const bytes = real_sdl.SDL_GetAudioStreamData(stream, pulled.ptr, @intCast(buffer.len));
        if (bytes > 0) for (mix[0..@intCast(@divTrunc(bytes, 4))], pulled[0..@intCast(@divTrunc(bytes, 4))]) |*sum, sample| {
            sum.* += sample;
        };
    }
    const spec: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_F32, .channels = @intCast(device.stream.spec.frame_bytes / 4), .freq = @intCast(device.stream.spec.rate) };
    finishBlock(device, &spec, mix.ptr, @intCast(buffer.len), discontinuity);
}

fn findLocked(id: sdl.SDL_AudioDeviceID) ?*Device {
    for (&devices) |*device| if (id != 0 and device.id == id) return device;
    return null;
}

/// The device `id`, the one opened with `device_stream`, or with a null `id`
/// every device.
fn matches(device: *const Device, id: ?sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) bool {
    return device.id != 0 and (id == null or device.id == id.? or (device_stream != null and device.device_stream == device_stream));
}

/// The matching devices with a virtual device. Callers take each device's
/// lock, or join its thread, after the table lock is dropped: the app's
/// stream callback runs under the device lock and may call a wrapper.
fn virtualDevices(id: ?sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) [devices.len]?*Device {
    var found: [devices.len]?*Device = @splat(null);
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices, &found) |*device, *slot| {
        if (device.virtual != null and matches(device, id, device_stream)) slot.* = device;
    }
    return found;
}

fn findVirtual(id: sdl.SDL_AudioDeviceID) ?*Device {
    if (id == 0) return null;
    for (virtualDevices(id, null)) |device| if (device) |found| return found;
    return null;
}

/// Stops the matching virtual devices before SDL closes them or destroys
/// their streams.
fn stopVirtual(id: ?sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) void {
    for (virtualDevices(id, device_stream)) |device| if (device) |found| found.virtual.?.stop();
}

/// Takes `stream` off every virtual device before the app unbinds or
/// destroys it. A device stream stays: only closing its device unbinds it.
fn forget(stream: *sdl.SDL_AudioStream) void {
    for (virtualDevices(null, null)) |found| {
        const device = found orelse continue;
        if (device.device_stream == stream) continue;
        const virtual = &device.virtual.?;
        virtual.lock.lock();
        defer virtual.lock.unlock();
        for (device.bound[0..device.bound_len], 0..) |bound, index| {
            if (bound != stream) continue;
            device.bound_len -= 1;
            device.bound[index] = device.bound[device.bound_len];
            break;
        }
    }
}

/// After a successful real open: opens a model stream for a playback device
/// and installs Katzensteg's postmix.
fn attach(id: sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) void {
    var spec: sdl.SDL_AudioSpec = undefined;
    var sample_frames: c_int = 0;
    if (!real_sdl.SDL_IsAudioDevicePlayback(id) or !real_sdl.SDL_GetAudioDeviceFormat(id, &spec, &sample_frames)) return;
    // SDL3 mixes at most 8 channels.
    if (spec.channels < 1 or spec.channels > 8 or spec.freq <= 0) {
        return log.warn("id={d} channels={d} freq={d}: unexpected device format; playing it unmodified", .{ id, spec.channels, spec.freq });
    }
    const device = reserve(id, device_stream, &spec) orelse return;
    // A virtual device paces the app, so SDL's own device must never run our
    // postmix: pause it before installing the postmix, not after.
    const virtual = device.model.pacing == .virtual_device;
    if (virtual and !real_sdl.SDL_PauseAudioDevice(id)) log.warn("id={d}: SDL_PauseAudioDevice failed: {s}; SDL's device may run alongside the virtual one", .{ id, std.mem.span(real_sdl.SDL_GetError()) });
    if (!real_sdl.SDL_SetAudioPostmixCallback(id, postmix, device)) {
        log.warn("id={d}: SDL_SetAudioPostmixCallback failed: {s}; playing it unmodified", .{ id, std.mem.span(real_sdl.SDL_GetError()) });
        if (virtual) resumeReal(device);
        return release(id, null);
    }
    // Our postmix also keeps SDL off its single-stream fast path, so every
    // bound stream outputs F32 at the device's channels and rate.
    if (virtual) startVirtual(device, @intCast(@max(sample_frames, 1)));
    log.info("opened id={d} mode={s} freq={d} channels={d} sequence={d} virtual={}", .{
        id, if (device_stream != null) "devstream" else "device", spec.freq, spec.channels, device.stream.sequence, device.virtual != null,
    });
}

/// Pulls the streams of SDL's (already paused) device on a virtual device
/// instead, which starts paused for a device stream and playing otherwise, as
/// SDL does. On failure SDL's device is resumed and keeps pacing.
fn startVirtual(device: *Device, sample_frames: u32) void {
    const f32_per_block = sample_frames * device.stream.spec.frame_bytes / 4;
    device.scratch = std.heap.c_allocator.alloc(f32, 2 * f32_per_block) catch {
        log.warn("id={d}: out of memory for the virtual device", .{device.id});
        resumeReal(device);
        return;
    };
    device.virtual = .{ .clock = device.model.clock, .rate = device.stream.spec.rate, .samples = sample_frames, .buffer = std.mem.sliceAsBytes(device.scratch[0..f32_per_block]), .context = device, .render = render };
    if (device.device_stream) |stream| {
        device.bound[0] = stream;
        device.bound_len = 1;
    }
    device.virtual.?.start() catch {
        log.warn("id={d}: could not start the virtual device", .{device.id});
        std.heap.c_allocator.free(device.scratch);
        device.virtual = null;
        resumeReal(device);
        return;
    };
    if (device.device_stream == null) device.virtual.?.pause(false);
}

/// After a failed start: SDL's device paces again, unless it is a device
/// stream's, which SDL opens paused for the app to resume.
fn resumeReal(device: *Device) void {
    if (device.device_stream == null) _ = real_sdl.SDL_ResumeAudioDevice(device.id);
}

fn reserve(id: sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream, spec: *const sdl.SDL_AudioSpec) ?*Device {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| {
        if (device.id != 0) continue;
        const model = audio_process.model();
        // The postmix buffer is always F32 at the device's channels and rate.
        // Labelled "default": the adapter does not resolve SDL3 device names.
        const stream = model.openStream(.{ .format = .f32, .silence = 0, .channels = @intCast(spec.channels), .frame_bytes = 4 * @as(u32, @intCast(spec.channels)), .rate = @intCast(spec.freq) }, "default") orelse break;
        device.* = .{ .id = id, .device_stream = device_stream, .model = model, .stream = stream };
        return device;
    }
    log.warn("id={d}: no free device record or model stream; playing it unmodified", .{id});
    return null;
}

/// Closes the model stream of the device `id`, or of the one opened with
/// `device_stream`, once SDL can no longer run its postmix.
fn release(id: sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) void {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| {
        if (!matches(device, id, device_stream)) continue;
        if (device.virtual != null) std.heap.c_allocator.free(device.scratch);
        device.model.closeStream(device.stream.id);
        log.info("closed id={d} sequence={d}", .{ device.id, device.stream.sequence });
        device.* = .{};
    }
}

/// SDL destroys every stream when the audio subsystem quits. Call before the
/// real quit.
pub fn noteAudioQuitting() void {
    stopVirtual(null, null);
}

/// SDL closes every device when the audio subsystem quits. Call after the
/// real quit returns; devices SDL still knows (a nested init) stay hooked.
pub fn noteAudioQuit() void {
    var ids: [devices.len]sdl.SDL_AudioDeviceID = undefined;
    {
        devices_mutex.lock();
        defer devices_mutex.unlock();
        for (&devices, &ids) |*device, *id| id.* = device.id;
    }
    var spec: sdl.SDL_AudioSpec = undefined;
    for (ids) |id| if (id != 0 and !real_sdl.SDL_GetAudioDeviceFormat(id, &spec, null)) release(id, null);
    audio_process.quit();
}

// Wrappers.

pub export fn ks_SDL_OpenAudioDevice(devid: sdl.SDL_AudioDeviceID, spec: ?*const sdl.SDL_AudioSpec) callconv(.c) sdl.SDL_AudioDeviceID {
    const id = real_sdl.SDL_OpenAudioDevice(devid, spec);
    if (id != 0) attach(id, null);
    return id;
}

pub export fn ks_SDL_OpenAudioDeviceStream(devid: sdl.SDL_AudioDeviceID, spec: ?*const sdl.SDL_AudioSpec, callback: sdl.SDL_AudioStreamCallback, userdata: ?*anyopaque) callconv(.c) ?*sdl.SDL_AudioStream {
    const stream = real_sdl.SDL_OpenAudioDeviceStream(devid, spec, callback, userdata) orelse return null;
    attach(real_sdl.SDL_GetAudioStreamDevice(stream), stream);
    return stream;
}

pub export fn ks_SDL_SetAudioPostmixCallback(devid: sdl.SDL_AudioDeviceID, callback: sdl.SDL_AudioPostmixCallback, userdata: ?*anyopaque) callconv(.c) sdl.SDL_bool {
    postmix_mutex.lock();
    defer postmix_mutex.unlock();
    const device = hooked: {
        devices_mutex.lock();
        defer devices_mutex.unlock();
        const device = findLocked(devid) orelse break :hooked null;
        device.setApp(.{ .callback = callback, .userdata = userdata });
        break :hooked device;
    } orelse return real_sdl.SDL_SetAudioPostmixCallback(devid, callback, userdata);
    // Reinstalling takes SDL's device lock, so once it returns no postmix
    // still reads the previous slot and the next set may overwrite it. A
    // virtual device reads it under its own lock: taking and releasing that
    // lock waits for any in-progress render still reading the previous slot.
    if (device.virtual) |*virtual| {
        virtual.lock.lock();
        virtual.lock.unlock();
    }
    return real_sdl.SDL_SetAudioPostmixCallback(devid, postmix, device);
}

pub export fn ks_SDL_CloseAudioDevice(devid: sdl.SDL_AudioDeviceID) callconv(.c) void {
    stopVirtual(devid, null);
    real_sdl.SDL_CloseAudioDevice(devid);
    release(devid, null);
}

pub export fn ks_SDL_DestroyAudioStream(stream: ?*sdl.SDL_AudioStream) callconv(.c) void {
    if (stream) |destroyed| {
        forget(destroyed);
        stopVirtual(0, destroyed);
    }
    real_sdl.SDL_DestroyAudioStream(stream);
    if (stream != null) release(0, stream);
}

pub export fn ks_SDL_PauseAudioDevice(devid: sdl.SDL_AudioDeviceID) callconv(.c) sdl.SDL_bool {
    (findVirtual(devid) orelse return real_sdl.SDL_PauseAudioDevice(devid)).virtual.?.pause(true);
    return true;
}

pub export fn ks_SDL_ResumeAudioDevice(devid: sdl.SDL_AudioDeviceID) callconv(.c) sdl.SDL_bool {
    (findVirtual(devid) orelse return real_sdl.SDL_ResumeAudioDevice(devid)).virtual.?.pause(false);
    return true;
}

pub export fn ks_SDL_AudioDevicePaused(devid: sdl.SDL_AudioDeviceID) callconv(.c) sdl.SDL_bool {
    return (findVirtual(devid) orelse return real_sdl.SDL_AudioDevicePaused(devid)).virtual.?.paused.load(.acquire);
}

// SDL's own stream-device calls reach the device ones without the wrappers.

pub export fn ks_SDL_PauseAudioStreamDevice(stream: ?*sdl.SDL_AudioStream) callconv(.c) sdl.SDL_bool {
    const devid = real_sdl.SDL_GetAudioStreamDevice(stream);
    return devid != 0 and ks_SDL_PauseAudioDevice(devid);
}

pub export fn ks_SDL_ResumeAudioStreamDevice(stream: ?*sdl.SDL_AudioStream) callconv(.c) sdl.SDL_bool {
    const devid = real_sdl.SDL_GetAudioStreamDevice(stream);
    return devid != 0 and ks_SDL_ResumeAudioDevice(devid);
}

pub export fn ks_SDL_AudioStreamDevicePaused(stream: ?*sdl.SDL_AudioStream) callconv(.c) sdl.SDL_bool {
    const devid = real_sdl.SDL_GetAudioStreamDevice(stream);
    return devid != 0 and ks_SDL_AudioDevicePaused(devid);
}

pub export fn ks_SDL_BindAudioStreams(devid: sdl.SDL_AudioDeviceID, streams: ?[*]const ?*sdl.SDL_AudioStream, num_streams: c_int) callconv(.c) sdl.SDL_bool {
    const device = findVirtual(devid) orelse return real_sdl.SDL_BindAudioStreams(devid, streams, num_streams);
    const virtual = &device.virtual.?;
    virtual.lock.lock();
    defer virtual.lock.unlock();
    const count: usize = @intCast(@max(num_streams, 0));
    if (device.bound_len + count > max_bound_streams) return real_sdl.SDL_SetError("Katzensteg's virtual audio device takes at most 64 streams");
    if (!real_sdl.SDL_BindAudioStreams(devid, streams, num_streams)) return false;
    // SDL accepted the call, so every listed stream is non-null; a NULL
    // list with no streams is a successful no-op.
    if (streams) |list| for (list[0..count]) |stream| {
        device.bound[device.bound_len] = stream.?;
        device.bound_len += 1;
    };
    return true;
}

pub export fn ks_SDL_BindAudioStream(devid: sdl.SDL_AudioDeviceID, stream: ?*sdl.SDL_AudioStream) callconv(.c) sdl.SDL_bool {
    return ks_SDL_BindAudioStreams(devid, @ptrCast(&stream), 1);
}

pub export fn ks_SDL_UnbindAudioStreams(streams: ?[*]const ?*sdl.SDL_AudioStream, num_streams: c_int) callconv(.c) void {
    if (streams) |list| for (list[0..@intCast(@max(num_streams, 0))]) |stream| forget(stream orelse continue);
    real_sdl.SDL_UnbindAudioStreams(streams, num_streams);
}

pub export fn ks_SDL_UnbindAudioStream(stream: ?*sdl.SDL_AudioStream) callconv(.c) void {
    ks_SDL_UnbindAudioStreams(@ptrCast(&stream), 1);
}

// Tests: drive the postmix as SDL's audio thread does, with a fake tap.

const testing = std.testing;
const local_device_sink = @import("audio_local_device_sink.zig");
const FakeClock = @import("audio_virtual_device.zig").FakeClock;

const FakeTap = struct {
    samples: [4]f32 = undefined,
    blocks: usize = 0,
    time_ns: u64 = 0,
    discontinuity: bool = false,

    fn sink(self: *FakeTap) audio_model.TapSink {
        return .{ .context = self, .opened = opened, .consume = consume, .closed = ignore };
    }

    fn opened(_: *anyopaque, _: audio_model.StreamInfo, _: []const u8) void {}
    fn ignore(_: *anyopaque, _: audio_model.StreamInfo) void {}

    fn consume(context: *anyopaque, block: *const audio_model.Block) void {
        const self: *FakeTap = @ptrCast(@alignCast(context));
        @memcpy(std.mem.asBytes(&self.samples), block.bytes);
        self.blocks += 1;
        self.time_ns = block.time_ns;
        self.discontinuity = block.discontinuity;
    }
};

/// The app's postmix: adds `offset` to every sample.
const AppEffect = struct {
    offset: f32,
    calls: usize = 0,

    fn callback(userdata: ?*anyopaque, _: ?*const sdl.SDL_AudioSpec, buffer: ?[*]f32, buflen: c_int) callconv(.c) void {
        const self: *AppEffect = @ptrCast(@alignCast(userdata.?));
        self.calls += 1;
        for (buffer.?[0..@intCast(@divExact(buflen, 4))]) |*sample| sample.* += self.offset;
    }
};

fn testPostmix(device: *Device, buffer: *[4]f32) void {
    const spec: sdl.SDL_AudioSpec = .{ .format = 0, .channels = 2, .freq = 48000 };
    postmix(device, &spec, buffer, @sizeOf([4]f32));
}

test "the app's postmix runs first, the tap sees its output unscaled and the device plays it scaled" {
    var tap: FakeTap = .{};
    var model: audio_model.Model = .{ .clock = .monotonic, .local = local_device_sink.sink, .tap = tap.sink() };
    model.setGain(0.5);
    var device: Device = .{ .id = 2, .model = &model, .stream = model.openStream(.{ .format = .f32, .silence = 0, .channels = 2, .frame_bytes = 8, .rate = 48000 }, "default").? };

    var buffer: [4]f32 = .{ 0.1, 0.2, 0.3, 0.4 };
    testPostmix(&device, &buffer);
    try testing.expectEqualSlices(f32, &.{ 0.1, 0.2, 0.3, 0.4 }, &tap.samples);
    try testing.expectEqualSlices(f32, &.{ 0.05, 0.1, 0.15, 0.2 }, &buffer);

    var first: AppEffect = .{ .offset = 0.5 };
    var second: AppEffect = .{ .offset = 0.25 };
    device.setApp(.{ .callback = AppEffect.callback, .userdata = &first });
    buffer = .{ 0, 0, 0, 0 };
    testPostmix(&device, &buffer);
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 0.5 }, &tap.samples);
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.25, 0.25, 0.25 }, &buffer);

    // A replacement applies from the next block; clearing it unchains.
    device.setApp(.{ .callback = AppEffect.callback, .userdata = &second });
    buffer = .{ 0, 0, 0, 0 };
    testPostmix(&device, &buffer);
    device.setApp(.{});
    testPostmix(&device, &buffer);
    try testing.expectEqual(@as(usize, 1), first.calls);
    try testing.expectEqual(@as(usize, 1), second.calls);
}

test "the virtual device mixes its bound SDL streams on its own deadlines" {
    var clock: FakeClock = .{};
    var tap: FakeTap = .{};
    var model: audio_model.Model = .{ .clock = clock.clock(), .local = local_device_sink.sink, .tap = tap.sink() };
    const spec: sdl.SDL_AudioSpec = .{ .format = sdl.SDL_AUDIO_F32, .channels = 2, .freq = 48000 };
    const streams: [2]*sdl.SDL_AudioStream = .{ sdl.SDL_CreateAudioStream(&spec, &spec).?, sdl.SDL_CreateAudioStream(&spec, &spec).? };
    defer for (streams) |stream| sdl.SDL_DestroyAudioStream(stream);
    try testing.expect(sdl.SDL_PutAudioStreamData(streams[0], &[8]f32{ 0.5, 0.25, 0.125, 0.0625, 0.5, 0.5, 0.5, 0.5 }, 32));
    try testing.expect(sdl.SDL_PutAudioStreamData(streams[1], &[4]f32{ 0.25, 0.25, 0.25, 0.25 }, 16));

    var scratch: [8]f32 = undefined;
    var device: Device = .{ .id = 2, .model = &model, .stream = model.openStream(.{ .format = .f32, .silence = 0, .channels = 2, .frame_bytes = 8, .rate = 48000 }, "default").?, .scratch = &scratch, .bound_len = 2 };
    device.bound[0..2].* = streams;
    device.virtual = .{ .clock = model.clock, .rate = 48000, .samples = 2, .buffer = std.mem.sliceAsBytes(scratch[0..4]), .context = &device, .render = render };
    var app: AppEffect = .{ .offset = 0 };
    device.setApp(.{ .callback = AppEffect.callback, .userdata = &app });
    const virtual = &device.virtual.?;
    virtual.pause(false);

    while (tap.blocks < 1) virtual.step();
    try testing.expectEqualSlices(f32, &.{ 0.75, 0.5, 0.375, 0.3125 }, &tap.samples);
    try testing.expectEqual(@as(u64, 5_000), tap.time_ns);
    try testing.expect(tap.discontinuity);
    // The second stream has run dry; the block still runs on its deadline.
    while (tap.blocks < 2) virtual.step();
    try testing.expectEqualSlices(f32, &.{ 0.5, 0.5, 0.5, 0.5 }, &tap.samples);
    try testing.expectEqual(@as(u64, 5_000 + 2 * std.time.ns_per_s / 48000), tap.time_ns);
    try testing.expect(!tap.discontinuity);
    try testing.expectEqual(@as(usize, 2), app.calls);
}
