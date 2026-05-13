// SDL3 frontend plumbing currently reuses the SDL2 ABI surface while SDL3
// symbol/signature divergence is implemented incrementally.
const std = @import("std");

pub const Sint32 = i32;
pub const Sint64 = i64;
pub const Uint8 = u8;
pub const Uint32 = u32;
pub const Uint64 = u64;
pub const SDL_bool = bool;
pub const SDL_PropertiesID = Uint32;
pub const SDL_Keymod = u16;

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

pub const SDL_FPoint = extern struct {
    x: f32,
    y: f32,
};

pub const SDL_FRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
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

pub const SDL_FColor = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const SDL_Keysym = extern struct {
    scancode: c_int,
    sym: c_int,
    mod: u16,
    unused: Uint32,
};

pub const SDL_KeyboardEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    which: Uint32,
    scancode: c_int,
    key: c_int,
    mod: u16,
    raw: u16,
    down: SDL_bool,
    repeat: SDL_bool,
};

pub const SDL_TextInputEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    text: ?[*:0]const u8,
};

pub const SDL_WindowEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    data1: Sint32,
    data2: Sint32,
};

pub const SDL_MouseMotionEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    which: Uint32,
    state: Uint32,
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
};

pub const SDL_MouseButtonEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    which: Uint32,
    button: Uint8,
    down: SDL_bool,
    clicks: Uint8,
    padding: Uint8 = 0,
    x: f32,
    y: f32,
};

pub const SDL_MouseWheelEvent = extern struct {
    type: Uint32,
    reserved: Uint32,
    timestamp: Uint64,
    windowID: Uint32,
    which: Uint32,
    x: f32,
    y: f32,
    direction: Uint32,
    mouse_x: f32,
    mouse_y: f32,
    integer_x: Sint32,
    integer_y: Sint32,
};

pub const SDL_Event = extern union {
    type: Uint32,
    window: SDL_WindowEvent,
    key: SDL_KeyboardEvent,
    text: SDL_TextInputEvent,
    motion: SDL_MouseMotionEvent,
    button: SDL_MouseButtonEvent,
    wheel: SDL_MouseWheelEvent,
    padding: [128]Uint8,
};

pub const SDL_WindowFlags = Uint64;

pub const SDL_WINDOW_HIDDEN: SDL_WindowFlags = 0x0000000000000008;

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
pub const SDL_BLENDMODE_NONE: Uint32 = 0x00000000;
pub const SDL_BLENDMODE_BLEND: Uint32 = 0x00000001;
pub const SDL_BLENDMODE_ADD: Uint32 = 0x00000002;
pub const SDL_BLENDMODE_MOD: Uint32 = 0x00000004;
pub const SDL_BLENDMODE_MUL: Uint32 = 0x00000008;
pub const SDL_PROP_TEXTURE_FORMAT_NUMBER: [*:0]const u8 = "SDL.texture.format";
pub const SDL_PROP_TEXTURE_ACCESS_NUMBER: [*:0]const u8 = "SDL.texture.access";
pub const SDL_FLIP_NONE: c_int = 0;
pub const SDL_FLIP_HORIZONTAL: c_int = 1;
pub const SDL_FLIP_VERTICAL: c_int = 2;
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
pub const SDL_WINDOWEVENT_RESIZED: Uint32 = 0x206;
pub const SDL_WINDOWEVENT_SIZE_CHANGED: Uint32 = 0x207;
pub const SDL_WINDOWEVENT_ENTER: Uint32 = 0x20c;
pub const SDL_WINDOWEVENT_LEAVE: Uint32 = 0x20d;
pub const SDL_WINDOWEVENT_FOCUS_GAINED: Uint32 = 0x20e;
pub const SDL_WINDOWEVENT_FOCUS_LOST: Uint32 = 0x20f;
pub const SDL_WINDOWEVENT_CLOSE: Uint32 = 0x210;
pub const SDL_WINDOW_INPUT_FOCUS: SDL_WindowFlags = 0x0000000000000200;
pub const SDL_WINDOW_MOUSE_FOCUS: SDL_WindowFlags = 0x0000000000000400;
pub const SDL_DISABLE: c_int = 0;
pub const SDL_ENABLE: c_int = 1;
pub const SDL_QUERY: c_int = -1;
pub const SDL_KMOD_NONE: SDL_Keymod = 0x0000;
pub const SDL_KMOD_LSHIFT: SDL_Keymod = 0x0001;
pub const SDL_KMOD_RSHIFT: SDL_Keymod = 0x0002;
pub const SDL_KMOD_SHIFT: SDL_Keymod = SDL_KMOD_LSHIFT | SDL_KMOD_RSHIFT;

pub extern fn SDL_Init(flags: Uint32) SDL_bool;
pub extern fn SDL_InitSubSystem(flags: Uint32) SDL_bool;
pub extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) SDL_bool;
pub extern fn SDL_QuitSubSystem(flags: Uint32) void;
pub extern fn SDL_Quit() void;
pub extern fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: SDL_WindowFlags) ?*SDL_Window;
pub extern fn SDL_GetWindowID(window: ?*SDL_Window) Uint32;
pub extern fn SDL_GetWindowFlags(window: ?*SDL_Window) SDL_WindowFlags;
pub extern fn SDL_SetWindowSize(window: ?*SDL_Window, w: c_int, h: c_int) SDL_bool;
pub extern fn SDL_ShowWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_HideWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_MinimizeWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_RestoreWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_RaiseWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_DestroyWindow(window: ?*SDL_Window) void;
pub extern fn SDL_CreateRenderer(window: ?*SDL_Window, name: ?[*:0]const u8) ?*SDL_Renderer;
pub extern fn SDL_GetRendererInfo(renderer: ?*SDL_Renderer, info: ?*SDL_RendererInfo) c_int;
pub extern fn SDL_DestroyRenderer(renderer: ?*SDL_Renderer) void;
pub extern fn SDL_CreateTexture(renderer: ?*SDL_Renderer, format: Uint32, access: c_int, w: c_int, h: c_int) ?*SDL_Texture;
pub extern fn SDL_CreateTextureFromSurface(renderer: ?*SDL_Renderer, surface: ?*SDL_Surface) ?*SDL_Texture;
pub extern fn SDL_DestroyTexture(texture: ?*SDL_Texture) void;
pub extern fn SDL_UpdateTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) SDL_bool;
pub extern fn SDL_UpdateYUVTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, yplane: ?[*]const Uint8, ypitch: c_int, uplane: ?[*]const Uint8, upitch: c_int, vplane: ?[*]const Uint8, vpitch: c_int) SDL_bool;
pub extern fn SDL_UpdateNVTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, yplane: ?[*]const Uint8, ypitch: c_int, uvplane: ?[*]const Uint8, uvpitch: c_int) SDL_bool;
pub extern fn SDL_LockTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) SDL_bool;
pub extern fn SDL_UnlockTexture(texture: ?*SDL_Texture) void;
pub extern fn SDL_CreateSurfaceFrom(width: c_int, height: c_int, format: Uint32, pixels: ?*anyopaque, pitch: c_int) ?*SDL_Surface;
pub extern fn SDL_ConvertSurfaceFormat(surface: ?*SDL_Surface, pixel_format: Uint32, flags: Uint32) ?*SDL_Surface;
pub extern fn SDL_DestroySurface(surface: ?*SDL_Surface) void;
pub extern fn SDL_BlitSurface(src: ?*SDL_Surface, srcrect: ?*const SDL_Rect, dst: ?*SDL_Surface, dstrect: ?*const SDL_Rect) SDL_bool;
pub extern fn SDL_UpperBlit(src: ?*SDL_Surface, srcrect: ?*const SDL_Rect, dst: ?*SDL_Surface, dstrect: ?*SDL_Rect) c_int;
pub extern fn SDL_CreateColorCursor(surface: ?*SDL_Surface, hot_x: c_int, hot_y: c_int) ?*SDL_Cursor;
pub extern fn SDL_SetCursor(cursor: ?*SDL_Cursor) SDL_bool;
pub extern fn SDL_ShowCursor() SDL_bool;
pub extern fn SDL_HideCursor() SDL_bool;
pub extern fn SDL_DestroyCursor(cursor: ?*SDL_Cursor) void;
pub extern fn SDL_SetRenderDrawColor(renderer: ?*SDL_Renderer, r: Uint8, g: Uint8, b: Uint8, a: Uint8) SDL_bool;
pub extern fn SDL_SetTextureColorMod(texture: ?*SDL_Texture, r: Uint8, g: Uint8, b: Uint8) SDL_bool;
pub extern fn SDL_SetTextureAlphaMod(texture: ?*SDL_Texture, a: Uint8) SDL_bool;
pub extern fn SDL_SetTextureBlendMode(texture: ?*SDL_Texture, blendMode: Uint32) SDL_bool;
pub extern fn SDL_RenderClear(renderer: ?*SDL_Renderer) SDL_bool;
pub extern fn SDL_RenderTexture(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, srcrect: ?*const SDL_FRect, dstrect: ?*const SDL_FRect) SDL_bool;
pub extern fn SDL_RenderTextureRotated(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, srcrect: ?*const SDL_FRect, dstrect: ?*const SDL_FRect, angle: f64, center: ?*const SDL_FPoint, flip: c_int) SDL_bool;
pub extern fn SDL_RenderGeometryRaw(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, color: ?[*]const SDL_FColor, color_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) SDL_bool;
pub extern fn SDL_RenderPresent(renderer: ?*SDL_Renderer) SDL_bool;
pub extern fn SDL_GetTextureProperties(texture: ?*SDL_Texture) SDL_PropertiesID;
pub extern fn SDL_GetNumberProperty(props: SDL_PropertiesID, name: [*:0]const u8, default_value: Sint64) Sint64;
pub extern fn SDL_GetTextureSize(texture: ?*SDL_Texture, w: ?*f32, h: ?*f32) SDL_bool;
pub extern fn SDL_QueryTexture(texture: ?*SDL_Texture, format: ?*Uint32, access: ?*c_int, w: ?*c_int, h: ?*c_int) c_int;
pub extern fn SDL_RenderFillRect(renderer: ?*SDL_Renderer, rect: ?*const SDL_FRect) SDL_bool;
pub extern fn SDL_RenderPoint(renderer: ?*SDL_Renderer, x: f32, y: f32) SDL_bool;
pub extern fn SDL_RenderLine(renderer: ?*SDL_Renderer, x1: f32, y1: f32, x2: f32, y2: f32) SDL_bool;
pub extern fn SDL_SetRenderViewport(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) SDL_bool;
pub extern fn SDL_SetRenderClipRect(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) SDL_bool;
pub extern fn SDL_RenderGetViewport(renderer: ?*SDL_Renderer, rect: *SDL_Rect) void;
pub extern fn SDL_GL_CreateContext(window: ?*SDL_Window) SDL_GLContext;
pub extern fn SDL_GL_MakeCurrent(window: ?*SDL_Window, context: SDL_GLContext) SDL_bool;
pub extern fn SDL_GL_GetDrawableSize(window: ?*SDL_Window, w: *c_int, h: *c_int) void;
pub extern fn SDL_GL_SwapWindow(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_Vulkan_LoadLibrary(path: ?[*:0]const u8) SDL_bool;
pub extern fn SDL_PumpEvents() void;
pub extern fn SDL_PollEvent(event: ?*SDL_Event) SDL_bool;
pub extern fn SDL_PeepEvents(events: ?[*]SDL_Event, numevents: c_int, action: c_int, minType: Uint32, maxType: Uint32) c_int;
pub extern fn SDL_SetEventEnabled(event_type: Uint32, enabled: SDL_bool) void;
pub extern fn SDL_EventEnabled(event_type: Uint32) SDL_bool;
pub extern fn SDL_StartTextInput(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_StopTextInput(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_TextInputActive(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_SetTextInputArea(window: ?*SDL_Window, rect: ?*const SDL_Rect, cursor: c_int) SDL_bool;
pub extern fn SDL_GetTextInputArea(window: ?*SDL_Window, rect: ?*SDL_Rect, cursor: ?*c_int) SDL_bool;
pub extern fn SDL_HasKeyboard() SDL_bool;
pub extern fn SDL_GetKeyboardFocus() ?*SDL_Window;
pub extern fn SDL_GetKeyboardState(numkeys: ?*c_int) ?[*]const SDL_bool;
pub extern fn SDL_GetModState() SDL_Keymod;
pub extern fn SDL_SetModState(modstate: SDL_Keymod) void;
pub extern fn SDL_GetMouseFocus() ?*SDL_Window;
pub extern fn SDL_GetMouseState(x: ?*f32, y: ?*f32) Uint32;
pub extern fn SDL_GetGlobalMouseState(x: ?*f32, y: ?*f32) Uint32;
pub extern fn SDL_GetRelativeMouseState(x: ?*f32, y: ?*f32) Uint32;
pub extern fn SDL_SetWindowRelativeMouseMode(window: ?*SDL_Window, enabled: SDL_bool) SDL_bool;
pub extern fn SDL_GetWindowRelativeMouseMode(window: ?*SDL_Window) SDL_bool;
pub extern fn SDL_CaptureMouse(enabled: SDL_bool) SDL_bool;
pub extern fn SDL_Delay(ms: Uint32) void;
pub extern fn SDL_GetTicks() Uint32;
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

test "SDL_Event binding matches SDL3 ABI size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(SDL_Event));
}
