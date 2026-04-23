const std = @import("std");
const sdl = @import("katzensteg_sdl");
const termscene = @import("termscene");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;

const ts_types = termscene.types;
const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;
const kitty_protocol = termscene.kitty.protocol;

const bg_namespace: u24 = 210;
const sprite_namespace: u24 = 211;
const fill_namespace: u24 = 212;
const composite_tile_cols: i32 = 8;
const composite_tile_rows: i32 = 4;
const composite_strip_max_w: i32 = 4096;

const CompositeStripEntry = struct {
    tile_index: usize,
    x: i32,
};

const CompositeTileState = struct {
    src_rect: sdl.SDL_Rect,
    dest_rect: ts_types.CellRect,
    image_id: u32 = 0,
    placement_id: u32 = 0,
};

const RendererState = struct {
    window_w: i32,
    window_h: i32,
    viewport: sdl.SDL_Rect,
    clip_rect: ?sdl.SDL_Rect = null,
    draw_color: [4]u8 = .{ 0, 0, 0, 255 },
    clear_color: [4]u8 = .{ 0, 0, 0, 255 },
    had_clear: bool = false,
    last_logged_bg_image_id: u32 = 0,
    composite_mode_active: bool = false,
    force_composite: bool = false,
    composite_image_id: u32 = 0,
    composite_placement_id: u32 = 0,
    composite_rgba: ?[]u8 = null,
    composite_last_presented: ?[]u8 = null,
    composite_tiles: std.ArrayList(CompositeTileState),
    copies: std.ArrayList(RenderCopyOp),
    fills: std.ArrayList(FillRectOp),
    lines: std.ArrayList(LineOp),

    fn init(_: std.mem.Allocator, window_w: i32, window_h: i32) RendererState {
        return .{
            .window_w = window_w,
            .window_h = window_h,
            .viewport = .{ .x = 0, .y = 0, .w = window_w, .h = window_h },
            .composite_tiles = std.ArrayList(CompositeTileState).empty,
            .copies = std.ArrayList(RenderCopyOp).empty,
            .fills = std.ArrayList(FillRectOp).empty,
            .lines = std.ArrayList(LineOp).empty,
        };
    }

    fn deinit(self: *RendererState, allocator: std.mem.Allocator) void {
        if (self.composite_rgba) |buf| allocator.free(buf);
        if (self.composite_last_presented) |buf| allocator.free(buf);
        self.composite_tiles.deinit(allocator);
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
    locked_pixels: ?[*]u8 = null,
    locked_pitch: i32 = 0,
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

pub const CompositeMode = enum {
    fullscreen,
    tiled_strip,
};

const Stats = struct {
    enabled: bool = false,
    frame_count: u64 = 0,
    texture_uploads: u64 = 0,
    texture_upload_bytes: u64 = 0,
    retired_images: u64 = 0,
    sprite_ops: u64 = 0,
    copy_ops: u64 = 0,
    fill_ops: u64 = 0,
    line_ops: u64 = 0,
    last_report_ns: i128 = 0,
};

pub const FrameBuilder = struct {
    allocator: std.mem.Allocator,
    windows: std.AutoHashMap(usize, WindowRecord),
    renderers: std.AutoHashMap(usize, RendererState),
    textures: std.AutoHashMap(usize, TextureRecord),
    solid_images: std.AutoHashMap(u32, u32),
    retired_image_ids: std.ArrayList(u32),
    stats: Stats,
    composite_mode: CompositeMode = .tiled_strip,
    dump_composites: bool = false,
    debug_composite: bool = false,
    next_image_id: u32 = 5000,
    last_composite_dump_ns: i128 = 0,
    last_composite_image_id: u32 = 0,
    next_composite_placement_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, stats_enabled: bool, composite_mode: CompositeMode, dump_composites: bool, debug_composite: bool) FrameBuilder {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(usize, WindowRecord).init(allocator),
            .renderers = std.AutoHashMap(usize, RendererState).init(allocator),
            .textures = std.AutoHashMap(usize, TextureRecord).init(allocator),
            .solid_images = std.AutoHashMap(u32, u32).init(allocator),
            .retired_image_ids = .empty,
            .stats = .{ .enabled = stats_enabled, .last_report_ns = std.time.nanoTimestamp() },
            .composite_mode = composite_mode,
            .dump_composites = dump_composites,
            .debug_composite = debug_composite,
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
        self.retired_image_ids.deinit(self.allocator);
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
        self.textures.put(key, .{ .w = w, .h = h, .format = format, .image_id = 0 }) catch {};
    }

    pub fn onDestroyTexture(self: *FrameBuilder, texture: ?*sdl.SDL_Texture) void {
        const key = ptrKey(texture);
        if (self.textures.fetchRemove(key)) |entry| {
            if (entry.value.base_rgba) |buf| self.allocator.free(buf);
            self.retireImageId(entry.value.image_id);
        }
    }

    pub fn onUpdateTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*const anyopaque, pitch: i32) void {
        const key = ptrKey(texture);
        const record = self.textures.getPtr(key) orelse return;
        if (rect != null) {
            logger.writeOnce("katzensteg: partial SDL_UpdateTexture rects are not supported in this slice");
            return;
        }
        if (pixels == null) return;
        self.captureTexturePixels(logger, backend, record, @ptrCast(@constCast(pixels.?)), pitch);
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
        const src: [*]u8 = @ptrCast(surf.pixels.?);
        self.captureTexturePixels(logger, backend, record, src, surf.pitch);
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
        logger.writeFmt("katzensteg: SDL_SetTextureBlendMode texture={x} mode={s} ({d})", .{ ptrKey(texture), blendModeName(blend_mode), blend_mode });
        if (blend_mode != sdl.SDL_BLENDMODE_NONE and blend_mode != sdl.SDL_BLENDMODE_BLEND) {
            logger.writeFmt("katzensteg: unsupported SDL texture blend mode {s} ({d}); some compositions may require framebuffer-side compositing before terminal upload", .{ blendModeName(blend_mode), blend_mode });
            var renderer_it = self.renderers.valueIterator();
            while (renderer_it.next()) |state| state.force_composite = true;
        }
    }

    pub fn onLockTexture(self: *FrameBuilder, logger: *Logger, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, pixels: ?*anyopaque, pitch: i32) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        if (rect != null) {
            logger.writeOnce("katzensteg: partial SDL_LockTexture rects are not supported yet");
            record.locked_pixels = null;
            record.locked_pitch = 0;
            return;
        }
        if (pixels == null) return;
        record.locked_pixels = @ptrCast(pixels.?);
        record.locked_pitch = pitch;
    }

    pub fn onUnlockTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        const pixels = record.locked_pixels orelse return;
        const pitch = record.locked_pitch;
        record.locked_pixels = null;
        record.locked_pitch = 0;
        self.captureTexturePixels(logger, backend, record, pixels, pitch);
    }

    fn uploadTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, record: *TextureRecord, rgba: []const u8) void {
        const modulated = self.allocator.alloc(u8, rgba.len) catch return;
        defer self.allocator.free(modulated);
        applyMods(modulated, rgba, record.color_mod, record.alpha_mod);
        self.retireImageId(record.image_id);
        record.image_id = self.allocImageId();
        backend.registerRawImage(record.image_id, modulated, record.w, record.h) catch |err| {
            logger.writeFmt("katzensteg: registerRawImage failed: {any}", .{err});
            return;
        };
        if (self.stats.enabled) {
            self.stats.texture_uploads += 1;
            self.stats.texture_upload_bytes += rgba.len;
        }
    }

    fn captureTexturePixels(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, record: *TextureRecord, src: [*]u8, pitch: i32) void {
        const len: usize = @intCast(record.w * record.h * 4);
        const rgba = self.allocator.alloc(u8, len) catch return;
        defer self.allocator.free(rgba);
        if (!convertTextureToRgba(rgba, src, pitch, record.w, record.h, record.format)) {
            logger.writeFmt("katzensteg: unsupported texture pixel format: {d}", .{record.format});
            return;
        }
        if (record.base_rgba) |old| self.allocator.free(old);
        record.base_rgba = self.allocator.dupe(u8, rgba) catch null;
        self.uploadTexture(logger, backend, record, rgba);
    }

    pub fn onSetRenderDrawColor(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, r: u8, g: u8, b: u8, a: u8) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.draw_color = .{ r, g, b, a };
    }

    pub fn onRenderSetViewport(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.viewport = if (rect) |r| r.* else sdl.SDL_Rect{ .x = 0, .y = 0, .w = state.window_w, .h = state.window_h };
    }

    pub fn onRenderSetClipRect(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, rect: ?*const sdl.SDL_Rect) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        state.clip_rect = if (rect) |r| applyViewportRect(r.*, state.viewport) else null;
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
        const fill = rect orelse &sdl.SDL_Rect{ .x = 0, .y = 0, .w = state.viewport.w, .h = state.viewport.h };
        const mapped = applyViewportRect(fill.*, state.viewport);
        const clipped = clipRect(mapped, state.clip_rect) orelse return;
        state.fills.append(self.allocator, .{ .rect = clipped, .color = state.draw_color }) catch {};
    }

    pub fn onRenderDrawPoint(self: *FrameBuilder, renderer: ?*sdl.SDL_Renderer, x: i32, y: i32) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        const mapped = applyViewportRect(.{ .x = x, .y = y, .w = 1, .h = 1 }, state.viewport);
        const clipped = clipRect(mapped, state.clip_rect) orelse return;
        state.fills.append(self.allocator, .{ .rect = clipped, .color = state.draw_color }) catch {};
    }

    pub fn onRenderDrawLine(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, x1: i32, y1: i32, x2: i32, y2: i32) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        if (x1 != x2 and y1 != y2) {
            logger.writeOnce("katzensteg: diagonal SDL_RenderDrawLine mirroring not implemented yet; skipping line");
            return;
        }
        const mapped = LineOp{
            .x1 = x1 + state.viewport.x,
            .y1 = y1 + state.viewport.y,
            .x2 = x2 + state.viewport.x,
            .y2 = y2 + state.viewport.y,
            .color = state.draw_color,
        };
        const line_rect = sdl.SDL_Rect{
            .x = @min(mapped.x1, mapped.x2),
            .y = @min(mapped.y1, mapped.y2),
            .w = @max(1, @max(mapped.x1, mapped.x2) - @min(mapped.x1, mapped.x2) + 1),
            .h = @max(1, @max(mapped.y1, mapped.y2) - @min(mapped.y1, mapped.y2) + 1),
        };
        if (clipRect(line_rect, state.clip_rect) == null) return;
        state.lines.append(self.allocator, mapped) catch {};
    }

    pub fn onRenderCopy(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect) void {
        self.recordRenderCopy(logger, renderer, texture, src, dst);
    }

    pub fn onRenderCopyEx(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect, angle: f64, center: ?*const sdl.SDL_Point, flip: c_int) void {
        _ = center;
        if (angle != 0 or flip != sdl.SDL_FLIP_NONE) {
            logger.writeOnce("katzensteg: SDL_RenderCopyEx rotation/flip not implemented; approximating as SDL_RenderCopy");
        }
        self.recordRenderCopy(logger, renderer, texture, src, dst);
    }

    fn recordRenderCopy(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, src: ?*const sdl.SDL_Rect, dst: ?*const sdl.SDL_Rect) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        const texture_key = ptrKey(texture);
        const record = self.textures.get(texture_key) orelse return;
        if (record.blend_mode != sdl.SDL_BLENDMODE_NONE and record.blend_mode != sdl.SDL_BLENDMODE_BLEND) {
            logger.writeFmt(
                "katzensteg: SDL_RenderCopy using unsupported texture blend mode {s} ({d}) tex={x} alpha_mod={d} color_mod=({d},{d},{d})",
                .{ blendModeName(record.blend_mode), record.blend_mode, texture_key, record.alpha_mod, record.color_mod[0], record.color_mod[1], record.color_mod[2] },
            );
            state.force_composite = true;
        }
        const dst_rect = dst orelse &sdl.SDL_Rect{
            .x = 0,
            .y = 0,
            .w = if (state.viewport.w > 0) state.viewport.w else state.window_w,
            .h = if (state.viewport.h > 0) state.viewport.h else state.window_h,
        };
        if (dst == null) {
            logger.writeOnce("katzensteg: null destination rect approximated to full viewport");
        }
        const src_rect = src orelse &sdl.SDL_Rect{ .x = 0, .y = 0, .w = record.w, .h = record.h };
        const mapped_dst = applyViewportRect(dst_rect.*, state.viewport);
        if (clipCopyRect(src_rect.*, mapped_dst, state.clip_rect, record.w, record.h)) |clipped| {
            state.copies.append(self.allocator, .{ .texture_key = texture_key, .src = clipped.src, .dst = clipped.dst }) catch {};
        }
    }

    pub fn onRenderPresent(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, renderer: ?*sdl.SDL_Renderer, bg_only: bool, debug_protocol_replies: bool, image_gc: bool) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;

        const use_composite = !bg_only and (state.force_composite or self.needsFramebufferComposite(state));
        state.composite_mode_active = use_composite;
        if (use_composite) {
            engine.beginScene();
            engine.diff() catch |err| {
                logger.writeFmt("katzensteg: scene diff failed while entering composite direct mode: {any}", .{err});
                state.copies.clearRetainingCapacity();
                state.fills.clearRetainingCapacity();
                state.lines.clearRetainingCapacity();
                return;
            };
            backend.applySpriteOps(engine.sprite_ops.items) catch |err| logger.writeFmt("katzensteg: applySpriteOps failed while entering composite direct mode: {any}", .{err});
            engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed while entering composite direct mode: {any}", .{err});

            self.buildCompositeFrame(logger, state) catch |err| {
                logger.writeFmt("katzensteg: buildCompositeFrame failed: {any}", .{err});
            };
            switch (self.composite_mode) {
                .fullscreen => self.presentCompositeFullscreenDirect(logger, tty, backend, state) catch |err| {
                    logger.writeFmt("katzensteg: presentCompositeFullscreenDirect failed: {any}", .{err});
                },
                .tiled_strip => self.presentCompositeTilesDirect(logger, tty, backend, state) catch |err| {
                    logger.writeFmt("katzensteg: presentCompositeTilesDirect failed: {any}", .{err});
                },
            }
            if (image_gc) self.deleteRetiredImages(logger, backend);
            if (debug_protocol_replies) self.drainKittyReplies(logger, tty);
            if (self.stats.enabled) {
                self.stats.frame_count += 1;
                self.stats.copy_ops += state.copies.items.len;
                self.stats.fill_ops += state.fills.items.len;
                self.stats.line_ops += state.lines.items.len;
                self.maybeReportStats(logger);
            }
            state.copies.clearRetainingCapacity();
            state.fills.clearRetainingCapacity();
            state.lines.clearRetainingCapacity();
            return;
        } else {
            switch (self.composite_mode) {
                .fullscreen => self.deleteCompositeFullscreenDirect(logger, tty, state),
                .tiled_strip => self.deleteCompositeTilesDirect(logger, tty, state),
            }
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
        if (image_gc) self.deleteRetiredImages(logger, backend);
        if (debug_protocol_replies) self.drainKittyReplies(logger, tty);
        engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed: {any}", .{err});
        if (self.stats.enabled) {
            self.stats.frame_count += 1;
            self.stats.sprite_ops += engine.sprite_ops.items.len;
            self.stats.copy_ops += state.copies.items.len;
            self.stats.fill_ops += state.fills.items.len;
            self.stats.line_ops += state.lines.items.len;
            self.maybeReportStats(logger);
        }
        state.copies.clearRetainingCapacity();
        state.fills.clearRetainingCapacity();
        state.lines.clearRetainingCapacity();
    }

    fn drainKittyReplies(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty) void {
        var buf: [1024]u8 = undefined;
        var b64_buf: [2048]u8 = undefined;
        while (true) {
            const n = tty.file.read(&buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    logger.writeFmt("katzensteg: failed reading kitty reply: {any}", .{err});
                    return;
                },
            };
            if (n == 0) return;
            const encoded_len = std.base64.standard.Encoder.calcSize(n);
            if (encoded_len <= b64_buf.len) {
                const b64 = std.base64.standard.Encoder.encode(b64_buf[0..encoded_len], buf[0..n]);
                logger.writeFmt("katzensteg: kitty reply b64={s}", .{b64});
            } else {
                logger.writeFmt("katzensteg: kitty reply {d} bytes (too large for inline log)", .{n});
            }
            if (self.last_composite_image_id != 0) {
                var needle_buf: [32]u8 = undefined;
                const needle = std.fmt.bufPrint(&needle_buf, "i={d}", .{self.last_composite_image_id}) catch return;
                if (std.mem.indexOf(u8, buf[0..n], needle) != null) {
                    logger.writeFmt("katzensteg: kitty reply mentions composite image_id={d}", .{self.last_composite_image_id});
                }
            }
            if (n < buf.len) return;
        }
    }

    fn presentCompositeFullscreenDirect(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, backend: *ts_kitty.Backend, state: *RendererState) !void {
        const buf = state.composite_rgba.?;
        if (state.composite_last_presented) |last| {
            if (last.len == buf.len and std.mem.eql(u8, last, buf) and state.composite_image_id != 0 and state.composite_placement_id != 0) return;
        }
        if (state.composite_last_presented == null or state.composite_last_presented.?.len != buf.len) {
            if (state.composite_last_presented) |old| self.allocator.free(old);
            state.composite_last_presented = try self.allocator.alloc(u8, buf.len);
            @memset(state.composite_last_presented.?, 0);
        }

        const old_image_id = state.composite_image_id;
        const old_placement_id = state.composite_placement_id;
        state.composite_image_id = self.allocImageId();
        state.composite_placement_id = self.next_composite_placement_id;
        self.next_composite_placement_id +%= 1;
        if (self.next_composite_placement_id == 0) self.next_composite_placement_id = 1;
        self.last_composite_image_id = state.composite_image_id;
        if (self.debug_composite) logger.writeFmt("katzensteg: composite fullscreen upload image_id={d} size={d}x{d}", .{ state.composite_image_id, state.window_w, state.window_h });
        try backend.registerRawImage(state.composite_image_id, buf, state.window_w, state.window_h);
        try kitty_protocol.writePlace(tty.file.deprecatedWriter(), 1, 1, .{
            .image_id = state.composite_image_id,
            .placement_id = state.composite_placement_id,
            .cols = tty.cols,
            .rows = tty.rows,
            .src_x = 0,
            .src_y = 0,
            .src_w = state.window_w,
            .src_h = state.window_h,
            .z = 100,
        });
        if (old_image_id != 0 and old_placement_id != 0) {
            kitty_protocol.writeDeleteExactPlacement(tty.file.deprecatedWriter(), .{ .image_id = old_image_id, .placement_id = old_placement_id }) catch |err| {
                logger.writeFmt("katzensteg: composite fullscreen delete failed: {any}", .{err});
            };
            self.retireImageId(old_image_id);
        }
        @memcpy(state.composite_last_presented.?, buf);
        if (self.stats.enabled) {
            self.stats.texture_uploads += 1;
            self.stats.texture_upload_bytes += buf.len;
        }
    }

    fn deleteCompositeFullscreenDirect(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, state: *RendererState) void {
        if (state.composite_image_id != 0 and state.composite_placement_id != 0) {
            kitty_protocol.writeDeleteExactPlacement(tty.file.deprecatedWriter(), .{ .image_id = state.composite_image_id, .placement_id = state.composite_placement_id }) catch |err| {
                logger.writeFmt("katzensteg: composite fullscreen delete failed: {any}", .{err});
            };
            self.retireImageId(state.composite_image_id);
        }
        state.composite_image_id = 0;
        state.composite_placement_id = 0;
        if (state.composite_last_presented) |last| @memset(last, 0);
    }

    fn presentCompositeTilesDirect(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, backend: *ts_kitty.Backend, state: *RendererState) !void {
        try self.ensureCompositeTiles(state, tty);
        if (state.composite_last_presented == null or state.composite_last_presented.?.len != state.composite_rgba.?.len) {
            if (state.composite_last_presented) |old| self.allocator.free(old);
            state.composite_last_presented = try self.allocator.alloc(u8, state.composite_rgba.?.len);
            @memset(state.composite_last_presented.?, 0);
            for (state.composite_tiles.items) |*tile| {
                tile.image_id = 0;
                tile.placement_id = 0;
            }
        }

        const writer = tty.file.deprecatedWriter();
        const buf = state.composite_rgba.?;
        const last = state.composite_last_presented.?;
        var changed_entries = std.ArrayList(CompositeStripEntry).empty;
        defer changed_entries.deinit(self.allocator);

        var strip_w: i32 = 0;
        var strip_h: i32 = 0;
        for (state.composite_tiles.items, 0..) |*tile, tile_index| {
            const changed = tile.placement_id == 0 or tileDiffers(buf, last, state.window_w, tile.src_rect);
            if (!changed) continue;

            if (strip_w > 0 and strip_w + tile.src_rect.w > composite_strip_max_w) {
                try self.flushCompositeStrip(logger, writer, backend, state, buf, last, changed_entries.items, strip_w, strip_h);
                changed_entries.clearRetainingCapacity();
                strip_w = 0;
                strip_h = 0;
            }
            changed_entries.append(self.allocator, .{ .tile_index = tile_index, .x = strip_w }) catch {};
            strip_w += tile.src_rect.w;
            strip_h = @max(strip_h, tile.src_rect.h);
        }
        if (changed_entries.items.len > 0) {
            try self.flushCompositeStrip(logger, writer, backend, state, buf, last, changed_entries.items, strip_w, strip_h);
        }
    }

    fn flushCompositeStrip(self: *FrameBuilder, logger: *Logger, writer: std.fs.File.DeprecatedWriter, backend: *ts_kitty.Backend, state: *RendererState, buf: []const u8, last: []u8, entries: []const CompositeStripEntry, strip_w: i32, strip_h: i32) !void {
        const strip_len: usize = @intCast(strip_w * strip_h * 4);
        const strip_rgba = try self.allocator.alloc(u8, strip_len);
        defer self.allocator.free(strip_rgba);
        @memset(strip_rgba, 0);

        for (entries) |entry| {
            const tile = &state.composite_tiles.items[entry.tile_index];
            blitTileIntoStrip(strip_rgba, strip_w, buf, state.window_w, tile.src_rect, entry.x, 0);
        }

        const strip_image_id = self.allocImageId();
        self.last_composite_image_id = strip_image_id;
        if (self.debug_composite) logger.writeFmt("katzensteg: composite strip upload image_id={d} entries={d} size={d}x{d}", .{ strip_image_id, entries.len, strip_w, strip_h });
        try backend.registerRawImage(strip_image_id, strip_rgba, strip_w, strip_h);

        for (entries) |entry| {
            const tile = &state.composite_tiles.items[entry.tile_index];
            const old_image_id = tile.image_id;
            const old_placement_id = tile.placement_id;
            tile.placement_id = self.next_composite_placement_id;
            self.next_composite_placement_id +%= 1;
            if (self.next_composite_placement_id == 0) self.next_composite_placement_id = 1;
            tile.image_id = strip_image_id;
            const dest = tile.dest_rect;
            if (self.debug_composite) logger.writeFmt("katzensteg: composite tile place image_id={d} placement_id={d} tile={d} src={d},0 {d}x{d} cell={d},{d} {d}x{d}", .{ strip_image_id, tile.placement_id, entry.tile_index, entry.x, tile.src_rect.w, tile.src_rect.h, dest.col, dest.row, dest.w, dest.h });
            try kitty_protocol.writePlace(writer, dest.row, dest.col, .{
                .image_id = strip_image_id,
                .placement_id = tile.placement_id,
                .cols = dest.w,
                .rows = dest.h,
                .src_x = entry.x,
                .src_y = 0,
                .src_w = tile.src_rect.w,
                .src_h = tile.src_rect.h,
                .z = 100,
            });
            if (old_image_id != 0 and old_placement_id != 0) {
                kitty_protocol.writeDeleteExactPlacement(writer, .{ .image_id = old_image_id, .placement_id = old_placement_id }) catch |err| {
                    logger.writeFmt("katzensteg: composite tile delete failed: {any}", .{err});
                };
                self.retireImageId(old_image_id);
            }
            copyTileToLast(last, state.window_w, buf, tile.src_rect);
        }
        if (self.stats.enabled) {
            self.stats.texture_uploads += 1;
            self.stats.texture_upload_bytes += strip_rgba.len;
        }
    }

    fn deleteCompositeTilesDirect(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, state: *RendererState) void {
        const writer = tty.file.deprecatedWriter();
        for (state.composite_tiles.items) |*tile| {
            if (tile.image_id != 0 and tile.placement_id != 0) {
                kitty_protocol.writeDeleteExactPlacement(writer, .{ .image_id = tile.image_id, .placement_id = tile.placement_id }) catch |err| {
                    logger.writeFmt("katzensteg: composite tile delete failed: {any}", .{err});
                };
                self.retireImageId(tile.image_id);
            }
            tile.image_id = 0;
            tile.placement_id = 0;
        }
        if (state.composite_last_presented) |last| @memset(last, 0);
    }

    fn ensureCompositeTiles(self: *FrameBuilder, state: *RendererState, tty: *const DirectTty) !void {
        const contained = containedCellRect(state.window_w, state.window_h, tty);
        const tiles_x = @divTrunc(contained.w + composite_tile_cols - 1, composite_tile_cols);
        const tiles_y = @divTrunc(contained.h + composite_tile_rows - 1, composite_tile_rows);
        const tile_count: usize = @intCast(tiles_x * tiles_y);

        var needs_rebuild = state.composite_tiles.items.len != tile_count;
        if (!needs_rebuild) {
            var idx: usize = 0;
            var cell_row_off: i32 = 0;
            while (cell_row_off < contained.h and !needs_rebuild) : (cell_row_off += composite_tile_rows) {
                var cell_col_off: i32 = 0;
                while (cell_col_off < contained.w) : (cell_col_off += composite_tile_cols) {
                    const tile_cols = @min(composite_tile_cols, contained.w - cell_col_off);
                    const tile_rows = @min(composite_tile_rows, contained.h - cell_row_off);
                    const src_x0 = @divTrunc(cell_col_off * state.window_w, contained.w);
                    const src_x1 = @divTrunc((cell_col_off + tile_cols) * state.window_w, contained.w);
                    const src_y0 = @divTrunc(cell_row_off * state.window_h, contained.h);
                    const src_y1 = @divTrunc((cell_row_off + tile_rows) * state.window_h, contained.h);
                    const expected = CompositeTileState{
                        .src_rect = .{
                            .x = src_x0,
                            .y = src_y0,
                            .w = @max(1, src_x1 - src_x0),
                            .h = @max(1, src_y1 - src_y0),
                        },
                        .dest_rect = .{
                            .col = contained.col + cell_col_off,
                            .row = contained.row + cell_row_off,
                            .w = tile_cols,
                            .h = tile_rows,
                        },
                    };
                    const existing = state.composite_tiles.items[idx];
                    if (!std.meta.eql(existing.src_rect, expected.src_rect) or !std.meta.eql(existing.dest_rect, expected.dest_rect)) {
                        needs_rebuild = true;
                        break;
                    }
                    idx += 1;
                }
            }
        }
        if (!needs_rebuild) return;

        for (state.composite_tiles.items) |*tile| {
            self.retireImageId(tile.image_id);
            tile.image_id = 0;
            tile.placement_id = 0;
        }
        try state.composite_tiles.resize(self.allocator, tile_count);
        var idx: usize = 0;
        var cell_row_off: i32 = 0;
        while (cell_row_off < contained.h) : (cell_row_off += composite_tile_rows) {
            var cell_col_off: i32 = 0;
            while (cell_col_off < contained.w) : (cell_col_off += composite_tile_cols) {
                const tile_cols = @min(composite_tile_cols, contained.w - cell_col_off);
                const tile_rows = @min(composite_tile_rows, contained.h - cell_row_off);
                const src_x0 = @divTrunc(cell_col_off * state.window_w, contained.w);
                const src_x1 = @divTrunc((cell_col_off + tile_cols) * state.window_w, contained.w);
                const src_y0 = @divTrunc(cell_row_off * state.window_h, contained.h);
                const src_y1 = @divTrunc((cell_row_off + tile_rows) * state.window_h, contained.h);
                state.composite_tiles.items[idx] = .{
                    .src_rect = .{
                        .x = src_x0,
                        .y = src_y0,
                        .w = @max(1, src_x1 - src_x0),
                        .h = @max(1, src_y1 - src_y0),
                    },
                    .dest_rect = .{
                        .col = contained.col + cell_col_off,
                        .row = contained.row + cell_row_off,
                        .w = tile_cols,
                        .h = tile_rows,
                    },
                    .image_id = 0,
                    .placement_id = 0,
                };
                idx += 1;
            }
        }
        if (state.composite_last_presented) |old| {
            self.allocator.free(old);
            state.composite_last_presented = null;
        }
    }

    fn tileDiffers(current: []const u8, previous: []const u8, window_w: i32, rect: sdl.SDL_Rect) bool {
        var row: i32 = 0;
        while (row < rect.h) : (row += 1) {
            const x: usize = @intCast(rect.x);
            const y: usize = @intCast(rect.y + row);
            const start: usize = (y * @as(usize, @intCast(window_w)) + x) * 4;
            const len: usize = @intCast(rect.w * 4);
            if (!std.mem.eql(u8, current[start .. start + len], previous[start .. start + len])) return true;
        }
        return false;
    }

    fn extractTileRgba(dst: []u8, src: []const u8, window_w: i32, rect: sdl.SDL_Rect) void {
        const src_w: usize = @intCast(window_w);
        const row_bytes: usize = @intCast(rect.w * 4);
        var row: i32 = 0;
        while (row < rect.h) : (row += 1) {
            const sx: usize = @intCast(rect.x);
            const sy: usize = @intCast(rect.y + row);
            const src_start: usize = (sy * src_w + sx) * 4;
            const dst_start: usize = @as(usize, @intCast(row)) * row_bytes;
            @memcpy(dst[dst_start .. dst_start + row_bytes], src[src_start .. src_start + row_bytes]);
        }
    }

    fn blitTileIntoStrip(dst: []u8, dst_w: i32, src: []const u8, src_w: i32, rect: sdl.SDL_Rect, dst_x: i32, dst_y: i32) void {
        const dst_w_usize: usize = @intCast(dst_w);
        const src_w_usize: usize = @intCast(src_w);
        const row_bytes: usize = @intCast(rect.w * 4);
        var row: i32 = 0;
        while (row < rect.h) : (row += 1) {
            const sx: usize = @intCast(rect.x);
            const sy: usize = @intCast(rect.y + row);
            const src_start: usize = (sy * src_w_usize + sx) * 4;
            const dx: usize = @intCast(dst_x);
            const dy: usize = @intCast(dst_y + row);
            const dst_start: usize = (dy * dst_w_usize + dx) * 4;
            @memcpy(dst[dst_start .. dst_start + row_bytes], src[src_start .. src_start + row_bytes]);
        }
    }

    fn copyTileToLast(dst: []u8, window_w: i32, src: []const u8, rect: sdl.SDL_Rect) void {
        const dst_w: usize = @intCast(window_w);
        const row_bytes: usize = @intCast(rect.w * 4);
        var row: i32 = 0;
        while (row < rect.h) : (row += 1) {
            const x: usize = @intCast(rect.x);
            const y: usize = @intCast(rect.y + row);
            const start: usize = (y * dst_w + x) * 4;
            @memcpy(dst[start .. start + row_bytes], src[start .. start + row_bytes]);
        }
    }

    fn needsFramebufferComposite(self: *FrameBuilder, state: *const RendererState) bool {
        for (state.copies.items) |copy| {
            const texture = self.textures.get(copy.texture_key) orelse continue;
            if (texture.blend_mode != sdl.SDL_BLENDMODE_NONE and texture.blend_mode != sdl.SDL_BLENDMODE_BLEND) return true;
        }
        return false;
    }

    fn buildCompositeFrame(self: *FrameBuilder, logger: *Logger, state: *RendererState) !void {
        if (self.debug_composite) logger.writeFmt("katzensteg: composite fallback active window={d}x{d} copies={d} fills={d} lines={d}", .{ state.window_w, state.window_h, state.copies.items.len, state.fills.items.len, state.lines.items.len });
        const pixel_count: usize = @intCast(state.window_w * state.window_h * 4);
        if (state.composite_rgba == null or state.composite_rgba.?.len != pixel_count) {
            if (state.composite_rgba) |buf| self.allocator.free(buf);
            state.composite_rgba = try self.allocator.alloc(u8, pixel_count);
        }
        const buf = state.composite_rgba.?;
        clearFramebuffer(buf, state.window_w, state.window_h, state.clear_color);
        for (state.fills.items) |fill| compositeFill(buf, state.window_w, state.window_h, fill.rect, fill.color);
        for (state.lines.items) |line| compositeFill(buf, state.window_w, state.window_h, .{ .x = @min(line.x1, line.x2), .y = @min(line.y1, line.y2), .w = @max(1, @max(line.x1, line.x2) - @min(line.x1, line.x2) + 1), .h = @max(1, @max(line.y1, line.y2) - @min(line.y1, line.y2) + 1) }, line.color);
        for (state.copies.items) |copy| {
            const texture = self.textures.get(copy.texture_key) orelse continue;
            const src_rgba = texture.base_rgba orelse continue;
            compositeCopy(
                buf,
                state.window_w,
                state.window_h,
                src_rgba,
                texture.w,
                texture.h,
                copy.src,
                copy.dst,
                texture.blend_mode,
                texture.color_mod,
                texture.alpha_mod,
            );
        }
        forceOpaqueAlpha(buf);
        if (self.debug_composite) _ = self.logCompositeStats(logger, buf, state.window_w, state.window_h);
        const now = std.time.nanoTimestamp();
        if (self.dump_composites and now - self.last_composite_dump_ns >= 2 * std.time.ns_per_s) {
            self.dumpCompositeFrame(logger, buf, state.window_w, state.window_h);
            self.last_composite_dump_ns = now;
        }
        if (state.composite_last_presented) |last| {
            if (last.len == buf.len and std.mem.eql(u8, last, buf)) {
                if (self.debug_composite) logger.write("katzensteg: composite unchanged; skipping tile uploads");
                return;
            }
        }
    }

    fn logCompositeStats(self: *FrameBuilder, logger: *Logger, buf: []const u8, w: i32, h: i32) usize {
        _ = self;
        var non_black: usize = 0;
        var non_zero_alpha: usize = 0;
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            if (buf[i + 0] != 0 or buf[i + 1] != 0 or buf[i + 2] != 0) non_black += 1;
            if (buf[i + 3] != 0) non_zero_alpha += 1;
        }
        logger.writeFmt(
            "katzensteg: composite stats {d}x{d} non_black={d}/{d} non_zero_alpha={d}/{d}",
            .{ w, h, non_black, @as(usize, @intCast(w * h)), non_zero_alpha, @as(usize, @intCast(w * h)) },
        );
        return non_black;
    }

    fn dumpCompositeFrame(self: *FrameBuilder, logger: *Logger, buf: []const u8, w: i32, h: i32) void {
        _ = self;
        const path = "/tmp/katzensteg-composite.ppm";
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |err| {
            logger.writeFmt("katzensteg: failed to create composite dump: {any}", .{err});
            return;
        };
        defer file.close();
        var writer = file.writerStreaming(&.{});
        writer.interface.print("P6\n{d} {d}\n255\n", .{ w, h }) catch return;
        var rgb: [3]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            rgb[0] = buf[i + 0];
            rgb[1] = buf[i + 1];
            rgb[2] = buf[i + 2];
            writer.interface.writeAll(&rgb) catch return;
        }
        writer.interface.flush() catch return;
        logger.writeFmt("katzensteg: wrote composite dump to {s}", .{path});
    }

    fn blendModeName(blend_mode: i32) []const u8 {
        return switch (blend_mode) {
            sdl.SDL_BLENDMODE_NONE => "none",
            sdl.SDL_BLENDMODE_BLEND => "blend",
            sdl.SDL_BLENDMODE_ADD => "add",
            sdl.SDL_BLENDMODE_MOD => "mod",
            sdl.SDL_BLENDMODE_MUL => "mul",
            else => "unknown",
        };
    }

    fn retireImageId(self: *FrameBuilder, image_id: u32) void {
        if (image_id == 0) return;
        self.retired_image_ids.append(self.allocator, image_id) catch {};
    }

    fn deleteRetiredImages(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend) void {
        if (self.retired_image_ids.items.len == 0) return;
        for (self.retired_image_ids.items) |image_id| {
            backend.deleteImageData(image_id) catch |err| logger.writeFmt("katzensteg: deleteImageData failed: {any}", .{err});
        }
        if (self.stats.enabled) self.stats.retired_images += self.retired_image_ids.items.len;
        self.retired_image_ids.clearRetainingCapacity();
    }

    fn maybeReportStats(self: *FrameBuilder, logger: *Logger) void {
        const now = std.time.nanoTimestamp();
        if (now - self.stats.last_report_ns < std.time.ns_per_s) return;
        const elapsed_ns = now - self.stats.last_report_ns;
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const frames_per_s = if (elapsed_s > 0) @as(f64, @floatFromInt(self.stats.frame_count)) / elapsed_s else 0;
        const mib_uploaded = @as(f64, @floatFromInt(self.stats.texture_upload_bytes)) / (1024.0 * 1024.0);
        const mib_per_s = if (elapsed_s > 0) mib_uploaded / elapsed_s else 0;
        logger.writeFmt(
            "katzensteg: stats {d} frames ({d:.1} fps) uploads={d} ({d:.2} MiB, {d:.2} MiB/s) retired={d} copies={d} fills={d} lines={d} sprite_ops={d}",
            .{
                self.stats.frame_count,
                frames_per_s,
                self.stats.texture_uploads,
                mib_uploaded,
                mib_per_s,
                self.stats.retired_images,
                self.stats.copy_ops,
                self.stats.fill_ops,
                self.stats.line_ops,
                self.stats.sprite_ops,
            },
        );
        self.stats.frame_count = 0;
        self.stats.texture_uploads = 0;
        self.stats.texture_upload_bytes = 0;
        self.stats.sprite_ops = 0;
        self.stats.copy_ops = 0;
        self.stats.fill_ops = 0;
        self.stats.line_ops = 0;
        self.stats.retired_images = 0;
        self.stats.last_report_ns = now;
    }

    fn allocImageId(self: *FrameBuilder) u32 {
        const id = self.next_image_id;
        self.next_image_id +%= 1;
        if (self.next_image_id == 0) self.next_image_id = 1;
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

    fn convertTextureToRgba(dst: []u8, src: [*]u8, pitch: i32, w: i32, h: i32, format: sdl.Uint32) bool {
        const row_bytes: usize = @intCast(w * 4);
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            const src_row = src[@as(usize, @intCast(y * pitch))..][0..row_bytes];
            const dst_row = dst[@as(usize, @intCast(y * w * 4))..][0..row_bytes];
            switch (format) {
                sdl.SDL_PIXELFORMAT_ABGR8888 => {
                    // On little-endian systems this is already byte-wise RGBA.
                    std.mem.copyForwards(u8, dst_row, src_row);
                },
                sdl.SDL_PIXELFORMAT_ARGB8888 => {
                    var i: usize = 0;
                    while (i < row_bytes) : (i += 4) {
                        dst_row[i + 0] = src_row[i + 2];
                        dst_row[i + 1] = src_row[i + 1];
                        dst_row[i + 2] = src_row[i + 0];
                        dst_row[i + 3] = src_row[i + 3];
                    }
                },
                sdl.SDL_PIXELFORMAT_RGB565 => {
                    var x: usize = 0;
                    while (x < @as(usize, @intCast(w))) : (x += 1) {
                        const si = x * 2;
                        const di = x * 4;
                        const pix: u16 = @as(u16, src_row[si + 0]) | (@as(u16, src_row[si + 1]) << 8);
                        const r5: u8 = @intCast((pix >> 11) & 0x1f);
                        const g6: u8 = @intCast((pix >> 5) & 0x3f);
                        const b5: u8 = @intCast(pix & 0x1f);
                        dst_row[di + 0] = (r5 << 3) | (r5 >> 2);
                        dst_row[di + 1] = (g6 << 2) | (g6 >> 4);
                        dst_row[di + 2] = (b5 << 3) | (b5 >> 2);
                        dst_row[di + 3] = 255;
                    }
                },
                sdl.SDL_PIXELFORMAT_RGBA4444 => {
                    var x: usize = 0;
                    while (x < @as(usize, @intCast(w))) : (x += 1) {
                        const si = x * 2;
                        const di = x * 4;
                        const pix: u16 = @as(u16, src_row[si + 0]) | (@as(u16, src_row[si + 1]) << 8);
                        const r4: u8 = @intCast((pix >> 12) & 0x0f);
                        const g4: u8 = @intCast((pix >> 8) & 0x0f);
                        const b4: u8 = @intCast((pix >> 4) & 0x0f);
                        const a4: u8 = @intCast(pix & 0x0f);
                        dst_row[di + 0] = (r4 << 4) | r4;
                        dst_row[di + 1] = (g4 << 4) | g4;
                        dst_row[di + 2] = (b4 << 4) | b4;
                        dst_row[di + 3] = (a4 << 4) | a4;
                    }
                },
                else => return false,
            }
        }
        return true;
    }

    fn clearFramebuffer(buf: []u8, w: i32, h: i32, color: [4]u8) void {
        _ = w;
        _ = h;
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            buf[i + 0] = color[0];
            buf[i + 1] = color[1];
            buf[i + 2] = color[2];
            buf[i + 3] = color[3];
        }
    }

    fn compositeFill(dst: []u8, dst_w: i32, dst_h: i32, rect: sdl.SDL_Rect, color: [4]u8) void {
        const clipped = clipRect(rect, .{ .x = 0, .y = 0, .w = dst_w, .h = dst_h }) orelse return;
        var y = clipped.y;
        while (y < clipped.y + clipped.h) : (y += 1) {
            var x = clipped.x;
            while (x < clipped.x + clipped.w) : (x += 1) {
                const di: usize = @intCast((y * dst_w + x) * 4);
                dst[di + 0] = color[0];
                dst[di + 1] = color[1];
                dst[di + 2] = color[2];
                dst[di + 3] = color[3];
            }
        }
    }

    fn compositeCopy(dst: []u8, dst_w: i32, dst_h: i32, src: []const u8, src_w: i32, src_h: i32, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, blend_mode: i32, color_mod: [3]u8, alpha_mod: u8) void {
        if (dst_rect.w <= 0 or dst_rect.h <= 0 or src_rect.w <= 0 or src_rect.h <= 0) return;
        var y: i32 = 0;
        while (y < dst_rect.h) : (y += 1) {
            const dy = dst_rect.y + y;
            if (dy < 0 or dy >= dst_h) continue;
            const sy = src_rect.y + @divTrunc(y * src_rect.h, dst_rect.h);
            if (sy < 0 or sy >= src_h) continue;
            var x: i32 = 0;
            while (x < dst_rect.w) : (x += 1) {
                const dx = dst_rect.x + x;
                if (dx < 0 or dx >= dst_w) continue;
                const sx = src_rect.x + @divTrunc(x * src_rect.w, dst_rect.w);
                if (sx < 0 or sx >= src_w) continue;
                const si: usize = @intCast((sy * src_w + sx) * 4);
                const di: usize = @intCast((dy * dst_w + dx) * 4);
                const modulated = modulatedPixel(src[si .. si + 4], color_mod, alpha_mod);
                switch (blend_mode) {
                    sdl.SDL_BLENDMODE_NONE => {
                        dst[di + 0] = modulated[0];
                        dst[di + 1] = modulated[1];
                        dst[di + 2] = modulated[2];
                        dst[di + 3] = modulated[3];
                    },
                    sdl.SDL_BLENDMODE_BLEND => blendPixel(dst[di .. di + 4], &modulated),
                    sdl.SDL_BLENDMODE_ADD => addPixel(dst[di .. di + 4], &modulated),
                    else => blendPixel(dst[di .. di + 4], &modulated),
                }
            }
        }
    }

    fn modulatedPixel(src: []const u8, color_mod: [3]u8, alpha_mod: u8) [4]u8 {
        return .{
            @intCast((@as(u16, src[0]) * color_mod[0]) / 255),
            @intCast((@as(u16, src[1]) * color_mod[1]) / 255),
            @intCast((@as(u16, src[2]) * color_mod[2]) / 255),
            @intCast((@as(u16, src[3]) * alpha_mod) / 255),
        };
    }

    fn forceOpaqueAlpha(buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            buf[i + 3] = 255;
        }
    }

    fn blendPixel(dst: []u8, src: []const u8) void {
        const sa: u16 = src[3];
        const inv: u16 = 255 - sa;
        dst[0] = @intCast((@as(u16, src[0]) * sa + @as(u16, dst[0]) * inv) / 255);
        dst[1] = @intCast((@as(u16, src[1]) * sa + @as(u16, dst[1]) * inv) / 255);
        dst[2] = @intCast((@as(u16, src[2]) * sa + @as(u16, dst[2]) * inv) / 255);
        dst[3] = @intCast(@min(255, @as(u16, src[3]) + (@as(u16, dst[3]) * inv) / 255));
    }

    fn addPixel(dst: []u8, src: []const u8) void {
        const sa: u16 = src[3];
        dst[0] = @intCast(@min(255, @as(u16, dst[0]) + (@as(u16, src[0]) * sa) / 255));
        dst[1] = @intCast(@min(255, @as(u16, dst[1]) + (@as(u16, src[1]) * sa) / 255));
        dst[2] = @intCast(@min(255, @as(u16, dst[2]) + (@as(u16, src[2]) * sa) / 255));
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

    fn containedCellRect(window_w: i32, window_h: i32, tty: *const DirectTty) ts_types.CellRect {
        const cols: i32 = @intCast(tty.cols);
        const rows: i32 = @intCast(tty.rows);
        const avail_w = if (tty.pixel_width > 0) @as(f64, @floatFromInt(tty.pixel_width)) else @as(f64, @floatFromInt(cols));
        const avail_h = if (tty.pixel_height > 0) @as(f64, @floatFromInt(tty.pixel_height)) else @as(f64, @floatFromInt(rows));
        const scale = @min(avail_w / @as(f64, @floatFromInt(@max(window_w, 1))), avail_h / @as(f64, @floatFromInt(@max(window_h, 1))));
        const display_w = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(window_w)) * scale))));
        const display_h = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(window_h)) * scale))));
        const cell_w = if (tty.pixel_width > 0) @as(f64, @floatFromInt(tty.pixel_width)) / @as(f64, @floatFromInt(@max(cols, 1))) else 1.0;
        const cell_h = if (tty.pixel_height > 0) @as(f64, @floatFromInt(tty.pixel_height)) / @as(f64, @floatFromInt(@max(rows, 1))) else 1.0;
        const used_cols = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(display_w)) / cell_w))), 1, cols);
        const used_rows = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(display_h)) / cell_h))), 1, rows);
        return .{
            .col = 1 + @divTrunc(cols - used_cols, 2),
            .row = 1 + @divTrunc(rows - used_rows, 2),
            .w = used_cols,
            .h = used_rows,
        };
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

    fn mapLineToCells(line: LineOp, window_w: i32, window_h: i32, tty_cols: u16, tty_rows: u16) ts_types.CellRect {
        const min_x = @min(line.x1, line.x2);
        const min_y = @min(line.y1, line.y2);
        const max_x = @max(line.x1, line.x2);
        const max_y = @max(line.y1, line.y2);
        return mapRectToCells(.{ .x = min_x, .y = min_y, .w = @max(1, max_x - min_x + 1), .h = @max(1, max_y - min_y + 1) }, window_w, window_h, tty_cols, tty_rows);
    }

    fn applyViewportRect(rect: sdl.SDL_Rect, viewport: sdl.SDL_Rect) sdl.SDL_Rect {
        return .{ .x = rect.x + viewport.x, .y = rect.y + viewport.y, .w = rect.w, .h = rect.h };
    }

    fn clipRect(rect: sdl.SDL_Rect, clip: ?sdl.SDL_Rect) ?sdl.SDL_Rect {
        const c = clip orelse return rect;
        const x1 = @max(rect.x, c.x);
        const y1 = @max(rect.y, c.y);
        const x2 = @min(rect.x + rect.w, c.x + c.w);
        const y2 = @min(rect.y + rect.h, c.y + c.h);
        if (x2 <= x1 or y2 <= y1) return null;
        return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
    }

    fn clipCopyRect(src: sdl.SDL_Rect, dst: sdl.SDL_Rect, clip: ?sdl.SDL_Rect, tex_w: i32, tex_h: i32) ?struct { src: sdl.SDL_Rect, dst: sdl.SDL_Rect } {
        const clipped_dst = clipRect(dst, clip) orelse return null;
        if (clipped_dst.x == dst.x and clipped_dst.y == dst.y and clipped_dst.w == dst.w and clipped_dst.h == dst.h) {
            return .{ .src = src, .dst = dst };
        }
        if (dst.w <= 0 or dst.h <= 0 or src.w <= 0 or src.h <= 0) return null;

        const left_trim = clipped_dst.x - dst.x;
        const top_trim = clipped_dst.y - dst.y;
        const right_trim = (dst.x + dst.w) - (clipped_dst.x + clipped_dst.w);
        const bottom_trim = (dst.y + dst.h) - (clipped_dst.y + clipped_dst.h);

        var clipped_src = src;
        clipped_src.x += @divTrunc(left_trim * src.w, dst.w);
        clipped_src.y += @divTrunc(top_trim * src.h, dst.h);
        clipped_src.w -= @divTrunc((left_trim + right_trim) * src.w, dst.w);
        clipped_src.h -= @divTrunc((top_trim + bottom_trim) * src.h, dst.h);

        clipped_src.x = std.math.clamp(clipped_src.x, 0, tex_w);
        clipped_src.y = std.math.clamp(clipped_src.y, 0, tex_h);
        clipped_src.w = std.math.clamp(clipped_src.w, 0, tex_w - clipped_src.x);
        clipped_src.h = std.math.clamp(clipped_src.h, 0, tex_h - clipped_src.y);
        if (clipped_src.w <= 0 or clipped_src.h <= 0) return null;

        return .{ .src = clipped_src, .dst = clipped_dst };
    }
};
