const builtin = @import("builtin");
const build_options = @import("katzensteg_build_options");
const sdl = @import("katzensteg_sdl");

const use_c_real = build_options.use_c_real_sdl and !builtin.is_test;
const has_texture_query_compat = @hasDecl(sdl, "SDL_GetTextureSize") and
    @hasDecl(sdl, "SDL_GetTextureProperties") and
    @hasDecl(sdl, "SDL_GetNumberProperty") and
    @hasDecl(sdl, "SDL_PROP_TEXTURE_FORMAT_NUMBER") and
    @hasDecl(sdl, "SDL_PROP_TEXTURE_ACCESS_NUMBER");

extern fn ks_real_SDL_Init(flags: sdl.Uint32) c_int;
extern fn ks_real_SDL_InitSubSystem(flags: sdl.Uint32) c_int;
extern fn ks_real_SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) sdl.SDL_bool;
extern fn ks_real_SDL_QuitSubSystem(flags: sdl.Uint32) void;
extern fn ks_real_SDL_Quit() void;
extern fn ks_real_SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: sdl.Uint32) ?*sdl.SDL_Window;
extern fn ks_real_SDL_GetWindowID(window: ?*sdl.SDL_Window) sdl.Uint32;
extern fn ks_real_SDL_GetWindowFlags(window: ?*sdl.SDL_Window) sdl.Uint32;
extern fn ks_real_SDL_SetWindowSize(window: ?*sdl.SDL_Window, w: c_int, h: c_int) void;
extern fn ks_real_SDL_ShowWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_HideWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_MinimizeWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_RestoreWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_RaiseWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_DestroyWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_CreateRenderer(window: ?*sdl.SDL_Window, index: c_int, flags: sdl.Uint32) ?*sdl.SDL_Renderer;
extern fn ks_real_SDL_GetRendererInfo(renderer: ?*sdl.SDL_Renderer, info: ?*sdl.SDL_RendererInfo) c_int;
extern fn ks_real_SDL_DestroyRenderer(renderer: ?*sdl.SDL_Renderer) void;
extern fn ks_real_SDL_CreateTexture(renderer: ?*sdl.SDL_Renderer, format: sdl.Uint32, access: c_int, w: c_int, h: c_int) ?*sdl.SDL_Texture;
extern fn ks_real_SDL_CreateTextureFromSurface(renderer: ?*sdl.SDL_Renderer, surface: ?*sdl.SDL_Surface) ?*sdl.SDL_Texture;
extern fn ks_real_SDL_DestroyTexture(texture: ?*sdl.SDL_Texture) void;
extern fn ks_real_SDL_UpdateTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) c_int;
extern fn ks_real_SDL_UpdateYUVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uplane: ?[*]const sdl.Uint8, upitch: c_int, vplane: ?[*]const sdl.Uint8, vpitch: c_int) c_int;
extern fn ks_real_SDL_UpdateNVTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const sdl.Uint8, ypitch: c_int, uvplane: ?[*]const sdl.Uint8, uvpitch: c_int) c_int;
extern fn ks_real_SDL_LockTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) c_int;
extern fn ks_real_SDL_UnlockTexture(texture: ?*sdl.SDL_Texture) void;
extern fn ks_real_SDL_SetTextureColorMod(texture: ?*sdl.SDL_Texture, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8) c_int;
extern fn ks_real_SDL_SetTextureAlphaMod(texture: ?*sdl.SDL_Texture, a: sdl.Uint8) c_int;
extern fn ks_real_SDL_SetTextureBlendMode(texture: ?*sdl.SDL_Texture, blendMode: c_int) c_int;
extern fn ks_real_SDL_SetRenderDrawColor(renderer: ?*sdl.SDL_Renderer, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8, a: sdl.Uint8) c_int;
extern fn ks_real_SDL_RenderClear(renderer: ?*sdl.SDL_Renderer) c_int;
extern fn ks_real_SDL_RenderCopy(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect) c_int;
extern fn ks_real_SDL_RenderCopyEx(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) c_int;
extern fn ks_real_SDL_RenderGeometryRaw(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, color: ?[*]const sdl.SDL_Color, color_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) c_int;
extern fn ks_real_SDL_RenderPresent(renderer: ?*sdl.SDL_Renderer) void;
extern fn ks_real_SDL_QueryTexture(texture: ?*sdl.SDL_Texture, format: ?*sdl.Uint32, access: ?*c_int, w: ?*c_int, h: ?*c_int) c_int;
extern fn ks_real_SDL_RenderFillRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) c_int;
extern fn ks_real_SDL_RenderDrawPoint(renderer: ?*sdl.SDL_Renderer, x: c_int, y: c_int) c_int;
extern fn ks_real_SDL_RenderDrawLine(renderer: ?*sdl.SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) c_int;
extern fn ks_real_SDL_RenderSetViewport(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) c_int;
extern fn ks_real_SDL_RenderSetClipRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) c_int;
extern fn ks_real_SDL_GL_CreateContext(window: ?*sdl.SDL_Window) sdl.SDL_GLContext;
extern fn ks_real_SDL_GL_MakeCurrent(window: ?*sdl.SDL_Window, context: sdl.SDL_GLContext) c_int;
extern fn ks_real_SDL_GL_GetDrawableSize(window: ?*sdl.SDL_Window, w: *c_int, h: *c_int) void;
extern fn ks_real_SDL_GL_SwapWindow(window: ?*sdl.SDL_Window) void;
extern fn ks_real_SDL_Vulkan_LoadLibrary(path: ?[*:0]const u8) c_int;
extern fn ks_real_SDL_PumpEvents() void;
extern fn ks_real_SDL_PollEvent(event: ?*sdl.SDL_Event) c_int;
extern fn ks_real_SDL_PeepEvents(events: ?[*]sdl.SDL_Event, numevents: c_int, action: c_int, minType: sdl.Uint32, maxType: sdl.Uint32) c_int;
extern fn ks_real_SDL_GetKeyboardState(numkeys: ?*c_int) ?[*]const sdl.Uint8;
extern fn ks_real_SDL_GetMouseFocus() ?*sdl.SDL_Window;
extern fn ks_real_SDL_GetMouseState(x: ?*c_int, y: ?*c_int) sdl.Uint32;
extern fn ks_real_SDL_GetRelativeMouseState(x: ?*c_int, y: ?*c_int) sdl.Uint32;
extern fn ks_real_SDL_GetTicks() sdl.Uint32;
extern fn ks_real_SDL_ConvertSurfaceFormat(surface: ?*sdl.SDL_Surface, pixel_format: sdl.Uint32, flags: sdl.Uint32) ?*sdl.SDL_Surface;
extern fn ks_real_SDL_FreeSurface(surface: ?*sdl.SDL_Surface) void;
extern fn ks_real_SDL_UpperBlit(src: ?*sdl.SDL_Surface, srcrect: ?*const sdl.SDL_Rect, dst: ?*sdl.SDL_Surface, dstrect: ?*sdl.SDL_Rect) c_int;
extern fn ks_real_SDL_CreateColorCursor(surface: ?*sdl.SDL_Surface, hot_x: c_int, hot_y: c_int) ?*sdl.SDL_Cursor;
extern fn ks_real_SDL_SetCursor(cursor: ?*sdl.SDL_Cursor) void;
extern fn ks_real_SDL_ShowCursor(toggle: c_int) c_int;
extern fn ks_real_SDL_FreeCursor(cursor: ?*sdl.SDL_Cursor) void;
extern fn ks_real_SDL_GetError() [*:0]const u8;
extern fn ks_real_dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;

pub const SDL_Init = if (use_c_real) ks_real_SDL_Init else sdl.SDL_Init;
pub const SDL_InitSubSystem = if (use_c_real) ks_real_SDL_InitSubSystem else sdl.SDL_InitSubSystem;
pub const SDL_SetHint = if (use_c_real) ks_real_SDL_SetHint else sdl.SDL_SetHint;
pub const SDL_QuitSubSystem = if (use_c_real) ks_real_SDL_QuitSubSystem else sdl.SDL_QuitSubSystem;
pub const SDL_Quit = if (use_c_real) ks_real_SDL_Quit else sdl.SDL_Quit;
pub const SDL_CreateWindow = if (use_c_real) ks_real_SDL_CreateWindow else sdl.SDL_CreateWindow;
pub const SDL_GetWindowID = if (use_c_real) ks_real_SDL_GetWindowID else sdl.SDL_GetWindowID;
pub const SDL_GetWindowFlags = if (use_c_real) ks_real_SDL_GetWindowFlags else sdl.SDL_GetWindowFlags;
pub const SDL_SetWindowSize = if (use_c_real) ks_real_SDL_SetWindowSize else sdl.SDL_SetWindowSize;
pub const SDL_ShowWindow = if (use_c_real) ks_real_SDL_ShowWindow else sdl.SDL_ShowWindow;
pub const SDL_HideWindow = if (use_c_real) ks_real_SDL_HideWindow else sdl.SDL_HideWindow;
pub const SDL_MinimizeWindow = if (use_c_real) ks_real_SDL_MinimizeWindow else sdl.SDL_MinimizeWindow;
pub const SDL_RestoreWindow = if (use_c_real) ks_real_SDL_RestoreWindow else sdl.SDL_RestoreWindow;
pub const SDL_RaiseWindow = if (use_c_real) ks_real_SDL_RaiseWindow else sdl.SDL_RaiseWindow;
pub const SDL_DestroyWindow = if (use_c_real) ks_real_SDL_DestroyWindow else sdl.SDL_DestroyWindow;
pub const SDL_CreateRenderer = if (use_c_real) ks_real_SDL_CreateRenderer else sdl.SDL_CreateRenderer;
pub const SDL_GetRendererInfo = if (use_c_real) ks_real_SDL_GetRendererInfo else sdl.SDL_GetRendererInfo;
pub const SDL_DestroyRenderer = if (use_c_real) ks_real_SDL_DestroyRenderer else sdl.SDL_DestroyRenderer;
pub const SDL_CreateTexture = if (use_c_real) ks_real_SDL_CreateTexture else sdl.SDL_CreateTexture;
pub const SDL_CreateTextureFromSurface = if (use_c_real) ks_real_SDL_CreateTextureFromSurface else sdl.SDL_CreateTextureFromSurface;
pub const SDL_DestroyTexture = if (use_c_real) ks_real_SDL_DestroyTexture else sdl.SDL_DestroyTexture;
pub const SDL_UpdateTexture = if (use_c_real) ks_real_SDL_UpdateTexture else sdl.SDL_UpdateTexture;
pub const SDL_UpdateYUVTexture = if (use_c_real) ks_real_SDL_UpdateYUVTexture else sdl.SDL_UpdateYUVTexture;
pub const SDL_UpdateNVTexture = if (use_c_real) ks_real_SDL_UpdateNVTexture else sdl.SDL_UpdateNVTexture;
pub const SDL_LockTexture = if (use_c_real) ks_real_SDL_LockTexture else sdl.SDL_LockTexture;
pub const SDL_UnlockTexture = if (use_c_real) ks_real_SDL_UnlockTexture else sdl.SDL_UnlockTexture;
pub const SDL_SetTextureColorMod = if (use_c_real) ks_real_SDL_SetTextureColorMod else sdl.SDL_SetTextureColorMod;
pub const SDL_SetTextureAlphaMod = if (use_c_real) ks_real_SDL_SetTextureAlphaMod else sdl.SDL_SetTextureAlphaMod;
pub const SDL_SetTextureBlendMode = if (use_c_real) ks_real_SDL_SetTextureBlendMode else sdl.SDL_SetTextureBlendMode;
pub const SDL_SetRenderDrawColor = if (use_c_real) ks_real_SDL_SetRenderDrawColor else sdl.SDL_SetRenderDrawColor;
pub const SDL_RenderClear = if (use_c_real) ks_real_SDL_RenderClear else sdl.SDL_RenderClear;
pub const SDL_RenderCopy = if (use_c_real) ks_real_SDL_RenderCopy else sdl.SDL_RenderCopy;
pub const SDL_RenderCopyEx = if (use_c_real) ks_real_SDL_RenderCopyEx else sdl.SDL_RenderCopyEx;
pub const SDL_RenderGeometryRaw = if (use_c_real) ks_real_SDL_RenderGeometryRaw else sdl.SDL_RenderGeometryRaw;
pub const SDL_RenderPresent = if (use_c_real) ks_real_SDL_RenderPresent else sdl.SDL_RenderPresent;
pub fn SDL_QueryTexture(texture: ?*sdl.SDL_Texture, format: ?*sdl.Uint32, access: ?*c_int, w: ?*c_int, h: ?*c_int) c_int {
    if (use_c_real) return ks_real_SDL_QueryTexture(texture, format, access, w, h);
    if (comptime has_texture_query_compat) {
        const tex = texture orelse return -1;
        var width: f32 = 0;
        var height: f32 = 0;
        if (!sdl.SDL_GetTextureSize(tex, &width, &height)) return -1;

        if (w) |out| out.* = @intFromFloat(width);
        if (h) |out| out.* = @intFromFloat(height);
        if (format) |out| out.* = 0;
        if (access) |out| out.* = 0;

        const props = sdl.SDL_GetTextureProperties(tex);
        if (props != 0) {
            if (format) |out| {
                out.* = @intCast(sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_TEXTURE_FORMAT_NUMBER, out.*));
            }
            if (access) |out| {
                out.* = @intCast(sdl.SDL_GetNumberProperty(props, sdl.SDL_PROP_TEXTURE_ACCESS_NUMBER, out.*));
            }
        }
        return 0;
    }
    return sdl.SDL_QueryTexture(texture, format, access, w, h);
}
pub const SDL_RenderFillRect = if (use_c_real) ks_real_SDL_RenderFillRect else sdl.SDL_RenderFillRect;
pub const SDL_RenderDrawPoint = if (use_c_real) ks_real_SDL_RenderDrawPoint else sdl.SDL_RenderDrawPoint;
pub const SDL_RenderDrawLine = if (use_c_real) ks_real_SDL_RenderDrawLine else sdl.SDL_RenderDrawLine;
pub const SDL_RenderSetViewport = if (use_c_real) ks_real_SDL_RenderSetViewport else sdl.SDL_RenderSetViewport;
pub const SDL_RenderSetClipRect = if (use_c_real) ks_real_SDL_RenderSetClipRect else sdl.SDL_RenderSetClipRect;
pub const SDL_GL_CreateContext = if (use_c_real) ks_real_SDL_GL_CreateContext else sdl.SDL_GL_CreateContext;
pub const SDL_GL_MakeCurrent = if (use_c_real) ks_real_SDL_GL_MakeCurrent else sdl.SDL_GL_MakeCurrent;
pub const SDL_GL_GetDrawableSize = if (use_c_real) ks_real_SDL_GL_GetDrawableSize else sdl.SDL_GL_GetDrawableSize;
pub const SDL_GL_SwapWindow = if (use_c_real) ks_real_SDL_GL_SwapWindow else sdl.SDL_GL_SwapWindow;
pub const SDL_Vulkan_LoadLibrary = if (use_c_real) ks_real_SDL_Vulkan_LoadLibrary else sdl.SDL_Vulkan_LoadLibrary;
pub const SDL_PumpEvents = if (use_c_real) ks_real_SDL_PumpEvents else sdl.SDL_PumpEvents;
pub const SDL_PollEvent = if (use_c_real) ks_real_SDL_PollEvent else sdl.SDL_PollEvent;
pub const SDL_PeepEvents = if (use_c_real) ks_real_SDL_PeepEvents else sdl.SDL_PeepEvents;
pub const SDL_GetKeyboardState = if (use_c_real) ks_real_SDL_GetKeyboardState else sdl.SDL_GetKeyboardState;
pub const SDL_GetMouseFocus = if (use_c_real) ks_real_SDL_GetMouseFocus else sdl.SDL_GetMouseFocus;
pub const SDL_GetMouseState = if (use_c_real) ks_real_SDL_GetMouseState else sdl.SDL_GetMouseState;
pub const SDL_GetRelativeMouseState = if (use_c_real) ks_real_SDL_GetRelativeMouseState else sdl.SDL_GetRelativeMouseState;
pub const SDL_GetTicks = if (use_c_real) ks_real_SDL_GetTicks else sdl.SDL_GetTicks;
pub fn SDL_ConvertSurfaceFormat(surface: ?*sdl.SDL_Surface, pixel_format: sdl.Uint32, _flags: sdl.Uint32) ?*sdl.SDL_Surface {
    if (use_c_real) return ks_real_SDL_ConvertSurfaceFormat(surface, pixel_format, _flags);
    if (comptime @hasDecl(sdl, "SDL_ConvertSurfaceFormat")) {
        return sdl.SDL_ConvertSurfaceFormat(surface, pixel_format, _flags);
    } else {
        return sdl.SDL_ConvertSurface(surface, pixel_format);
    }
}
pub const SDL_FreeSurface = if (use_c_real) ks_real_SDL_FreeSurface else sdl.SDL_FreeSurface;
pub const SDL_UpperBlit = if (use_c_real) ks_real_SDL_UpperBlit else sdl.SDL_UpperBlit;
pub const SDL_CreateColorCursor = if (use_c_real) ks_real_SDL_CreateColorCursor else sdl.SDL_CreateColorCursor;
pub const SDL_SetCursor = if (use_c_real) ks_real_SDL_SetCursor else sdl.SDL_SetCursor;
pub const SDL_ShowCursor = if (use_c_real) ks_real_SDL_ShowCursor else sdl.SDL_ShowCursor;
pub const SDL_FreeCursor = if (use_c_real) ks_real_SDL_FreeCursor else sdl.SDL_FreeCursor;
pub const SDL_GetError = if (use_c_real) ks_real_SDL_GetError else sdl.SDL_GetError;

pub fn realDlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque {
    if (use_c_real) return ks_real_dlopen(path, mode);
    return dlopen(path, mode);
}
