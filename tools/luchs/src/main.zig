const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("katzensteg_sdl");

const frame_width = 800;
const frame_height = 600;
const run_frames = 180;
const native_webview_fps = 15;

const RendererBackend = enum {
    test_pattern,
    native_webview,
};

const PixelFormat = enum {
    rgba8,
};

const RawFrameHeader = struct {
    format: PixelFormat,
    width: u32,
    height: u32,
    stride: usize,
    len: usize,
};

const RawFrame = struct {
    header: RawFrameHeader,
    pixels: []u8,
};

const RawFrameHeaderPayload = struct {
    format: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    len: usize,
};

const CliOptions = struct {
    html_path: []const u8,
    renderer_backend: RendererBackend = .test_pattern,
};

fn parseRendererBackend(value: []const u8) !RendererBackend {
    if (std.mem.eql(u8, value, "test-pattern")) return .test_pattern;
    if (std.mem.eql(u8, value, "native-webview")) return .native_webview;
    return error.UnknownRendererBackend;
}

fn ensureRendererBackendAvailable(backend: RendererBackend) !void {
    switch (backend) {
        .test_pattern => {},
        .native_webview => if (builtin.os.tag != .macos) return error.NativeWebviewUnavailable,
    }
}

fn parsePixelFormat(value: []const u8) !PixelFormat {
    if (std.mem.eql(u8, value, "rgba8")) return .rgba8;
    return error.InvalidRawFrameHeader;
}

fn parseRawFrameHeader(line: []const u8) !RawFrameHeader {
    const prefix = "LUCHS_RAW_FRAME ";
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidRawFrameHeader;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(RawFrameHeaderPayload, arena.allocator(), line[prefix.len..], .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidRawFrameHeader;
    if (parsed.width == 0 or parsed.height == 0) return error.InvalidRawFrameHeader;
    if (parsed.stride < @as(usize, parsed.width) * 4) return error.InvalidRawFrameHeader;
    if (parsed.len < parsed.stride * @as(usize, parsed.height)) return error.InvalidRawFrameHeader;
    return .{
        .format = try parsePixelFormat(parsed.format),
        .width = parsed.width,
        .height = parsed.height,
        .stride = parsed.stride,
        .len = parsed.len,
    };
}

fn helperPathFromExePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "luchs-webview-capture" });
}

fn nativeWebviewHelperPath(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    return helperPathFromExePath(allocator, exe_path);
}

fn readLineAlloc(allocator: std.mem.Allocator, file: std.fs.File, max_len: usize) ![]u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (line.items.len < max_len) {
        const n = try file.read(&byte);
        if (n == 0) return error.EndOfStream;
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }
    return error.RawFrameHeaderTooLong;
}

fn readExactFile(file: std.fs.File, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try file.read(buf[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn readRawFrameFromFile(allocator: std.mem.Allocator, file: std.fs.File) !RawFrame {
    const line = try readLineAlloc(allocator, file, 4096);
    defer allocator.free(line);
    const header = try parseRawFrameHeader(line);
    const pixels = try allocator.alloc(u8, header.len);
    errdefer allocator.free(pixels);
    try readExactFile(file, pixels);
    return .{ .header = header, .pixels = pixels };
}

fn freeRawFrame(allocator: std.mem.Allocator, frame: RawFrame) void {
    allocator.free(frame.pixels);
}

const NativeWebviewStream = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdout_file: std.fs.File,
    waited: bool = false,

    fn init(allocator: std.mem.Allocator, html_path: []const u8) !NativeWebviewStream {
        const helper_path = try nativeWebviewHelperPath(allocator);
        defer allocator.free(helper_path);

        var width_buf: [16]u8 = undefined;
        var height_buf: [16]u8 = undefined;
        var frames_buf: [16]u8 = undefined;
        var fps_buf: [16]u8 = undefined;
        const width_arg = try std.fmt.bufPrint(&width_buf, "{d}", .{frame_width});
        const height_arg = try std.fmt.bufPrint(&height_buf, "{d}", .{frame_height});
        const frames_arg = try std.fmt.bufPrint(&frames_buf, "{d}", .{run_frames});
        const fps_arg = try std.fmt.bufPrint(&fps_buf, "{d}", .{native_webview_fps});

        var argv = [_][]const u8{ helper_path, html_path, width_arg, height_arg, frames_arg, fps_arg };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        errdefer _ = child.kill() catch {};

        const stdout_file = child.stdout orelse return error.NativeWebviewCaptureFailed;
        child.stdout = null;

        return .{
            .allocator = allocator,
            .child = child,
            .stdout_file = stdout_file,
        };
    }

    fn deinit(self: *NativeWebviewStream) void {
        self.stdout_file.close();
        if (!self.waited) {
            _ = self.child.kill() catch {};
            self.waited = true;
        }
    }

    fn nextFrame(self: *NativeWebviewStream) !?RawFrame {
        return readRawFrameFromFile(self.allocator, self.stdout_file) catch |err| switch (err) {
            error.EndOfStream => {
                const term = try self.child.wait();
                self.waited = true;
                switch (term) {
                    .Exited => |code| if (code == 0) return null else return error.NativeWebviewCaptureFailed,
                    else => return error.NativeWebviewCaptureFailed,
                }
            },
            else => return err,
        };
    }
};

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
    var options = CliOptions{ .html_path = "" };
    var html_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        const renderer_prefix = "--renderer=";
        if (std.mem.startsWith(u8, arg, renderer_prefix)) {
            options.renderer_backend = try parseRendererBackend(arg[renderer_prefix.len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.Usage;
        if (html_path != null) return error.Usage;
        html_path = arg;
    }
    options.html_path = html_path orelse return error.Usage;
    return options;
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

test "parseRendererBackend accepts only supported renderer backends" {
    try std.testing.expectEqual(RendererBackend.test_pattern, try parseRendererBackend("test-pattern"));
    try std.testing.expectEqual(RendererBackend.native_webview, try parseRendererBackend("native-webview"));
    try std.testing.expectError(error.UnknownRendererBackend, parseRendererBackend("cdp"));
}

test "luchs accepts explicit renderer backend option" {
    const opts = try parseArgs(&.{ "luchs", "--renderer=native-webview", "tools/luchs/testdata/static.html" });
    try std.testing.expectEqual(RendererBackend.native_webview, opts.renderer_backend);
    try std.testing.expectEqualStrings("tools/luchs/testdata/static.html", opts.html_path);
}

test "native webview renderer is available on macOS only" {
    try ensureRendererBackendAvailable(.test_pattern);
    if (builtin.os.tag == .macos) {
        try ensureRendererBackendAvailable(.native_webview);
    } else {
        try std.testing.expectError(error.NativeWebviewUnavailable, ensureRendererBackendAvailable(.native_webview));
    }
}

test "parseRawFrameHeader parses raw rgba frame metadata" {
    const header = "LUCHS_RAW_FRAME {\"format\":\"rgba8\",\"width\":2,\"height\":1,\"stride\":8,\"len\":8}";
    const frame = try parseRawFrameHeader(header);
    try std.testing.expectEqual(PixelFormat.rgba8, frame.format);
    try std.testing.expectEqual(@as(u32, 2), frame.width);
    try std.testing.expectEqual(@as(u32, 1), frame.height);
    try std.testing.expectEqual(@as(usize, 8), frame.stride);
    try std.testing.expectEqual(@as(usize, 8), frame.len);
}

test "parseRawFrameHeader rejects encoded image frames" {
    const header = "LUCHS_RAW_FRAME {\"format\":\"png\",\"width\":2,\"height\":1,\"stride\":8,\"len\":8}";
    try std.testing.expectError(error.InvalidRawFrameHeader, parseRawFrameHeader(header));
}

test "helperPathFromExePath resolves sibling helper" {
    const path = try helperPathFromExePath(std.testing.allocator, "/tmp/zig-out/bin/luchs");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/zig-out/bin/luchs-webview-capture", path);
}

test "native webview stream uses bounded frame cadence" {
    try std.testing.expect(run_frames > 1);
    try std.testing.expect(native_webview_fps > 0);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    const options = try parseArgs(args);
    try ensureRendererBackendAvailable(options.renderer_backend);

    const frame_allocator = std.heap.page_allocator;
    var native_stream: ?NativeWebviewStream = switch (options.renderer_backend) {
        .test_pattern => null,
        .native_webview => try NativeWebviewStream.init(frame_allocator, options.html_path),
    };
    defer if (native_stream) |*stream| stream.deinit();

    var pending_native_frame: ?RawFrame = if (native_stream) |*stream|
        try stream.nextFrame() orelse return error.NativeWebviewCaptureFailed
    else
        null;
    defer if (pending_native_frame) |frame| freeRawFrame(frame_allocator, frame);

    const window_width: u32 = if (pending_native_frame) |frame| frame.header.width else frame_width;
    const window_height: u32 = if (pending_native_frame) |frame| frame.header.height else frame_height;

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) != 0) return error.SDLInitFailed;
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow(
        "luchs",
        sdl.SDL_WINDOWPOS_CENTERED,
        sdl.SDL_WINDOWPOS_CENTERED,
        @intCast(window_width),
        @intCast(window_height),
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
        @intCast(window_width),
        @intCast(window_height),
    ) orelse return error.SDLCreateTextureFailed;
    defer sdl.SDL_DestroyTexture(texture);

    const pixels = try arena.allocator().alloc(u8, @as(usize, window_width) * @as(usize, window_height) * 4);
    var frame: usize = 0;
    var quit = false;
    while (!quit and frame < run_frames) : (frame += 1) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl.SDL_QUIT) quit = true;
        }

        var frame_to_free: ?RawFrame = null;
        defer if (frame_to_free) |captured| freeRawFrame(frame_allocator, captured);
        const present_pixels, const present_pitch = if (native_stream) |*stream| native: {
            const captured = pending_native_frame orelse (try stream.nextFrame() orelse break);
            pending_native_frame = null;
            frame_to_free = captured;
            break :native .{
                captured.pixels,
                captured.header.stride,
            };
        } else .{
            blk: {
                fillTestFrame(pixels, window_width, window_height, frame);
                break :blk pixels;
            },
            @as(usize, window_width) * 4,
        };
        if (sdl.SDL_UpdateTexture(texture, null, present_pixels.ptr, @intCast(present_pitch)) != 0) return error.SDLUpdateTextureFailed;
        _ = sdl.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, texture, null, null);
        sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
