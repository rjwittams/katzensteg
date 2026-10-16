//! Composes the process's audio model when the app opens its first device:
//! the local device sink, the starting controls and, for tests, the tap file
//! sink. The starting controls come from the environment; command mode then
//! drives them through `audio_model.Model.control`.
//!   KATZENSTEG_AUDIO_VOLUME    0 to 1, or 0% to 100% (default 1); the
//!                              launcher sets it from `runtime.audio.volume`
//!   KATZENSTEG_AUDIO_MUTE      1/true/on/yes starts muted
//!   KATZENSTEG_AUDIO_TAP_FILE  base path for audio_tap_file_sink.zig
//!   KATZENSTEG_AUDIO_DEVICE    `virtual`: nothing plays locally and the
//!                              virtual paced device paces the app (the
//!                              launcher sets it for a Jackstay target)

const std = @import("std");
const system_io = @import("platform");
const audio_model = @import("audio_model.zig");
const local_device_sink = @import("audio_local_device_sink.zig");
const TapFileSink = @import("audio_tap_file_sink.zig").TapFileSink;

const log = std.log.scoped(.audio);

var model_storage: audio_model.Model = .{ .clock = .monotonic, .local = local_device_sink.sink };
var tap_file: TapFileSink = undefined;
var compose_mutex: system_io.Mutex = .{};
var composed = false;

/// The process's audio model, composed on first use. App threads only.
pub fn model() *audio_model.Model {
    compose_mutex.lock();
    defer compose_mutex.unlock();
    if (composed) return &model_storage;
    composed = true;
    const volume_text = getenv("KATZENSTEG_AUDIO_VOLUME");
    const volume = if (volume_text) |text| parseVolume(text) orelse 1.0 else 1.0;
    const muted = if (getenv("KATZENSTEG_AUDIO_MUTE")) |text| parseEnabled(text) else false;
    model_storage.setGain(volume);
    model_storage.muted.store(muted, .release);
    const virtual = if (getenv("KATZENSTEG_AUDIO_DEVICE")) |text| std.mem.eql(u8, text, "virtual") else false;
    if (virtual) {
        model_storage.pacing = .virtual_device;
        model_storage.route_local_device.store(false, .release);
    }
    const tap_path = getenv("KATZENSTEG_AUDIO_TAP_FILE") orelse "";
    if (tap_path.len > 0) {
        tap_file = .{ .base_path = tap_path };
        model_storage.tap = tap_file.sink();
    }
    log.info("audio model: volume={d:.2} (KATZENSTEG_AUDIO_VOLUME={s}) muted={} pacing={s} tap_file={s}", .{ volume, volume_text orelse "", muted, @tagName(model_storage.pacing), tap_path });
    return &model_storage;
}

/// The model without composing it, for the control path: a control acts only
/// while a stream is open, and the first open composes the model.
/// Skipping `compose_mutex` is safe because the `playing()` guard means
/// composition has already finished before any control fires.
pub fn controls() *audio_model.Model {
    return &model_storage;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

/// A fraction ("0.5") or a percentage ("50%"), clamped to [0, 1].
fn parseVolume(text: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, text, " \t");
    const percent = std.mem.endsWith(u8, trimmed, "%");
    const value = std.fmt.parseFloat(f32, if (percent) trimmed[0 .. trimmed.len - 1] else trimmed) catch return null;
    if (std.math.isNan(value)) return null;
    return std.math.clamp(if (percent) value / 100 else value, 0, 1);
}

fn parseEnabled(text: []const u8) bool {
    for ([_][]const u8{ "1", "true", "on", "yes" }) |word| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, " \t"), word)) return true;
    }
    return false;
}

test "volume and mute parse the environment forms" {
    try std.testing.expectEqual(@as(?f32, 0.5), parseVolume("0.5"));
    try std.testing.expectEqual(@as(?f32, 0.3), parseVolume(" 30% "));
    try std.testing.expectEqual(@as(?f32, 1), parseVolume("1.5"));
    try std.testing.expectEqual(@as(?f32, null), parseVolume("loud"));
    try std.testing.expect(parseEnabled("TRUE") and !parseEnabled("0"));
}
