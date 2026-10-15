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
//! Recording devices pass through. The postmix runs on SDL's audio thread
//! under SDL's device lock and never allocates, blocks or takes a Katzensteg
//! lock. The virtual paced device is SDL2-only for now (#166): with it
//! selected, SDL3's real device still paces the app and plays silence.

const std = @import("std");
const system_io = @import("platform");
const sdl = @import("katzensteg_sdl");
const real_sdl = @import("real_sdl3.zig");
const audio_model = @import("audio_model.zig");
const audio_process = @import("audio_process.zig");

const log = std.log.scoped(.audio);

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
    const device: *Device = @ptrCast(@alignCast(userdata.?));
    const app = device.app[device.app_index.load(.acquire)];
    if (app.callback) |callback| callback(app.userdata, spec, buffer, buflen);
    const samples = buffer orelse return;
    if (buflen > 0) device.model.processBlock(device.stream.id, @as([*]u8, @ptrCast(samples))[0..@intCast(buflen)], false);
}

fn find(id: sdl.SDL_AudioDeviceID) ?*Device {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| if (id != 0 and device.id == id) return device;
    return null;
}

/// After a successful real open: opens a model stream for a playback device
/// and installs Katzensteg's postmix.
fn attach(id: sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream) void {
    var spec: sdl.SDL_AudioSpec = undefined;
    if (!real_sdl.SDL_IsAudioDevicePlayback(id) or !real_sdl.SDL_GetAudioDeviceFormat(id, &spec, null)) return;
    const device = reserve(id, device_stream, &spec) orelse return;
    if (!real_sdl.SDL_SetAudioPostmixCallback(id, postmix, device)) {
        log.warn("id={d}: SDL_SetAudioPostmixCallback failed: {s}; playing it unmodified", .{ id, std.mem.span(real_sdl.SDL_GetError()) });
        return release(id, null);
    }
    log.info("opened id={d} mode={s} freq={d} channels={d} sequence={d}", .{
        id, if (device_stream != null) "devstream" else "device", spec.freq, spec.channels, device.stream.sequence,
    });
}

fn reserve(id: sdl.SDL_AudioDeviceID, device_stream: ?*sdl.SDL_AudioStream, spec: *const sdl.SDL_AudioSpec) ?*Device {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| {
        if (device.id != 0) continue;
        const model = audio_process.model();
        // The postmix buffer is always F32 at the device's channels and rate.
        const stream = model.openStream(.{ .format = .f32, .silence = 0, .frame_bytes = 4 * @as(u32, @intCast(@max(spec.channels, 0))), .rate = @intCast(@max(spec.freq, 0)) }) orelse break;
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
        if (device.id == 0 or (device.id != id and (device_stream == null or device.device_stream != device_stream))) continue;
        device.model.closeStream(device.stream.id);
        log.info("closed id={d} sequence={d}", .{ device.id, device.stream.sequence });
        device.* = .{};
    }
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
    const device = find(devid) orelse return real_sdl.SDL_SetAudioPostmixCallback(devid, callback, userdata);
    device.setApp(.{ .callback = callback, .userdata = userdata });
    // Reinstalling takes SDL's device lock, so once it returns no postmix
    // still reads the previous slot and the next set may overwrite it.
    return real_sdl.SDL_SetAudioPostmixCallback(devid, postmix, device);
}

pub export fn ks_SDL_CloseAudioDevice(devid: sdl.SDL_AudioDeviceID) callconv(.c) void {
    real_sdl.SDL_CloseAudioDevice(devid);
    release(devid, null);
}

pub export fn ks_SDL_DestroyAudioStream(stream: ?*sdl.SDL_AudioStream) callconv(.c) void {
    real_sdl.SDL_DestroyAudioStream(stream);
    if (stream != null) release(0, stream);
}

// Tests: drive the postmix as SDL's audio thread does, with a fake tap.

const testing = std.testing;
const local_device_sink = @import("audio_local_device_sink.zig");

const FakeTap = struct {
    samples: [4]f32 = undefined,

    fn sink(self: *FakeTap) audio_model.TapSink {
        return .{ .context = self, .opened = ignore, .consume = consume, .closed = ignore };
    }

    fn ignore(_: *anyopaque, _: audio_model.StreamInfo) void {}

    fn consume(context: *anyopaque, block: *const audio_model.Block) void {
        const self: *FakeTap = @ptrCast(@alignCast(context));
        @memcpy(std.mem.asBytes(&self.samples), block.bytes);
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
    var device: Device = .{ .id = 2, .model = &model, .stream = model.openStream(.{ .format = .f32, .silence = 0, .frame_bytes = 8, .rate = 48000 }).? };

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
