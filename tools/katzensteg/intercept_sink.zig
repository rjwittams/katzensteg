const std = @import("std");
const sdl = @import("katzensteg_sdl");
const runtime_mod = @import("runtime.zig");
const frame_builder_mod = @import("frame_builder.zig");

pub const InterceptMode = enum {
    sync_compose,
    queued_replay,
};

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
    create_window: struct { window: ?*sdl.SDL_Window, w: i32, h: i32 },
    create_renderer: struct { window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer },
    destroy_renderer: struct { renderer: ?*sdl.SDL_Renderer },
    create_texture: struct { texture: ?*sdl.SDL_Texture, format: sdl.Uint32, w: i32, h: i32 },
    destroy_texture: struct { texture: ?*sdl.SDL_Texture },
    update_texture: struct { texture: ?*sdl.SDL_Texture, rect: ?sdl.SDL_Rect, pixels: ?[]u8, pitch: i32 },
    update_yuv_texture: struct { texture: ?*sdl.SDL_Texture, rect: ?sdl.SDL_Rect, yplane: ?[]u8, ypitch: i32, uplane: ?[]u8, upitch: i32, vplane: ?[]u8, vpitch: i32 },
    update_nv_texture: struct { texture: ?*sdl.SDL_Texture, rect: ?sdl.SDL_Rect, yplane: ?[]u8, ypitch: i32, uvplane: ?[]u8, uvpitch: i32 },
    create_texture_from_surface: struct { texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface },
    lock_texture: struct { texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*anyopaque, pitch: i32 },
    unlock_texture: struct { texture: ?*sdl.SDL_Texture },
    set_texture_color_mod: struct { texture: ?*sdl.SDL_Texture, r: u8, g: u8, b: u8 },
    set_texture_alpha_mod: struct { texture: ?*sdl.SDL_Texture, a: u8 },
    set_texture_blend_mode: struct { texture: ?*sdl.SDL_Texture, blend_mode: i32 },
    set_render_draw_color: struct { renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8 },
    render_clear: struct { renderer: ?*sdl.SDL_Renderer },
    render_copy: struct { renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?sdl.SDL_Rect, dst: ?sdl.SDL_Rect },
    render_copy_ex: struct { renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?sdl.SDL_Rect, dst: ?sdl.SDL_Rect, angle: f64, center: ?sdl.SDL_Point, flip: c_int },
    render_fill_rect: struct { renderer: ?*sdl.SDL_Renderer, rect: ?sdl.SDL_Rect },
    render_draw_point: struct { renderer: ?*sdl.SDL_Renderer, x: i32, y: i32 },
    render_draw_line: struct { renderer: ?*sdl.SDL_Renderer, x1: i32, y1: i32, x2: i32, y2: i32 },
    render_set_viewport: struct { renderer: ?*sdl.SDL_Renderer, rect: ?sdl.SDL_Rect },
    render_set_clip_rect: struct { renderer: ?*sdl.SDL_Renderer, rect: ?sdl.SDL_Rect },
    render_present: struct { renderer: ?*sdl.SDL_Renderer },

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .update_texture => |*c| if (c.pixels) |buf| allocator.free(buf),
            .update_yuv_texture => |*c| {
                if (c.yplane) |buf| allocator.free(buf);
                if (c.uplane) |buf| allocator.free(buf);
                if (c.vplane) |buf| allocator.free(buf);
            },
            .update_nv_texture => |*c| {
                if (c.yplane) |buf| allocator.free(buf);
                if (c.uvplane) |buf| allocator.free(buf);
            },
            else => {},
        }
        self.* = undefined;
    }
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
                rt.logger.write("katzensteg: cloneCommand failed in sync_compose; dropping command");
                return;
            };
            defer owned.deinit(rt.allocator);
            handleCommand(rt, owned);
        },
        .queued_replay => {
            const owned = cloneCommand(rt, cmd) catch {
                rt.logger.write("katzensteg: cloneCommand failed in queued_replay; dropping command");
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
                    if (sdl.SDL_QueryTexture(c.texture, &format, &access, &w, &h) != 0) break :blk2 0;
                    break :blk2 @as(usize, @intCast(c.pitch * h));
                };
                if (byte_len > 0) {
                    copied = try rt.acquirePayloadBuffer(byte_len);
                    @memcpy(copied.?, @as([*]const u8, @ptrCast(p))[0..byte_len]);
                }
            }
            break :blk .{ .update_texture = .{ .texture = c.texture, .rect = if (c.rect) |r| r else null, .pixels = copied, .pitch = c.pitch } };
        },
        .update_yuv_texture => |c| .{ .update_yuv_texture = .{
            .texture = c.texture,
            .rect = c.rect,
            .yplane = try cloneBytes(rt, c.yplane),
            .ypitch = c.ypitch,
            .uplane = try cloneBytes(rt, c.uplane),
            .upitch = c.upitch,
            .vplane = try cloneBytes(rt, c.vplane),
            .vpitch = c.vpitch,
        } },
        .update_nv_texture => |c| .{ .update_nv_texture = .{
            .texture = c.texture,
            .rect = c.rect,
            .yplane = try cloneBytes(rt, c.yplane),
            .ypitch = c.ypitch,
            .uvplane = try cloneBytes(rt, c.uvplane),
            .uvpitch = c.uvpitch,
        } },
        .create_texture_from_surface => |c| .{ .create_texture_from_surface = c },
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
    };
}

fn cloneBytes(rt: *runtime_mod.Runtime, src: ?[]u8) !?[]u8 {
    const bytes = src orelse return null;
    const copied = try rt.acquirePayloadBuffer(bytes.len);
    @memcpy(copied, bytes);
    return copied;
}

pub fn onCreateWindow(rt: *runtime_mod.Runtime, window: ?*sdl.SDL_Window, w: i32, h: i32) void {
    rt.frame_builder.onCreateWindow(window, w, h);
}

pub fn onCreateRenderer(rt: *runtime_mod.Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onCreateRenderer(window, renderer);
}

pub fn onDestroyRenderer(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onDestroyRenderer(renderer);
}

pub fn onCreateTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, format: sdl.Uint32, w: i32, h: i32) void {
    rt.frame_builder.onCreateTexture(texture, format, w, h);
}

pub fn onDestroyTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    rt.frame_builder.onDestroyTexture(texture);
}

pub fn onUpdateTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, texture, rect, pixels, pitch);
}

pub fn onUpdateYuvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uplane: ?[*]const u8, upitch: i32, vplane: ?[*]const u8, vpitch: i32) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onUpdateYuvTexture(&rt.logger, &rt.backend.?, texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch);
}

pub fn onUpdateNvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uvplane: ?[*]const u8, uvpitch: i32) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onUpdateNvTexture(&rt.logger, &rt.backend.?, texture, rect, yplane, ypitch, uvplane, uvpitch);
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
            if (sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) break :blk 0;
            break :blk @as(usize, @intCast(pitch * h));
        };
        if (byte_len > 0) {
            copied = rt.acquirePayloadBuffer(byte_len) catch null;
            if (copied) |buf| @memcpy(buf, @as([*]const u8, @ptrCast(p))[0..byte_len]);
        }
    }
    if (copied == null and pixels != null) {
        rt.logger.write("katzensteg: failed to copy update_texture payload for queued replay");
    }
    rt.enqueueCommand(.{ .update_texture = .{ .texture = texture, .rect = if (rect) |r| r.* else null, .pixels = copied, .pitch = pitch } });
}

pub fn enqueueUpdateYuvTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uplane: ?[*]const u8, upitch: i32, vplane: ?[*]const u8, vpitch: i32) void {
    const dims = textureUpdateDimensions(texture, rect) orelse {
        rt.logger.write("katzensteg: failed to size SDL_UpdateYUVTexture payload");
        return;
    };
    const chroma_h = @divTrunc(dims.h + 1, 2);
    const copied_y = copyPlanePayload(rt, yplane, ypitch, dims.h);
    const copied_u = copyPlanePayload(rt, uplane, upitch, chroma_h);
    const copied_v = copyPlanePayload(rt, vplane, vpitch, chroma_h);
    if (copied_y == null or copied_u == null or copied_v == null) {
        rt.logger.write("katzensteg: failed to copy SDL_UpdateYUVTexture payload");
        if (copied_y) |buf| rt.allocator.free(buf);
        if (copied_u) |buf| rt.allocator.free(buf);
        if (copied_v) |buf| rt.allocator.free(buf);
        return;
    }
    rt.enqueueCommand(.{ .update_yuv_texture = .{
        .texture = texture,
        .rect = if (rect) |r| r.* else null,
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
        rt.logger.write("katzensteg: failed to size SDL_UpdateNVTexture payload");
        return;
    };
    const chroma_h = @divTrunc(dims.h + 1, 2);
    const copied_y = copyPlanePayload(rt, yplane, ypitch, dims.h);
    const copied_uv = copyPlanePayload(rt, uvplane, uvpitch, chroma_h);
    if (copied_y == null or copied_uv == null) {
        rt.logger.write("katzensteg: failed to copy SDL_UpdateNVTexture payload");
        if (copied_y) |buf| rt.allocator.free(buf);
        if (copied_uv) |buf| rt.allocator.free(buf);
        return;
    }
    rt.enqueueCommand(.{ .update_nv_texture = .{
        .texture = texture,
        .rect = if (rect) |r| r.* else null,
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
    if (sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) return null;
    return .{ .w = w, .h = h };
}

fn copyPlanePayload(rt: *runtime_mod.Runtime, plane: ?[*]const u8, pitch: i32, rows: i32) ?[]u8 {
    const src = plane orelse return null;
    if (pitch <= 0 or rows <= 0) return null;
    const byte_len: usize = @intCast(pitch * rows);
    const copied = rt.acquirePayloadBuffer(byte_len) catch return null;
    @memcpy(copied, src[0..byte_len]);
    return copied;
}

pub fn enqueueCreateTextureFromSurface(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.create_texture_from_surface, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    var format: u32 = 0;
    var access: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) {
        rt.logger.write("katzensteg: SDL_QueryTexture failed in enqueueCreateTextureFromSurface; using fallback metadata");
        format = sdl.SDL_PIXELFORMAT_ABGR8888;
    }
    rt.enqueueCommand(.{ .create_texture = .{ .texture = texture, .format = format, .w = w, .h = h } });

    if (surface == null) return;
    const converted = sdl.SDL_ConvertSurfaceFormat(surface, sdl.SDL_PIXELFORMAT_ABGR8888, 0) orelse {
        rt.logger.write("katzensteg: SDL_ConvertSurfaceFormat failed in enqueueCreateTextureFromSurface");
        return;
    };
    defer sdl.SDL_FreeSurface(converted);
    const surf: *SurfaceView = @ptrCast(@alignCast(converted));
    const byte_len: usize = @intCast(surf.pitch * surf.h);
    const copied = rt.acquirePayloadBuffer(byte_len) catch {
        rt.logger.write("katzensteg: alloc failed in enqueueCreateTextureFromSurface");
        return;
    };
    @memcpy(copied, @as([*]const u8, @ptrCast(surf.pixels.?))[0..byte_len]);
    rt.enqueueCommand(.{ .update_texture = .{
        .texture = texture,
        .rect = null,
        .pixels = copied,
        .pitch = surf.pitch,
    } });
}

pub fn onCreateTextureFromSurface(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onCreateTextureFromSurface(&rt.logger, &rt.backend.?, texture, surface);
}

pub fn enqueueQueuedUnlockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    const start_ns = std.time.nanoTimestamp();
    defer rt.noteProducerTime(.unlock_texture, @intCast(@max(0, std.time.nanoTimestamp() - start_ns)));
    const capture = rt.takeQueuedLock(texture) orelse {
        rt.logger.write("katzensteg: queued unlock without remembered lock capture");
        return;
    };
    const pixels = capture.pixels orelse {
        rt.logger.write("katzensteg: queued unlock capture had null pixels");
        return;
    };
    const byte_len: usize = if (capture.rect) |r| @intCast(capture.pitch * r.h) else blk: {
        var format: u32 = 0;
        var access: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        if (sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) break :blk 0;
        break :blk @as(usize, @intCast(capture.pitch * h));
    };
    if (byte_len == 0) {
        rt.logger.write("katzensteg: queued unlock capture had zero-sized payload");
        return;
    }
    const copied = rt.acquirePayloadBuffer(byte_len) catch {
        rt.logger.write("katzensteg: alloc failed in enqueueQueuedUnlockTexture");
        return;
    };
    @memcpy(copied, @as([*]const u8, @ptrCast(pixels))[0..byte_len]);
    rt.enqueueCommand(.{ .update_texture = .{
        .texture = texture,
        .rect = capture.rect,
        .pixels = copied,
        .pitch = capture.pitch,
    } });
}

pub fn onLockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*anyopaque, pitch: i32) void {
    rt.frame_builder.onLockTexture(&rt.logger, texture, rect, pixels, pitch);
}

pub fn onUnlockTexture(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onUnlockTexture(&rt.logger, &rt.backend.?, texture);
}

pub fn onSetTextureColorMod(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, r: u8, g: u8, b: u8) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onSetTextureColorMod(&rt.logger, &rt.backend.?, texture, r, g, b);
}

pub fn onSetTextureAlphaMod(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, a: u8) void {
    if (rt.active and rt.backend != null) rt.frame_builder.onSetTextureAlphaMod(&rt.logger, &rt.backend.?, texture, a);
}

pub fn onSetTextureBlendMode(rt: *runtime_mod.Runtime, texture: ?*sdl.SDL_Texture, blend_mode: i32) void {
    rt.frame_builder.onSetTextureBlendMode(&rt.logger, texture, blend_mode);
}

pub fn onSetRenderDrawColor(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) void {
    rt.frame_builder.onSetRenderDrawColor(renderer, r, g, b, a);
}

pub fn onRenderClear(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    rt.frame_builder.onRenderClear(renderer);
}

pub fn onRenderCopy(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect) void {
    rt.frame_builder.onRenderCopy(&rt.logger, renderer, texture, src, dst);
}

pub fn onRenderCopyEx(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) void {
    rt.frame_builder.onRenderCopyEx(&rt.logger, renderer, texture, src, dst, angle, center, flip);
}

pub fn onRenderGeometryRaw(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) void {
    rt.frame_builder.onRenderGeometryRaw(&rt.logger, renderer, texture, xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices);
}

pub fn enqueueRenderGeometryRaw(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) void {
    if (xy_stride <= 0 or uv_stride <= 0 or num_vertices <= 0 or num_indices < 0 or (indices != null and size_indices <= 0)) return;
    var format: u32 = 0;
    var access: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (sdl.SDL_QueryTexture(texture, &format, &access, &w, &h) != 0) return;
    const copy = frame_builder_mod.FrameBuilder.geometryRawAsCopy(xy, @intCast(xy_stride), uv, @intCast(uv_stride), @intCast(num_vertices), indices, @intCast(num_indices), @intCast(size_indices), w, h) orelse {
        rt.logger.writeOnce("katzensteg: unsupported SDL_RenderGeometryRaw shape; skipping geometry");
        return;
    };
    dispatchCommand(rt, .{ .render_copy = .{
        .renderer = renderer,
        .texture = texture,
        .src = copy.src,
        .dst = copy.dst,
    } });
}

pub fn onRenderFillRect(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    rt.frame_builder.onRenderFillRect(renderer, rect);
}

pub fn onRenderDrawPoint(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, x: i32, y: i32) void {
    rt.frame_builder.onRenderDrawPoint(renderer, x, y);
}

pub fn onRenderDrawLine(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, x1: i32, y1: i32, x2: i32, y2: i32) void {
    rt.frame_builder.onRenderDrawLine(&rt.logger, renderer, x1, y1, x2, y2);
}

pub fn onRenderSetViewport(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    rt.frame_builder.onRenderSetViewport(renderer, rect);
}

pub fn onRenderSetClipRect(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
    rt.frame_builder.onRenderSetClipRect(renderer, rect);
}

pub fn onRenderPresent(rt: *runtime_mod.Runtime, renderer: ?*sdl.SDL_Renderer) void {
    if (rt.active and rt.tty != null and rt.engine != null and rt.backend != null and rt.shouldPresent()) {
        const start_ns = std.time.nanoTimestamp();
        rt.frame_builder.onRenderPresent(&rt.logger, &rt.tty.?, &rt.engine.?, &rt.backend.?, renderer, rt.bg_only, rt.debug_protocol_replies, rt.image_gc);
        const duration = std.time.nanoTimestamp() - start_ns;
        rt.notePresentDuration(duration);
        if (rt.inspector) |*inspector| {
            if (inspector.isEnabled()) {
                const summary = rt.frame_builder.inspectSummary();
                inspector.noteFrame(.{
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
            });
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
                        .alias = @import("inspector.zig").makeAlias(if (res.texture_key != 0) res.texture_key else res.image_id),
                        .w = res.w,
                        .h = res.h,
                        .format = res.format,
                        .blend_mode = res.blend_mode,
                        .update_count = res.update_count,
                        .image_id = res.image_id,
                    }) catch {};
                }
                inspector.noteResources(rt.inspect_resource_records.items);
            }
        }
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
                    .alias = @import("inspector.zig").makeAlias(if (res.texture_key != 0) res.texture_key else res.image_id),
                    .w = res.w,
                    .h = res.h,
                    .format = res.format,
                    .blend_mode = res.blend_mode,
                    .update_count = res.update_count,
                    .image_id = res.image_id,
                }) catch {};
            }
            client.notePresent(rt.inspect_resource_records.items.len);
        }
    }
}

pub fn handleCommand(rt: *runtime_mod.Runtime, cmd: Command) void {
    switch (cmd) {
        .create_window => |c| onCreateWindow(rt, c.window, c.w, c.h),
        .create_renderer => |c| onCreateRenderer(rt, c.window, c.renderer),
        .destroy_renderer => |c| onDestroyRenderer(rt, c.renderer),
        .create_texture => |c| onCreateTexture(rt, c.texture, c.format, c.w, c.h),
        .destroy_texture => |c| onDestroyTexture(rt, c.texture),
        .update_texture => |c| onUpdateTexture(rt, c.texture, if (c.rect) |*r| r else null, if (c.pixels) |buf| @ptrCast(buf.ptr) else null, c.pitch),
        .update_yuv_texture => |c| onUpdateYuvTexture(rt, c.texture, if (c.rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uplane) |buf| @ptrCast(buf.ptr) else null, c.upitch, if (c.vplane) |buf| @ptrCast(buf.ptr) else null, c.vpitch),
        .update_nv_texture => |c| onUpdateNvTexture(rt, c.texture, if (c.rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uvplane) |buf| @ptrCast(buf.ptr) else null, c.uvpitch),
        .create_texture_from_surface => |c| onCreateTextureFromSurface(rt, c.texture, c.surface),
        .lock_texture => |c| onLockTexture(rt, c.texture, c.rect, c.pixels, c.pitch),
        .unlock_texture => |c| onUnlockTexture(rt, c.texture),
        .set_texture_color_mod => |c| onSetTextureColorMod(rt, c.texture, c.r, c.g, c.b),
        .set_texture_alpha_mod => |c| onSetTextureAlphaMod(rt, c.texture, c.a),
        .set_texture_blend_mode => |c| onSetTextureBlendMode(rt, c.texture, c.blend_mode),
        .set_render_draw_color => |c| onSetRenderDrawColor(rt, c.renderer, c.r, c.g, c.b, c.a),
        .render_clear => |c| onRenderClear(rt, c.renderer),
        .render_copy => |c| onRenderCopy(rt, c.renderer, c.texture, if (c.src) |*r| r else null, if (c.dst) |*r| r else null),
        .render_copy_ex => |c| onRenderCopyEx(rt, c.renderer, c.texture, if (c.src) |*r| r else null, if (c.dst) |*r| r else null, c.angle, if (c.center) |*p| p else null, c.flip),
        .render_fill_rect => |c| onRenderFillRect(rt, c.renderer, if (c.rect) |*r| r else null),
        .render_draw_point => |c| onRenderDrawPoint(rt, c.renderer, c.x, c.y),
        .render_draw_line => |c| onRenderDrawLine(rt, c.renderer, c.x1, c.y1, c.x2, c.y2),
        .render_set_viewport => |c| onRenderSetViewport(rt, c.renderer, if (c.rect) |*r| r else null),
        .render_set_clip_rect => |c| onRenderSetClipRect(rt, c.renderer, if (c.rect) |*r| r else null),
        .render_present => |c| onRenderPresent(rt, c.renderer),
    }
}
