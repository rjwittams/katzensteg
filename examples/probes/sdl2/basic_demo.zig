const std = @import("std");
const sdl = @import("katzensteg_sdl");

const tex_w = 128;
const tex_h = 128;
const win_w = 640;
const win_h = 480;
const default_frames = 900;
const key_marks = 16;

/// Key presses the demo has seen, drawn as a row of squares so a capture
/// shows input reaching the application. Escape or `q` quits.
const KeyLog = struct {
    count: usize = 0,
    scancodes: [key_marks]c_int = [_]c_int{0} ** key_marks,

    fn record(self: *KeyLog, scancode: c_int) void {
        self.scancodes[self.count % key_marks] = scancode;
        self.count += 1;
    }

    fn draw(self: *const KeyLog, renderer: *sdl.SDL_Renderer) void {
        const shown = @min(self.count, key_marks);
        for (0..shown) |i| {
            // Oldest first, so the newest press is always on the right.
            const scancode: u8 = @truncate(@as(u32, @bitCast(self.scancodes[(self.count - shown + i) % key_marks])));
            _ = sdl.SDL_SetRenderDrawColor(renderer, scancode *% 97, 255 -% scancode *% 41, scancode *% 13 +% 128, 255);
            const mark = sdl.SDL_Rect{ .x = @intCast(8 + i * 24), .y = 8, .w = 16, .h = 16 };
            _ = sdl.SDL_RenderFillRect(renderer, &mark);
        }
    }
};

/// `--frames N` sets how many frames to draw; 0 runs until quit.
fn frameLimit(args: []const []const u8) !usize {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--frames") and i + 1 < args.len) return std.fmt.parseInt(usize, args[i + 1], 10);
    }
    return default_frames;
}

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

pub fn main(init: std.process.Init) !void {
    const run_frames = try frameLimit(try init.minimal.args.toSlice(init.arena.allocator()));
    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) return error.SDLInitFailed;
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("basic-sdl-demo", sdl.SDL_WINDOWPOS_CENTERED, sdl.SDL_WINDOWPOS_CENTERED, win_w, win_h, @intFromEnum(sdl.SDL_WindowFlags.shown)) orelse return error.SDLCreateWindowFailed;
    defer sdl.SDL_DestroyWindow(window);
    sdl.SDL_ShowWindow(window);
    sdl.SDL_RaiseWindow(window);

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

    var keys: KeyLog = .{};
    var frame: usize = 0;
    frames: while (run_frames == 0 or frame < run_frames) : (frame += 1) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl.SDL_QUIT) break :frames;
            if (event.type != sdl.SDL_KEYDOWN or event.key.repeat != 0) continue;
            if (event.key.keysym.sym == 27 or event.key.keysym.sym == 'q') break :frames;
            keys.record(event.key.keysym.scancode);
        }
        fillTexture(&pixels, frame);
        if (sdl.SDL_UpdateTexture(streaming, null, &pixels, tex_w * 4) != 0) return error.SDLUpdateTextureFailed;
        _ = sdl.SDL_SetTextureColorMod(surface_texture, 255, @intCast((frame * 3) % 255), @intCast((frame * 5) % 255));
        _ = sdl.SDL_SetTextureAlphaMod(surface_texture, @intCast(120 + (frame % 120)));

        _ = sdl.SDL_SetRenderDrawColor(renderer, @intCast((frame * 2) % 255), 16, @intCast(60 + ((frame * 3) % 120)), 255);
        _ = sdl.SDL_RenderClear(renderer);

        const fill = sdl.SDL_Rect{ .x = 32, .y = 32, .w = 96, .h = 96 };
        _ = sdl.SDL_RenderFillRect(renderer, &fill);

        _ = sdl.SDL_SetRenderDrawColor(renderer, 255, 64, 64, 255);
        _ = sdl.SDL_RenderDrawPoint(renderer, 0, 0);
        _ = sdl.SDL_RenderDrawPoint(renderer, win_w - 1, 0);
        _ = sdl.SDL_RenderDrawPoint(renderer, 0, win_h - 1);
        _ = sdl.SDL_RenderDrawPoint(renderer, win_w - 1, win_h - 1);

        _ = sdl.SDL_SetRenderDrawColor(renderer, 64, 255, 64, 255);
        _ = sdl.SDL_RenderDrawLine(renderer, 0, win_h / 2, win_w - 1, win_h / 2);
        _ = sdl.SDL_RenderDrawLine(renderer, win_w / 2, 0, win_w / 2, win_h - 1);
        _ = sdl.SDL_RenderDrawLine(renderer, 0, 0, win_w - 1, win_h - 1);

        const dst_a = sdl.SDL_Rect{
            .x = @intCast(80 + @as(c_int, @intCast((frame * 3) % 240))),
            .y = @intCast(100 + @as(c_int, @intCast((frame * 2) % 160))),
            .w = 192,
            .h = 192,
        };
        const dst_b = sdl.SDL_Rect{ .x = 360, .y = 180, .w = 160, .h = 160 };
        _ = sdl.SDL_RenderCopy(renderer, streaming, null, &dst_a);
        _ = sdl.SDL_RenderCopy(renderer, surface_texture, null, &dst_b);
        keys.draw(renderer);
        sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
