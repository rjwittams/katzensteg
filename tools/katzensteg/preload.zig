const std = @import("std");
const sdl = @import("katzensteg_sdl");
const runtime = @import("runtime.zig");

pub export fn ks_SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Window {
    const window = sdl.SDL_CreateWindow(title, x, y, w, h, flags);
    runtime.get().frame_builder.onCreateWindow(window, w, h);
    return window;
}

pub export fn ks_SDL_DestroyWindow(window: ?*sdl.SDL_Window) callconv(.c) void {
    sdl.SDL_DestroyWindow(window);
}

pub export fn ks_SDL_CreateRenderer(window: ?*sdl.SDL_Window, index: c_int, flags: sdl.Uint32) callconv(.c) ?*sdl.SDL_Renderer {
    const renderer = sdl.SDL_CreateRenderer(window, index, flags);
    runtime.get().frame_builder.onCreateRenderer(window, renderer);
    return renderer;
}

pub export fn ks_SDL_DestroyRenderer(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    runtime.get().frame_builder.onDestroyRenderer(renderer);
    sdl.SDL_DestroyRenderer(renderer);
}

pub export fn ks_SDL_CreateTexture(renderer: ?*sdl.SDL_Renderer, format: sdl.Uint32, access: c_int, w: c_int, h: c_int) callconv(.c) ?*sdl.SDL_Texture {
    const texture = sdl.SDL_CreateTexture(renderer, format, access, w, h);
    runtime.get().frame_builder.onCreateTexture(texture, format, w, h);
    return texture;
}

pub export fn ks_SDL_CreateTextureFromSurface(renderer: ?*sdl.SDL_Renderer, surface: ?*sdl.SDL_Surface) callconv(.c) ?*sdl.SDL_Texture {
    const texture = sdl.SDL_CreateTextureFromSurface(renderer, surface);
    const rt = runtime.get();
    if (texture) |tex| {
        rt.frame_builder.onCreateTexture(tex, sdl.SDL_PIXELFORMAT_ABGR8888, 0, 0);
        if (rt.active and rt.backend != null) rt.frame_builder.onCreateTextureFromSurface(&rt.logger, &rt.backend.?, tex, surface);
    }
    return texture;
}

pub export fn ks_SDL_DestroyTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    runtime.get().frame_builder.onDestroyTexture(texture);
    sdl.SDL_DestroyTexture(texture);
}

pub export fn ks_SDL_UpdateTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_UpdateTexture(texture, rect, pixels, pitch);
    const rt = runtime.get();
    if (rc == 0 and rt.active and rt.backend != null) {
        rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, texture, rect, pixels, pitch);
    }
    return rc;
}

pub export fn ks_SDL_LockTexture(texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: *?*anyopaque, pitch: *c_int) callconv(.c) c_int {
    const rc = sdl.SDL_LockTexture(texture, rect, pixels, pitch);
    if (rc == 0) {
        const rt = runtime.get();
        rt.frame_builder.onLockTexture(&rt.logger, texture, rect, pixels.*, pitch.*);
    }
    return rc;
}

pub export fn ks_SDL_UnlockTexture(texture: ?*sdl.SDL_Texture) callconv(.c) void {
    const rt = runtime.get();
    if (rt.active and rt.backend != null) {
        rt.frame_builder.onUnlockTexture(&rt.logger, &rt.backend.?, texture);
    }
    sdl.SDL_UnlockTexture(texture);
}

pub export fn ks_SDL_SetTextureColorMod(texture: ?*sdl.SDL_Texture, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureColorMod(texture, r, g, b);
    const rt = runtime.get();
    if (rc == 0 and rt.active and rt.backend != null) rt.frame_builder.onSetTextureColorMod(&rt.logger, &rt.backend.?, texture, r, g, b);
    return rc;
}

pub export fn ks_SDL_SetTextureAlphaMod(texture: ?*sdl.SDL_Texture, a: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureAlphaMod(texture, a);
    const rt = runtime.get();
    if (rc == 0 and rt.active and rt.backend != null) rt.frame_builder.onSetTextureAlphaMod(&rt.logger, &rt.backend.?, texture, a);
    return rc;
}

pub export fn ks_SDL_SetTextureBlendMode(texture: ?*sdl.SDL_Texture, blendMode: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_SetTextureBlendMode(texture, blendMode);
    if (rc == 0) runtime.get().frame_builder.onSetTextureBlendMode(&runtime.get().logger, texture, blendMode);
    return rc;
}

pub export fn ks_SDL_SetRenderDrawColor(renderer: ?*sdl.SDL_Renderer, r: sdl.Uint8, g: sdl.Uint8, b: sdl.Uint8, a: sdl.Uint8) callconv(.c) c_int {
    const rc = sdl.SDL_SetRenderDrawColor(renderer, r, g, b, a);
    if (rc == 0) runtime.get().frame_builder.onSetRenderDrawColor(renderer, r, g, b, a);
    return rc;
}

pub export fn ks_SDL_RenderClear(renderer: ?*sdl.SDL_Renderer) callconv(.c) c_int {
    const rc = sdl.SDL_RenderClear(renderer);
    if (rc == 0) runtime.get().frame_builder.onRenderClear(renderer);
    return rc;
}

pub export fn ks_SDL_RenderCopy(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderCopy(renderer, texture, srcrect, dstrect);
    if (rc == 0) {
        const rt = runtime.get();
        rt.frame_builder.onRenderCopy(&rt.logger, renderer, texture, srcrect, dstrect);
    }
    return rc;
}

pub export fn ks_SDL_RenderCopyEx(renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, srcrect: ?*const sdl.SDL_Rect, dstrect: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderCopyEx(renderer, texture, srcrect, dstrect, angle, center, flip);
    if (rc == 0) {
        const rt = runtime.get();
        rt.frame_builder.onRenderCopyEx(&rt.logger, renderer, texture, srcrect, dstrect, angle, center, flip);
    }
    return rc;
}

pub export fn ks_SDL_RenderFillRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderFillRect(renderer, rect);
    if (rc == 0) runtime.get().frame_builder.onRenderFillRect(renderer, rect);
    return rc;
}

pub export fn ks_SDL_RenderDrawPoint(renderer: ?*sdl.SDL_Renderer, x: c_int, y: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderDrawPoint(renderer, x, y);
    if (rc == 0) runtime.get().frame_builder.onRenderDrawPoint(renderer, x, y);
    return rc;
}

pub export fn ks_SDL_RenderDrawLine(renderer: ?*sdl.SDL_Renderer, x1: c_int, y1: c_int, x2: c_int, y2: c_int) callconv(.c) c_int {
    const rc = sdl.SDL_RenderDrawLine(renderer, x1, y1, x2, y2);
    if (rc == 0) {
        const rt = runtime.get();
        rt.frame_builder.onRenderDrawLine(&rt.logger, renderer, x1, y1, x2, y2);
    }
    return rc;
}

pub export fn ks_SDL_RenderSetViewport(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderSetViewport(renderer, rect);
    if (rc == 0) runtime.get().frame_builder.onRenderSetViewport(renderer, rect);
    return rc;
}

pub export fn ks_SDL_RenderSetClipRect(renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) callconv(.c) c_int {
    const rc = sdl.SDL_RenderSetClipRect(renderer, rect);
    if (rc == 0) runtime.get().frame_builder.onRenderSetClipRect(renderer, rect);
    return rc;
}

pub export fn ks_SDL_RenderPresent(renderer: ?*sdl.SDL_Renderer) callconv(.c) void {
    const rt = runtime.get();
    if (rt.active and rt.tty != null and rt.engine != null and rt.backend != null and rt.*.shouldPresent()) {
        const start_ns = std.time.nanoTimestamp();
        rt.frame_builder.onRenderPresent(&rt.logger, &rt.tty.?, &rt.engine.?, &rt.backend.?, renderer, rt.bg_only, rt.debug_protocol_replies, rt.image_gc);
        rt.*.notePresentDuration(std.time.nanoTimestamp() - start_ns);
    }
    sdl.SDL_RenderPresent(renderer);
}

