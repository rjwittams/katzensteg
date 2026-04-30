const std = @import("std");
const sdl = @import("katzensteg_sdl");

const frame_width = 800;
const frame_height = 600;
const run_frames = 180;

const CliOptions = struct {
    html_path: []const u8,
};

const FrameHeader = struct {
    format: []const u8,
    width: u32,
    height: u32,
    len: usize,

    fn deinit(self: FrameHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.format);
    }
};

const FrameHeaderPayload = struct {
    format: []const u8,
    width: u32,
    height: u32,
    len: usize,
};

fn parseFrameHeader(allocator: std.mem.Allocator, line: []const u8) !FrameHeader {
    const prefix = "LUCHS_FRAME ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidFrameHeader;
    var parsed = std.json.parseFromSlice(FrameHeaderPayload, allocator, line[prefix.len..], .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidFrameHeader;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.format, "png") and !std.mem.eql(u8, parsed.value.format, "rgba")) {
        return error.InvalidFrameHeader;
    }
    return .{
        .format = try allocator.dupe(u8, parsed.value.format),
        .width = parsed.value.width,
        .height = parsed.value.height,
        .len = parsed.value.len,
    };
}

fn fillTestFrame(buf: []u8, width: usize, height: usize, tick: usize) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const i = (y * width + x) * 4;
            buf[i + 0] = @intCast((x + tick) % 256);
            buf[i + 1] = @intCast((y + tick) % 256);
            buf[i + 2] = 160;
            buf[i + 3] = 255;
        }
    }
}

fn parseArgs(args: []const []const u8) !CliOptions {
    if (args.len != 2) return error.Usage;
    return .{ .html_path = args[1] };
}

test "luchs requires one html path" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"luchs"}));
    const opts = try parseArgs(&.{ "luchs", "tools/luchs/testdata/static.html" });
    try std.testing.expectEqualStrings("tools/luchs/testdata/static.html", opts.html_path);
}

test "fillTestFrame writes rgba pixels" {
    var buf: [8]u8 = undefined;
    @memset(&buf, 0);
    fillTestFrame(&buf, 1, 2, 3);
    try std.testing.expectEqual(@as(u8, 3), buf[0]);
    try std.testing.expectEqual(@as(u8, 3), buf[1]);
    try std.testing.expectEqual(@as(u8, 255), buf[3]);
}

test "parseFrameHeader parses png envelope" {
    const header = "LUCHS_FRAME {\"format\":\"png\",\"width\":2,\"height\":1,\"len\":8}";
    const frame = try parseFrameHeader(std.testing.allocator, header);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("png", frame.format);
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 1), frame.height);
    try std.testing.expectEqual(@as(usize, 8), frame.len);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    const options = try parseArgs(args);
    _ = options;

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) return error.SDLInitFailed;
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "luchs",
        sdl.SDL_WINDOWPOS_CENTERED,
        sdl.SDL_WINDOWPOS_CENTERED,
        frame_width,
        frame_height,
        @intFromEnum(sdl.SDL_WindowFlags.shown),
    ) orelse return error.SDLCreateWindowFailed;
    defer sdl.SDL_DestroyWindow(window);
    sdl.SDL_ShowWindow(window);
    sdl.SDL_RaiseWindow(window);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        @intFromEnum(sdl.SDL_RendererFlags.accelerated) | @intFromEnum(sdl.SDL_RendererFlags.presentvsync),
    ) orelse return error.SDLCreateRendererFailed;
    defer sdl.SDL_DestroyRenderer(renderer);

    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl.SDL_PIXELFORMAT_ABGR8888,
        sdl.SDL_TEXTUREACCESS_STATIC,
        frame_width,
        frame_height,
    ) orelse return error.SDLCreateTextureFailed;
    defer sdl.SDL_DestroyTexture(texture);

    const pixels = try arena.allocator().alloc(u8, frame_width * frame_height * 4);
    var frame: usize = 0;
    var quit = false;
    while (!quit and frame < run_frames) : (frame += 1) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl.SDL_QUIT) quit = true;
        }

        fillTestFrame(pixels, frame_width, frame_height, frame);
        if (sdl.SDL_UpdateTexture(texture, null, pixels.ptr, frame_width * 4) != 0) return error.SDLUpdateTextureFailed;
        _ = sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
