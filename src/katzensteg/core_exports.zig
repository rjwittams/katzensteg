const std = @import("std");
const system_io = @import("platform");
const runtime = @import("runtime.zig");
const frame_builder = @import("frame_builder.zig");
const log_mod = @import("log.zig");

pub const std_options: std.Options = .{ .log_level = .info, .logFn = log_mod.stdLogFn };

const ExternalFramebufferFormat = frame_builder.ExternalFramebufferFormat;

pub export fn ks_katzensteg_shutdown() callconv(.c) void {
    runtime.shutdownGlobal();
}

pub export fn ks_katzensteg_log_c(scope_z: ?[*:0]const u8, message_z: ?[*:0]const u8) callconv(.c) void {
    const scope = if (scope_z) |value| std.mem.span(value) else "c";
    const message = if (message_z) |value| std.mem.span(value) else "";
    log_mod.writeCLog(scope, message);
}

pub export fn ks_katzensteg_present_external_rgba(width: c_int, height: c_int, pixels: ?[*]const u8, len: usize) callconv(.c) void {
    ks_katzensteg_present_external_framebuffer_at(width, height, @intFromEnum(ExternalFramebufferFormat.rgba8), pixels, len, system_io.time.hostTimeNs());
}

/// Host time (Jackstay `HostTime`, the platform monotonic clock in
/// nanoseconds). Capture layers read it on entry to the app's present hook so
/// that every present path shares one clock implementation.
pub export fn ks_katzensteg_host_time_ns() callconv(.c) u64 {
    return system_io.time.hostTimeNs();
}

/// For callers that cannot stamp their present hook: the frame is stamped
/// with host time now, after any capture the caller already did.
pub export fn ks_katzensteg_present_external_framebuffer(width: c_int, height: c_int, format_value: c_int, pixels: ?[*]const u8, len: usize) callconv(.c) void {
    ks_katzensteg_present_external_framebuffer_at(width, height, format_value, pixels, len, system_io.time.hostTimeNs());
}

/// present_host_ns is host time from `ks_katzensteg_host_time_ns`, read on
/// entry to the app's present hook before capture; 0 means unknown and stamps
/// the frame now.
pub export fn ks_katzensteg_present_external_framebuffer_at(width: c_int, height: c_int, format_value: c_int, pixels: ?[*]const u8, len: usize, present_host_ns: u64) callconv(.c) void {
    const stamp = presentStamp(present_host_ns);
    if (width <= 0 or height <= 0) return;
    const data = pixels orelse return;
    const byte_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    if (len < byte_len) return;
    const format: ExternalFramebufferFormat = switch (format_value) {
        @intFromEnum(ExternalFramebufferFormat.rgba8) => .rgba8,
        @intFromEnum(ExternalFramebufferFormat.bgra8) => .bgra8,
        @intFromEnum(ExternalFramebufferFormat.a2b10g10r10_unorm_pack32) => .a2b10g10r10_unorm_pack32,
        else => return,
    };
    const rt = runtime.get();
    if (!rt.shouldCaptureExternalFrame()) return;
    switch (rt.intercept_mode) {
        .sync_compose => rt.presentExternalFramebuffer(width, height, format, data[0..byte_len], stamp),
        .queued_replay => enqueueExternalFramebufferPresent(rt, width, height, format, data[0..byte_len], stamp),
    }
}

fn enqueueExternalFramebufferPresent(rt: *runtime.Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8, present_host_ns: u64) void {
    const byte_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const copied = rt.acquirePayloadBuffer(byte_len) catch return;
    @memcpy(copied, pixels[0..byte_len]);
    rt.enqueueCommand(.{ .external_framebuffer_present = .{
        .width = width,
        .height = height,
        .format = format,
        .pixels = copied,
        .present_host_ns = present_host_ns,
    } });
}

/// The stamp a frame carries: the caller's hook-entry host time, or host time
/// now when the caller passes 0 (unknown).
fn presentStamp(present_host_ns: u64) u64 {
    return if (present_host_ns != 0) present_host_ns else system_io.time.hostTimeNs();
}

test "a known present stamp passes through and an unknown one is stamped now" {
    try std.testing.expectEqual(@as(u64, 42), presentStamp(42));
    const before = system_io.time.hostTimeNs();
    const stamped = presentStamp(0);
    try std.testing.expect(stamped != 0);
    try std.testing.expect(stamped >= before);
    try std.testing.expect(stamped <= system_io.time.hostTimeNs());
}
