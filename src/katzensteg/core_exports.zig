const runtime = @import("runtime.zig");
const sink = @import("intercept_sink.zig");
const frame_builder = @import("frame_builder.zig");
const log_mod = @import("log.zig");

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
    ks_katzensteg_present_external_framebuffer(width, height, @intFromEnum(ExternalFramebufferFormat.rgba8), pixels, len);
}

pub export fn ks_katzensteg_present_external_framebuffer(width: c_int, height: c_int, format_value: c_int, pixels: ?[*]const u8, len: usize) callconv(.c) void {
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
        .sync_compose => sink.onExternalFramebufferPresent(rt, width, height, format, data[0..byte_len]),
        .queued_replay => sink.enqueueExternalFramebufferPresent(rt, width, height, format, data[0..byte_len]),
    }
}
