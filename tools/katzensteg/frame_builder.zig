const std = @import("std");
const sdl = @import("katzensteg_sdl");
const termscene = @import("termscene");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;

const ts_types = termscene.types;
const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;

const bg_namespace: u24 = 210;
const sprite_namespace: u24 = 211;

const RendererState = struct {
    window_w: i32,
    window_h: i32,
    clear_color: [4]u8 = .{ 0, 0, 0, 255 },
    had_clear: bool = false,
    copies: std.ArrayList(RenderCopyOp),

    fn init(_: std.mem.Allocator, window_w: i32, window_h: i32) RendererState {
        return .{ .window_w = window_w, .window_h = window_h, .copies = std.ArrayList(RenderCopyOp).empty };
    }

    fn deinit(self: *RendererState, allocator: std.mem.Allocator) void {
        self.copies.deinit(allocator);
    }
};

const TextureRecord = struct {
    w: i32,
    h: i32,
    format: sdl.Uint32,
    image_id: u32,
};

const WindowRecord = struct {
    w: i32,
    h: i32,
};

const RenderCopyOp = struct {
    texture_key: usize,
    src: sdl.SDL_Rect,
    dst: sdl.SDL_Rect,
};

pub const FrameBuilder = struct {
    allocator: std.mem.Allocator,
    windows: std.AutoHashMap(usize, WindowRecord),
    renderers: std.AutoHashMap(usize, RendererState),
    textures: std.AutoHashMap(usize, TextureRecord),
    solid_images: std.AutoHashMap(u32, u32),
    next_image_id: u32 = 5000,

    pub fn init(allocator: std.mem.Allocator) FrameBuilder {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(usize, WindowRecord).init(allocator),
            .renderers = std.AutoHashMap(usize, RendererState).init(allocator),
            .textures = std.AutoHashMap(usize, TextureRecord).init(allocator),
            .solid_images = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *FrameBuilder) void {
        var it = self.renderers.valueIterator();
        while (it.next()) |state| state.deinit(self.allocator);
        self.windows.deinit();
        self.renderers.deinit();
        self.textures.deinit();
        self.solid_images.deinit();
    }

    pub fn onCreateWindow(self: *FrameBuilder, window: ?*sdl.SDL_Window, w: i32, h: i32) void {
        const key = ptrKey(window);
        if (key == 0) return;
        self.windows.put(key, .{ .w = w, .h = h }) catch {};
    }

    pub fn onCreateRenderer(self: *FrameBuilder, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) void {
        const renderer_key = ptrKey(renderer);
        const window_key = ptrKey(window);
        if (renderer_key == 0) return;
        const dims = self.windows.get(window_key) orelse WindowRecord{ .w = 640, .h = 480 };
        self.renderers.put(renderer_key, RendererState.init(self.allocator, dims.w, dims.h)) catch {};
    }

    pub fn onDestroyRenderer(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer) void {
        const key = ptrKey(renderer);
        if (self.renderers.fetchRemove(key)) |entry| {
            var state = entry.value;
            state.deinit(self.allocator);
        }
    }

    pub fn onCreateTexture(self: *FrameBuilder, texture: ?*sdl.SDL_Texture, format: sdl.Uint32, w: i32, h: i32) void {
        const key = ptrKey(texture);
        if (key == 0) return;
        self.textures.put(key, .{ .w = w, .h = h, .format = format, .image_id = self.allocImageId() }) catch {};
    }

    pub fn onDestroyTexture(self: *FrameBuilder, texture: ?*sdl.SDL_Texture) void {
        _ = self.textures.remove(ptrKey(texture));
    }

    pub fn onUpdateTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
        const key = ptrKey(texture);
        const record = self.textures.get(key) orelse return;
        if (rect != null) {
            logger.writeOnce("katzensteg: partial SDL_UpdateTexture rects are not supported in slice 1");
            return;
        }
        if (record.format != sdl.SDL_PIXELFORMAT_ABGR8888) {
            logger.writeOnce("katzensteg: only SDL_PIXELFORMAT_ABGR8888 textures are supported in slice 1");
            return;
        }
        if (pixels == null) return;
        if (pitch != record.w * 4) {
            logger.writeOnce("katzensteg: only tightly packed SDL_UpdateTexture uploads are supported in slice 1");
            return;
        }
        const src: [*]const u8 = @ptrCast(pixels.?);
        const len: usize = @intCast(record.w * record.h * 4);
        const rgba = self.allocator.alloc(u8, len) catch return;
        defer self.allocator.free(rgba);
        convertAbgrToRgba(rgba, src[0..len]);
        backend.registerRawImage(record.image_id, rgba, record.w, record.h) catch |err| {
            logger.writeFmt("katzensteg: registerRawImage failed: {any}", .{err});
        };
    }

    pub fn onSetRenderDrawColor(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.clear_color = .{ r, g, b, a };
    }

    pub fn onRenderClear(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.had_clear = true;
        state.copies.clearRetainingCapacity();
    }

    pub fn onRenderCopy(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        const texture_key = ptrKey(texture);
        const record = self.textures.get(texture_key) orelse return;
        if (dst == null) {
            logger.writeOnce("katzensteg: null destination rects are not supported in slice 1");
            return;
        }
        const src_rect = src orelse &sdl.SDL_Rect{ .x = 0, .y = 0, .w = record.w, .h = record.h };
        state.copies.append(self.allocator, .{ .texture_key = texture_key, .src = src_rect.*, .dst = dst.?.* }) catch {};
    }

    pub fn onRenderPresent(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, renderer: ?*sdl.SDL_Renderer) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;

        engine.beginScene();
        if (state.had_clear) {
            const bg_image_id = self.ensureSolidImage(logger, backend, state.clear_color);
            const bg_image: ts_types.ImageHandle = @enumFromInt(bg_image_id);
            engine.sprite(.{
                .key = ts_types.NodeKey.sprite(bg_namespace, 1),
                .image = bg_image,
                .source_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                .dest_rect = .{ .col = 1, .row = 1, .w = tty.cols, .h = tty.rows },
                .z = -100,
            }) catch {};
        }

        for (state.copies.items, 0..) |copy, i| {
            const texture = self.textures.get(copy.texture_key) orelse continue;
            const dest = mapRectToCells(copy.dst, state.window_w, state.window_h, tty.cols, tty.rows);
            const image: ts_types.ImageHandle = @enumFromInt(texture.image_id);
            engine.sprite(.{
                .key = ts_types.NodeKey.sprite(sprite_namespace, @as(u32, @intCast(i + 1))),
                .image = image,
                .source_rect = .{ .x = copy.src.x, .y = copy.src.y, .w = copy.src.w, .h = copy.src.h },
                .dest_rect = dest,
                .z = @intCast(i),
            }) catch {};
        }

        engine.diff() catch |err| {
            logger.writeFmt("katzensteg: scene diff failed: {any}", .{err});
            state.copies.clearRetainingCapacity();
            return;
        };
        backend.applySpriteOps(engine.sprite_ops.items) catch |err| logger.writeFmt("katzensteg: applySpriteOps failed: {any}", .{err});
        engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed: {any}", .{err});
        state.copies.clearRetainingCapacity();
    }

    fn allocImageId(self: *FrameBuilder) u32 {
        const id = self.next_image_id;
        self.next_image_id += 1;
        return id;
    }

    fn ensureSolidImage(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, color: [4]u8) u32 {
        const key = std.mem.readInt(u32, &color, .little);
        if (self.solid_images.get(key)) |image_id| return image_id;
        const image_id = self.allocImageId();
        const pixel = [_]u8{ color[0], color[1], color[2], color[3] };
        backend.registerRawImage(image_id, &pixel, 1, 1) catch |err| logger.writeFmt("katzensteg: solid image upload failed: {any}", .{err});
        self.solid_images.put(key, image_id) catch {};
        return image_id;
    }

    fn ptrKey(ptr: anytype) usize {
        return if (ptr) |p| @intFromPtr(p) else 0;
    }

    fn convertAbgrToRgba(dst: []u8, src: []const u8) void {
        var i: usize = 0;
        while (i < src.len) : (i += 4) {
            dst[i + 0] = src[i + 3];
            dst[i + 1] = src[i + 2];
            dst[i + 2] = src[i + 1];
            dst[i + 3] = src[i + 0];
        }
    }

    fn mapRectToCells(dst: sdl.SDL_Rect, window_w: i32, window_h: i32, tty_cols: u16, tty_rows: u16) ts_types.CellRect {
        const cols: i32 = @intCast(tty_cols);
        const rows: i32 = @intCast(tty_rows);
        const col = 1 + @divTrunc(dst.x * cols, @max(window_w, 1));
        const row = 1 + @divTrunc(dst.y * rows, @max(window_h, 1));
        const w = @max(1, @divTrunc(dst.w * cols, @max(window_w, 1)));
        const h = @max(1, @divTrunc(dst.h * rows, @max(window_h, 1)));
        return .{ .col = col, .row = row, .w = w, .h = h };
    }
};
