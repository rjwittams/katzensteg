const std = @import("std");
const sdl = @import("katzensteg_sdl");

const tex_w = 128;
const tex_h = 128;
const win_w = 640;
const win_h = 480;
const run_frames = 900;

fn fillTexture(buf: []u8, tick: usize) void {
    var y: usize = 0;
    while (y < tex_h) : (y += 1) {
        var x: usize = 0;
        while (x < tex_w) : (x += 1) {
            const idx = (y * tex_w + x) * 4;
            const xf: u8 = @intCast((x + tick) % 256);
            const yf: u8 = @intCast((y * 2 + tick * 3) % 256);
            const checker: u8 = if (((x / 16) + (y / 16) + tick / 10) % 2 == 0) 220 else 80;
            // ABGR8888 byte layout for little-endian memory.
            buf[idx + 0] = xf;
            buf[idx + 1] = yf;
            buf[idx + 2] = checker;
            buf[idx + 3] = 255;
        }
    }
}

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SDLInitFailed;
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("basic-sdl3-demo", win_w, win_h, 0) orelse return error.SDLCreateWindowFailed;
    defer sdl.SDL_DestroyWindow(window);
    _ = sdl.SDL_ShowWindow(window);
    _ = sdl.SDL_RaiseWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return error.SDLCreateRendererFailed;
    defer sdl.SDL_DestroyRenderer(renderer);

    const streaming = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_ABGR8888, sdl.SDL_TEXTUREACCESS_STATIC, tex_w, tex_h) orelse return error.SDLCreateTextureFailed;
    defer sdl.SDL_DestroyTexture(streaming);
    _ = sdl.SDL_SetTextureBlendMode(streaming, sdl.SDL_BLENDMODE_BLEND);

    var pixels: [tex_w * tex_h * 4]u8 = undefined;
    fillTexture(&pixels, 0);
    const surface = sdl.SDL_CreateRGBSurfaceWithFormatFrom(@ptrCast(&pixels), tex_w, tex_h, 32, tex_w * 4, sdl.SDL_PIXELFORMAT_ABGR8888) orelse return error.SDLSurfaceCreateFailed;
    defer sdl.SDL_FreeSurface(surface);
    const surface_texture = sdl.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.SDLCreateTextureFromSurfaceFailed;
    defer sdl.SDL_DestroyTexture(surface_texture);
    _ = sdl.SDL_SetTextureBlendMode(surface_texture, sdl.SDL_BLENDMODE_BLEND);

    var frame: usize = 0;
    while (frame < run_frames) : (frame += 1) {
        sdl.SDL_PumpEvents();
        fillTexture(&pixels, frame);
        if (!sdl.SDL_UpdateTexture(streaming, null, &pixels, tex_w * 4)) return error.SDLUpdateTextureFailed;
        const mod_g: u8 = @intCast((frame * 3) % 255);
        const mod_b: u8 = @intCast((frame * 5) % 255);
        const alpha: u8 = @intCast(120 + (frame % 120));
        _ = sdl.SDL_SetTextureColorMod(streaming, 255, mod_g, mod_b);
        _ = sdl.SDL_SetTextureAlphaMod(streaming, alpha);
        _ = sdl.SDL_SetTextureColorMod(surface_texture, 255, mod_g, mod_b);
        _ = sdl.SDL_SetTextureAlphaMod(surface_texture, alpha);

        _ = sdl.SDL_SetRenderDrawColor(renderer, @intCast((frame * 2) % 255), 16, @intCast(60 + ((frame * 3) % 120)), 255);
        _ = sdl.SDL_RenderClear(renderer);

        const fill = sdl.SDL_FRect{ .x = 32, .y = 32, .w = 96, .h = 96 };
        _ = sdl.SDL_RenderFillRect(renderer, &fill);

        _ = sdl.SDL_SetRenderDrawColor(renderer, 255, 64, 64, 255);
        _ = sdl.SDL_RenderPoint(renderer, 0, 0);
        _ = sdl.SDL_RenderPoint(renderer, win_w - 1, 0);
        _ = sdl.SDL_RenderPoint(renderer, 0, win_h - 1);
        _ = sdl.SDL_RenderPoint(renderer, win_w - 1, win_h - 1);

        _ = sdl.SDL_SetRenderDrawColor(renderer, 64, 255, 64, 255);
        _ = sdl.SDL_RenderLine(renderer, 0, win_h / 2, win_w - 1, win_h / 2);
        _ = sdl.SDL_RenderLine(renderer, win_w / 2, 0, win_w / 2, win_h - 1);
        _ = sdl.SDL_RenderLine(renderer, 0, 0, win_w - 1, win_h - 1);

        const dst_a = sdl.SDL_FRect{
            .x = @floatFromInt(80 + @as(c_int, @intCast((frame * 3) % 240))),
            .y = @floatFromInt(100 + @as(c_int, @intCast((frame * 2) % 160))),
            .w = 192,
            .h = 192,
        };
        const dst_b = sdl.SDL_FRect{ .x = 360, .y = 180, .w = 160, .h = 160 };
        const center = sdl.SDL_FPoint{ .x = dst_b.w / 2.0, .y = dst_b.h / 2.0 };
        _ = sdl.SDL_RenderTexture(renderer, streaming, null, &dst_a);
        _ = sdl.SDL_RenderTexture(renderer, surface_texture, null, &dst_b);
        _ = sdl.SDL_RenderTextureRotated(renderer, streaming, null, &dst_b, @floatFromInt(frame % 360), &center, sdl.SDL_FLIP_NONE);
        _ = sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
