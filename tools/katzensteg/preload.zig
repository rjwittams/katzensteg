const std = @import("std");
const sdl = @import("katzensteg_sdl");
const runtime = @import("runtime.zig");
const sink = @import("intercept_sink.zig");

var trace_create_window: usize = 0;
var trace_create_renderer: usize = 0;
var trace_get_renderer_info: usize = 0;
var trace_create_texture: usize = 0;
var trace_update_texture: usize = 0;
var trace_update_yuv_texture: usize = 0;
var trace_update_nv_texture: usize = 0;
var trace_lock_texture: usize = 0;
var trace_unlock_texture: usize = 0;
var trace_render_clear: usize = 0;
var trace_render_copy: usize = 0;
var trace_render_copy_ex: usize = 0;
var trace_render_geometry_raw: usize = 0;
var trace_render_present: usize = 0;
var trace_gl_create_context: usize = 0;
var trace_gl_make_current: usize = 0;
var trace_gl_swap_window: usize = 0;
var trace_upper_blit: usize = 0;

const SurfaceTraceView = extern struct {
    flags: u32,
    format: ?*anyopaque,
    w: i32,
    h: i32,
    pitch: i32,
    pixels: ?*anyopaque,
};

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};

extern fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

fn traceLimited(rt: *runtime.Runtime, counter: *usize, comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") == null) return;
    counter.* += 1;
    if (counter.* <= 12 or (counter.* % 300) == 0) {
        rt.logger.writeFmt(fmt, args);
    }
}

fn isTextureFormatFilterDisabled() bool {
    const value_z = std.c.getenv("KATZENSTEG_FILTER_TEXTURE_FORMATS") orelse return false;
    const value = std.mem.span(value_z);
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off");
}

fn parseEnabledEnvValue(value: ?[]const u8) bool {
    const text = value orelse return true;
    return !(std.mem.eql(u8, text, "0") or
        std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off"));
}

fn shouldAllowBackgroundGamepadEvents() bool {
    if (!parseEnabledEnvValue(if (std.c.getenv("KATZENSTEG_INPUT")) |value| std.mem.span(value) else null)) return false;
    if (!parseEnabledEnvValue(if (std.c.getenv("KATZENSTEG_INPUT_CLAIM")) |value| std.mem.span(value) else null)) return false;
    return parseEnabledEnvValue(if (std.c.getenv("KATZENSTEG_GAMEPAD_BACKGROUND")) |value| std.mem.span(value) else null);
}

fn applyBackgroundGamepadHint() void {
    if (!shouldAllowBackgroundGamepadEvents()) return;
    _ = sdl.SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
}

fn isKatzenstegTextureFormatSupported(format: sdl.Uint32) bool {
    return switch (format) {
        sdl.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_PIXELFORMAT_ARGB8888,
        sdl.SDL_PIXELFORMAT_XRGB8888,
        sdl.SDL_PIXELFORMAT_RGB565,
        sdl.SDL_PIXELFORMAT_RGBA4444,
        => true,
        else => false,
    };
}

fn filterRendererInfoTextureFormats(info: *sdl.SDL_RendererInfo) void {
    const count = @min(info.num_texture_formats, info.texture_formats.len);
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < count) : (read_index += 1) {
        const format = info.texture_formats[read_index];
        if (!isKatzenstegTextureFormatSupported(format)) continue;
        info.texture_formats[write_index] = format;
        write_index += 1;
    }
    var clear_index = write_index;
    while (clear_index < info.texture_formats.len) : (clear_index += 1) {
        info.texture_formats[clear_index] = 0;
    }
    info.num_texture_formats = @intCast(write_index);
}

fn surfaceSummary(surface: ?*sdl.SDL_Surface) struct { ptr: usize, w: i32, h: i32, pitch: i32, pixels: usize } {
    const s = surface orelse return .{ .ptr = 0, .w = 0, .h = 0, .pitch = 0, .pixels = 0 };
    const view: *const SurfaceTraceView = @ptrCast(@alignCast(s));
    return .{
        .ptr = @intFromPtr(s),
        .w = view.w,
        .h = view.h,
        .pitch = view.pitch,
        .pixels = if (view.pixels) |p| @intFromPtr(p) else 0,
    };
}

fn callerSummary(return_addr: usize) struct { image: []const u8, symbol: []const u8, offset: usize } {
    var info: DlInfo = .{ .dli_fname = null, .dli_fbase = null, .dli_sname = null, .dli_saddr = null };
    if (dladdr(@ptrFromInt(return_addr), &info) == 0) return .{ .image = "unknown", .symbol = "unknown", .offset = 0 };
    const symbol_addr = if (info.dli_saddr) |p| @intFromPtr(p) else return_addr;
    return .{
        .image = if (info.dli_fname) |s| std.mem.span(s) else "unknown",
        .symbol = if (info.dli_sname) |s| std.mem.span(s) else "unknown",
        .offset = return_addr -| symbol_addr,
    };
}

pub export fn ks_katzensteg_shutdown() callconv(.c) void {
    runtime.shutdownGlobal();
}

pub export fn ks_SDL_Init(flags: sdl.Uint32) callconv(.c) c_int {
    applyBackgroundGamepadHint();
    return sdl.SDL_Init(flags);
}

pub export fn ks_SDL_InitSubSystem(flags: sdl.Uint32) callconv(.c) c_int {
    applyBackgroundGamepadHint();
    return sdl.SDL_InitSubSystem(flags);
}

pub export fn ks_SDL_QuitSubSystem(flags: sdl.Uint32) callconv(.c) void {
    if ((flags & sdl.SDL_INIT_VIDEO) != 0) runtime.shutdownGlobal();
    sdl.SDL_QuitSubSystem(flags);
}

pub export fn ks_SDL_Quit() callconv(.c) void {
    runtime.shutdownGlobal();
    sdl.SDL_Quit();
}

pub export fn ks_SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Window {
    const window = sdl.SDL_CreateWindow(title, x, y, w, h, flags);
    const rt = runtime.get();
    rt.noteInputWindowSize(w, h);
    traceLimited(rt, &trace_create_window, "katzensteg-trace: SDL_CreateWindow window={x} size={d}x{d} flags=0x{x}", .{ if (window) |p| @intFromPtr(p) else 0, w, h, flags });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateWindow(rt, window, w, h),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_window = .{ .window = window, .w = w, .h = h } }),
    }
    return window;
}

pub export fn ks_SDL_GetWindowFlags(window: ?*sdl.SDL_Window) callconv(.c) sdl.Uint32 {
    const flags = sdl.SDL_GetWindowFlags(window);
    return runtime.get().claimedWindowFlags(flags);
}

pub export fn ks_SDL_DestroyWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    sdl.SDL_DestroyWindow(window);
}

pub export fn ks_SDL_CreateRenderer(window: ?*sdl.SDL_Window, index: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Renderer {
    const renderer = sdl.SDL_CreateRenderer(window, index, flags);
    const rt = runtime.get();
    traceLimited(rt, &trace_create_renderer, "katzensteg-trace: SDL_CreateRenderer window={x} renderer={x} index={d} flags=0x{x}", .{ if (window) |p| @intFromPtr(p) else 0, if (renderer) |p| @intFromPtr(p) else 0, index, flags });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateRenderer(rt, window, renderer),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_renderer = .{ .window = window, .renderer = renderer } }),
    }
    return renderer;
}

pub export fn ks_SDL_GetRendererInfo(renderer: ?*sdl.SDL_Renderer, info: ?*sdl.SDL_RendererInfo) callconv(.c) c_int {
    const rc = sdl.SDL_GetRendererInfo(renderer, info);
    if (rc == 0) {
        if (info) |renderer_info| {
            const before = renderer_info.num_texture_formats;
            if (!isTextureFormatFilterDisabled()) filterRendererInfoTextureFormats(renderer_info);
            if (std.c.getenv("KATZENSTEG_TRACE_SDL") != null) {
                const rt = runtime.get();
                traceLimited(rt, &trace_get_renderer_info, "katzensteg-trace: SDL_GetRendererInfo renderer={x} rc={d} texture_formats={d}->{d}", .{ if (renderer) |p| @intFromPtr(p) else 0, rc, before, renderer_info.num_texture_formats });
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_DestroyRenderer(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    const rt = runtime.get();
    switch (rt.intercept_mode) {
        .sync_compose => sink.onDestroyRenderer(rt, renderer),
        .queued_replay => sink.dispatchCommand(rt, .{ .destroy_renderer = .{ .renderer = renderer } }),
    }
    sdl.SDL_DestroyRenderer(renderer);
}

pub export fn ks_SDL_CreateTexture(renderer: ?*sdl.SDL_Renderer, format: sdl.Uint32, access: c_int, w: c_int, h: c_int) callconv(.c) ?*sdl.SDL_Texture {
    const texture = sdl.SDL_CreateTexture(renderer, format, access, w, h);
    const rt = runtime.get();
    traceLimited(rt, &trace_create_texture, "katzensteg-trace: SDL_CreateTexture renderer={x} texture={x} format={d} access={d} size={d}x{d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, format, access, w, h });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateTexture(rt, texture, format, w, h),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_texture = .{ .texture = texture, .format = format, .w = w, .h = h } }),
    }
    return texture;
}

pub export fn ks_SDL_CreateTextureFromSurface(renderer: ?*sdl.SDL_Renderer, surface: ?*sdl.SDL_Surface) callconv(.c) ?*sdl.SDL_Texture {
    const texture = sdl.SDL_CreateTextureFromSurface(renderer, surface);
    const rt = runtime.get();
    if (texture) |tex| {
        switch (rt.intercept_mode) {
            .sync_compose => {
                sink.onCreateTexture(rt, tex, sdl.SDL_PIXELFORMAT_ABGR8888, 0, 0);
                sink.onCreateTextureFromSurface(rt, tex, surface);
            },
            .queued_replay => sink.enqueueCreateTextureFromSurface(rt, tex, surface),
        }
    }
    return texture;
}

pub export fn ks_SDL_DestroyTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    const rt = runtime.get();
    switch (rt.intercept_mode) {
        .sync_compose => sink.onDestroyTexture(rt, texture),
        .queued_replay => sink.dispatchCommand(rt, .{ .destroy_texture = .{ .texture = texture } }),
    }
    sdl.SDL_DestroyTexture(texture);
}

pub export fn ks_SDL_UpdateTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_UpdateTexture(texture, rect, pixels, pitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_texture, "katzensteg-trace: SDL_UpdateTexture texture={x} rc={d} rect={s} pitch={d} pixels={x}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", pitch, if (pixels) |p| @intFromPtr(p) else 0 });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateTexture(rt, texture, rect, pixels, pitch),
        .queued_replay => sink.enqueueUpdateTexture(rt, texture, rect, pixels, pitch),
    };
    return rc;
}

pub export fn ks_SDL_UpdateYUVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uplane: ?[*]const sdl.Uint8, upitch: c_int, vplane: ?[*]const sdl.Uint8, vpitch: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_UpdateYUVTexture(texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_yuv_texture, "katzensteg-trace: SDL_UpdateYUVTexture texture={x} rc={d} rect={s} ypitch={d} upitch={d} vpitch={d}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", ypitch, upitch, vpitch });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateYuvTexture(rt, texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch),
        .queued_replay => sink.enqueueUpdateYuvTexture(rt, texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch),
    };
    return rc;
}

pub export fn ks_SDL_UpdateNVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uvplane: ?[*]const sdl.Uint8, uvpitch: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_UpdateNVTexture(texture, rect, yplane, ypitch, uvplane, uvpitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_nv_texture, "katzensteg-trace: SDL_UpdateNVTexture texture={x} rc={d} rect={s} ypitch={d} uvpitch={d}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", ypitch, uvpitch });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateNvTexture(rt, texture, rect, yplane, ypitch, uvplane, uvpitch),
        .queued_replay => sink.enqueueUpdateNvTexture(rt, texture, rect, yplane, ypitch, uvplane, uvpitch),
    };
    return rc;
}

pub export fn ks_SDL_LockTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) callconv(.c) c_int {
    const rc = sdl.SDL_LockTexture(texture, rect, pixels, pitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_lock_texture, "katzensteg-trace: SDL_LockTexture texture={x} rc={d} rect={s} pitch={d} pixels={x}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", if (rc == 0) pitch.* else 0, if (rc == 0) if (pixels.*) |p| @intFromPtr(p) else 0 else 0 });
    if (rc == 0) {
        switch (rt.intercept_mode) {
            .sync_compose => sink.onLockTexture(rt, texture, rect, pixels.*, pitch.*),
            .queued_replay => rt.rememberQueuedLock(texture, rect, pixels.*, pitch.*),
        }
    }
    return rc;
}

pub export fn ks_SDL_UnlockTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_unlock_texture, "katzensteg-trace: SDL_UnlockTexture texture={x}", .{if (texture) |p| @intFromPtr(p) else 0});
    switch (rt.intercept_mode) {
        .sync_compose => sink.onUnlockTexture(rt, texture),
        .queued_replay => sink.enqueueQueuedUnlockTexture(rt, texture),
    }
    sdl.SDL_UnlockTexture(texture);
}

pub export fn ks_SDL_SetTextureColorMod(texture: ?*sdl.SDL_Texture, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureColorMod(texture, r, g, b);
    const rt = runtime.get();
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onSetTextureColorMod(rt, texture, r, g, b),
        .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_color_mod = .{ .texture = texture, .r = r, .g = g, .b = b } }),
    };
    return rc;
}

pub export fn ks_SDL_SetTextureAlphaMod(texture: ?*sdl.SDL_Texture, a: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureAlphaMod(texture, a);
    const rt = runtime.get();
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onSetTextureAlphaMod(rt, texture, a),
        .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_alpha_mod = .{ .texture = texture, .a = a } }),
    };
    return rc;
}

pub export fn ks_SDL_SetTextureBlendMode(texture: ?*sdl.SDL_Texture, blendMode: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureBlendMode(texture, blendMode);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onSetTextureBlendMode(rt, texture, blendMode),
            .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_blend_mode = .{ .texture = texture, .blend_mode = blendMode } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_SetRenderDrawColor(renderer: ?*sdl.SDL_Renderer, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8, a: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetRenderDrawColor(renderer, r, g, b, a);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onSetRenderDrawColor(rt, renderer, r, g, b, a),
            .queued_replay => sink.dispatchCommand(rt, .{ .set_render_draw_color = .{ .renderer = renderer, .r = r, .g = g, .b = b, .a = a } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderClear(renderer: ?*sdl.SDL_Renderer) callconv(.c) c_int {
    const rc = sdl.SDL_RenderClear(renderer);
    if (rc == 0) {
        const rt = runtime.get();
        traceLimited(rt, &trace_render_clear, "katzensteg-trace: SDL_RenderClear renderer={x}", .{if (renderer) |p| @intFromPtr(p) else 0});
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderClear(rt, renderer),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_clear = .{ .renderer = renderer } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderCopy(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderCopy(renderer, texture, srcrect, dstrect);
    if (rc == 0) {
        const rt = runtime.get();
        traceLimited(rt, &trace_render_copy, "katzensteg-trace: SDL_RenderCopy renderer={x} texture={x} src={s} dst={s}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, if (srcrect == null) "null" else "set", if (dstrect == null) "null" else "set" });
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderCopy(rt, renderer, texture, srcrect, dstrect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_copy = .{ .renderer = renderer, .texture = texture, .src = if (srcrect) |r| r.* else null, .dst = if (dstrect) |r| r.* else null } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderCopyEx(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderCopyEx(renderer, texture, srcrect, dstrect, angle, center, flip);
    if (rc == 0) {
        const rt = runtime.get();
        traceLimited(rt, &trace_render_copy_ex, "katzensteg-trace: SDL_RenderCopyEx renderer={x} texture={x} src={s} dst={s} angle={d:.2} flip={d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, if (srcrect == null) "null" else "set", if (dstrect == null) "null" else "set", angle, flip });
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderCopyEx(rt, renderer, texture, srcrect, dstrect, angle, center, flip),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_copy_ex = .{ .renderer = renderer, .texture = texture, .src = if (srcrect) |r| r.* else null, .dst = if (dstrect) |r| r.* else null, .angle = angle, .center = if (center) |p| p.* else null, .flip = flip } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderGeometryRaw(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, color: ?[*]const sdl.SDL_Color, color_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderGeometryRaw(renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices);
    if (rc == 0) {
        const rt = runtime.get();
        traceLimited(rt, &trace_render_geometry_raw, "katzensteg-trace: SDL_RenderGeometryRaw renderer={x} texture={x} vertices={d} indices={d} size_indices={d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, num_vertices, num_indices, size_indices });
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderGeometryRaw(rt, renderer, texture, xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices),
            .queued_replay => sink.enqueueRenderGeometryRaw(rt, renderer, texture, xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderFillRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderFillRect(renderer, rect);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderFillRect(rt, renderer, rect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_fill_rect = .{ .renderer = renderer, .rect = if (rect) |r| r.* else null } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderDrawPoint(renderer: ?*sdl.SDL_Renderer, x: c_int, y: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderDrawPoint(renderer, x, y);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderDrawPoint(rt, renderer, x, y),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_draw_point = .{ .renderer = renderer, .x = x, .y = y } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderDrawLine(renderer: ?*sdl.SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderDrawLine(renderer, x1, y1, x2, y2);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderDrawLine(rt, renderer, x1, y1, x2, y2),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_draw_line = .{ .renderer = renderer, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderSetViewport(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderSetViewport(renderer, rect);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderSetViewport(rt, renderer, rect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_set_viewport = .{ .renderer = renderer, .rect = if (rect) |r| r.* else null } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderSetClipRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderSetClipRect(renderer, rect);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderSetClipRect(rt, renderer, rect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_set_clip_rect = .{ .renderer = renderer, .rect = if (rect) |r| r.* else null } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderPresent(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_render_present, "katzensteg-trace: SDL_RenderPresent renderer={x}", .{if (renderer) |p| @intFromPtr(p) else 0});
    switch (rt.intercept_mode) {
        .sync_compose => sink.onRenderPresent(rt, renderer),
        .queued_replay => sink.dispatchCommand(rt, .{ .render_present = .{ .renderer = renderer } }),
    }
    sdl.SDL_RenderPresent(renderer);
}

pub export fn ks_SDL_GL_CreateContext(window: ?*sdl.SDL_Window) callconv(.c) sdl.SDL_GLContext {
    const context = sdl.SDL_GL_CreateContext(window);
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_create_context, "katzensteg-trace: SDL_GL_CreateContext window={x} context={x}", .{ if (window) |p| @intFromPtr(p) else 0, if (context) |p| @intFromPtr(p) else 0 });
    return context;
}

pub export fn ks_SDL_GL_MakeCurrent(window: ?*sdl.SDL_Window, context: sdl.SDL_GLContext) callconv(.c) c_int {
    const rc = sdl.SDL_GL_MakeCurrent(window, context);
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_make_current, "katzensteg-trace: SDL_GL_MakeCurrent window={x} context={x} rc={d}", .{ if (window) |p| @intFromPtr(p) else 0, if (context) |p| @intFromPtr(p) else 0, rc });
    return rc;
}

pub export fn ks_SDL_GL_SwapWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_swap_window, "katzensteg-trace: SDL_GL_SwapWindow window={x}", .{if (window) |p| @intFromPtr(p) else 0});
    sdl.SDL_GL_SwapWindow(window);
}

pub export fn ks_SDL_PollEvent(event: ?*sdl.SDL_Event) callconv(.c) c_int {
    const rt = runtime.get();
    rt.pollTerminalInput();
    if (rt.popSdlInputEvent(event)) return 1;
    const out = event orelse return sdl.SDL_PollEvent(event);
    while (true) {
        const rc = sdl.SDL_PollEvent(out);
        if (rc == 0) return 0;
        if (!rt.shouldSuppressSdlEvent(out)) return rc;
    }
}

pub export fn ks_SDL_GetMouseState(x: ?*c_int, y: ?*c_int) callconv(.c) sdl.Uint32 {
    const rt = runtime.get();
    rt.pollTerminalInput();
    if (rt.terminalMouseState()) |state| {
        if (x) |out_x| out_x.* = state.x;
        if (y) |out_y| out_y.* = state.y;
        return state.buttons;
    }
    return sdl.SDL_GetMouseState(x, y);
}

pub export fn ks_SDL_UpperBlit(src: ?*sdl.SDL_Surface, srcrect: ?*const sdl.SDL_Rect, dst: ?*sdl.SDL_Surface, dstrect: ?*sdl.SDL_Rect) callconv(.c) c_int {
    const return_addr = @returnAddress();
    const rc = sdl.SDL_UpperBlit(src, srcrect, dst, dstrect);
    const rt = runtime.get();
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") != null) {
        trace_upper_blit += 1;
        if (rc != 0 or trace_upper_blit <= 20 or (trace_upper_blit % 300) == 0) {
            const ss = surfaceSummary(src);
            const ds = surfaceSummary(dst);
            const caller = callerSummary(return_addr);
            rt.logger.writeFmt(
                "katzensteg-trace: SDL_UpperBlit rc={d} caller={s}+0x{x} image={s} src={x} {d}x{d} pitch={d} pixels={x} srcrect={s} dst={x} {d}x{d} pitch={d} pixels={x} dstrect={s} err={s}",
                .{
                    rc,
                    caller.symbol,
                    caller.offset,
                    caller.image,
                    ss.ptr,
                    ss.w,
                    ss.h,
                    ss.pitch,
                    ss.pixels,
                    if (srcrect == null) "null" else "set",
                    ds.ptr,
                    ds.w,
                    ds.h,
                    ds.pitch,
                    ds.pixels,
                    if (dstrect == null) "null" else "set",
                    std.mem.span(sdl.SDL_GetError()),
                },
            );
        }
    }
    return rc;
}

test "renderer info texture format filter keeps only capturable formats in renderer order" {
    var info = sdl.SDL_RendererInfo{
        .name = null,
        .flags = 0,
        .num_texture_formats = 7,
        .texture_formats = .{
            sdl.SDL_PIXELFORMAT_YV12,
            sdl.SDL_PIXELFORMAT_ABGR8888,
            sdl.SDL_PIXELFORMAT_NV12,
            sdl.SDL_PIXELFORMAT_XRGB8888,
            sdl.SDL_PIXELFORMAT_RGB565,
            sdl.SDL_PIXELFORMAT_IYUV,
            sdl.SDL_PIXELFORMAT_ARGB8888,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        },
        .max_texture_width = 0,
        .max_texture_height = 0,
    };

    filterRendererInfoTextureFormats(&info);

    try std.testing.expectEqual(@as(sdl.Uint32, 4), info.num_texture_formats);
    try std.testing.expectEqual(sdl.SDL_PIXELFORMAT_ABGR8888, info.texture_formats[0]);
    try std.testing.expectEqual(sdl.SDL_PIXELFORMAT_XRGB8888, info.texture_formats[1]);
    try std.testing.expectEqual(sdl.SDL_PIXELFORMAT_RGB565, info.texture_formats[2]);
    try std.testing.expectEqual(sdl.SDL_PIXELFORMAT_ARGB8888, info.texture_formats[3]);
    try std.testing.expectEqual(@as(sdl.Uint32, 0), info.texture_formats[4]);
}

test "background gamepad env parser defaults on and accepts common opt-outs" {
    try std.testing.expect(parseEnabledEnvValue(null));
    try std.testing.expect(parseEnabledEnvValue("1"));
    try std.testing.expect(parseEnabledEnvValue("true"));
    try std.testing.expect(!parseEnabledEnvValue("0"));
    try std.testing.expect(!parseEnabledEnvValue("false"));
    try std.testing.expect(!parseEnabledEnvValue("no"));
    try std.testing.expect(!parseEnabledEnvValue("off"));
}
