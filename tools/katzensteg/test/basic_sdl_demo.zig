const std = @import("std");
const sdl = @import("katzensteg_sdl");

const tex_w = 128;
const tex_h = 128;
const win_w = 640;
const win_h = 480;

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
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) return error.SDLInitFailed;
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("basic-sdl-demo", sdl.SDL_WINDOWPOS_CENTERED, sdl.SDL_WINDOWPOS_CENTERED, win_w, win_h, @intFromEnum(sdl.SDL_WindowFlags.shown)) orelse return error.SDLCreateWindowFailed;
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, -1, @intFromEnum(sdl.SDL_RendererFlags.accelerated) | @intFromEnum(sdl.SDL_RendererFlags.presentvsync)) orelse return error.SDLCreateRendererFailed;
    defer sdl.SDL_DestroyRenderer(renderer);

    const streaming = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_ABGR8888, sdl.SDL_TEXTUREACCESS_STATIC, tex_w, tex_h) orelse return error.SDLCreateTextureFailed;
    defer sdl.SDL_DestroyTexture(streaming);

    var pixels: [tex_w * tex_h * 4]u8 = undefined;
    fillTexture(&pixels, 0);
    if (sdl.SDL_UpdateTexture(streaming, null, &pixels, tex_w * 4) != 0) return error.SDLUpdateTextureFailed;

    const surface = sdl.SDL_CreateRGBSurfaceWithFormatFrom(@ptrCast(&pixels), tex_w, tex_h, 32, tex_w * 4, sdl.SDL_PIXELFORMAT_ABGR8888) orelse return error.SDLSurfaceCreateFailed;
    defer sdl.SDL_FreeSurface(surface);
    const surface_texture = sdl.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.SDLCreateTextureFromSurfaceFailed;
    defer sdl.SDL_DestroyTexture(surface_texture);
    _ = sdl.SDL_SetTextureBlendMode(surface_texture, sdl.SDL_BLENDMODE_BLEND);

    var frame: usize = 0;
    while (frame < 240) : (frame += 1) {
        fillTexture(&pixels, frame);
        if (sdl.SDL_UpdateTexture(streaming, null, &pixels, tex_w * 4) != 0) return error.SDLUpdateTextureFailed;
        _ = sdl.SDL_SetTextureColorMod(surface_texture, 255, @intCast((frame * 3) % 255), @intCast((frame * 5) % 255));
        _ = sdl.SDL_SetTextureAlphaMod(surface_texture, @intCast(120 + (frame % 120)));

        _ = sdl.SDL_SetRenderDrawColor(renderer, @intCast((frame * 2) % 255), 16, @intCast(60 + ((frame * 3) % 120)), 255);
        _ = sdl.SDL_RenderClear(renderer);

        const fill = sdl.SDL_Rect{ .x = 32, .y = 32, .w = 96, .h = 96 };
        _ = sdl.SDL_RenderFillRect(renderer, &fill);

        const dst_a = sdl.SDL_Rect{
            .x = @intCast(80 + @as(c_int, @intCast((frame * 3) % 240))),
            .y = @intCast(100 + @as(c_int, @intCast((frame * 2) % 160))),
            .w = 192,
            .h = 192,
        };
        const dst_b = sdl.SDL_Rect{ .x = 360, .y = 180, .w = 160, .h = 160 };
        _ = sdl.SDL_RenderCopy(renderer, streaming, null, &dst_a);
        _ = sdl.SDL_RenderCopy(renderer, surface_texture, null, &dst_b);
        sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
