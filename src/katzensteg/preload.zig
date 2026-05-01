const std = @import("std");
const sdl = @import("katzensteg_sdl");
const sdl_adapter = @import("sdl2_adapter.zig");
const real_gl = @import("real_gl.zig");
const real_sdl = @import("real_sdl.zig");
const sdl_input = @import("sdl2_input_adapter.zig");
const log_mod = @import("log.zig");
const runtime = @import("runtime.zig");
const sink = @import("intercept_sink.zig");
const window_policy = @import("window_policy.zig");
const gl_capture = @import("gl_capture.zig");
const frame_builder_mod = @import("frame_builder.zig");
const ExternalFramebufferFormat = frame_builder_mod.ExternalFramebufferFormat;
const core_exports = @import("core_exports.zig");

comptime {
    _ = core_exports;
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_mod.stdLogFn,
};

const sdl_log = std.log.scoped(.sdl);
const gl_log = std.log.scoped(.gl);

var trace_create_window: usize = 0;
var trace_show_window: usize = 0;
var trace_hide_window: usize = 0;
var trace_minimize_window: usize = 0;
var trace_restore_window: usize = 0;
var trace_raise_window: usize = 0;
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
var trace_gl_capture_error: usize = 0;
var trace_gl_downscale_target: usize = 0;
var trace_upper_blit: usize = 0;
var trace_get_mouse_state: usize = 0;

const SDL_QUIT_ON_LAST_WINDOW_CLOSE_HINT = "SDL_QUIT_ON_LAST_WINDOW_CLOSE";
var tracked_sdl_window_count: i32 = 0;

const GL_BACK: c_uint = 0x0405;
const GL_RGBA: c_uint = 0x1908;
const GL_UNSIGNED_BYTE: c_uint = 0x1401;
const GL_PACK_ALIGNMENT: c_uint = 0x0D05;
const GL_READ_BUFFER: c_uint = 0x0C02;
const GL_PIXEL_PACK_BUFFER: c_uint = 0x88EB;
const GL_PIXEL_PACK_BUFFER_BINDING: c_uint = 0x88ED;
const GL_STREAM_READ: c_uint = 0x88E1;
const GL_READ_ONLY: c_uint = 0x88B8;
const GL_TEXTURE_2D: c_uint = 0x0DE1;
const GL_TEXTURE_MIN_FILTER: c_uint = 0x2801;
const GL_TEXTURE_MAG_FILTER: c_uint = 0x2800;
const GL_LINEAR: c_uint = 0x2601;
const GL_COLOR_BUFFER_BIT: c_uint = 0x00004000;
const GL_FRAMEBUFFER: c_uint = 0x8D40;
const GL_READ_FRAMEBUFFER: c_uint = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: c_uint = 0x8CA9;
const GL_FRAMEBUFFER_BINDING: c_uint = 0x8CA6;
const GL_READ_FRAMEBUFFER_BINDING: c_uint = 0x8CAA;
const GL_DRAW_FRAMEBUFFER_BINDING: c_uint = 0x8CA6;
const GL_COLOR_ATTACHMENT0: c_uint = 0x8CE0;
const GL_FRAMEBUFFER_COMPLETE: c_uint = 0x8CD5;
const GL_NO_ERROR: c_uint = 0;

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
    _ = rt;
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") == null) return;
    counter.* += 1;
    if (counter.* <= 12 or (counter.* % 300) == 0) {
        sdl_log.debug(fmt, args);
    }
}

fn traceSdlLifecycle(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") == null) return;
    sdl_log.debug(fmt, args);
}

fn shouldTraceSdlHint(name: ?[]const u8) bool {
    const value = name orelse return false;
    return std.mem.eql(u8, value, SDL_QUIT_ON_LAST_WINDOW_CLOSE_HINT);
}

fn nextTrackedSdlWindowCountAfterCreate(window: ?*sdl.SDL_Window, current: i32) i32 {
    if (window == null) return current;
    return current + 1;
}

fn nextTrackedSdlWindowCountAfterDestroy(window: ?*sdl.SDL_Window, current: i32) i32 {
    if (window == null or current <= 0) return current;
    return current - 1;
}

fn noteTrackedSdlWindowCreate(window: ?*sdl.SDL_Window) i32 {
    tracked_sdl_window_count = nextTrackedSdlWindowCountAfterCreate(window, tracked_sdl_window_count);
    return tracked_sdl_window_count;
}

fn noteTrackedSdlWindowDestroy(window: ?*sdl.SDL_Window) i32 {
    tracked_sdl_window_count = nextTrackedSdlWindowCountAfterDestroy(window, tracked_sdl_window_count);
    return tracked_sdl_window_count;
}

fn windowEventTraceName(event: sdl.Uint8) []const u8 {
    return switch (event) {
        sdl.SDL_WINDOWEVENT_ENTER => "window.enter",
        sdl.SDL_WINDOWEVENT_LEAVE => "window.leave",
        sdl.SDL_WINDOWEVENT_FOCUS_GAINED => "window.focus_gained",
        sdl.SDL_WINDOWEVENT_FOCUS_LOST => "window.focus_lost",
        sdl.SDL_WINDOWEVENT_CLOSE => "window.close",
        else => "window.other",
    };
}

fn shouldTraceSdlEvent(event: *const sdl.SDL_Event) bool {
    return switch (event.type) {
        sdl.SDL_QUIT,
        sdl.SDL_WINDOWEVENT,
        sdl.SDL_MOUSEMOTION,
        sdl.SDL_MOUSEBUTTONDOWN,
        sdl.SDL_MOUSEBUTTONUP,
        sdl.SDL_MOUSEWHEEL,
        => true,
        else => false,
    };
}

fn sdlEventTraceName(event: *const sdl.SDL_Event) []const u8 {
    return switch (event.type) {
        sdl.SDL_QUIT => "quit",
        sdl.SDL_WINDOWEVENT => windowEventTraceName(event.window.event),
        sdl.SDL_MOUSEMOTION => "mouse.motion",
        sdl.SDL_MOUSEBUTTONDOWN => "mouse.button_down",
        sdl.SDL_MOUSEBUTTONUP => "mouse.button_up",
        sdl.SDL_MOUSEWHEEL => "mouse.wheel",
        else => "other",
    };
}

fn traceSdlEvent(comptime source: []const u8, event: *const sdl.SDL_Event, suppressed: bool) void {
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") == null) return;
    if (!shouldTraceSdlEvent(event)) return;
    if (event.type == sdl.SDL_WINDOWEVENT) {
        sdl_log.debug(
            "{s} {s} type=0x{x} window_event={s}({d}) window={d} data={d},{d} suppressed={} tracked_windows={d}",
            .{
                source,
                sdlEventTraceName(event),
                event.type,
                windowEventTraceName(event.window.event),
                event.window.event,
                event.window.windowID,
                event.window.data1,
                event.window.data2,
                suppressed,
                tracked_sdl_window_count,
            },
        );
    } else if (event.type == sdl.SDL_MOUSEMOTION) {
        sdl_log.debug(
            "{s} {s} type=0x{x} window={d} which={d} pos={d},{d} rel={d},{d} buttons=0x{x} suppressed={} tracked_windows={d}",
            .{
                source,
                sdlEventTraceName(event),
                event.type,
                event.motion.windowID,
                event.motion.which,
                event.motion.x,
                event.motion.y,
                event.motion.xrel,
                event.motion.yrel,
                event.motion.state,
                suppressed,
                tracked_sdl_window_count,
            },
        );
    } else if (event.type == sdl.SDL_MOUSEBUTTONDOWN or event.type == sdl.SDL_MOUSEBUTTONUP) {
        sdl_log.debug(
            "{s} {s} type=0x{x} window={d} which={d} button={d} state={d} clicks={d} pos={d},{d} suppressed={} tracked_windows={d}",
            .{
                source,
                sdlEventTraceName(event),
                event.type,
                event.button.windowID,
                event.button.which,
                event.button.button,
                event.button.state,
                event.button.clicks,
                event.button.x,
                event.button.y,
                suppressed,
                tracked_sdl_window_count,
            },
        );
    } else if (event.type == sdl.SDL_MOUSEWHEEL) {
        sdl_log.debug(
            "{s} {s} type=0x{x} window={d} which={d} wheel={d},{d} precise={d},{d} mouse={d},{d} suppressed={} tracked_windows={d}",
            .{
                source,
                sdlEventTraceName(event),
                event.type,
                event.wheel.windowID,
                event.wheel.which,
                event.wheel.x,
                event.wheel.y,
                event.wheel.preciseX,
                event.wheel.preciseY,
                event.wheel.mouseX,
                event.wheel.mouseY,
                suppressed,
                tracked_sdl_window_count,
            },
        );
    } else {
        sdl_log.debug("{s} {s} type=0x{x} suppressed={} tracked_windows={d}", .{ source, sdlEventTraceName(event), event.type, suppressed, tracked_sdl_window_count });
    }
}

fn traceSdlEvents(comptime source: []const u8, events: [*]const sdl.SDL_Event, count: c_int) void {
    if (count <= 0) return;
    var idx: usize = 0;
    const n: usize = @intCast(count);
    while (idx < n) : (idx += 1) traceSdlEvent(source, &events[idx], false);
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
    _ = real_sdl.SDL_SetHint("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1");
}

fn shouldForwardRealRendererCall(policy: window_policy.WindowPresentationPolicy) bool {
    return policy.realRenderEnabled();
}

fn selectVulkanLoaderPath(requested: ?[*:0]const u8, override: ?[*:0]const u8) ?[*:0]const u8 {
    if (requested != null) return requested;
    return override;
}

fn selectDlopenPath(requested: ?[*:0]const u8, override: ?[*:0]const u8) ?[*:0]const u8 {
    const path = requested orelse return null;
    const loader = override orelse return requested;
    if (std.mem.eql(u8, std.mem.span(path), "libvulkan.dylib")) return loader;
    return requested;
}

fn applyRealWindowAction(action: window_policy.RealWindowAction, window: ?*sdl.SDL_Window) void {
    switch (action) {
        .none => {},
        .show => real_sdl.SDL_ShowWindow(window),
        .hide => real_sdl.SDL_HideWindow(window),
        .minimize => real_sdl.SDL_MinimizeWindow(window),
        .restore => real_sdl.SDL_RestoreWindow(window),
    }
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

fn copySurfaceToRgba(allocator: std.mem.Allocator, surface: ?*sdl.SDL_Surface) ?struct { width: i32, height: i32, rgba: []u8 } {
    const converted = real_sdl.SDL_ConvertSurfaceFormat(surface, sdl.SDL_PIXELFORMAT_ABGR8888, 0) orelse return null;
    defer real_sdl.SDL_FreeSurface(converted);

    const view: *const SurfaceTraceView = @ptrCast(@alignCast(converted));
    if (view.w <= 0 or view.h <= 0 or view.pitch < view.w * 4) return null;
    const pixels = view.pixels orelse return null;
    const row_len: usize = @as(usize, @intCast(view.w)) * 4;
    const out_len: usize = row_len * @as(usize, @intCast(view.h));
    const out = allocator.alloc(u8, out_len) catch return null;
    errdefer allocator.free(out);

    const src: [*]const u8 = @ptrCast(pixels);
    const pitch: usize = @intCast(view.pitch);
    var y: usize = 0;
    while (y < @as(usize, @intCast(view.h))) : (y += 1) {
        @memcpy(out[y * row_len ..][0..row_len], src[y * pitch ..][0..row_len]);
    }
    return .{ .width = view.w, .height = view.h, .rgba = out };
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

pub export fn ks_SDL_Init(flags: sdl.Uint32) callconv(.c) c_int {
    applyBackgroundGamepadHint();
    return real_sdl.SDL_Init(flags);
}

pub export fn ks_SDL_InitSubSystem(flags: sdl.Uint32) callconv(.c) c_int {
    applyBackgroundGamepadHint();
    return real_sdl.SDL_InitSubSystem(flags);
}

pub export fn ks_SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) sdl.SDL_bool {
    const rc = real_sdl.SDL_SetHint(name, value);
    const name_slice = std.mem.span(name);
    if (shouldTraceSdlHint(name_slice)) {
        traceSdlLifecycle("SDL_SetHint {s}={s} rc={d}", .{ name_slice, std.mem.span(value), rc });
    }
    return rc;
}

pub export fn ks_SDL_QuitSubSystem(flags: sdl.Uint32) callconv(.c) void {
    traceSdlLifecycle("SDL_QuitSubSystem flags=0x{x} video={}", .{ flags, (flags & sdl.SDL_INIT_VIDEO) != 0 });
    if ((flags & sdl.SDL_INIT_VIDEO) != 0) runtime.shutdownGlobal();
    real_sdl.SDL_QuitSubSystem(flags);
}

pub export fn ks_SDL_Quit() callconv(.c) void {
    traceSdlLifecycle("SDL_Quit called; shutting down Katzensteg runtime", .{});
    runtime.shutdownGlobal();
    real_sdl.SDL_Quit();
}

pub export fn ks_SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Window {
    const window = real_sdl.SDL_CreateWindow(title, x, y, w, h, flags);
    const tracked_windows = noteTrackedSdlWindowCreate(window);
    const rt = runtime.get();
    rt.noteInputWindowSize(w, h);
    traceLimited(rt, &trace_create_window, "SDL_CreateWindow window={x} size={d}x{d} flags=0x{x} tracked_windows={d}", .{ if (window) |p| @intFromPtr(p) else 0, w, h, flags, tracked_windows });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateWindow(rt, window, w, h),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_window = .{ .window = sdl_adapter.handleFromPtr(window), .w = w, .h = h } }),
    }
    applyRealWindowAction(rt.realWindowCreateAction(), window);
    return window;
}

pub export fn ks_SDL_GetWindowFlags(window: ?*sdl.SDL_Window) callconv(.c) sdl.Uint32 {
    const flags = real_sdl.SDL_GetWindowFlags(window);
    return sdl_input.claimedWindowFlags(runtime.get(), flags);
}

pub export fn ks_SDL_ShowWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    const action = rt.realWindowShowAction();
    traceLimited(rt, &trace_show_window, "SDL_ShowWindow window={x} action={s}", .{ if (window) |p| @intFromPtr(p) else 0, @tagName(action) });
    applyRealWindowAction(action, window);
}

pub export fn ks_SDL_HideWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    const action = rt.realWindowCreateAction();
    traceLimited(rt, &trace_hide_window, "SDL_HideWindow window={x} action={s}", .{ if (window) |p| @intFromPtr(p) else 0, @tagName(action) });
    if (action == .none) {
        real_sdl.SDL_HideWindow(window);
    } else {
        applyRealWindowAction(action, window);
    }
}

pub export fn ks_SDL_MinimizeWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    const action = rt.realWindowCreateAction();
    traceLimited(rt, &trace_minimize_window, "SDL_MinimizeWindow window={x} action={s}", .{ if (window) |p| @intFromPtr(p) else 0, @tagName(action) });
    if (action == .none) {
        real_sdl.SDL_MinimizeWindow(window);
    } else {
        applyRealWindowAction(action, window);
    }
}

pub export fn ks_SDL_RestoreWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    const action = rt.realWindowRestoreAction();
    traceLimited(rt, &trace_restore_window, "SDL_RestoreWindow window={x} action={s}", .{ if (window) |p| @intFromPtr(p) else 0, @tagName(action) });
    applyRealWindowAction(action, window);
}

pub export fn ks_SDL_RaiseWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    const action = rt.realWindowShowAction();
    traceLimited(rt, &trace_raise_window, "SDL_RaiseWindow window={x} action={s}", .{ if (window) |p| @intFromPtr(p) else 0, @tagName(action) });
    if (action == .show) {
        real_sdl.SDL_RaiseWindow(window);
    } else {
        applyRealWindowAction(action, window);
    }
}

pub export fn ks_SDL_DestroyWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const before = tracked_sdl_window_count;
    real_sdl.SDL_DestroyWindow(window);
    const after = noteTrackedSdlWindowDestroy(window);
    traceSdlLifecycle("SDL_DestroyWindow window={x} tracked_windows={d}->{d}", .{ if (window) |p| @intFromPtr(p) else 0, before, after });
}

pub export fn ks_SDL_CreateRenderer(window: ?*sdl.SDL_Window, index: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Renderer {
    const renderer = real_sdl.SDL_CreateRenderer(window, index, flags);
    const rt = runtime.get();
    traceLimited(rt, &trace_create_renderer, "SDL_CreateRenderer window={x} renderer={x} index={d} flags=0x{x}", .{ if (window) |p| @intFromPtr(p) else 0, if (renderer) |p| @intFromPtr(p) else 0, index, flags });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateRenderer(rt, window, renderer),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_renderer = .{ .window = sdl_adapter.handleFromPtr(window), .renderer = sdl_adapter.handleFromPtr(renderer) } }),
    }
    return renderer;
}

pub export fn ks_SDL_GetRendererInfo(renderer: ?*sdl.SDL_Renderer, info: ?*sdl.SDL_RendererInfo) callconv(.c) c_int {
    const rc = real_sdl.SDL_GetRendererInfo(renderer, info);
    if (rc == 0) {
        if (info) |renderer_info| {
            const before = renderer_info.num_texture_formats;
            if (!isTextureFormatFilterDisabled()) filterRendererInfoTextureFormats(renderer_info);
            if (std.c.getenv("KATZENSTEG_TRACE_SDL") != null) {
                const rt = runtime.get();
                traceLimited(rt, &trace_get_renderer_info, "SDL_GetRendererInfo renderer={x} rc={d} texture_formats={d}->{d}", .{ if (renderer) |p| @intFromPtr(p) else 0, rc, before, renderer_info.num_texture_formats });
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_DestroyRenderer(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    const rt = runtime.get();
    switch (rt.intercept_mode) {
        .sync_compose => sink.onDestroyRenderer(rt, renderer),
        .queued_replay => sink.dispatchCommand(rt, .{ .destroy_renderer = .{ .renderer = sdl_adapter.handleFromPtr(renderer) } }),
    }
    real_sdl.SDL_DestroyRenderer(renderer);
}

pub export fn ks_SDL_CreateTexture(renderer: ?*sdl.SDL_Renderer, format: sdl.Uint32, access: c_int, w: c_int, h: c_int) callconv(.c) ?*sdl.SDL_Texture {
    const texture = real_sdl.SDL_CreateTexture(renderer, format, access, w, h);
    const rt = runtime.get();
    traceLimited(rt, &trace_create_texture, "SDL_CreateTexture renderer={x} texture={x} format={d} access={d} size={d}x{d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, format, access, w, h });
    switch (rt.intercept_mode) {
        .sync_compose => sink.onCreateTexture(rt, texture, format, w, h),
        .queued_replay => sink.dispatchCommand(rt, .{ .create_texture = .{ .texture = sdl_adapter.handleFromPtr(texture), .format = sdl_adapter.pixelFormatFromSdl2(format), .w = w, .h = h } }),
    }
    return texture;
}

pub export fn ks_SDL_CreateTextureFromSurface(renderer: ?*sdl.SDL_Renderer, surface: ?*sdl.SDL_Surface) callconv(.c) ?*sdl.SDL_Texture {
    const texture = real_sdl.SDL_CreateTextureFromSurface(renderer, surface);
    const rt = runtime.get();
    if (texture) |tex| {
        switch (rt.intercept_mode) {
            .sync_compose => sink.onCreateTextureFromSurface(rt, tex, surface),
            .queued_replay => sink.enqueueCreateTextureFromSurface(rt, tex, surface),
        }
    }
    return texture;
}

pub export fn ks_SDL_DestroyTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    const rt = runtime.get();
    switch (rt.intercept_mode) {
        .sync_compose => sink.onDestroyTexture(rt, texture),
        .queued_replay => sink.dispatchCommand(rt, .{ .destroy_texture = .{ .texture = sdl_adapter.handleFromPtr(texture) } }),
    }
    real_sdl.SDL_DestroyTexture(texture);
}

pub export fn ks_SDL_UpdateTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_UpdateTexture(texture, rect, pixels, pitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_texture, "SDL_UpdateTexture texture={x} rc={d} rect={s} pitch={d} pixels={x}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", pitch, if (pixels) |p| @intFromPtr(p) else 0 });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateTexture(rt, texture, rect, pixels, pitch),
        .queued_replay => sink.enqueueUpdateTexture(rt, texture, rect, pixels, pitch),
    };
    return rc;
}

pub export fn ks_SDL_UpdateYUVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uplane: ?[*]const sdl.Uint8, upitch: c_int, vplane: ?[*]const sdl.Uint8, vpitch: c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_UpdateYUVTexture(texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_yuv_texture, "SDL_UpdateYUVTexture texture={x} rc={d} rect={s} ypitch={d} upitch={d} vpitch={d}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", ypitch, upitch, vpitch });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateYuvTexture(rt, texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch),
        .queued_replay => sink.enqueueUpdateYuvTexture(rt, texture, rect, yplane, ypitch, uplane, upitch, vplane, vpitch),
    };
    return rc;
}

pub export fn ks_SDL_UpdateNVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uvplane: ?[*]const sdl.Uint8, uvpitch: c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_UpdateNVTexture(texture, rect, yplane, ypitch, uvplane, uvpitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_update_nv_texture, "SDL_UpdateNVTexture texture={x} rc={d} rect={s} ypitch={d} uvpitch={d}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", ypitch, uvpitch });
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onUpdateNvTexture(rt, texture, rect, yplane, ypitch, uvplane, uvpitch),
        .queued_replay => sink.enqueueUpdateNvTexture(rt, texture, rect, yplane, ypitch, uvplane, uvpitch),
    };
    return rc;
}

pub export fn ks_SDL_LockTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_LockTexture(texture, rect, pixels, pitch);
    const rt = runtime.get();
    traceLimited(rt, &trace_lock_texture, "SDL_LockTexture texture={x} rc={d} rect={s} pitch={d} pixels={x}", .{ if (texture) |p| @intFromPtr(p) else 0, rc, if (rect == null) "null" else "partial", if (rc == 0) pitch.* else 0, if (rc == 0) if (pixels.*) |p| @intFromPtr(p) else 0 else 0 });
    if (rc == 0) {
        switch (rt.intercept_mode) {
            .sync_compose => sink.onLockTexture(rt, texture, rect, pixels.*, pitch.*),
            .queued_replay => rt.rememberQueuedLock(sdl_adapter.handleFromPtr(texture), sdl_adapter.rectFromSdl(rect), pixels.*, pitch.*),
        }
    }
    return rc;
}

pub export fn ks_SDL_UnlockTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_unlock_texture, "SDL_UnlockTexture texture={x}", .{if (texture) |p| @intFromPtr(p) else 0});
    switch (rt.intercept_mode) {
        .sync_compose => sink.onUnlockTexture(rt, texture),
        .queued_replay => sink.enqueueQueuedUnlockTexture(rt, texture),
    }
    real_sdl.SDL_UnlockTexture(texture);
}

pub export fn ks_SDL_SetTextureColorMod(texture: ?*sdl.SDL_Texture, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8) callconv(.c) c_int {
    const rc = real_sdl.SDL_SetTextureColorMod(texture, r, g, b);
    const rt = runtime.get();
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onSetTextureColorMod(rt, texture, r, g, b),
        .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_color_mod = .{ .texture = sdl_adapter.handleFromPtr(texture), .r = r, .g = g, .b = b } }),
    };
    return rc;
}

pub export fn ks_SDL_SetTextureAlphaMod(texture: ?*sdl.SDL_Texture, a: sdl.Uint8) callconv(.c) c_int {
    const rc = real_sdl.SDL_SetTextureAlphaMod(texture, a);
    const rt = runtime.get();
    if (rc == 0) switch (rt.intercept_mode) {
        .sync_compose => sink.onSetTextureAlphaMod(rt, texture, a),
        .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_alpha_mod = .{ .texture = sdl_adapter.handleFromPtr(texture), .a = a } }),
    };
    return rc;
}

pub export fn ks_SDL_SetTextureBlendMode(texture: ?*sdl.SDL_Texture, blendMode: c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_SetTextureBlendMode(texture, blendMode);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onSetTextureBlendMode(rt, texture, blendMode),
            .queued_replay => sink.dispatchCommand(rt, .{ .set_texture_blend_mode = .{ .texture = sdl_adapter.handleFromPtr(texture), .blend_mode = sdl_adapter.blendModeFromSdl2(blendMode) } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_SetRenderDrawColor(renderer: ?*sdl.SDL_Renderer, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8, a: sdl.Uint8) callconv(.c) c_int {
    const rc = real_sdl.SDL_SetRenderDrawColor(renderer, r, g, b, a);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onSetRenderDrawColor(rt, renderer, r, g, b, a),
            .queued_replay => sink.dispatchCommand(rt, .{ .set_render_draw_color = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .r = r, .g = g, .b = b, .a = a } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderClear(renderer: ?*sdl.SDL_Renderer) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderClear(renderer) else 0;
    if (rc == 0) {
        traceLimited(rt, &trace_render_clear, "SDL_RenderClear renderer={x}", .{if (renderer) |p| @intFromPtr(p) else 0});
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderClear(rt, renderer),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_clear = .{ .renderer = sdl_adapter.handleFromPtr(renderer) } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderCopy(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderCopy(renderer, texture, srcrect, dstrect) else 0;
    if (rc == 0) {
        traceLimited(rt, &trace_render_copy, "SDL_RenderCopy renderer={x} texture={x} src={s} dst={s}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, if (srcrect == null) "null" else "set", if (dstrect == null) "null" else "set" });
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderCopy(rt, renderer, texture, srcrect, dstrect),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_copy = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .texture = sdl_adapter.handleFromPtr(texture), .src = sdl_adapter.rectFromSdl(srcrect), .dst = sdl_adapter.rectFromSdl(dstrect) } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderCopyEx(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderCopyEx(renderer, texture, srcrect, dstrect, angle, center, flip) else 0;
    if (rc == 0) {
        traceLimited(rt, &trace_render_copy_ex, "SDL_RenderCopyEx renderer={x} texture={x} src={s} dst={s} angle={d:.2} flip={d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, if (srcrect == null) "null" else "set", if (dstrect == null) "null" else "set", angle, flip });
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderCopyEx(rt, renderer, texture, srcrect, dstrect, angle, center, flip),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_copy_ex = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .texture = sdl_adapter.handleFromPtr(texture), .src = sdl_adapter.rectFromSdl(srcrect), .dst = sdl_adapter.rectFromSdl(dstrect), .angle = angle, .center = sdl_adapter.pointFromSdl(center), .flip = flip } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderGeometryRaw(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, color: ?[*]const sdl.SDL_Color, color_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderGeometryRaw(renderer, texture, xy, xy_stride, color, color_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices) else 0;
    if (rc == 0) {
        traceLimited(rt, &trace_render_geometry_raw, "SDL_RenderGeometryRaw renderer={x} texture={x} vertices={d} indices={d} size_indices={d}", .{ if (renderer) |p| @intFromPtr(p) else 0, if (texture) |p| @intFromPtr(p) else 0, num_vertices, num_indices, size_indices });
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderGeometryRaw(rt, renderer, texture, xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices),
                .queued_replay => sink.enqueueRenderGeometryRaw(rt, renderer, texture, xy, xy_stride, uv, uv_stride, num_vertices, indices, num_indices, size_indices),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderFillRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderFillRect(renderer, rect) else 0;
    if (rc == 0) {
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderFillRect(rt, renderer, rect),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_fill_rect = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .rect = sdl_adapter.rectFromSdl(rect) } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderDrawPoint(renderer: ?*sdl.SDL_Renderer, x: c_int, y: c_int) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderDrawPoint(renderer, x, y) else 0;
    if (rc == 0) {
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderDrawPoint(rt, renderer, x, y),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_draw_point = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .x = x, .y = y } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderDrawLine(renderer: ?*sdl.SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) callconv(.c) c_int {
    const rt = runtime.get();
    const rc = if (rt.realRenderEnabled()) real_sdl.SDL_RenderDrawLine(renderer, x1, y1, x2, y2) else 0;
    if (rc == 0) {
        if (rt.terminalRenderingEnabled()) {
            switch (rt.intercept_mode) {
                .sync_compose => sink.onRenderDrawLine(rt, renderer, x1, y1, x2, y2),
                .queued_replay => sink.dispatchCommand(rt, .{ .render_draw_line = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 } }),
            }
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderSetViewport(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = real_sdl.SDL_RenderSetViewport(renderer, rect);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderSetViewport(rt, renderer, rect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_set_viewport = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .rect = sdl_adapter.rectFromSdl(rect) } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderSetClipRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = real_sdl.SDL_RenderSetClipRect(renderer, rect);
    if (rc == 0) {
        const rt = runtime.get();
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderSetClipRect(rt, renderer, rect),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_set_clip_rect = .{ .renderer = sdl_adapter.handleFromPtr(renderer), .rect = sdl_adapter.rectFromSdl(rect) } }),
        }
    }
    return rc;
}

pub export fn ks_SDL_RenderPresent(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_render_present, "SDL_RenderPresent renderer={x}", .{if (renderer) |p| @intFromPtr(p) else 0});
    if (rt.terminalRenderingEnabled()) {
        switch (rt.intercept_mode) {
            .sync_compose => sink.onRenderPresent(rt, renderer),
            .queued_replay => sink.dispatchCommand(rt, .{ .render_present = .{ .renderer = sdl_adapter.handleFromPtr(renderer) } }),
        }
    }
    if (rt.realRenderEnabled()) real_sdl.SDL_RenderPresent(renderer);
}

pub export fn ks_SDL_GL_CreateContext(window: ?*sdl.SDL_Window) callconv(.c) sdl.SDL_GLContext {
    const context = real_sdl.SDL_GL_CreateContext(window);
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_create_context, "SDL_GL_CreateContext window={x} context={x}", .{ if (window) |p| @intFromPtr(p) else 0, if (context) |p| @intFromPtr(p) else 0 });
    return context;
}

pub export fn ks_SDL_GL_MakeCurrent(window: ?*sdl.SDL_Window, context: sdl.SDL_GLContext) callconv(.c) c_int {
    const rc = real_sdl.SDL_GL_MakeCurrent(window, context);
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_make_current, "SDL_GL_MakeCurrent window={x} context={x} rc={d}", .{ if (window) |p| @intFromPtr(p) else 0, if (context) |p| @intFromPtr(p) else 0, rc });
    return rc;
}

pub export fn ks_SDL_GL_SwapWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    const rt = runtime.get();
    traceLimited(rt, &trace_gl_swap_window, "SDL_GL_SwapWindow window={x}", .{if (window) |p| @intFromPtr(p) else 0});
    const capture_mode = rt.glCaptureMode();
    if (capture_mode != .disabled and !real_gl.available()) {
        rt.logger.writeOnceScoped(.warn, .gl, "GL capture disabled because OpenGL symbols are unavailable");
    } else switch (capture_mode) {
        .disabled => {},
        .sync => captureGlFramebufferSync(rt, window),
        .pbo => captureGlFramebufferPbo(rt, window),
    }
    real_sdl.SDL_GL_SwapWindow(window);
}

pub export fn ks_SDL_Vulkan_LoadLibrary(path: ?[*:0]const u8) callconv(.c) c_int {
    const selected = selectVulkanLoaderPath(path, std.c.getenv("KATZENSTEG_VULKAN_LOADER"));
    return real_sdl.SDL_Vulkan_LoadLibrary(selected);
}

pub export fn ks_dlopen(path: ?[*:0]const u8, mode: c_int) callconv(.c) ?*anyopaque {
    const selected = selectDlopenPath(path, std.c.getenv("KATZENSTEG_VULKAN_LOADER"));
    return real_sdl.realDlopen(selected, mode);
}

fn drawableCaptureSize(rt: *runtime.Runtime, window: ?*sdl.SDL_Window) ?struct { w: c_int, h: c_int, len: usize } {
    var w: c_int = 0;
    var h: c_int = 0;
    real_sdl.SDL_GL_GetDrawableSize(window, &w, &h);
    if (w <= 0 or h <= 0) return null;
    if (!rt.shouldCaptureExternalFrame()) return null;
    return .{ .w = w, .h = h, .len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4 };
}

fn captureGlFramebufferSync(rt: *runtime.Runtime, window: ?*sdl.SDL_Window) void {
    const size = drawableCaptureSize(rt, window) orelse return;

    const buffers = rt.ensureGlCaptureBuffers(size.len) orelse return;

    var old_read_buffer: c_int = 0;
    var old_pack_alignment: c_int = 4;
    var old_pack_buffer: c_int = 0;
    real_gl.GetIntegerv(GL_READ_BUFFER, &old_read_buffer);
    real_gl.GetIntegerv(GL_PACK_ALIGNMENT, &old_pack_alignment);
    real_gl.GetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &old_pack_buffer);
    defer real_gl.ReadBuffer(@intCast(old_read_buffer));
    defer real_gl.PixelStorei(GL_PACK_ALIGNMENT, old_pack_alignment);
    defer real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, @intCast(old_pack_buffer));

    real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    real_gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
    real_gl.ReadBuffer(GL_BACK);
    real_gl.ReadPixels(0, 0, size.w, size.h, GL_RGBA, GL_UNSIGNED_BYTE, buffers.raw.ptr);
    const err = real_gl.GetError();
    if (err != GL_NO_ERROR) {
        trace_gl_capture_error += 1;
        if (trace_gl_capture_error <= 12 or (trace_gl_capture_error % 300) == 0) {
            gl_log.warn("GL capture glReadPixels failed err=0x{x} size={d}x{d}", .{ err, size.w, size.h });
        }
        return;
    }

    gl_capture.flipRgbaRows(buffers.rgba, buffers.raw, size.w, size.h);
    publishGlFramebuffer(rt, size.w, size.h, buffers.rgba);
}

fn captureGlFramebufferPbo(rt: *runtime.Runtime, window: ?*sdl.SDL_Window) void {
    const size = drawableCaptureSize(rt, window) orelse return;
    const target = rt.externalFramebufferUploadSize(size.w, size.h);
    if (!ensureGlDownscaleTarget(rt, target.w, target.h)) return;
    const target_len = @as(usize, @intCast(target.w)) * @as(usize, @intCast(target.h)) * 4;
    const buffers = rt.ensureGlCaptureBuffers(target_len) orelse return;
    if (!ensureGlPboState(rt, target_len)) return;
    const state = &rt.gl_capture_pbo;

    var old_read_buffer: c_int = 0;
    var old_pack_alignment: c_int = 4;
    var old_pack_buffer: c_int = 0;
    var old_framebuffer: c_int = 0;
    var old_read_framebuffer: c_int = 0;
    var old_draw_framebuffer: c_int = 0;
    real_gl.GetIntegerv(GL_READ_BUFFER, &old_read_buffer);
    real_gl.GetIntegerv(GL_PACK_ALIGNMENT, &old_pack_alignment);
    real_gl.GetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &old_pack_buffer);
    real_gl.GetIntegerv(GL_FRAMEBUFFER_BINDING, &old_framebuffer);
    real_gl.GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &old_read_framebuffer);
    real_gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &old_draw_framebuffer);
    defer real_gl.ReadBuffer(@intCast(old_read_buffer));
    defer real_gl.PixelStorei(GL_PACK_ALIGNMENT, old_pack_alignment);
    defer real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, @intCast(old_pack_buffer));
    defer real_gl.BindFramebuffer(GL_FRAMEBUFFER, @intCast(old_framebuffer));
    defer real_gl.BindFramebuffer(GL_READ_FRAMEBUFFER, @intCast(old_read_framebuffer));
    defer real_gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, @intCast(old_draw_framebuffer));

    real_gl.BindFramebuffer(GL_READ_FRAMEBUFFER, @intCast(old_framebuffer));
    real_gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, rt.gl_capture_downscale.fbo);
    real_gl.BlitFramebuffer(0, 0, size.w, size.h, 0, 0, target.w, target.h, GL_COLOR_BUFFER_BIT, GL_LINEAR);
    const blit_err = real_gl.GetError();
    if (blit_err != GL_NO_ERROR) {
        trace_gl_capture_error += 1;
        if (trace_gl_capture_error <= 12 or (trace_gl_capture_error % 300) == 0) {
            gl_log.warn("GL FBO downscale blit failed err=0x{x} source={d}x{d} target={d}x{d}", .{ blit_err, size.w, size.h, target.w, target.h });
        }
        return;
    }

    real_gl.BindFramebuffer(GL_READ_FRAMEBUFFER, rt.gl_capture_downscale.fbo);
    const read_index = state.index;
    const map_index = (state.index + 1) % state.ids.len;
    real_gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
    real_gl.ReadBuffer(GL_COLOR_ATTACHMENT0);
    real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, state.ids[read_index]);
    real_gl.ReadPixels(0, 0, target.w, target.h, GL_RGBA, GL_UNSIGNED_BYTE, null);
    const read_err = real_gl.GetError();
    if (read_err != GL_NO_ERROR) {
        trace_gl_capture_error += 1;
        if (trace_gl_capture_error <= 12 or (trace_gl_capture_error % 300) == 0) {
            gl_log.warn("GL PBO glReadPixels failed err=0x{x} size={d}x{d}", .{ read_err, target.w, target.h });
        }
        return;
    }

    if (state.primed) {
        real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, state.ids[map_index]);
        if (real_gl.MapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY)) |mapped| {
            const mapped_bytes = @as([*]const u8, @ptrCast(mapped))[0..target_len];
            gl_capture.flipRgbaRows(buffers.rgba, mapped_bytes, target.w, target.h);
            if (real_gl.UnmapBuffer(GL_PIXEL_PACK_BUFFER) == 0) {
                gl_log.warn("GL PBO unmap reported data invalid", .{});
            } else {
                publishGlFramebuffer(rt, target.w, target.h, buffers.rgba);
            }
        } else {
            const map_err = real_gl.GetError();
            trace_gl_capture_error += 1;
            if (trace_gl_capture_error <= 12 or (trace_gl_capture_error % 300) == 0) {
                gl_log.warn("GL PBO map failed err=0x{x} size={d}", .{ map_err, target_len });
            }
        }
    } else {
        state.primed = true;
    }
    state.index = map_index;
}

fn publishGlFramebuffer(rt: *runtime.Runtime, width: i32, height: i32, rgba: []const u8) void {
    publishExternalFramebuffer(rt, width, height, .rgba8, rgba);
}

fn publishExternalFramebuffer(rt: *runtime.Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
    switch (rt.intercept_mode) {
        .sync_compose => sink.onExternalFramebufferPresent(rt, width, height, format, pixels),
        .queued_replay => sink.enqueueExternalFramebufferPresent(rt, width, height, format, pixels),
    }
}

fn ensureGlDownscaleTarget(rt: *runtime.Runtime, w: i32, h: i32) bool {
    const state = &rt.gl_capture_downscale;
    if (state.fbo != 0 and state.texture != 0 and state.w == w and state.h == h) return true;

    if (state.fbo != 0) real_gl.DeleteFramebuffers(1, &state.fbo);
    if (state.texture != 0) real_gl.DeleteTextures(1, &state.texture);
    state.reset();

    real_gl.GenFramebuffers(1, &state.fbo);
    real_gl.GenTextures(1, &state.texture);
    if (state.fbo == 0 or state.texture == 0) {
        gl_log.warn("GL FBO downscale allocation returned id 0", .{});
        state.reset();
        return false;
    }

    var old_texture: c_int = 0;
    var old_framebuffer: c_int = 0;
    real_gl.GetIntegerv(GL_FRAMEBUFFER_BINDING, &old_framebuffer);
    real_gl.GetIntegerv(0x8069, &old_texture);
    defer real_gl.BindFramebuffer(GL_FRAMEBUFFER, @intCast(old_framebuffer));
    defer real_gl.BindTexture(GL_TEXTURE_2D, @intCast(old_texture));

    real_gl.BindTexture(GL_TEXTURE_2D, state.texture);
    real_gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, @intCast(GL_LINEAR));
    real_gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, @intCast(GL_LINEAR));
    real_gl.TexImage2D(GL_TEXTURE_2D, 0, @intCast(GL_RGBA), w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
    real_gl.BindFramebuffer(GL_FRAMEBUFFER, state.fbo);
    real_gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, state.texture, 0);
    const status = real_gl.CheckFramebufferStatus(GL_FRAMEBUFFER);
    const err = real_gl.GetError();
    if (status != GL_FRAMEBUFFER_COMPLETE or err != GL_NO_ERROR) {
        gl_log.warn("GL FBO downscale setup failed status=0x{x} err=0x{x} size={d}x{d}", .{ status, err, w, h });
        real_gl.DeleteFramebuffers(1, &state.fbo);
        real_gl.DeleteTextures(1, &state.texture);
        state.reset();
        return false;
    }
    state.w = w;
    state.h = h;
    rt.gl_capture_pbo.reset();
    traceLimited(rt, &trace_gl_downscale_target, "GL downscale target fbo={d} texture={d} size={d}x{d}", .{ state.fbo, state.texture, w, h });
    return true;
}

fn ensureGlPboState(rt: *runtime.Runtime, len: usize) bool {
    const state = &rt.gl_capture_pbo;
    if (state.len == len and state.ids[0] != 0 and state.ids[1] != 0) return true;

    if (state.ids[0] != 0 or state.ids[1] != 0) {
        real_gl.DeleteBuffers(2, &state.ids[0]);
        state.reset();
    }

    real_gl.GenBuffers(2, &state.ids[0]);
    var i: usize = 0;
    while (i < state.ids.len) : (i += 1) {
        if (state.ids[i] == 0) {
            gl_log.warn("GL PBO allocation returned id 0", .{});
            state.reset();
            return false;
        }
        real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, state.ids[i]);
        real_gl.BufferData(GL_PIXEL_PACK_BUFFER, @intCast(len), null, GL_STREAM_READ);
    }
    real_gl.BindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    const err = real_gl.GetError();
    if (err != GL_NO_ERROR) {
        gl_log.warn("GL PBO setup failed err=0x{x} len={d}", .{ err, len });
        real_gl.DeleteBuffers(2, &state.ids[0]);
        state.reset();
        return false;
    }
    state.len = len;
    state.index = 0;
    state.primed = false;
    return true;
}

pub export fn ks_SDL_PollEvent(event: ?*sdl.SDL_Event) callconv(.c) c_int {
    const rt = runtime.get();
    rt.pollTerminalInput();
    if (realMouseFocused()) {
        rt.claimRealWindowMouse();
    } else if (sdl_input.popInputEvent(rt, event)) {
        if (event) |out| traceSdlEvent("SDL_PollEvent synthetic", out, false);
        return 1;
    }
    const out = event orelse return real_sdl.SDL_PollEvent(event);
    while (true) {
        const rc = real_sdl.SDL_PollEvent(out);
        if (rc == 0) return 0;
        if (sdl_input.shouldSuppressEvent(rt, out)) {
            traceSdlEvent("SDL_PollEvent suppressed", out, true);
            continue;
        }
        traceSdlEvent("SDL_PollEvent delivered", out, false);
        sdl_input.noteRealEvent(rt, out);
        return rc;
    }
}

pub export fn ks_SDL_PumpEvents() callconv(.c) void {
    const rt = runtime.get();
    rt.pollTerminalInput();
    real_sdl.SDL_PumpEvents();
}

pub export fn ks_SDL_PeepEvents(events: ?[*]sdl.SDL_Event, numevents: c_int, action: c_int, minType: sdl.Uint32, maxType: sdl.Uint32) callconv(.c) c_int {
    const rt = runtime.get();
    rt.pollTerminalInput();

    if (action != sdl.SDL_GETEVENT or numevents <= 0) {
        const rc = real_sdl.SDL_PeepEvents(events, numevents, action, minType, maxType);
        if (events) |out| traceSdlEvents("SDL_PeepEvents observed", out, rc);
        return rc;
    }

    const out = events orelse return real_sdl.SDL_PeepEvents(events, numevents, action, minType, maxType);
    var emitted: c_int = 0;
    while (emitted < numevents) : (emitted += 1) {
        const idx: usize = @intCast(emitted);
        if (!sdl_input.popInputEventInRange(rt, &out[idx], minType, maxType)) break;
        traceSdlEvent("SDL_PeepEvents synthetic", &out[idx], false);
    }

    if (emitted == numevents) return emitted;
    const rest_ptr = out + @as(usize, @intCast(emitted));
    const real_rc = real_sdl.SDL_PeepEvents(rest_ptr, numevents - emitted, action, minType, maxType);
    if (real_rc < 0) return if (emitted > 0) emitted else real_rc;
    traceSdlEvents("SDL_PeepEvents delivered", rest_ptr, real_rc);
    var real_index: c_int = 0;
    while (real_index < real_rc) : (real_index += 1) {
        sdl_input.noteRealEvent(rt, &rest_ptr[@intCast(real_index)]);
    }
    return emitted + real_rc;
}

pub export fn ks_SDL_GetKeyboardState(numkeys: ?*c_int) callconv(.c) ?[*]const sdl.Uint8 {
    var real_count: c_int = 0;
    const real_state = real_sdl.SDL_GetKeyboardState(&real_count);
    const rt = runtime.get();
    rt.pollTerminalInput();
    return sdl_input.mergedKeyboardState(rt, real_state, real_count, numkeys);
}

pub export fn ks_SDL_GetMouseState(x: ?*c_int, y: ?*c_int) callconv(.c) sdl.Uint32 {
    const rt = runtime.get();
    rt.pollTerminalInput();
    if (realMouseFocused()) {
        rt.claimRealWindowMouse();
        var real_x: c_int = 0;
        var real_y: c_int = 0;
        const out_x = x orelse &real_x;
        const out_y = y orelse &real_y;
        const buttons = real_sdl.SDL_GetMouseState(out_x, out_y);
        rt.dispatchCursorPosition(.{ .x = out_x.*, .y = out_y.* });
        traceLimited(rt, &trace_get_mouse_state, "SDL_GetMouseState real pos={d},{d} buttons=0x{x}", .{ out_x.*, out_y.*, buttons });
        return buttons;
    }
    if (rt.terminalMouseState()) |state| {
        if (x) |out_x| out_x.* = state.x;
        if (y) |out_y| out_y.* = state.y;
        rt.dispatchCursorPosition(.{ .x = state.x, .y = state.y });
        traceLimited(rt, &trace_get_mouse_state, "SDL_GetMouseState terminal pos={d},{d} buttons=0x{x}", .{ state.x, state.y, state.buttons });
        return state.buttons;
    }
    const buttons = real_sdl.SDL_GetMouseState(x, y);
    if (buttons != 0) rt.claimRealWindowMouse();
    traceLimited(rt, &trace_get_mouse_state, "SDL_GetMouseState fallback buttons=0x{x}", .{buttons});
    return buttons;
}

pub export fn ks_SDL_GetRelativeMouseState(x: ?*c_int, y: ?*c_int) callconv(.c) sdl.Uint32 {
    const rt = runtime.get();
    rt.pollTerminalInput();
    if (realMouseFocused()) {
        rt.claimRealWindowMouse();
        return real_sdl.SDL_GetRelativeMouseState(x, y);
    }
    if (rt.terminalRelativeMouseState()) |state| {
        if (x) |out_x| out_x.* = state.xrel;
        if (y) |out_y| out_y.* = state.yrel;
        return state.buttons;
    }
    const buttons = real_sdl.SDL_GetRelativeMouseState(x, y);
    const xrel = if (x) |out_x| out_x.* else 0;
    const yrel = if (y) |out_y| out_y.* else 0;
    if (buttons != 0 or xrel != 0 or yrel != 0) rt.claimRealWindowMouse();
    return buttons;
}

fn realMouseFocused() bool {
    return real_sdl.SDL_GetMouseFocus() != null;
}

pub export fn ks_SDL_UpperBlit(src: ?*sdl.SDL_Surface, srcrect: ?*const sdl.SDL_Rect, dst: ?*sdl.SDL_Surface, dstrect: ?*sdl.SDL_Rect) callconv(.c) c_int {
    const return_addr = @returnAddress();
    const rc = real_sdl.SDL_UpperBlit(src, srcrect, dst, dstrect);
    if (std.c.getenv("KATZENSTEG_TRACE_SDL") != null) {
        trace_upper_blit += 1;
        if (rc != 0 or trace_upper_blit <= 20 or (trace_upper_blit % 300) == 0) {
            const ss = surfaceSummary(src);
            const ds = surfaceSummary(dst);
            const caller = callerSummary(return_addr);
            sdl_log.debug(
                "SDL_UpperBlit rc={d} caller={s}+0x{x} image={s} src={x} {d}x{d} pitch={d} pixels={x} srcrect={s} dst={x} {d}x{d} pitch={d} pixels={x} dstrect={s} err={s}",
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
                    std.mem.span(real_sdl.SDL_GetError()),
                },
            );
        }
    }
    return rc;
}

pub export fn ks_SDL_CreateColorCursor(surface: ?*sdl.SDL_Surface, hot_x: c_int, hot_y: c_int) callconv(.c) ?*sdl.SDL_Cursor {
    const cursor = real_sdl.SDL_CreateColorCursor(surface, hot_x, hot_y);
    const handle = if (cursor) |p| @intFromPtr(p) else 0;
    if (handle != 0) {
        const rt = runtime.get();
        if (copySurfaceToRgba(rt.allocator, surface)) |image| {
            defer rt.allocator.free(image.rgba);
            sink.dispatchCommand(rt, .{ .create_color_cursor = .{
                .cursor = handle,
                .width = image.width,
                .height = image.height,
                .hot_x = hot_x,
                .hot_y = hot_y,
                .rgba = image.rgba,
            } });
            traceSdlLifecycle("SDL_CreateColorCursor cursor={x} surface={x} {d}x{d} hot={d},{d}", .{ handle, if (surface) |s| @intFromPtr(s) else 0, image.width, image.height, hot_x, hot_y });
        }
    }
    return cursor;
}

pub export fn ks_SDL_SetCursor(cursor: ?*sdl.SDL_Cursor) callconv(.c) void {
    real_sdl.SDL_SetCursor(cursor);
    const rt = runtime.get();
    const handle = if (cursor) |p| @intFromPtr(p) else 0;
    sink.dispatchCommand(rt, .{ .set_cursor = .{ .cursor = handle } });
    traceSdlLifecycle("SDL_SetCursor cursor={x}", .{handle});
}

pub export fn ks_SDL_ShowCursor(toggle: c_int) callconv(.c) c_int {
    const rc = real_sdl.SDL_ShowCursor(toggle);
    if (rc >= 0 and toggle != sdl.SDL_QUERY) {
        const rt = runtime.get();
        sink.dispatchCommand(rt, .{ .show_cursor = .{ .visible = toggle == sdl.SDL_ENABLE } });
    }
    traceSdlLifecycle("SDL_ShowCursor toggle={d} rc={d}", .{ toggle, rc });
    return rc;
}

pub export fn ks_SDL_FreeCursor(cursor: ?*sdl.SDL_Cursor) callconv(.c) void {
    const rt = runtime.get();
    const handle = if (cursor) |p| @intFromPtr(p) else 0;
    sink.dispatchCommand(rt, .{ .free_cursor = .{ .cursor = handle } });
    real_sdl.SDL_FreeCursor(cursor);
    traceSdlLifecycle("SDL_FreeCursor cursor={x}", .{handle});
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

test "window policy controls forwarding real renderer calls" {
    try std.testing.expect(shouldForwardRealRendererCall(.mirror));
    try std.testing.expect(!shouldForwardRealRendererCall(.terminal_only));
    try std.testing.expect(shouldForwardRealRendererCall(.real_only));
}

test "Vulkan loader override only replaces SDL default lookup" {
    const explicit = "/tmp/custom-vulkan.dylib";
    const override = "/opt/homebrew/lib/libvulkan.1.dylib";

    try std.testing.expectEqualStrings(override, std.mem.span(selectVulkanLoaderPath(null, override.ptr).?));
    try std.testing.expectEqualStrings(explicit, std.mem.span(selectVulkanLoaderPath(explicit.ptr, override.ptr).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), selectVulkanLoaderPath(null, null));
}

test "Vulkan loader override replaces RetroArch bare dlopen lookup only" {
    const override = "/opt/homebrew/lib/libvulkan.1.dylib";
    const bare = "libvulkan.dylib";
    const versioned = "libvulkan.1.dylib";
    const unrelated = "libSDL2.dylib";

    try std.testing.expectEqualStrings(override, std.mem.span(selectDlopenPath(bare.ptr, override.ptr).?));
    try std.testing.expectEqualStrings(versioned, std.mem.span(selectDlopenPath(versioned.ptr, override.ptr).?));
    try std.testing.expectEqualStrings(unrelated, std.mem.span(selectDlopenPath(unrelated.ptr, override.ptr).?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), selectDlopenPath(null, override.ptr));
}

test "SDL exit trace helpers name quit and claimed-window events" {
    var quit_event: sdl.SDL_Event = undefined;
    quit_event.type = sdl.SDL_QUIT;
    try std.testing.expect(shouldTraceSdlEvent(&quit_event));
    try std.testing.expectEqualStrings("quit", sdlEventTraceName(&quit_event));

    var close_event: sdl.SDL_Event = undefined;
    close_event.window = .{
        .type = sdl.SDL_WINDOWEVENT,
        .timestamp = 0,
        .windowID = 7,
        .event = sdl.SDL_WINDOWEVENT_CLOSE,
        .data1 = 0,
        .data2 = 0,
    };
    try std.testing.expect(shouldTraceSdlEvent(&close_event));
    try std.testing.expectEqualStrings("window.close", sdlEventTraceName(&close_event));

    var key_event: sdl.SDL_Event = undefined;
    key_event.type = sdl.SDL_KEYDOWN;
    try std.testing.expect(!shouldTraceSdlEvent(&key_event));
}

test "SDL close diagnostics identify quit-on-last-window hint" {
    try std.testing.expect(shouldTraceSdlHint("SDL_QUIT_ON_LAST_WINDOW_CLOSE"));
    try std.testing.expect(!shouldTraceSdlHint("SDL_RENDER_VSYNC"));
    try std.testing.expect(!shouldTraceSdlHint(null));
}

test "SDL close diagnostics track successful window creates and destroys" {
    try std.testing.expectEqual(@as(i32, 2), nextTrackedSdlWindowCountAfterCreate(@ptrFromInt(0x1000), 1));
    try std.testing.expectEqual(@as(i32, 1), nextTrackedSdlWindowCountAfterCreate(null, 1));
    try std.testing.expectEqual(@as(i32, 1), nextTrackedSdlWindowCountAfterDestroy(@ptrFromInt(0x1000), 2));
    try std.testing.expectEqual(@as(i32, 0), nextTrackedSdlWindowCountAfterDestroy(@ptrFromInt(0x1000), 0));
    try std.testing.expectEqual(@as(i32, 2), nextTrackedSdlWindowCountAfterDestroy(null, 2));
}
