const std = @import("std");

pub const Sint32 = i32;
pub const Uint8 = u8;
pub const Uint32 = u32;
pub const SDL_bool = c_int;

pub const SDL_Window = opaque {};
pub const SDL_Renderer = opaque {};
pub const SDL_Texture = opaque {};
pub const SDL_Surface = opaque {};

pub const SDL_Rect = extern struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
};

pub const SDL_WindowFlags = enum(Uint32) {
    shown = 0x00000004,
};

pub const SDL_RendererFlags = enum(Uint32) {
    accelerated = 0x00000002,
    presentvsync = 0x00000004,
};

pub const SDL_PIXELFORMAT_ABGR8888: Uint32 = 376840196;
pub const SDL_TEXTUREACCESS_STATIC: c_int = 0;
pub const SDL_BLENDMODE_NONE: c_int = 0x00000000;
pub const SDL_BLENDMODE_BLEND: c_int = 0x00000001;

pub extern fn SDL_Init(flags: Uint32) c_int;
pub extern fn SDL_Quit() void;
pub extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: Uint32) ?*SDL_Window;
pub extern fn SDL_DestroyWindow(window: ?*SDL_Window) void;
pub extern fn SDL_CreateRenderer(window: ?*SDL_Window, index: c_int, flags: Uint32) ?*SDL_Renderer;
pub extern fn SDL_DestroyRenderer(renderer: ?*SDL_Renderer) void;
pub extern fn SDL_CreateTexture(renderer: ?*SDL_Renderer, format: Uint32, access: c_int, w: c_int, h: c_int) ?*SDL_Texture;
pub extern fn SDL_CreateTextureFromSurface(renderer: ?*SDL_Renderer, surface: ?*SDL_Surface) ?*SDL_Texture;
pub extern fn SDL_DestroyTexture(texture: ?*SDL_Texture) void;
pub extern fn SDL_UpdateTexture(texture: ?*SDL_Texture, rect: ?*const SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) c_int;
pub extern fn SDL_CreateRGBSurfaceWithFormatFrom(pixels: ?*anyopaque, width: c_int, height: c_int, depth: c_int, pitch: c_int, format: Uint32) ?*SDL_Surface;
pub extern fn SDL_ConvertSurfaceFormat(surface: ?*SDL_Surface, pixel_format: Uint32, flags: Uint32) ?*SDL_Surface;
pub extern fn SDL_FreeSurface(surface: ?*SDL_Surface) void;
pub extern fn SDL_SetRenderDrawColor(renderer: ?*SDL_Renderer, r: Uint8, g: Uint8, b: Uint8, a: Uint8) c_int;
pub extern fn SDL_SetTextureColorMod(texture: ?*SDL_Texture, r: Uint8, g: Uint8, b: Uint8) c_int;
pub extern fn SDL_SetTextureAlphaMod(texture: ?*SDL_Texture, a: Uint8) c_int;
pub extern fn SDL_SetTextureBlendMode(texture: ?*SDL_Texture, blendMode: c_int) c_int;
pub extern fn SDL_RenderClear(renderer: ?*SDL_Renderer) c_int;
pub extern fn SDL_RenderCopy(renderer: ?*SDL_Renderer, texture: ?*SDL_Texture, srcrect: ?*const SDL_Rect, dstrect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderPresent(renderer: ?*SDL_Renderer) void;
pub extern fn SDL_RenderFillRect(renderer: ?*SDL_Renderer, rect: ?*const SDL_Rect) c_int;
pub extern fn SDL_RenderDrawPoint(renderer: ?*SDL_Renderer, x: c_int, y: c_int) c_int;
pub extern fn SDL_RenderDrawLine(renderer: ?*SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) c_int;
pub extern fn SDL_RenderGetViewport(renderer: ?*SDL_Renderer, rect: *SDL_Rect) void;
pub extern fn SDL_Delay(ms: Uint32) void;
pub extern fn SDL_GetError() [*:0]const u8;

pub const SDL_INIT_VIDEO: Uint32 = 0x00000020;
pub const SDL_WINDOWPOS_CENTERED_MASK: Uint32 = 0x2FFF0000;
pub const SDL_WINDOWPOS_CENTERED: c_int = @bitCast(SDL_WINDOWPOS_CENTERED_MASK);

pub fn sdlError() []const u8 {
    return std.mem.span(SDL_GetError());
}
