//! SDL2 audio adapter: maps SDL2's device semantics onto the audio model, for
//! classic SDL2 and sdl2-compat, through preload and SDL_DYNAMIC_API.
//!
//! - `SDL_OpenAudioDevice`, `SDL_OpenAudio`: a playback device gets a
//!   trampoline that runs the app callback, or for queue mode (NULL callback)
//!   a drain callback over a fixed-capacity queue the adapter owns; either
//!   then hands the buffer to the model.
//! - `SDL_QueueAudio`, `SDL_GetQueuedAudioSize`, `SDL_ClearQueuedAudio`: served
//!   from that queue for the adapter's devices, passed through otherwise.
//! - `SDL_CloseAudioDevice`, `SDL_CloseAudio` and `noteAudioQuit` close the
//!   model stream once SDL can no longer run the callback.
//!
//! When the model is paced by the virtual device, a playback open never
//! reaches SDL: the adapter grants the desired spec, hands out its own ID and
//! runs the callback or drain on a virtual paced device
//! (audio_virtual_device.zig). It then serves pause, status, lock and close
//! for that ID; every other ID passes through.
//!
//! Capture devices pass through. Callbacks run on SDL's audio thread (or the
//! virtual device's) and never allocate, block or take a Katzensteg lock; the
//! device table lock is taken only by app threads.

const std = @import("std");
const system_io = @import("platform");
const sdl = @import("katzensteg_sdl");
const real_sdl = @import("real_sdl.zig");
const audio_model = @import("audio_model.zig");
const audio_process = @import("audio_process.zig");
const ByteQueue = @import("audio_byte_queue.zig").ByteQueue;
const VirtualDevice = @import("audio_virtual_device.zig").VirtualDevice;

const log = std.log.scoped(.audio);

const legacy_device_id: sdl.SDL_AudioDeviceID = 1;
/// Virtual device IDs sit far above SDL2's own (it opens at most 16 devices),
/// so a capture device SDL opens never collides with one.
const virtual_id_base: sdl.SDL_AudioDeviceID = 0x10000;
/// Queue capacity: two seconds of audio, and at least this much.
const min_queue_bytes = 256 * 1024;

const Device = struct {
    in_use: bool = false,
    /// SDL's device ID once the real open returned; 0 before.
    id: sdl.SDL_AudioDeviceID = 0,
    app_callback: sdl.SDL_AudioCallback = null,
    app_userdata: ?*anyopaque = null,
    /// Queue-mode devices only.
    queue: ?ByteQueue = null,
    model: *audio_model.Model = undefined,
    stream: audio_model.StreamInfo = undefined,
    /// Set once `stream` is open in the model.
    ready: std.atomic.Value(bool) = .init(false),
    virtual: ?VirtualDevice = null,
    /// The ID while `virtual` runs: read without the table lock, since an app
    /// may lock its device from inside the callback.
    virtual_id: std.atomic.Value(sdl.SDL_AudioDeviceID) = .init(0),
};

var devices: [audio_model.max_streams]Device = [_]Device{.{}} ** audio_model.max_streams;
var devices_mutex: system_io.Mutex = .{};
/// A nested public open call from inside SDL's own open passes straight through.
threadlocal var opening: bool = false;
var warned_unscaled = false;

fn specFromSdl2(spec: *const sdl.SDL_AudioSpec) audio_model.Spec {
    return .{
        .format = switch (spec.format) {
            sdl.AUDIO_S16SYS => .s16,
            sdl.AUDIO_F32SYS => .f32,
            else => .other,
        },
        // The silence byte SDL computed for the obtained format.
        .silence = spec.silence,
        .frame_bytes = @as(u32, spec.format & 0xff) / 8 * spec.channels,
        .rate = @intCast(@max(spec.freq, 0)),
    };
}

// Audio-thread callbacks.

/// Fills `buffer` from the app's callback, or for queue mode its queue, then
/// hands it to the model.
fn render(context: *anyopaque, buffer: []u8, discontinuity: bool) void {
    const device: *Device = @ptrCast(@alignCast(context));
    if (device.queue) |*queue| {
        const filled = queue.pop(buffer);
        @memset(buffer[filled..], if (device.ready.load(.acquire)) device.stream.spec.silence else 0);
    } else if (device.app_callback) |callback| callback(device.app_userdata, buffer.ptr, @intCast(buffer.len));
    if (device.ready.load(.acquire)) device.model.processBlock(device.stream.id, buffer, discontinuity);
}

/// The callback a real SDL device runs in place of the app's.
fn deviceCallback(userdata: ?*anyopaque, stream: ?[*]sdl.Uint8, len: c_int) callconv(.c) void {
    if (stream != null and len > 0) render(userdata.?, stream.?[0..@intCast(len)], false);
}

// Device table (app threads only).

fn findLocked(id: sdl.SDL_AudioDeviceID) ?*Device {
    for (&devices) |*device| {
        if (id != 0 and device.in_use and device.id == id) return device;
    }
    return null;
}

fn reserve(desired: *const sdl.SDL_AudioSpec) ?*Device {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| {
        if (device.in_use) continue;
        var queue: ?ByteQueue = null;
        if (desired.callback == null) {
            const frame_bytes = @max(@as(usize, desired.format & 0xff) / 8 * desired.channels, 1);
            const capacity = @max(min_queue_bytes, 2 * @as(usize, @intCast(@max(desired.freq, 0))) * frame_bytes);
            queue = .{ .buffer = std.heap.c_allocator.alloc(u8, capacity) catch return null };
        }
        device.* = .{ .in_use = true, .app_callback = desired.callback, .app_userdata = desired.userdata, .queue = queue, .model = audio_process.model() };
        return device;
    }
    log.warn("more than {d} open devices; passing the next one through", .{devices.len});
    return null;
}

/// After a successful real open: record the ID and open the model stream.
fn attach(device: *Device, id: sdl.SDL_AudioDeviceID, used: *const sdl.SDL_AudioSpec) void {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    device.id = id;
    const spec = specFromSdl2(used);
    device.stream = device.model.openStream(spec) orelse return log.warn("id={d}: no free model stream; playing it unmodified", .{id});
    device.ready.store(true, .release);
    const gain = device.model.gain();
    if (spec.format == .other and gain != 0 and gain != 1 and !warned_unscaled) {
        warned_unscaled = true;
        log.warn("id={d} format=0x{x:0>4}: gain {d:.2} can't be applied to this format; it plays at unity gain", .{ id, used.format, gain });
    }
    log.info("opened id={d} mode={s} freq={d} format=0x{x:0>4} channels={d} samples={d} sequence={d}", .{
        id, if (device.queue != null) "queue" else "callback", used.freq, used.format, used.channels, used.samples, device.stream.sequence,
    });
}

/// Frees a record and closes its stream; its callback can no longer run.
fn releaseLocked(device: *Device) void {
    if (device.virtual) |*virtual| {
        device.virtual_id.store(0, .release);
        virtual.stop();
        std.heap.c_allocator.free(virtual.buffer);
    }
    if (device.ready.load(.acquire)) {
        device.model.closeStream(device.stream.id);
        log.info("closed id={d} sequence={d}", .{ device.id, device.stream.sequence });
    }
    if (device.queue) |queue| std.heap.c_allocator.free(queue.buffer);
    device.* = .{};
}

fn release(device: *Device) void {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    releaseLocked(device);
}

fn releaseId(id: sdl.SDL_AudioDeviceID) void {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    if (findLocked(id)) |device| releaseLocked(device);
}

/// SDL closes every device at `SDL_Quit` and when the audio subsystem quits.
/// Call after the real quit returns.
pub fn noteAudioQuit() void {
    devices_mutex.lock();
    defer devices_mutex.unlock();
    for (&devices) |*device| {
        if (device.in_use and device.id != 0) releaseLocked(device);
    }
}

fn substitute(device: *Device, want: *const sdl.SDL_AudioSpec) sdl.SDL_AudioSpec {
    var spec = want.*;
    spec.callback = deviceCallback;
    spec.userdata = device;
    return spec;
}

/// The spec SDL2 would obtain for `want` with no changes allowed: its
/// defaults for unset fields, then the computed silence and size.
fn grantedSpec(want: *const sdl.SDL_AudioSpec) sdl.SDL_AudioSpec {
    var spec = want.*;
    if (spec.freq <= 0) spec.freq = 22050;
    if (spec.format == 0) spec.format = sdl.AUDIO_S16LSB;
    if (spec.channels == 0) spec.channels = 2;
    if (spec.samples == 0) spec.samples = std.math.ceilPowerOfTwo(u16, @intCast(@min(@divTrunc(spec.freq, 1000) * 46, 32768))) catch 32768;
    spec.silence = switch (spec.format) {
        sdl.AUDIO_U8, sdl.AUDIO_U16LSB, sdl.AUDIO_U16MSB => 0x80,
        else => 0,
    };
    spec.size = @as(u32, spec.format & 0xff) / 8 * spec.channels * spec.samples;
    return spec;
}

/// Opens `device` as a virtual paced device under `id`. Returns the granted
/// spec, or null after setting the SDL error; the caller then releases it.
fn openVirtual(device: *Device, id: sdl.SDL_AudioDeviceID, want: *const sdl.SDL_AudioSpec) ?sdl.SDL_AudioSpec {
    const spec = grantedSpec(want);
    const buffer = std.heap.c_allocator.alloc(u8, spec.size) catch {
        _ = real_sdl.SDL_SetError("Out of memory");
        return null;
    };
    device.virtual = .{ .clock = device.model.clock, .rate = @intCast(spec.freq), .samples = spec.samples, .buffer = buffer, .context = device, .render = render };
    attach(device, id, &spec);
    device.virtual.?.start() catch {
        _ = real_sdl.SDL_SetError("Katzensteg could not start the virtual audio device");
        return null;
    };
    device.virtual_id.store(id, .release);
    return spec;
}

fn findVirtual(id: sdl.SDL_AudioDeviceID) ?*VirtualDevice {
    for (&devices) |*device| {
        if (id != 0 and device.virtual_id.load(.acquire) == id) return &device.virtual.?;
    }
    return null;
}

/// Attaches the opened device, hiding the substituted callback from the app.
fn finishOpen(device: *Device, id: sdl.SDL_AudioDeviceID, obtained: ?*sdl.SDL_AudioSpec, substituted: *const sdl.SDL_AudioSpec, want: *const sdl.SDL_AudioSpec) void {
    // With no obtained spec SDL changes nothing: the desired format is the
    // callback format.
    attach(device, id, obtained orelse substituted);
    if (obtained) |spec| {
        spec.callback = want.callback;
        spec.userdata = want.userdata;
    }
}

// Wrappers.

pub export fn ks_SDL_OpenAudioDevice(name: ?[*:0]const u8, iscapture: c_int, desired: ?*const sdl.SDL_AudioSpec, obtained: ?*sdl.SDL_AudioSpec, allowed_changes: c_int) callconv(.c) sdl.SDL_AudioDeviceID {
    const want = desired orelse return real_sdl.SDL_OpenAudioDevice(name, iscapture, desired, obtained, allowed_changes);
    if (iscapture != 0 or opening) return real_sdl.SDL_OpenAudioDevice(name, iscapture, desired, obtained, allowed_changes);
    const device = reserve(want) orelse return real_sdl.SDL_OpenAudioDevice(name, iscapture, desired, obtained, allowed_changes);
    if (device.model.pacing == .virtual_device) {
        const id: sdl.SDL_AudioDeviceID = @intCast(virtual_id_base + (@intFromPtr(device) - @intFromPtr(&devices)) / @sizeOf(Device));
        const spec = openVirtual(device, id, want) orelse {
            release(device);
            return 0;
        };
        if (obtained) |granted| granted.* = spec;
        return id;
    }
    var substituted = substitute(device, want);
    opening = true;
    const id = real_sdl.SDL_OpenAudioDevice(name, iscapture, &substituted, obtained, allowed_changes);
    opening = false;
    if (id == 0) release(device) else finishOpen(device, id, obtained, &substituted, want);
    return id;
}

pub export fn ks_SDL_OpenAudio(desired: ?*sdl.SDL_AudioSpec, obtained: ?*sdl.SDL_AudioSpec) callconv(.c) c_int {
    const want = desired orelse return real_sdl.SDL_OpenAudio(desired, obtained);
    if (opening) return real_sdl.SDL_OpenAudio(desired, obtained);
    const device = reserve(want) orelse return real_sdl.SDL_OpenAudio(desired, obtained);
    if (device.model.pacing == .virtual_device) {
        if (findVirtual(legacy_device_id) != null) {
            release(device);
            _ = real_sdl.SDL_SetError("Audio device is already opened");
            return -1;
        }
        const spec = openVirtual(device, legacy_device_id, want) orelse {
            release(device);
            return -1;
        };
        if (obtained) |granted| granted.* = spec else {
            want.size = spec.size;
            want.silence = spec.silence;
        }
        return 0;
    }
    var substituted = substitute(device, want);
    opening = true;
    // `obtained` stays as given: SDL_OpenAudio allows format changes only
    // when it is non-NULL.
    const rc = real_sdl.SDL_OpenAudio(&substituted, obtained);
    opening = false;
    if (rc < 0) {
        release(device);
        return rc;
    }
    if (obtained == null) {
        // SDL wrote the computed size and silence into our copy of desired.
        want.size = substituted.size;
        want.silence = substituted.silence;
    }
    finishOpen(device, legacy_device_id, obtained, &substituted, want);
    return rc;
}

pub export fn ks_SDL_QueueAudio(id: sdl.SDL_AudioDeviceID, data: ?*const anyopaque, len: sdl.Uint32) callconv(.c) c_int {
    {
        devices_mutex.lock();
        defer devices_mutex.unlock();
        if (findLocked(id)) |device| if (device.queue) |*queue| {
            if (len == 0) return 0;
            const ptr = data orelse {
                _ = real_sdl.SDL_SetError("SDL_QueueAudio: data is NULL");
                return -1;
            };
            const bytes = @as([*]const u8, @ptrCast(ptr))[0..len];
            if (queue.push(bytes)) return 0;
            // What SDL itself does when it cannot grow its queue.
            _ = real_sdl.SDL_SetError("Katzensteg audio queue is full");
            return -1;
        };
    }
    return real_sdl.SDL_QueueAudio(id, data, len);
}

pub export fn ks_SDL_GetQueuedAudioSize(id: sdl.SDL_AudioDeviceID) callconv(.c) sdl.Uint32 {
    {
        devices_mutex.lock();
        defer devices_mutex.unlock();
        if (findLocked(id)) |device| if (device.queue) |*queue| return @intCast(queue.queued());
    }
    return real_sdl.SDL_GetQueuedAudioSize(id);
}

pub export fn ks_SDL_ClearQueuedAudio(id: sdl.SDL_AudioDeviceID) callconv(.c) void {
    {
        devices_mutex.lock();
        defer devices_mutex.unlock();
        if (findLocked(id)) |device| if (device.queue) |*queue| return queue.clear();
    }
    real_sdl.SDL_ClearQueuedAudio(id);
}

pub export fn ks_SDL_CloseAudioDevice(id: sdl.SDL_AudioDeviceID) callconv(.c) void {
    if (findVirtual(id) == null) real_sdl.SDL_CloseAudioDevice(id);
    releaseId(id);
}

pub export fn ks_SDL_CloseAudio() callconv(.c) void {
    if (findVirtual(legacy_device_id) == null) real_sdl.SDL_CloseAudio();
    releaseId(legacy_device_id);
}

pub export fn ks_SDL_PauseAudioDevice(id: sdl.SDL_AudioDeviceID, pause_on: c_int) callconv(.c) void {
    const virtual = findVirtual(id) orelse return real_sdl.SDL_PauseAudioDevice(id, pause_on);
    virtual.pause(pause_on != 0);
}

pub export fn ks_SDL_PauseAudio(pause_on: c_int) callconv(.c) void {
    const virtual = findVirtual(legacy_device_id) orelse return real_sdl.SDL_PauseAudio(pause_on);
    virtual.pause(pause_on != 0);
}

fn virtualStatus(virtual: *VirtualDevice) sdl.SDL_AudioStatus {
    return if (virtual.paused.load(.acquire)) sdl.SDL_AUDIO_PAUSED else sdl.SDL_AUDIO_PLAYING;
}

pub export fn ks_SDL_GetAudioDeviceStatus(id: sdl.SDL_AudioDeviceID) callconv(.c) sdl.SDL_AudioStatus {
    return virtualStatus(findVirtual(id) orelse return real_sdl.SDL_GetAudioDeviceStatus(id));
}

pub export fn ks_SDL_GetAudioStatus() callconv(.c) sdl.SDL_AudioStatus {
    return virtualStatus(findVirtual(legacy_device_id) orelse return real_sdl.SDL_GetAudioStatus());
}

pub export fn ks_SDL_LockAudioDevice(id: sdl.SDL_AudioDeviceID) callconv(.c) void {
    (findVirtual(id) orelse return real_sdl.SDL_LockAudioDevice(id)).lock.lock();
}

pub export fn ks_SDL_UnlockAudioDevice(id: sdl.SDL_AudioDeviceID) callconv(.c) void {
    (findVirtual(id) orelse return real_sdl.SDL_UnlockAudioDevice(id)).lock.unlock();
}

pub export fn ks_SDL_LockAudio() callconv(.c) void {
    (findVirtual(legacy_device_id) orelse return real_sdl.SDL_LockAudio()).lock.lock();
}

pub export fn ks_SDL_UnlockAudio() callconv(.c) void {
    (findVirtual(legacy_device_id) orelse return real_sdl.SDL_UnlockAudio()).lock.unlock();
}
