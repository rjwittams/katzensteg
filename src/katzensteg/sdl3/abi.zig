// Staging area for a future SDL3 module split. The active production SDL3 path
// is still the flat sdl3.zig / real_sdl3.zig / sdl3_input_adapter.zig set;
// Python symbol checks read this file, but it is not compiled by build.zig yet.
const std = @import("std");

pub const Sint32 = i32;
pub const Uint8 = u8;
pub const Uint32 = u32;
pub const SDL_bool = c_int;

pub const SDL_Window = opaque {};
pub const SDL_Renderer = opaque {};
pub const SDL_Texture = opaque {};
pub const SDL_Surface = opaque {};
pub const SDL_Cursor = opaque {};
pub const SDL_GLContext = ?*anyopaque;

pub const SDL_Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub const SDL_Point = extern struct {
    x: c_int,
    y: c_int,
};

pub const SDL_RendererInfo = extern struct {
    name: ?[*:0]const u8,
    flags: Uint32,
    num_texture_formats: Uint32,
    texture_formats: [16]Uint32,
    max_texture_width: c_int,
    max_texture_height: c_int,
};

pub const SDL_Color = extern struct {
    r: Uint8,
    g: Uint8,
    b: Uint8,
    a: Uint8,
};

pub const SDL_Keysym = extern struct {
    scancode: c_int,
    sym: c_int,
    mod: u16,
    unused: Uint32,
};

pub const SDL_KeyboardEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    state: Uint8,
    repeat: Uint8,
    padding2: Uint8 = 0,
    padding3: Uint8 = 0,
    keysym: SDL_Keysym,
};

pub const SDL_TextInputEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    text: [32]u8,
};

pub const SDL_WindowEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    event: Uint8,
    padding1: Uint8 = 0,
    padding2: Uint8 = 0,
    padding3: Uint8 = 0,
    data1: Sint32,
    data2: Sint32,
};

pub const SDL_MouseMotionEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    which: Uint32,
    state: Uint32,
    x: Sint32,
    y: Sint32,
    xrel: Sint32,
    yrel: Sint32,
};

pub const SDL_MouseButtonEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    which: Uint32,
    button: Uint8,
    state: Uint8,
    clicks: Uint8,
    padding1: Uint8 = 0,
    x: Sint32,
    y: Sint32,
};

pub const SDL_MouseWheelEvent = extern struct {
    type: Uint32,
    timestamp: Uint32,
    windowID: Uint32,
    which: Uint32,
    x: Sint32,
    y: Sint32,
    direction: Uint32,
    preciseX: f32,
    preciseY: f32,
    mouseX: Sint32,
    mouseY: Sint32,
};

pub const SDL_Event = extern union {
    type: Uint32,
    window: SDL_WindowEvent,
    key: SDL_KeyboardEvent,
    text: SDL_TextInputEvent,
    motion: SDL_MouseMotionEvent,
    button: SDL_MouseButtonEvent,
    wheel: SDL_MouseWheelEvent,
    padding: [56]Uint8,
};

pub const SDL_WindowFlags = enum(Uint32) {
    shown = 0x00000004,
};

pub const SDL_RendererFlags = enum(Uint32) {
    accelerated = 0x00000002,
    presentvsync = 0x00000004,
};

pub const SDL_PIXELFORMAT_RGB565: Uint32 = 353701890;
pub const SDL_PIXELFORMAT_RGBA4444: Uint32 = 356651010;
pub const SDL_PIXELFORMAT_XRGB8888: Uint32 = 370546692;
pub const SDL_PIXELFORMAT_ARGB8888: Uint32 = 372645892;
pub const SDL_PIXELFORMAT_ABGR8888: Uint32 = 376840196;
pub const SDL_PIXELFORMAT_YV12: Uint32 = 842094169;
pub const SDL_PIXELFORMAT_IYUV: Uint32 = 1448433993;
pub const SDL_PIXELFORMAT_NV12: Uint32 = 842094158;
pub const SDL_PIXELFORMAT_NV21: Uint32 = 825382478;
pub const SDL_TEXTUREACCESS_STATIC: c_int = 0;
pub const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
pub const SDL_BLENDMODE_NONE: c_int = 0x00000000;
pub const SDL_BLENDMODE_BLEND: c_int = 0x00000001;
pub const SDL_BLENDMODE_ADD: c_int = 0x00000002;
pub const SDL_BLENDMODE_MOD: c_int = 0x00000004;
pub const SDL_BLENDMODE_MUL: c_int = 0x00000008;
pub const SDL_FLIP_NONE: c_int = 0x00000000;
pub const SDL_RELEASED: Uint8 = 0;
pub const SDL_PRESSED: Uint8 = 1;
pub const SDL_QUIT: Uint32 = 0x100;
pub const SDL_KEYDOWN: Uint32 = 0x300;
pub const SDL_KEYUP: Uint32 = 0x301;
pub const SDL_TEXTINPUT: Uint32 = 0x303;
pub const SDL_MOUSEMOTION: Uint32 = 0x400;
pub const SDL_MOUSEBUTTONDOWN: Uint32 = 0x401;
pub const SDL_MOUSEBUTTONUP: Uint32 = 0x402;
pub const SDL_MOUSEWHEEL: Uint32 = 0x403;
pub const SDL_MOUSEWHEEL_NORMAL: Uint32 = 0;
pub const SDL_NUM_SCANCODES: usize = 512;
pub const SDL_WINDOWEVENT: Uint32 = 0x200;
pub const SDL_WINDOWEVENT_RESIZED: Uint8 = 5;
pub const SDL_WINDOWEVENT_SIZE_CHANGED: Uint8 = 6;
pub const SDL_WINDOWEVENT_ENTER: Uint8 = 10;
pub const SDL_WINDOWEVENT_LEAVE: Uint8 = 11;
pub const SDL_WINDOWEVENT_FOCUS_GAINED: Uint8 = 12;
pub const SDL_WINDOWEVENT_FOCUS_LOST: Uint8 = 13;
pub const SDL_WINDOWEVENT_CLOSE: Uint8 = 14;
pub const SDL_WINDOW_INPUT_FOCUS: Uint32 = 0x00000200;
pub const SDL_WINDOW_MOUSE_FOCUS: Uint32 = 0x00000400;
pub const SDL_DISABLE: c_int = 0;
pub const SDL_ENABLE: c_int = 1;
pub const SDL_QUERY: c_int = -1;

pub extern fn SDL_Init(flags: Uint32) c_int;
pub extern fn SDL_InitSubSystem(flags: Uint32) c_int;
pub extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) SDL_bool;
pub extern fn SDL_QuitSubSystem(flags: Uint32) void;
pub extern fn SDL_Quit() void;
pub extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: Uint32) ?*SDL_Window;
pub extern fn SDL_GetWindowID(window: ?*SDL_Window) Uint32;
pub extern fn SDL_GetWindowFlags(window: ?*SDL_Window) Uint32;
pub extern fn SDL_SetWindowSize(window: ?*SDL_Window, w: c_int, h: c_int) void;
pub extern fn SDL_ShowWindow(window: ?*SDL_Window) void;
pub extern fn SDL_HideWindow(window: ?*SDL_Window) void;
pub extern fn SDL_MinimizeWindow(window: ?*SDL_Window) void;
pub extern fn SDL_RestoreWindow(window: ?*SDL_Window) void;
pub extern fn SDL_RaiseWindow(window: ?*SDL_Window) void;
pub extern fn SDL_DestroyWindow(window: ?*SDL_Window) void;
pub extern fn SDL_CreateRenderer(window: ?*SDL_Window, index: c_int, flags: Uint32) ?*SDL_Renderer;
pub extern fn SDL_GetRendererInfo(renderer: ?*SDL_Renderer, info: ?*SDL_RendererInfo) c_int;
pub extern fn SDL_DestroyRenderer(renderer: ?*SDL_Renderer) void;
pub extern fn SDL_CreateTexture(renderer: ?*SDL_Renderer, format: Uint32, access: c_int, w: c_int, h: c_int) ?*SDL_Texture;
pub extern fn SDL_CreateTextureFromSurface(renderer: ?*SDL_Renderer, surface: ?*SDL_Surface) ?*SDL_Texture;
pub extern fn SDL_DestroyTexture(texture: ?*SDL_Texture) void;
pub extern fn SDL_UpdateTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) c_int;
pub extern fn SDL_UpdateYUVTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, yplane: ?[*]const Uint8, ypitch: c_int, uplane: ?[*]const Uint8, upitch: c_int, vplane: ?[*]const Uint8, vpitch: c_int) c_int;
pub extern fn SDL_UpdateNVTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, yplane: ?[*]const Uint8, ypitch: c_int, uvplane: ?[*]const Uint8, uvpitch: c_int) c_int;
pub extern fn SDL_LockTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) c_int;
pub extern fn SDL_UnlockTexture(texture: ?*SDL_Texture) void;
pub extern fn SDL_CreateSurfaceFrom(width: c_int, height: c_int, format: Uint32, pixels: ?*anyopaque, pitch: c_int) ?*SDL_Surface;
pub extern fn SDL_ConvertSurface(surface: ?*SDL_Surface, pixel_format: Uint32) ?*SDL_Surface;
pub extern fn SDL_DestroySurface(surface: ?*SDL_Surface) void;
pub extern fn SDL_UpperBlit(src: ?*SDL_Surface, srcrect: ?*const SDL_Rect, dst: ?*SDL_Surface, dstrect: ?*SDL_Rect) c_int;
pub extern fn SDL_CreateColorCursor(surface: ?*SDL_Surface, hot_x: c_int, hot_y: c_int) ?*SDL_Cursor;
pub extern fn SDL_SetCursor(cursor: ?*SDL_Cursor) void;
pub extern fn SDL_ShowCursor(toggle: c_int) c_int;
pub extern fn SDL_FreeCursor(cursor: ?*SDL_Cursor) void;
pub extern fn SDL_SetRenderDrawColor(renderer: ?*SDL_Renderer, r: Uint8, g: Uint8, b: Uint8, a: Uint8) c_int;
pub extern fn SDL_SetTextureColorMod(texture: ?*SDL_Texture, r: Uint8, g: Uint8, b: Uint8) c_int;
pub extern fn SDL_SetTextureAlphaMod(texture: ?*SDL_Texture, a: Uint8) c_int;
pub extern fn SDL_SetTextureBlendMode(texture: ?*SDL_Texture, blendMode: c_int) c_int;
pub extern fn SDL_RenderClear(renderer: ?*SDL_Renderer) c_int;
pub extern fn SDL_RenderCopy(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, srcrect: ?*const SDL_Rect, dstrect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderCopyEx(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, srcrect: ?*const SDL_Rect, dstrect: ?*const SDL_Rect, angle: f64, center: ?*const SDL_Point, flip: c_int) c_int;
pub extern fn SDL_RenderGeometryRaw(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, color: ?[*]const SDL_Color, color_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) c_int;
pub extern fn SDL_RenderPresent(renderer: ?*SDL_Renderer) void;
pub extern fn SDL_QueryTexture(texture: ?*SDL_Texture, format: ?*Uint32, access: ?*c_int, w: ?*c_int, h: ?*c_int) c_int;
pub extern fn SDL_RenderFillRect(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderDrawPoint(renderer: ?*SDL_Renderer, x: c_int, y: c_int) c_int;
pub extern fn SDL_RenderDrawLine(renderer: ?*SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) c_int;
pub extern fn SDL_RenderSetViewport(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderSetClipRect(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderGetViewport(renderer: ?*SDL_Renderer, rect: *SDL_Rect) void;
pub extern fn SDL_GL_CreateContext(window: ?*SDL_Window) SDL_GLContext;
pub extern fn SDL_GL_MakeCurrent(window: ?*SDL_Window, context: SDL_GLContext) c_int;
pub extern fn SDL_GetWindowSizeInPixels(window: ?*SDL_Window, w: *c_int, h: *c_int) SDL_bool;
pub extern fn SDL_GL_SwapWindow(window: ?*SDL_Window) void;
pub extern fn SDL_Vulkan_LoadLibrary(path: ?[*:0]const u8) c_int;
pub extern fn SDL_PumpEvents() void;
pub extern fn SDL_PollEvent(event: ?*SDL_Event) c_int;
pub extern fn SDL_PeepEvents(events: ?[*]SDL_Event, numevents: c_int, action: c_int, minType: Uint32, maxType: Uint32) c_int;
pub extern fn SDL_StartTextInput() void;
pub extern fn SDL_StopTextInput() void;
pub extern fn SDL_GetKeyboardState(numkeys: ?*c_int) ?[*]const Uint8;
pub extern fn SDL_GetMouseFocus() ?*SDL_Window;
pub extern fn SDL_GetMouseState(x: ?*c_int, y: ?*c_int) Uint32;
pub extern fn SDL_GetRelativeMouseState(x: ?*c_int, y: ?*c_int) Uint32;
pub extern fn SDL_Delay(ms: Uint32) void;
pub extern fn SDL_GetTicks() Uint64;
pub extern fn SDL_GetError() [*:0]const u8;

pub const SDL_INIT_VIDEO: Uint32 = 0x00000020;
pub const SDL_INIT_JOYSTICK: Uint32 = 0x00000200;
pub const SDL_INIT_GAMECONTROLLER: Uint32 = 0x00002000;
pub const SDL_INIT_EVENTS: Uint32 = 0x00004000;
pub const SDL_ADDEVENT: c_int = 0;
pub const SDL_PEEKEVENT: c_int = 1;
pub const SDL_GETEVENT: c_int = 2;
pub const SDL_WINDOWPOS_CENTERED_MASK: Uint32 = 0x2FFF0000;
pub const SDL_WINDOWPOS_CENTERED: c_int = @bitCast(SDL_WINDOWPOS_CENTERED_MASK);

pub fn SDL_CreateRGBSurfaceWithFormatFrom(
    pixels: ?*anyopaque,
    width: c_int,
    height: c_int,
    depth: c_int,
    pitch: c_int,
    format: Uint32,
) ?*SDL_Surface {
    _ = depth;
    return SDL_CreateSurfaceFrom(width, height, format, pixels, pitch);
}

pub fn SDL_FreeSurface(surface: ?*SDL_Surface) void {
    SDL_DestroySurface(surface);
}

pub fn sdlError() []const u8 {
    return std.mem.span(SDL_GetError());
}

test "SDL_Event binding matches SDL2 ABI size" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(SDL_Event));
}
