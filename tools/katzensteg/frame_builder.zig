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
const fill_namespace: u24 = 212;

const RendererState = struct {
    window_w: i32,
    window_h: i32,
    draw_color: [4]u8 = .{ 0, 0, 0, 255 },
    clear_color: [4]u8 = .{ 0, 0, 0, 255 },
    had_clear: bool = false,
    last_logged_bg_image_id: u32 = 0,
    copies: std.ArrayList(RenderCopyOp),
    fills: std.ArrayList(FillRectOp),
    lines: std.ArrayList(LineOp),

    fn init(_: std.mem.Allocator, window_w: i32, window_h: i32) RendererState {
        return .{
            .window_w = window_w,
            .window_h = window_h,
            .copies = std.ArrayList(RenderCopyOp).empty,
            .fills = std.ArrayList(FillRectOp).empty,
            .lines = std.ArrayList(LineOp).empty,
        };
    }

    fn deinit(self: *RendererState, allocator: std.mem.Allocator) void {
        self.copies.deinit(allocator);
        self.fills.deinit(allocator);
        self.lines.deinit(allocator);
    }
};

const TextureRecord = struct {
    w: i32,
    h: i32,
    format: sdl.Uint32,
    image_id: u32,
    base_rgba: ?[]u8 = null,
    color_mod: [3]u8 = .{ 255, 255, 255 },
    alpha_mod: u8 = 255,
    blend_mode: i32 = sdl.SDL_BLENDMODE_NONE,
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

const FillRectOp = struct {
    rect: sdl.SDL_Rect,
    color: [4]u8,
};

const LineOp = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
    color: [4]u8,
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
        var tex_it = self.textures.valueIterator();
        while (tex_it.next()) |tex| if (tex.base_rgba) |buf| self.allocator.free(buf);
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
        const key = ptrKey(texture);
        if (self.textures.fetchRemove(key)) |entry| {
            if (entry.value.base_rgba) |buf| self.allocator.free(buf);
        }
    }

    pub fn onUpdateTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
        const key = ptrKey(texture);
        const record = self.textures.getPtr(key) orelse return;
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
        if (record.base_rgba) |old| self.allocator.free(old);
        record.base_rgba = self.allocator.dupe(u8, rgba) catch null;
        self.uploadTexture(logger, backend, record, rgba);
    }

    pub fn onCreateTextureFromSurface(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, surface: ?*sdl.SDL_Surface) void {
        const key = ptrKey(texture);
        const record = self.textures.getPtr(key) orelse return;
        if (surface == null) return;
        const converted = sdl.SDL_ConvertSurfaceFormat(surface, sdl.SDL_PIXELFORMAT_ABGR8888, 0) orelse {
            logger.writeOnce("katzensteg: SDL_ConvertSurfaceFormat failed for CreateTextureFromSurface");
            return;
        };
        defer sdl.SDL_FreeSurface(converted);
        const surf: *SurfaceView = @ptrCast(@alignCast(converted));
        record.w = surf.w;
        record.h = surf.h;
        record.format = sdl.SDL_PIXELFORMAT_ABGR8888;
        const len: usize = @intCast(surf.h * surf.pitch);
        const rgba = self.allocator.alloc(u8, len) catch return;
        defer self.allocator.free(rgba);
        const src: [*]const u8 = @ptrCast(surf.pixels.?);
        convertAbgrToRgba(rgba, src[0..len]);
        if (record.base_rgba) |old| self.allocator.free(old);
        record.base_rgba = self.allocator.dupe(u8, rgba) catch null;
        self.uploadTexture(logger, backend, record, rgba);
    }

    pub fn onSetTextureColorMod(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, r: u8, g: u8, b: u8) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        record.color_mod = .{ r, g, b };
        self.reuploadTexture(logger, backend, record);
    }

    pub fn onSetTextureAlphaMod(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, a: u8) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        record.alpha_mod = a;
        self.reuploadTexture(logger, backend, record);
    }

    pub fn onSetTextureBlendMode(self: *FrameBuilder, logger: *Logger, texture: ?*sdl.SDL_Texture, blend_mode: i32) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        record.blend_mode = blend_mode;
        if (blend_mode != sdl.SDL_BLENDMODE_NONE and blend_mode != sdl.SDL_BLENDMODE_BLEND) {
            logger.writeOnce("katzensteg: unsupported SDL texture blend mode; mirroring may be inaccurate");
        }
    }

    fn uploadTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, record: *TextureRecord, rgba: []const u8) void {
        const modulated = self.allocator.alloc(u8, rgba.len) catch return;
        defer self.allocator.free(modulated);
        applyMods(modulated, rgba, record.color_mod, record.alpha_mod);
        backend.registerRawImage(record.image_id, modulated, record.w, record.h) catch |err| {
            logger.writeFmt("katzensteg: registerRawImage failed: {any}", .{err});
        };
    }

    pub fn onSetRenderDrawColor(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.draw_color = .{ r, g, b, a };
    }

    pub fn onRenderClear(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.had_clear = true;
        state.clear_color = state.draw_color;
        state.copies.clearRetainingCapacity();
        state.fills.clearRetainingCapacity();
        state.lines.clearRetainingCapacity();
    }

    pub fn onRenderFillRect(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        const fill = rect orelse &sdl.SDL_Rect{ .x = 0, .y = 0, .w = state.window_w, .h = state.window_h };
        state.fills.append(self.allocator, .{ .rect = fill.*, .color = state.draw_color }) catch {};
    }

    pub fn onRenderDrawPoint(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, x: i32, y: i32) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.fills.append(self.allocator, .{ .rect = .{ .x = x, .y = y, .w = 1, .h = 1 }, .color = state.draw_color }) catch {};
    }

    pub fn onRenderDrawLine(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, x1: i32, y1: i32, x2: i32, y2: i32) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        if (x1 != x2 and y1 != y2) {
            logger.writeOnce("katzensteg: diagonal SDL_RenderDrawLine mirroring not implemented yet; skipping line");
            return;
        }
        state.lines.append(self.allocator, .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = state.draw_color }) catch {};
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

    pub fn onRenderPresent(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, renderer: ?*sdl.SDL_Renderer, bg_only: bool) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;

        engine.beginScene();
        if (state.had_clear) {
            const bg_image_id = self.ensureSolidImage(logger, backend, state.clear_color);
            if (bg_image_id != state.last_logged_bg_image_id) {
                logger.writeFmt(
                    "katzensteg: bg clear=rgba({d},{d},{d},{d}) image_id={d}",
                    .{ state.clear_color[0], state.clear_color[1], state.clear_color[2], state.clear_color[3], bg_image_id },
                );
                state.last_logged_bg_image_id = bg_image_id;
            }
            const bg_image: ts_types.ImageHandle = @enumFromInt(bg_image_id);
            engine.sprite(.{
                .key = ts_types.NodeKey.sprite(bg_namespace, 1),
                .image = bg_image,
                .source_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                .dest_rect = .{ .col = 1, .row = 1, .w = tty.cols, .h = tty.rows },
                .z = -100,
            }) catch {};
        }

        if (!bg_only) {
            for (state.fills.items, 0..) |fill, i| {
                const fill_image_id = self.ensureSolidImage(logger, backend, fill.color);
                const fill_image: ts_types.ImageHandle = @enumFromInt(fill_image_id);
                const fill_dest = mapRectToCells(fill.rect, state.window_w, state.window_h, tty.cols, tty.rows);
                engine.sprite(.{
                    .key = ts_types.NodeKey.sprite(fill_namespace, @as(u32, @intCast(i + 1))),
                    .image = fill_image,
                    .source_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                    .dest_rect = fill_dest,
                    .z = 0,
                }) catch {};
            }

            for (state.lines.items, 0..) |line, i| {
                const line_image_id = self.ensureSolidImage(logger, backend, line.color);
                const line_image: ts_types.ImageHandle = @enumFromInt(line_image_id);
                const line_dest = mapLineToCells(line, state.window_w, state.window_h, tty.cols, tty.rows);
                engine.sprite(.{
                    .key = ts_types.NodeKey.sprite(fill_namespace, @as(u32, @intCast(state.fills.items.len + i + 1))),
                    .image = line_image,
                    .source_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
                    .dest_rect = line_dest,
                    .z = 1,
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
                    .z = @intCast(100 + i),
                }) catch {};
            }
        }

        engine.diff() catch |err| {
            logger.writeFmt("katzensteg: scene diff failed: {any}", .{err});
            state.copies.clearRetainingCapacity();
            state.fills.clearRetainingCapacity();
            state.lines.clearRetainingCapacity();
            return;
        };
        if (state.had_clear and engine.sprite_ops.items.len > 0) {
            for (engine.sprite_ops.items) |op| {
                if (op.key.namespace == bg_namespace and op.key.id == 1) {
                    logger.writeFmt("katzensteg: bg sprite op={s} total_sprite_ops={d}", .{ @tagName(op.tag), engine.sprite_ops.items.len });
                    break;
                }
            }
        }
        backend.applySpriteOps(engine.sprite_ops.items) catch |err| logger.writeFmt("katzensteg: applySpriteOps failed: {any}", .{err});
        engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed: {any}", .{err});
        state.copies.clearRetainingCapacity();
        state.fills.clearRetainingCapacity();
        state.lines.clearRetainingCapacity();
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

    fn reuploadTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, record: *TextureRecord) void {
        const base = record.base_rgba orelse return;
        self.uploadTexture(logger, backend, record, base);
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

    fn applyMods(dst: []u8, src: []const u8, color_mod: [3]u8, alpha_mod: u8) void {
        var i: usize = 0;
        while (i < src.len) : (i += 4) {
            dst[i + 0] = @intCast((@as(u16, src[i + 0]) * color_mod[0]) / 255);
            dst[i + 1] = @intCast((@as(u16, src[i + 1]) * color_mod[1]) / 255);
            dst[i + 2] = @intCast((@as(u16, src[i + 2]) * color_mod[2]) / 255);
            dst[i + 3] = @intCast((@as(u16, src[i + 3]) * alpha_mod) / 255);
        }
    }

    const SurfaceView = extern struct {
        flags: u32,
        format: ?*anyopaque,
        w: i32,
        h: i32,
        pitch: i32,
        pixels: ?*anyopaque,
        userdata: ?*anyopaque,
        locked: i32,
        lock_data: ?*anyopaque,
        clip_rect: sdl.SDL_Rect,
        map: ?*anyopaque,
        refcount: i32,
    };

    fn mapRectToCells(dst: sdl.SDL_Rect, window_w: i32, window_h: i32, tty_cols: u16, tty_rows: u16) ts_types.CellRect {
        const cols: i32 = @intCast(tty_cols);
        const rows: i32 = @intCast(tty_rows);
        const col = 1 + @divTrunc(dst.x * cols, @max(window_w, 1));
        const row = 1 + @divTrunc(dst.y * rows, @max(window_h, 1));
        const w = @max(1, @divTrunc(dst.w * cols, @max(window_w, 1)));
        const h = @max(1, @divTrunc(dst.h * rows, @max(window_h, 1)));
        return .{ .col = col, .row = row, .w = w, .h = h };
    }

    fn mapLineToCells(line: LineOp, window_w: i32, window_h: i32, tty_cols: u16, tty_rows: u16) ts_types.CellRect {
        const min_x = @min(line.x1, line.x2);
        const min_y = @min(line.y1, line.y2);
        const max_x = @max(line.x1, line.x2);
        const max_y = @max(line.y1, line.y2);
        return mapRectToCells(.{ .x = min_x, .y = min_y, .w = @max(1, max_x - min_x + 1), .h = @max(1, max_y - min_y + 1) }, window_w, window_h, tty_cols, tty_rows);
    }
};
