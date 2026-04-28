const std = @import("std");
const config_mod = @import("config.zig");
const core = @import("core_types.zig");
const sdl = @import("katzensteg_sdl");
const sdl_adapter = @import("sdl2_adapter.zig");
const real_sdl = @import("real_sdl.zig");
const runtime_mod = @import("runtime.zig");
const frame_builder_mod = @import("frame_builder.zig");
const inspect_model = @import("inspect_model.zig");
const ExternalFramebufferFormat = frame_builder_mod.ExternalFramebufferFormat;

const log = std.log.scoped(.intercept);

pub const InterceptMode = config_mod.InterceptMode;
const CoreHandle = core.CoreHandle;
const CoreRect = core.CoreRect;
const CorePoint = core.CorePoint;

const SurfaceView = extern struct {
    flags: u32,
    format: ?*anyopaque,
    w: i32,
    h: i32,
    pitch: i32,
    pixels: ?*anyopaque,
    userdata: ?*anyopaque,
    locked: i32,
    lock_data: ?*anyopaque,
    clip_rect: sdl.SDL_Rect,
    map: ?*anyopaque,
    refcount: i32,
};

pub const Command = union(enum) {
    create_window: struct { window: CoreHandle, w: i32, h: i32 },
    create_renderer: struct { window: CoreHandle, renderer: CoreHandle },
    destroy_renderer: struct { renderer: CoreHandle },
    create_texture: struct { texture: CoreHandle, format: core.PixelFormat, w: i32, h: i32 },
    destroy_texture: struct { texture: CoreHandle },
    update_texture: struct { texture: CoreHandle, rect: ?CoreRect, pixels: ?[]u8, pitch: i32 },
    update_yuv_texture: struct { texture: CoreHandle, rect: ?CoreRect, yplane: ?[]u8, ypitch: i32, uplane: ?[]u8, upitch: i32, vplane: ?[]u8, vpitch: i32 },
    update_nv_texture: struct { texture: CoreHandle, rect: ?CoreRect, yplane: ?[]u8, ypitch: i32, uvplane: ?[]u8, uvpitch: i32 },
    lock_texture: struct { texture: CoreHandle, rect: ?CoreRect, pixels: ?*anyopaque, pitch: i32 },
    unlock_texture: struct { texture: CoreHandle },
    set_texture_color_mod: struct { texture: CoreHandle, r: u8, g: u8, b: u8 },
    set_texture_alpha_mod: struct { texture: CoreHandle, a: u8 },
    set_texture_blend_mode: struct { texture: CoreHandle, blend_mode: core.BlendMode },
    set_render_draw_color: struct { renderer: CoreHandle, r: u8, g: u8, b: u8, a: u8 },
    render_clear: struct { renderer: CoreHandle },
    render_copy: struct { renderer: CoreHandle, texture: CoreHandle, src: ?CoreRect, dst: ?CoreRect },
    render_copy_ex: struct { renderer: CoreHandle, texture: CoreHandle, src: ?CoreRect, dst: ?CoreRect, angle: f64, center: ?CorePoint, flip: c_int },
    render_fill_rect: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_draw_point: struct { renderer: CoreHandle, x: i32, y: i32 },
    render_draw_line: struct { renderer: CoreHandle, x1: i32, y1: i32, x2: i32, y2: i32 },
    render_set_viewport: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_set_clip_rect: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_present: struct { renderer: CoreHandle },
    external_framebuffer_present: struct { width: i32, height: i32, format: ExternalFramebufferFormat, pixels: ?[]u8 },
};

pub fn dispatchCommand(rt: *runtime_mod.Runtime, cmd: Command) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(switch (cmd) {
        .render_present => .render_present,
        else => .generic,
    }, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    switch (rt.intercept_mode) {
        .sync_compose => {
            var owned = cloneCommand(rt, cmd) catch {
                log.warn("cloneCommand failed in sync_compose; dropping command", .{});
                return;
            };
            defer rt.recycleCommand(&owned);
            handleCommand(rt, owned);
        },
        .queued_replay => {
            const owned = cloneCommand(rt, cmd) catch {
                log.warn("cloneCommand failed in queued_replay; dropping command", .{});
                return;
            };
            rt.enqueueCommand(owned);
        },
    }
}

fn cloneCommand(rt: *runtime_mod.Runtime, cmd: Command) !Command {
    return switch (cmd) {
        .create_window => |c| .{ .create_window = c },
        .create_renderer => |c| .{ .create_renderer = c },
        .destroy_renderer => |c| .{ .destroy_renderer = c },
        .create_texture => |c| .{ .create_texture = c },
        .destroy_texture => |c| .{ .destroy_texture = c },
        .update_texture => |c| blk: {
            var copied: ?[]u8 = null;
            if (c.pixels) |p| {
                const byte_len: usize = if (c.rect) |r| @intCast(c.pitch * r.h) else blk2: {
                    var format: u32 = 0;
                    var access: c_int = 0;
                    var w: c_int = 0;
                    var h: c_int = 0;
                    const texture = sdl_adapter.ptrFromHandle(sdl.SDL_Texture, c.texture);
                    if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) break :blk2 0;
                    break :blk2 @as(usize, @intCast(c.pitch * h));
                };
                if (byte_len > 0) {
                    copied = try rt.acquirePayloadBuffer(byte_len);
                    @memcpy(copied.?, @as([*]const u8, @ptrCast(p))[0..byte_len]);
                }
            }
            break :blk .{ .update_texture = .{ .texture = c.texture, .rect = if (c.rect) |r| r else null, .pixels = copied, .pitch = c.pitch } };
        },
        .update_yuv_texture => |c| blk: {
            var cloned = Command{ .update_yuv_texture = .{
                .texture = c.texture,
                .rect = c.rect,
                .yplane = null,
                .ypitch = c.ypitch,
                .uplane = null,
                .upitch = c.upitch,
                .vplane = null,
                .vpitch = c.vpitch,
            } };
            errdefer rt.recycleCommand(&cloned);
            cloned.update_yuv_texture.yplane = try cloneBytesToPayloadBuffer(rt, c.yplane);
            cloned.update_yuv_texture.uplane = try cloneBytesToPayloadBuffer(rt, c.uplane);
            cloned.update_yuv_texture.vplane = try cloneBytesToPayloadBuffer(rt, c.vplane);
            break :blk cloned;
        },
        .update_nv_texture => |c| blk: {
            var cloned = Command{ .update_nv_texture = .{
                .texture = c.texture,
                .rect = c.rect,
                .yplane = null,
                .ypitch = c.ypitch,
                .uvplane = null,
                .uvpitch = c.uvpitch,
            } };
            errdefer rt.recycleCommand(&cloned);
            cloned.update_nv_texture.yplane = try cloneBytesToPayloadBuffer(rt, c.yplane);
            cloned.update_nv_texture.uvplane = try cloneBytesToPayloadBuffer(rt, c.uvplane);
            break :blk cloned;
        },
        .lock_texture => |c| .{ .lock_texture = c },
        .unlock_texture => |c| .{ .unlock_texture = c },
        .set_texture_color_mod => |c| .{ .set_texture_color_mod = c },
        .set_texture_alpha_mod => |c| .{ .set_texture_alpha_mod = c },
        .set_texture_blend_mode => |c| .{ .set_texture_blend_mode = c },
        .set_render_draw_color => |c| .{ .set_render_draw_color = c },
        .render_clear => |c| .{ .render_clear = c },
        .render_copy => |c| .{ .render_copy = c },
        .render_copy_ex => |c| .{ .render_copy_ex = c },
        .render_fill_rect => |c| .{ .render_fill_rect = c },
        .render_draw_point => |c| .{ .render_draw_point = c },
        .render_draw_line => |c| .{ .render_draw_line = c },
        .render_set_viewport => |c| .{ .render_set_viewport = c },
        .render_set_clip_rect => |c| .{ .render_set_clip_rect = c },
        .render_present => |c| .{ .render_present = c },
        .external_framebuffer_present => |c| .{ .external_framebuffer_present = .{
            .width = c.width,
            .height = c.height,
            .format = c.format,
            .pixels = try cloneBytesToPayloadBuffer(rt, c.pixels),
        } },
    };
}

fn cloneBytesToPayloadBuffer(rt: *runtime_mod.Runtime, src: ?[]u8) !?[]u8 {
    const bytes = src orelse return null;
    const copied = try rt.acquirePayloadBuffer(bytes.len);
    @memcpy(copied, bytes);
    return copied;
}

pub fn onCreateWindow(rt: *runtime_mod.Runtime, window: ?*sdl.SDL_Window, w: i32, h: i32) void {
    rt.frame_builder.onCreateWindow(sdl_adapter.handleFromPtr(window), w, h);
}

pub fn onCreateRenderer(rt: *runtime_mod.Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onCreateRenderer(sdl_adapter.handleFromPtr(window), sdl_adapter.handleFromPtr(renderer));
}

pub fn onDestroyRenderer(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onDestroyRenderer(sdl_adapter.handleFromPtr(renderer));
}

pub fn onCreateTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, format: sdl.Uint32, w: i32, h: i32) void {
    rt.frame_builder.onCreateTexture(sdl_adapter.handleFromPtr(texture), sdl_adapter.pixelFormatFromSdl2(format), w, h);
}

pub fn onDestroyTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    rt.frame_builder.onDestroyTexture(sdl_adapter.handleFromPtr(texture));
}

pub fn onUpdateTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, texture_handle, if (core_rect) |*r| r else null, pixels, pitch);
    } else if (rt.active and rt.batch_sink != null) {
        rt.frame_builder.onUpdateTextureBatch(&rt.logger, texture_handle, if (core_rect) |*r| r else null, pixels, pitch);
    }
}

pub fn onUpdateYuvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uplane: ?[*]const u8, upitch: i32, vplane: ?[*]const u8, vpitch: i32) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onUpdateYuvTexture(&rt.logger, &rt.backend.?, texture_handle, if (core_rect) |*r| r else null, yplane, ypitch, uplane, upitch, vplane, vpitch);
    } else if (rt.active and rt.batch_sink != null) {
        rt.frame_builder.onUpdateYuvTextureBatch(&rt.logger, texture_handle, if (core_rect) |*r| r else null, yplane, ypitch, uplane, upitch, vplane, vpitch);
    }
}

pub fn onUpdateNvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uvplane: ?[*]const u8, uvpitch: i32) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onUpdateNvTexture(&rt.logger, &rt.backend.?, texture_handle, if (core_rect) |*r| r else null, yplane, ypitch, uvplane, uvpitch);
    } else if (rt.active and rt.batch_sink != null) {
        rt.frame_builder.onUpdateNvTextureBatch(&rt.logger, texture_handle, if (core_rect) |*r| r else null, yplane, ypitch, uvplane, uvpitch);
    }
}

pub fn enqueueUpdateTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.update_texture, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    var copied: ?[]u8 = null;
    if (pixels) |p| {
        const byte_len: usize = if (rect) |r| @intCast(pitch * r.h) else blk: {
            var format: u32 = 0;
            var access: c_int = 0;
            var w: c_int = 0;
            var h: c_int = 0;
            if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) break :blk 0;
            break :blk @as(usize, @intCast(pitch * h));
        };
        if (byte_len > 0) {
            copied = rt.acquirePayloadBuffer(byte_len) catch null;
            if (copied) |buf| @memcpy(buf, @as([*]const u8, @ptrCast(p))[0..byte_len]);
        }
    }
    if (copied == null and pixels != null) {
        log.warn("failed to copy update_texture payload for queued replay", .{});
    }
    rt.enqueueCommand(.{ .update_texture = .{
        .texture = sdl_adapter.handleFromPtr(texture),
        .rect = sdl_adapter.rectFromSdl(rect),
        .pixels = copied,
        .pitch = pitch,
    } });
}

pub fn enqueueUpdateYuvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uplane: ?[*]const u8, upitch: i32, vplane: ?[*]const u8, vpitch: i32) void {
    const dims = textureUpdateDimensions(texture, rect) orelse {
        log.warn("failed to size SDL_UpdateYUVTexture payload", .{});
        return;
    };
    const chroma_h = @divTrunc(dims.h + 1, 2);
    const copied_y = copyPlanePayload(rt, yplane, ypitch, dims.h);
    const copied_u = copyPlanePayload(rt, uplane, upitch, chroma_h);
    const copied_v = copyPlanePayload(rt, vplane, vpitch, chroma_h);
    if (copied_y == null or copied_u == null or copied_v == null) {
        log.warn("failed to copy SDL_UpdateYUVTexture payload", .{});
        var doomed = Command{ .update_yuv_texture = .{
            .texture = sdl_adapter.handleFromPtr(texture),
            .rect = null,
            .yplane = copied_y,
            .ypitch = ypitch,
            .uplane = copied_u,
            .upitch = upitch,
            .vplane = copied_v,
            .vpitch = vpitch,
        } };
        rt.recycleCommand(&doomed);
        return;
    }
    rt.enqueueCommand(.{ .update_yuv_texture = .{
        .texture = sdl_adapter.handleFromPtr(texture),
        .rect = sdl_adapter.rectFromSdl(rect),
        .yplane = copied_y,
        .ypitch = ypitch,
        .uplane = copied_u,
        .upitch = upitch,
        .vplane = copied_v,
        .vpitch = vpitch,
    } });
}

pub fn enqueueUpdateNvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uvplane: ?[*]const u8, uvpitch: i32) void {
    const dims = textureUpdateDimensions(texture, rect) orelse {
        log.warn("failed to size SDL_UpdateNVTexture payload", .{});
        return;
    };
    const chroma_h = @divTrunc(dims.h + 1, 2);
    const copied_y = copyPlanePayload(rt, yplane, ypitch, dims.h);
    const copied_uv = copyPlanePayload(rt, uvplane, uvpitch, chroma_h);
    if (copied_y == null or copied_uv == null) {
        log.warn("failed to copy SDL_UpdateNVTexture payload", .{});
        var doomed = Command{ .update_nv_texture = .{
            .texture = sdl_adapter.handleFromPtr(texture),
            .rect = null,
            .yplane = copied_y,
            .ypitch = ypitch,
            .uvplane = copied_uv,
            .uvpitch = uvpitch,
        } };
        rt.recycleCommand(&doomed);
        return;
    }
    rt.enqueueCommand(.{ .update_nv_texture = .{
        .texture = sdl_adapter.handleFromPtr(texture),
        .rect = sdl_adapter.rectFromSdl(rect),
        .yplane = copied_y,
        .ypitch = ypitch,
        .uvplane = copied_uv,
        .uvpitch = uvpitch,
    } });
}

fn textureUpdateDimensions(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect) ?struct { w: i32, h: i32 } {
    if (rect) |r| return .{ .w = r.w, .h = r.h };
    var format: u32 = 0;
    var access: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) return null;
    return .{ .w = w, .h = h };
}

fn textureMetadataOrFallback(texture: ?*sdl.SDL_Texture) struct { format: u32, w: i32, h: i32 } {
    var format: u32 = 0;
    var access: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) {
        log.warn("SDL_QueryTexture failed while capturing texture metadata; using fallback metadata", .{});
        return .{ .format = sdl.SDL_PIXELFORMAT_ABGR8888, .w = 0, .h = 0 };
    }
    return .{ .format = format, .w = w, .h = h };
}

fn copyPlanePayload(rt: *runtime_mod.Runtime, plane: ?[*]const u8, pitch: i32, rows: i32) ?[]u8 {
    const src = plane orelse return null;
    if (pitch <= 0 or rows <= 0) return null;
    const byte_len: usize = @intCast(pitch * rows);
    const copied = rt.acquirePayloadBuffer(byte_len) catch return null;
    @memcpy(copied, src[0..byte_len]);
    return copied;
}

pub fn enqueueExternalFramebufferPresent(rt: *runtime_mod.Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.render_present, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    if (width <= 0 or height <= 0) return;
    const byte_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    if (pixels.len < byte_len) {
        log.warn("external framebuffer payload too small: got={d} want={d}", .{ pixels.len, byte_len });
        return;
    }
    const copied = rt.acquirePayloadBuffer(byte_len) catch {
        log.warn("alloc failed in enqueueExternalFramebufferPresent", .{});
        return;
    };
    @memcpy(copied, pixels[0..byte_len]);
    rt.enqueueCommand(.{ .external_framebuffer_present = .{ .width = width, .height = height, .format = format, .pixels = copied } });
}

pub fn enqueueCreateTextureFromSurface(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.create_texture_from_surface, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (surface == null) {
        const metadata = textureMetadataOrFallback(texture);
        rt.enqueueCommand(.{ .create_texture = .{
            .texture = texture_handle,
            .format = sdl_adapter.pixelFormatFromSdl2(metadata.format),
            .w = metadata.w,
            .h = metadata.h,
        } });
        return;
    }
    const converted = real_sdl.SDL_ConvertSurfaceFormat(surface, sdl.SDL_PIXELFORMAT_ABGR8888, 0) orelse {
        log.warn("SDL_ConvertSurfaceFormat failed in enqueueCreateTextureFromSurface", .{});
        const metadata = textureMetadataOrFallback(texture);
        rt.enqueueCommand(.{ .create_texture = .{
            .texture = texture_handle,
            .format = sdl_adapter.pixelFormatFromSdl2(metadata.format),
            .w = metadata.w,
            .h = metadata.h,
        } });
        return;
    };
    defer real_sdl.SDL_FreeSurface(converted);
    const surf: *SurfaceView = @ptrCast(@alignCast(converted));
    rt.enqueueCommand(.{ .create_texture = .{
        .texture = texture_handle,
        .format = sdl_adapter.pixelFormatFromSdl2(sdl.SDL_PIXELFORMAT_ABGR8888),
        .w = surf.w,
        .h = surf.h,
    } });
    const byte_len: usize = @intCast(surf.pitch * surf.h);
    const copied = rt.acquirePayloadBuffer(byte_len) catch {
        log.warn("alloc failed in enqueueCreateTextureFromSurface", .{});
        return;
    };
    @memcpy(copied, @as([*]const u8, @ptrCast(surf.pixels.?))[0..byte_len]);
    rt.enqueueCommand(.{ .update_texture = .{
        .texture = texture_handle,
        .rect = null,
        .pixels = copied,
        .pitch = surf.pitch,
    } });
}

pub fn onCreateTextureFromSurface(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface) void {
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (surface == null) {
        const metadata = textureMetadataOrFallback(texture);
        rt.frame_builder.onCreateTexture(texture_handle, sdl_adapter.pixelFormatFromSdl2(metadata.format), metadata.w, metadata.h);
        return;
    }
    const converted = real_sdl.SDL_ConvertSurfaceFormat(surface, sdl.SDL_PIXELFORMAT_ABGR8888, 0) orelse {
        log.warn("SDL_ConvertSurfaceFormat failed in onCreateTextureFromSurface", .{});
        const metadata = textureMetadataOrFallback(texture);
        rt.frame_builder.onCreateTexture(texture_handle, sdl_adapter.pixelFormatFromSdl2(metadata.format), metadata.w, metadata.h);
        return;
    };
    defer real_sdl.SDL_FreeSurface(converted);
    const surf: *SurfaceView = @ptrCast(@alignCast(converted));
    rt.frame_builder.onCreateTexture(texture_handle, sdl_adapter.pixelFormatFromSdl2(sdl.SDL_PIXELFORMAT_ABGR8888), surf.w, surf.h);
    if (rt.active and rt.backend != null) {
        const src: [*]u8 = @ptrCast(surf.pixels.?);
        rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, texture_handle, null, src, surf.pitch);
    } else if (rt.active and rt.batch_sink != null) {
        const src: [*]u8 = @ptrCast(surf.pixels.?);
        rt.frame_builder.onUpdateTextureBatch(&rt.logger, texture_handle, null, src, surf.pitch);
    }
}

pub fn enqueueQueuedUnlockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.unlock_texture, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    const capture = rt.takeQueuedLock(texture) orelse {
        log.warn("queued unlock without remembered lock capture", .{});
        return;
    };
    const pixels = capture.pixels orelse {
        log.warn("queued unlock capture had null pixels", .{});
        return;
    };
    const byte_len: usize = if (capture.rect) |r| @intCast(capture.pitch * r.h) else blk: {
        var format: u32 = 0;
        var access: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) break :blk 0;
        break :blk @as(usize, @intCast(capture.pitch * h));
    };
    if (byte_len == 0) {
        log.warn("queued unlock capture had zero-sized payload", .{});
        return;
    }
    const copied = rt.acquirePayloadBuffer(byte_len) catch {
        log.warn("alloc failed in enqueueQueuedUnlockTexture", .{});
        return;
    };
    @memcpy(copied, @as([*]const u8, @ptrCast(pixels))[0..byte_len]);
    rt.enqueueCommand(.{ .update_texture = .{
        .texture = sdl_adapter.handleFromPtr(texture),
        .rect = if (capture.rect) |*r| sdl_adapter.rectFromSdl(r) else null,
        .pixels = copied,
        .pitch = capture.pitch,
    } });
}

pub fn onLockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*anyopaque, pitch: i32) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    rt.frame_builder.onLockTexture(&rt.logger, sdl_adapter.handleFromPtr(texture), if (core_rect) |*r| r else null, pixels, pitch);
}

pub fn onUnlockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onUnlockTexture(&rt.logger, &rt.backend.?, sdl_adapter.handleFromPtr(texture));
}

pub fn onSetTextureColorMod(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, r: u8, g: u8, b: u8) void {
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onSetTextureColorMod(&rt.logger, &rt.backend.?, texture_handle, r, g, b);
    } else if (rt.active and rt.batch_sink != null) {
        rt.frame_builder.onSetTextureColorModBatch(texture_handle, r, g, b);
    }
}

pub fn onSetTextureAlphaMod(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, a: u8) void {
    const texture_handle = sdl_adapter.handleFromPtr(texture);
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onSetTextureAlphaMod(&rt.logger, &rt.backend.?, texture_handle, a);
    } else if (rt.active and rt.batch_sink != null) {
        rt.frame_builder.onSetTextureAlphaModBatch(texture_handle, a);
    }
}

pub fn onSetTextureBlendMode(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, blend_mode: i32) void {
    rt.frame_builder.onSetTextureBlendMode(&rt.logger, sdl_adapter.handleFromPtr(texture), sdl_adapter.blendModeFromSdl2(blend_mode));
}

pub fn onSetRenderDrawColor(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) void {
    rt.frame_builder.onSetRenderDrawColor(sdl_adapter.handleFromPtr(renderer), r, g, b, a);
}

pub fn onRenderClear(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onRenderClear(sdl_adapter.handleFromPtr(renderer));
}

pub fn onRenderCopy(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect) void {
    var core_src = sdl_adapter.rectFromSdl(src);
    var core_dst = sdl_adapter.rectFromSdl(dst);
    rt.frame_builder.onRenderCopy(&rt.logger, sdl_adapter.handleFromPtr(renderer), sdl_adapter.handleFromPtr(texture), if (core_src) |*r| r else null, if (core_dst) |*r| r else null);
}

pub fn onRenderCopyEx(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) void {
    var core_src = sdl_adapter.rectFromSdl(src);
    var core_dst = sdl_adapter.rectFromSdl(dst);
    var core_center = sdl_adapter.pointFromSdl(center);
    rt.frame_builder.onRenderCopyEx(&rt.logger, sdl_adapter.handleFromPtr(renderer), sdl_adapter.handleFromPtr(texture), if (core_src) |*r| r else null, if (core_dst) |*r| r else null, angle, if (core_center) |*p| p else null, flip);
}

pub fn onRenderGeometryRaw(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) void {
    rt.frame_builder.onRenderGeometryRaw(&rt.logger, sdl_adapter.handleFromPtr(renderer), sdl_adapter.handleFromPtr(texture), xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices);
}

pub fn enqueueRenderGeometryRaw(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) void {
    if (xy_stride <= 0 or uv_stride <= 0 or num_vertices <= 0 or num_indices < 0 or (indices != null and size_indices <= 0)) return;
    var format: u32 = 0;
    var access: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (real_sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) return;
    const copy = frame_builder_mod.FrameBuilder.geometryRawAsCopy(xy, @intCast(xy_stride), uv, @intCast(uv_stride), @intCast(num_vertices), indices, @intCast(num_indices), @intCast(size_indices), w, h) orelse {
        rt.logger.writeOnceScoped(.warn, .intercept, "unsupported SDL_RenderGeometryRaw shape; skipping geometry");
        return;
    };
    dispatchCommand(rt, .{ .render_copy = .{
        .renderer = sdl_adapter.handleFromPtr(renderer),
        .texture = sdl_adapter.handleFromPtr(texture),
        .src = copy.src,
        .dst = copy.dst,
    } });
}

pub fn onRenderFillRect(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    rt.frame_builder.onRenderFillRect(sdl_adapter.handleFromPtr(renderer), if (core_rect) |*r| r else null);
}

pub fn onRenderDrawPoint(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, x: i32, y: i32) void {
    rt.frame_builder.onRenderDrawPoint(sdl_adapter.handleFromPtr(renderer), x, y);
}

pub fn onRenderDrawLine(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, x1: i32, y1: i32, x2: i32, y2: i32) void {
    rt.frame_builder.onRenderDrawLine(&rt.logger, sdl_adapter.handleFromPtr(renderer), x1, y1, x2, y2);
}

pub fn onRenderSetViewport(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    rt.frame_builder.onRenderSetViewport(sdl_adapter.handleFromPtr(renderer), if (core_rect) |*r| r else null);
}

pub fn onRenderSetClipRect(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    var core_rect = sdl_adapter.rectFromSdl(rect);
    rt.frame_builder.onRenderSetClipRect(sdl_adapter.handleFromPtr(renderer), if (core_rect) |*r| r else null);
}

pub fn onRenderPresent(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    if (rt.batch_sink != null) {
        rt.renderBatchPresent(renderer);
        return;
    }
    if (rt.active and rt.tty != null and rt.engine != null and rt.backend != null and rt.shouldPresent()) {
        if (!rt.terminalRenderingEnabled(null, renderer)) {
            rt.notePresentationLayout(.{});
            return;
        }
        const start_ns = std.time.nanoTimestamp();
        const renderer_handle = sdl_adapter.handleFromPtr(renderer);
        onRenderPresentCore(rt, renderer_handle, start_ns);
    }
}

fn onRenderPresentCore(rt: *runtime_mod.Runtime, renderer: CoreHandle, start_ns: i128) void {
    rt.frame_builder.onRenderPresent(&rt.logger, &rt.tty.?, &rt.engine.?, &rt.backend.?, renderer, rt.bg_only, rt.debug_protocol_replies, rt.image_gc);
    rt.notePresentationLayout(rt.frame_builder.presentationLayoutForRenderer(&rt.tty.?, renderer));
    const duration = std.time.nanoTimestamp() - start_ns;
    rt.notePresentDuration(duration);
    const summary = rt.frame_builder.inspectSummary();
    const whiskers_frame: inspect_model.FrameRecord = .{
        .id = 0,
        .ts_ns = std.time.nanoTimestamp(),
        .present_ns = duration,
        .queue_depth = rt.currentQueueDepth(),
        .skipped_presents = rt.skipped_presents,
        .render_strategy = summary.render_strategy,
        .strategy_short = summary.strategy_short,
        .copies = summary.copies,
        .fills = summary.fills,
        .lines = summary.lines,
        .uploads = summary.uploads,
        .placements = summary.placements,
        .bytes_uploaded = summary.bytes_uploaded,
        .fallback_texture_key = summary.fallback_texture_key,
        .fallback_reason = summary.fallback_reason,
        .image_id = summary.image_id,
        .placement_id = summary.placement_id,
    };
    if (rt.whiskers_client) |*client| {
        rt.inspect_resources.clearRetainingCapacity();
        rt.frame_builder.appendSnapshotResources(rt.allocator, &rt.inspect_resources) catch return;
        rt.inspect_resource_records.clearRetainingCapacity();
        for (rt.inspect_resources.items) |res| {
            rt.inspect_resource_records.append(rt.allocator, .{
                .kind = switch (res.kind) {
                    .texture => .texture,
                    .image => .image,
                    .placement => .placement,
                },
                .texture_key = res.texture_key,
                .placement_id = res.placement_id,
                .alias = inspect_model.makeAlias(if (res.texture_key != 0) res.texture_key else res.image_id),
                .w = res.w,
                .h = res.h,
                .format = res.format,
                .blend_mode = res.blend_mode,
                .update_count = res.update_count,
                .image_id = res.image_id,
            }) catch {};
        }
        client.notePresent(whiskers_frame, rt.inspect_resource_records.items);
    }
}

pub fn onExternalFramebufferPresent(rt: *runtime_mod.Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
    rt.presentExternalFramebuffer(width, height, format, pixels);
}

pub fn handleCommand(rt: *runtime_mod.Runtime, cmd: Command) void {
    switch (cmd) {
        .create_window => |c| rt.frame_builder.onCreateWindow(c.window, c.w, c.h),
        .create_renderer => |c| rt.frame_builder.onCreateRenderer(c.window, c.renderer),
        .destroy_renderer => |c| rt.frame_builder.onDestroyRenderer(c.renderer),
        .create_texture => |c| rt.frame_builder.onCreateTexture(c.texture, c.format, c.w, c.h),
        .destroy_texture => |c| rt.frame_builder.onDestroyTexture(c.texture),
        .update_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.pixels) |buf| @ptrCast(buf.ptr) else null, c.pitch);
        },
        .update_yuv_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) rt.frame_builder.onUpdateYuvTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uplane) |buf| @ptrCast(buf.ptr) else null, c.upitch, if (c.vplane) |buf| @ptrCast(buf.ptr) else null, c.vpitch);
        },
        .update_nv_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) rt.frame_builder.onUpdateNvTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uvplane) |buf| @ptrCast(buf.ptr) else null, c.uvpitch);
        },
        .lock_texture => |c| {
            var rect = c.rect;
            rt.frame_builder.onLockTexture(&rt.logger, c.texture, if (rect) |*r| r else null, c.pixels, c.pitch);
        },
        .unlock_texture => |c| if (rt.active and rt.backend != null) rt.frame_builder.onUnlockTexture(&rt.logger, &rt.backend.?, c.texture),
        .set_texture_color_mod => |c| if (rt.active and rt.backend != null) rt.frame_builder.onSetTextureColorMod(&rt.logger, &rt.backend.?, c.texture, c.r, c.g, c.b),
        .set_texture_alpha_mod => |c| if (rt.active and rt.backend != null) rt.frame_builder.onSetTextureAlphaMod(&rt.logger, &rt.backend.?, c.texture, c.a),
        .set_texture_blend_mode => |c| rt.frame_builder.onSetTextureBlendMode(&rt.logger, c.texture, c.blend_mode),
        .set_render_draw_color => |c| rt.frame_builder.onSetRenderDrawColor(c.renderer, c.r, c.g, c.b, c.a),
        .render_clear => |c| rt.frame_builder.onRenderClear(c.renderer),
        .render_copy => |c| {
            var src = c.src;
            var dst = c.dst;
            rt.frame_builder.onRenderCopy(&rt.logger, c.renderer, c.texture, if (src) |*r| r else null, if (dst) |*r| r else null);
        },
        .render_copy_ex => |c| {
            var src = c.src;
            var dst = c.dst;
            var center = c.center;
            rt.frame_builder.onRenderCopyEx(&rt.logger, c.renderer, c.texture, if (src) |*r| r else null, if (dst) |*r| r else null, c.angle, if (center) |*p| p else null, c.flip);
        },
        .render_fill_rect => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderFillRect(c.renderer, if (rect) |*r| r else null);
        },
        .render_draw_point => |c| rt.frame_builder.onRenderDrawPoint(c.renderer, c.x, c.y),
        .render_draw_line => |c| rt.frame_builder.onRenderDrawLine(&rt.logger, c.renderer, c.x1, c.y1, c.x2, c.y2),
        .render_set_viewport => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderSetViewport(c.renderer, if (rect) |*r| r else null);
        },
        .render_set_clip_rect => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderSetClipRect(c.renderer, if (rect) |*r| r else null);
        },
        .render_present => |c| {
            if (rt.active and rt.tty != null and rt.engine != null and rt.backend != null and rt.shouldPresent()) {
                if (!rt.terminalRenderingEnabled(null, null)) {
                    rt.notePresentationLayout(.{});
                    return;
                }
                onRenderPresentCore(rt, c.renderer, std.time.nanoTimestamp());
            }
        },
        .external_framebuffer_present => |c| if (c.pixels) |buf| onExternalFramebufferPresent(rt, c.width, c.height, c.format, buf),
    }
}
