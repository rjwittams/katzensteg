const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("katzensteg_sdl");
const termscene = @import("termscene");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;
const presentation_layout = @import("presentation_layout.zig");
const present_job = @import("present_job.zig");

const ts_types = termscene.types;
const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;
const kitty_protocol = termscene.kitty.protocol;
const PresentJob = present_job.PresentJob;
const SceneJob = present_job.SceneJob;
const FramebufferJob = present_job.FramebufferJob;
const AssetPublication = present_job.AssetPublication;
const SceneSprite = present_job.SceneSprite;
const SolidSprite = present_job.SolidSprite;

const bg_namespace: u24 = 210;
const sprite_namespace: u24 = 211;
const fill_namespace: u24 = 212;
const composite_tile_cols: i32 = 8;
const composite_tile_rows: i32 = 4;
const composite_strip_max_w: i32 = 4096;
const primitive_composite_threshold: usize = 128;
const external_framebuffer_renderer_key: usize = 0x6b73_676c;

extern fn ks_fast_i420_to_rgba(dst_rgba: [*]u8, width: c_int, height: c_int, yplane: [*]const u8, ypitch: c_int, uplane: [*]const u8, upitch: c_int, vplane: [*]const u8, vpitch: c_int) callconv(.c) c_int;
extern fn ks_fast_nv12_to_rgba(dst_rgba: [*]u8, width: c_int, height: c_int, yplane: [*]const u8, ypitch: c_int, uvplane: [*]const u8, uvpitch: c_int) callconv(.c) c_int;

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

const PresentDebugSignature = struct {
    use_composite: bool,
    copies: usize,
    fills: usize,
    lines: usize,
    unsupported_copies: usize = 0,
    mod_mismatch_copies: usize = 0,
    scaled_copies: usize = 0,
    missing_textures: usize = 0,
    first_copy_texture_key: usize = 0,
    first_copy_blend_mode: i32 = 0,
    first_copy_src: sdl.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    first_copy_dst: sdl.SDL_Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
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
    composite_image_id: u32 = 0,
    composite_placement_id: u32 = 0,
    composite_rgba: ?[]u8 = null,
    composite_last_presented: ?[]u8 = null,
    composite_tiles: std.ArrayList(CompositeTileState),
    copies: std.ArrayList(RenderCopyOp),
    fills: std.ArrayList(FillRectOp),
    lines: std.ArrayList(LineOp),
    last_debug_present_signature: ?PresentDebugSignature = null,
    logged_debug_composite_unchanged: bool = false,

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
    asset_id: u64 = 0,
    update_count: u64 = 0,
    base_rgba: ?[]u8 = null,
    base_opaque: bool = false,
    publish_rgba: ?[]u8 = null,
    publish_rgba_owned: bool = false,
    locked_pixels: ?[*]u8 = null,
    locked_pitch: i32 = 0,
    color_mod: [3]u8 = .{ 255, 255, 255 },
    alpha_mod: u8 = 255,
    blend_mode: i32 = sdl.SDL_BLENDMODE_NONE,
};

fn setTextureColorMod(record: *TextureRecord, r: u8, g: u8, b: u8) bool {
    const next = [3]u8{ r, g, b };
    if (std.meta.eql(record.color_mod, next)) return false;
    record.color_mod = next;
    return true;
}

fn setTextureAlphaMod(record: *TextureRecord, a: u8) bool {
    if (record.alpha_mod == a) return false;
    record.alpha_mod = a;
    return true;
}

const WindowRecord = struct {
    w: i32,
    h: i32,
};

const RenderCopyOp = struct {
    texture_key: usize,
    src: sdl.SDL_Rect,
    dst: sdl.SDL_Rect,
    blend_mode: i32 = sdl.SDL_BLENDMODE_NONE,
    color_mod: [3]u8 = .{ 255, 255, 255 },
    alpha_mod: u8 = 255,
    base_opaque: bool = false,
    update_count: u64 = 0,
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

pub const PixelSize = struct {
    w: i32,
    h: i32,
};

pub const InspectFrameSummary = struct {
    render_strategy: []const u8 = "sprite",
    strategy_short: []const u8 = "sprite",
    copies: u32 = 0,
    fills: u32 = 0,
    lines: u32 = 0,
    uploads: u32 = 0,
    placements: u32 = 0,
    bytes_uploaded: u64 = 0,
    fallback_texture_key: u64 = 0,
    fallback_reason: ?[]const u8 = null,
    image_id: u32 = 0,
    placement_id: u32 = 0,
};

pub const InspectResourceKind = enum {
    texture,
    image,
    placement,
};

pub const InspectResource = struct {
    kind: InspectResourceKind = .texture,
    texture_key: u64 = 0,
    placement_id: u32 = 0,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
    image_id: u32,
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
    published_assets: std.AutoHashMap(u64, u32),
    solid_images: std.AutoHashMap(u32, u32),
    retired_image_ids: std.ArrayList(u32),
    stats: Stats,
    composite_mode: CompositeMode = .fullscreen,
    dump_composites: bool = false,
    debug_composite: bool = false,
    last_inspect_summary: InspectFrameSummary = .{},
    next_image_id: u32 = 5000,
    next_asset_id: u64 = 1,
    last_composite_dump_ns: i128 = 0,
    last_composite_image_id: u32 = 0,
    next_composite_placement_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, stats_enabled: bool, composite_mode: CompositeMode, dump_composites: bool, debug_composite: bool) FrameBuilder {
        return .{
            .allocator = allocator,
            .windows = std.AutoHashMap(usize, WindowRecord).init(allocator),
            .renderers = std.AutoHashMap(usize, RendererState).init(allocator),
            .textures = std.AutoHashMap(usize, TextureRecord).init(allocator),
            .published_assets = std.AutoHashMap(u64, u32).init(allocator),
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
        while (tex_it.next()) |tex| {
            if (tex.base_rgba) |buf| self.allocator.free(buf);
            if (tex.publish_rgba_owned) {
                if (tex.publish_rgba) |buf| self.allocator.free(buf);
            }
        }
        self.textures.deinit();
        self.published_assets.deinit();
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

    pub fn presentExternalFramebuffer(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, width: i32, height: i32, rgba: []const u8, debug_protocol_replies: bool, image_gc: bool) void {
        if (width <= 0 or height <= 0) return;
        const expected_len: usize = @intCast(width * height * 4);
        if (rgba.len < expected_len) return;

        const result = self.renderers.getOrPut(external_framebuffer_renderer_key) catch |err| {
            logger.writeFmt("katzensteg: GL framebuffer state allocation failed: {any}", .{err});
            return;
        };
        if (!result.found_existing) {
            result.value_ptr.* = RendererState.init(self.allocator, width, height);
        } else if (result.value_ptr.window_w != width or result.value_ptr.window_h != height) {
            result.value_ptr.window_w = width;
            result.value_ptr.window_h = height;
            result.value_ptr.viewport = .{ .x = 0, .y = 0, .w = width, .h = height };
            if (result.value_ptr.composite_last_presented) |last| @memset(last, 0);
        }
        const state = result.value_ptr;

        engine.beginScene();
        engine.diff() catch |err| {
            logger.writeFmt("katzensteg: scene diff failed while entering GL framebuffer mode: {any}", .{err});
            return;
        };
        backend.applySpriteOps(engine.sprite_ops.items) catch |err| logger.writeFmt("katzensteg: applySpriteOps failed while entering GL framebuffer mode: {any}", .{err});
        engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed while entering GL framebuffer mode: {any}", .{err});

        if (state.composite_rgba == null or state.composite_rgba.?.len != expected_len) {
            if (state.composite_rgba) |old| self.allocator.free(old);
            state.composite_rgba = self.allocator.alloc(u8, expected_len) catch |err| {
                logger.writeFmt("katzensteg: GL framebuffer copy allocation failed: {any}", .{err});
                return;
            };
        }
        @memcpy(state.composite_rgba.?, rgba[0..expected_len]);
        state.composite_mode_active = true;

        self.presentCompositeFullscreenDirect(logger, tty, backend, state) catch |err| logger.writeFmt("katzensteg: GL framebuffer present failed: {any}", .{err});

        var job = PresentJob{ .framebuffer = .{
            .width = width,
            .height = height,
            .rgba = state.composite_rgba.?,
            .owns_rgba = false,
        } };
        self.last_inspect_summary = self.buildInspectSummary(state, &job);
        if (image_gc) self.deleteRetiredImages(logger, backend);
        if (debug_protocol_replies) self.drainKittyReplies(logger, tty);
        if (self.stats.enabled) {
            self.stats.frame_count += 1;
            self.maybeReportStats(logger);
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
            if (entry.value.publish_rgba_owned) {
                if (entry.value.publish_rgba) |buf| self.allocator.free(buf);
            }
            self.retireImageId(entry.value.image_id);
            if (entry.value.asset_id != 0) _ = self.published_assets.remove(entry.value.asset_id);
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

    pub fn onUpdateYuvTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uplane: ?[*]const u8, upitch: i32, vplane: ?[*]const u8, vpitch: i32) void {
        _ = backend;
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        if (yplane == null or uplane == null or vplane == null) return;
        self.captureYuvTexturePlanesIntoRecord(record, rect, yplane.?, ypitch, uplane.?, upitch, vplane.?, vpitch) catch |err| switch (err) {
            error.UnsupportedTextureFormat => logger.writeFmt("katzensteg: unsupported YUV texture pixel format: {d}", .{record.format}),
            error.UnsupportedTextureRect => logger.writeOnce("katzensteg: partial SDL_UpdateYUVTexture rects are not supported yet"),
            error.OutOfMemory => logger.writeOnce("katzensteg: failed to allocate YUV texture pixel storage"),
        };
    }

    pub fn onUpdateNvTexture(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, rect: ?*const sdl.SDL_Rect, yplane: ?[*]const u8, ypitch: i32, uvplane: ?[*]const u8, uvpitch: i32) void {
        _ = backend;
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        if (yplane == null or uvplane == null) return;
        self.captureNvTexturePlanesIntoRecord(record, rect, yplane.?, ypitch, uvplane.?, uvpitch) catch |err| switch (err) {
            error.UnsupportedTextureFormat => logger.writeFmt("katzensteg: unsupported NV texture pixel format: {d}", .{record.format}),
            error.UnsupportedTextureRect => logger.writeOnce("katzensteg: partial SDL_UpdateNVTexture rects are not supported yet"),
            error.OutOfMemory => logger.writeOnce("katzensteg: failed to allocate NV texture pixel storage"),
        };
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
        _ = logger;
        _ = backend;
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        if (!setTextureColorMod(record, r, g, b)) return;
        self.invalidateTexturePublication(record);
    }

    pub fn onSetTextureAlphaMod(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, texture: ?*sdl.SDL_Texture, a: u8) void {
        _ = logger;
        _ = backend;
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        if (!setTextureAlphaMod(record, a)) return;
        self.invalidateTexturePublication(record);
    }

    pub fn onSetTextureBlendMode(self: *FrameBuilder, logger: *Logger, texture: ?*sdl.SDL_Texture, blend_mode: i32) void {
        const record = self.textures.getPtr(ptrKey(texture)) orelse return;
        record.blend_mode = blend_mode;
        logger.writeFmt("katzensteg: SDL_SetTextureBlendMode texture={x} mode={s} ({d})", .{ ptrKey(texture), blendModeName(blend_mode), blend_mode });
        if (blend_mode != sdl.SDL_BLENDMODE_NONE and blend_mode != sdl.SDL_BLENDMODE_BLEND) {
            logger.writeFmt("katzensteg: unsupported SDL texture blend mode {s} ({d}); some compositions may require framebuffer-side compositing before terminal upload", .{ blendModeName(blend_mode), blend_mode });
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

    fn invalidateTexturePublication(self: *FrameBuilder, record: *TextureRecord) void {
        if (record.publish_rgba_owned) {
            if (record.publish_rgba) |old| self.allocator.free(old);
        }
        record.publish_rgba = null;
        record.publish_rgba_owned = false;
        if (record.asset_id != 0) {
            if (self.published_assets.fetchRemove(record.asset_id)) |entry| self.retireImageId(entry.value);
            record.asset_id = 0;
        }
        if (record.image_id != 0) {
            self.retireImageId(record.image_id);
            record.image_id = 0;
        }
    }

    fn ensureTexturePublication(self: *FrameBuilder, record: *TextureRecord) !void {
        if (record.asset_id != 0 and record.publish_rgba != null) return;
        const base = record.base_rgba orelse return error.MissingTexturePixels;
        if (isIdentityMod(record.color_mod, record.alpha_mod)) {
            record.publish_rgba = base;
            record.publish_rgba_owned = false;
            record.asset_id = self.allocAssetId();
            return;
        }
        const modulated = try self.allocator.alloc(u8, base.len);
        applyMods(modulated, base, record.color_mod, record.alpha_mod);
        errdefer self.allocator.free(modulated);
        record.publish_rgba = modulated;
        record.publish_rgba_owned = true;
        record.asset_id = self.allocAssetId();
    }

    fn captureTexturePixels(self: *FrameBuilder, logger: *Logger, backend: *ts_kitty.Backend, record: *TextureRecord, src: [*]u8, pitch: i32) void {
        _ = backend;
        self.captureTexturePixelsIntoRecord(record, src, pitch) catch |err| switch (err) {
            error.UnsupportedTextureFormat => logger.writeFmt("katzensteg: unsupported texture pixel format: {d}", .{record.format}),
            error.OutOfMemory => logger.writeOnce("katzensteg: failed to allocate texture pixel storage"),
        };
    }

    fn captureTexturePixelsIntoRecord(self: *FrameBuilder, record: *TextureRecord, src: [*]u8, pitch: i32) !void {
        if (!isSupportedTextureFormat(record.format)) return error.UnsupportedTextureFormat;

        const len: usize = @intCast(record.w * record.h * 4);
        if (record.base_rgba) |rgba| {
            if (rgba.len == len) {
                if (!convertTextureToRgba(rgba, src, pitch, record.w, record.h, record.format)) return error.UnsupportedTextureFormat;
                record.base_opaque = rgbaIsOpaque(rgba);
                record.update_count += 1;
                self.invalidateTexturePublication(record);
                return;
            }
        }

        const replacement = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(replacement);
        if (!convertTextureToRgba(replacement, src, pitch, record.w, record.h, record.format)) return error.UnsupportedTextureFormat;

        if (record.base_rgba) |old| self.allocator.free(old);
        record.base_rgba = replacement;
        record.base_opaque = rgbaIsOpaque(replacement);
        record.update_count += 1;
        self.invalidateTexturePublication(record);
    }

    fn captureYuvTexturePlanesIntoRecord(self: *FrameBuilder, record: *TextureRecord, rect: ?*const sdl.SDL_Rect, yplane: [*]const u8, ypitch: i32, uplane: [*]const u8, upitch: i32, vplane: [*]const u8, vpitch: i32) !void {
        if (record.format != sdl.SDL_PIXELFORMAT_IYUV and record.format != sdl.SDL_PIXELFORMAT_YV12) return error.UnsupportedTextureFormat;
        if (rect != null) return error.UnsupportedTextureRect;
        if (record.w <= 0 or record.h <= 0 or ypitch <= 0 or upitch <= 0 or vpitch <= 0) return error.UnsupportedTextureFormat;

        const len: usize = @intCast(record.w * record.h * 4);
        const rgba = try self.ensureWritableTextureRgba(record, len);
        if (tryFastYuv420PlanesToRgba(rgba, record.w, record.h, yplane, ypitch, uplane, upitch, vplane, vpitch)) {
            record.base_opaque = true;
            record.update_count += 1;
            self.invalidateTexturePublication(record);
            return;
        }
        convertYuv420PlanesToRgba(rgba, record.w, record.h, yplane, ypitch, uplane, upitch, vplane, vpitch);
        record.base_opaque = true;
        record.update_count += 1;
        self.invalidateTexturePublication(record);
    }

    fn captureNvTexturePlanesIntoRecord(self: *FrameBuilder, record: *TextureRecord, rect: ?*const sdl.SDL_Rect, yplane: [*]const u8, ypitch: i32, uvplane: [*]const u8, uvpitch: i32) !void {
        if (record.format != sdl.SDL_PIXELFORMAT_NV12 and record.format != sdl.SDL_PIXELFORMAT_NV21) return error.UnsupportedTextureFormat;
        if (rect != null) return error.UnsupportedTextureRect;
        if (record.w <= 0 or record.h <= 0 or ypitch <= 0 or uvpitch <= 0) return error.UnsupportedTextureFormat;

        const len: usize = @intCast(record.w * record.h * 4);
        const rgba = try self.ensureWritableTextureRgba(record, len);
        if (record.format == sdl.SDL_PIXELFORMAT_NV12 and tryFastNv12PlanesToRgba(rgba, record.w, record.h, yplane, ypitch, uvplane, uvpitch)) {
            record.base_opaque = true;
            record.update_count += 1;
            self.invalidateTexturePublication(record);
            return;
        }
        convertNv12PlanesToRgba(rgba, record.w, record.h, yplane, ypitch, uvplane, uvpitch, record.format == sdl.SDL_PIXELFORMAT_NV21);
        record.base_opaque = true;
        record.update_count += 1;
        self.invalidateTexturePublication(record);
    }

    fn ensureWritableTextureRgba(self: *FrameBuilder, record: *TextureRecord, len: usize) ![]u8 {
        if (record.base_rgba) |rgba| {
            if (rgba.len == len) return rgba;
            self.allocator.free(rgba);
            record.base_rgba = null;
        }
        const replacement = try self.allocator.alloc(u8, len);
        record.base_rgba = replacement;
        return replacement;
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

    pub const GeometryCopy = struct {
        src: sdl.SDL_Rect,
        dst: sdl.SDL_Rect,
    };

    pub fn onRenderGeometryRaw(self: *FrameBuilder, logger: *Logger, renderer: ?*sdl.SDL_Renderer, texture: ?*sdl.SDL_Texture, xy: ?[*]const f32, xy_stride: c_int, uv: ?[*]const f32, uv_stride: c_int, num_vertices: c_int, indices: ?*const anyopaque, num_indices: c_int, size_indices: c_int) void {
        if (xy_stride <= 0 or uv_stride <= 0 or num_vertices <= 0 or num_indices < 0) return;
        const record = self.textures.get(ptrKey(texture)) orelse return;
        const copy = geometryRawAsCopy(xy, @intCast(xy_stride), uv, @intCast(uv_stride), @intCast(num_vertices), indices, @intCast(num_indices), @intCast(size_indices), record.w, record.h) orelse {
            logger.writeOnce("katzensteg: unsupported SDL_RenderGeometryRaw shape; skipping geometry");
            return;
        };
        self.recordRenderCopy(logger, renderer, texture, &copy.src, &copy.dst);
    }

    pub fn geometryRawAsCopy(xy: ?[*]const f32, xy_stride: usize, uv: ?[*]const f32, uv_stride: usize, num_vertices: usize, indices: ?*const anyopaque, num_indices: usize, size_indices: usize, texture_w: i32, texture_h: i32) ?GeometryCopy {
        if (xy == null or uv == null) return null;
        if (texture_w <= 0 or texture_h <= 0) return null;
        if (num_vertices == 0 or num_vertices > 16 * 1024) return null;
        if (xy_stride < @sizeOf(f32) * 2 or uv_stride < @sizeOf(f32) * 2) return null;
        const count = if (indices != null) num_indices else num_vertices;
        if (count == 0) return null;

        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        var min_u: f32 = std.math.inf(f32);
        var min_v: f32 = std.math.inf(f32);
        var max_u: f32 = -std.math.inf(f32);
        var max_v: f32 = -std.math.inf(f32);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const vertex_index = geometryVertexIndex(indices, i, size_indices) orelse return null;
            if (vertex_index >= num_vertices) return null;
            const pos = readStridedF32Pair(xy.?, xy_stride, vertex_index);
            const tex = readStridedF32Pair(uv.?, uv_stride, vertex_index);
            min_x = @min(min_x, pos[0]);
            min_y = @min(min_y, pos[1]);
            max_x = @max(max_x, pos[0]);
            max_y = @max(max_y, pos[1]);
            min_u = @min(min_u, tex[0]);
            min_v = @min(min_v, tex[1]);
            max_u = @max(max_u, tex[0]);
            max_v = @max(max_v, tex[1]);
        }

        if (max_x <= min_x or max_y <= min_y or max_u <= min_u or max_v <= min_v) return null;

        i = 0;
        while (i < count) : (i += 1) {
            const vertex_index = geometryVertexIndex(indices, i, size_indices) orelse return null;
            const pos = readStridedF32Pair(xy.?, xy_stride, vertex_index);
            const tex = readStridedF32Pair(uv.?, uv_stride, vertex_index);
            if ((!nearF32(pos[0], min_x) and !nearF32(pos[0], max_x)) or (!nearF32(pos[1], min_y) and !nearF32(pos[1], max_y))) return null;
            if ((!nearF32(tex[0], min_u) and !nearF32(tex[0], max_u)) or (!nearF32(tex[1], min_v) and !nearF32(tex[1], max_v))) return null;
        }

        const dst_x = floorToI32(min_x);
        const dst_y = floorToI32(min_y);
        const dst_max_x = ceilToI32(max_x);
        const dst_max_y = ceilToI32(max_y);
        const src_x = clampI32(floorToI32(min_u * @as(f32, @floatFromInt(texture_w))), 0, texture_w);
        const src_y = clampI32(floorToI32(min_v * @as(f32, @floatFromInt(texture_h))), 0, texture_h);
        const src_max_x = clampI32(ceilToI32(max_u * @as(f32, @floatFromInt(texture_w))), 0, texture_w);
        const src_max_y = clampI32(ceilToI32(max_v * @as(f32, @floatFromInt(texture_h))), 0, texture_h);

        if (dst_max_x <= dst_x or dst_max_y <= dst_y or src_max_x <= src_x or src_max_y <= src_y) return null;
        return .{
            .src = .{ .x = src_x, .y = src_y, .w = src_max_x - src_x, .h = src_max_y - src_y },
            .dst = .{ .x = dst_x, .y = dst_y, .w = dst_max_x - dst_x, .h = dst_max_y - dst_y },
        };
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
            state.copies.append(self.allocator, .{
                .texture_key = texture_key,
                .src = clipped.src,
                .dst = clipped.dst,
                .blend_mode = record.blend_mode,
                .color_mod = record.color_mod,
                .alpha_mod = record.alpha_mod,
                .base_opaque = record.base_opaque,
                .update_count = record.update_count,
            }) catch {};
        }
    }

    pub fn onRenderPresent(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, renderer: ?*sdl.SDL_Renderer, bg_only: bool, debug_protocol_replies: bool, image_gc: bool) void {
        var job = self.buildPresentJob(logger, tty, renderer, bg_only) catch |err| {
            logger.writeFmt("katzensteg: buildPresentJob failed: {any}", .{err});
            const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
            state.copies.clearRetainingCapacity();
            state.fills.clearRetainingCapacity();
            state.lines.clearRetainingCapacity();
            return;
        };
        defer job.deinit(self.allocator);
        self.renderPresentJob(logger, tty, engine, backend, renderer, &job, debug_protocol_replies, image_gc);
    }

    pub fn buildPresentJob(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, renderer: ?*sdl.SDL_Renderer, bg_only: bool) !PresentJob {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return error.UnknownRenderer;
        const use_composite = !bg_only and self.needsFramebufferComposite(state);
        if (self.debug_composite) {
            if (self.changedPresentDebugSignature(state, use_composite)) |signature| {
                self.logPresentDecision(logger, state, signature);
            }
        }
        state.composite_mode_active = use_composite;
        if (use_composite) {
            try @call(.never_inline, FrameBuilder.buildCompositeFrame, .{ self, logger, state });
            const buf = state.composite_rgba orelse return error.MissingCompositeBuffer;
            return .{ .framebuffer = .{ .width = state.window_w, .height = state.window_h, .rgba = buf, .owns_rgba = false } };
        }

        var solids_list = std.ArrayList(SolidSprite).empty;
        defer solids_list.deinit(self.allocator);
        var sprites_list = std.ArrayList(SceneSprite).empty;
        defer sprites_list.deinit(self.allocator);
        var publications_list = std.ArrayList(AssetPublication).empty;
        defer publications_list.deinit(self.allocator);
        errdefer for (publications_list.items) |*publication| publication.deinit(self.allocator);
        var published_in_job = std.AutoHashMap(u64, void).init(self.allocator);
        defer published_in_job.deinit();

        if (state.had_clear) {
            try solids_list.append(self.allocator, .{
                .color = state.clear_color,
                .dest_rect = .{ .col = 1, .row = 1, .w = tty.cols, .h = tty.rows },
                .z = -100,
            });
        }
        if (!bg_only) {
            for (state.fills.items) |fill| {
                try solids_list.append(self.allocator, .{
                    .color = fill.color,
                    .dest_rect = mapRectToCells(fill.rect, state.window_w, state.window_h, tty.cols, tty.rows),
                    .z = 0,
                });
            }
            for (state.lines.items) |line| {
                try solids_list.append(self.allocator, .{
                    .color = line.color,
                    .dest_rect = mapLineToCells(line, state.window_w, state.window_h, tty.cols, tty.rows),
                    .z = 1,
                });
            }
            for (state.copies.items, 0..) |copy, i| {
                const texture = self.textures.getPtr(copy.texture_key) orelse continue;
                self.ensureTexturePublication(texture) catch continue;
                if (texture.asset_id == 0 or texture.publish_rgba == null) continue;
                if (!published_in_job.contains(texture.asset_id) and !self.published_assets.contains(texture.asset_id)) {
                    try publications_list.append(self.allocator, .{ .new_asset = .{
                        .asset_id = texture.asset_id,
                        .width = texture.w,
                        .height = texture.h,
                        .rgba = texture.publish_rgba.?,
                        .owns_rgba = false,
                    } });
                    try published_in_job.put(texture.asset_id, {});
                }
                try sprites_list.append(self.allocator, .{
                    .asset_id = texture.asset_id,
                    .source_rect = copy.src,
                    .dest_rect = mapRectToCells(copy.dst, state.window_w, state.window_h, tty.cols, tty.rows),
                    .z = @intCast(100 + i),
                });
            }
        }

        return .{ .scene = .{ .had_clear = state.had_clear, .clear_color = state.clear_color, .publications = try self.allocator.dupe(AssetPublication, publications_list.items), .sprites = try self.allocator.dupe(SceneSprite, sprites_list.items), .solids = try self.allocator.dupe(SolidSprite, solids_list.items) } };
    }

    pub fn renderPresentJob(self: *FrameBuilder, logger: *Logger, tty: *const DirectTty, engine: *ts_scene.SceneEngine, backend: *ts_kitty.Backend, renderer: ?*sdl.SDL_Renderer, job: *PresentJob, debug_protocol_replies: bool, image_gc: bool) void {
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return;
        switch (job.*) {
            .framebuffer => |fb| {
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
                if (state.composite_rgba == null or state.composite_rgba.?.ptr != fb.rgba.ptr or state.composite_rgba.?.len != fb.rgba.len) {
                    if (state.composite_rgba) |old| self.allocator.free(old);
                    state.composite_rgba = self.allocator.dupe(u8, fb.rgba) catch null;
                }
                switch (self.composite_mode) {
                    .fullscreen => self.presentCompositeFullscreenDirect(logger, tty, backend, state) catch |err| logger.writeFmt("katzensteg: presentCompositeFullscreenDirect failed: {any}", .{err}),
                    .tiled_strip => self.presentCompositeTilesDirect(logger, tty, backend, state) catch |err| logger.writeFmt("katzensteg: presentCompositeTilesDirect failed: {any}", .{err}),
                }
            },
            .scene => |scene_job| {
                for (scene_job.publications) |publication| {
                    switch (publication) {
                        .new_asset => |asset| {
                            if (!self.published_assets.contains(asset.asset_id)) {
                                const image_id = self.allocImageId();
                                backend.registerRawImage(image_id, asset.rgba, asset.width, asset.height) catch |err| {
                                    logger.writeFmt("katzensteg: scene asset publish failed: {any}", .{err});
                                    continue;
                                };
                                self.published_assets.put(asset.asset_id, image_id) catch {};
                                if (self.stats.enabled) {
                                    self.stats.texture_uploads += 1;
                                    self.stats.texture_upload_bytes += asset.rgba.len;
                                }
                            }
                        },
                    }
                }
                switch (self.composite_mode) {
                    .fullscreen => self.deleteCompositeFullscreenDirect(logger, tty, state),
                    .tiled_strip => self.deleteCompositeTilesDirect(logger, tty, state),
                }
                engine.beginScene();
                var solid_sprite_index: usize = 0;
                for (scene_job.solids, 0..) |solid, i| {
                    const image_id = self.ensureSolidImage(logger, backend, solid.color);
                    if (i == 0 and scene_job.had_clear and image_id != state.last_logged_bg_image_id) {
                        logger.writeFmt("katzensteg: bg clear=rgba({d},{d},{d},{d}) image_id={d}", .{ solid.color[0], solid.color[1], solid.color[2], solid.color[3], image_id });
                        state.last_logged_bg_image_id = image_id;
                    }
                    const image: ts_types.ImageHandle = @enumFromInt(image_id);
                    const namespace = if (scene_job.had_clear and i == 0) bg_namespace else fill_namespace;
                    const key_id: u32 = if (namespace == bg_namespace) 1 else @intCast(solid_sprite_index + 1);
                    if (namespace == fill_namespace) solid_sprite_index += 1;
                    engine.sprite(.{ .key = ts_types.NodeKey.sprite(namespace, key_id), .image = image, .source_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .dest_rect = solid.dest_rect, .z = solid.z }) catch {};
                }
                for (scene_job.sprites, 0..) |sprite, i| {
                    const image_id = self.published_assets.get(sprite.asset_id) orelse continue;
                    const image: ts_types.ImageHandle = @enumFromInt(image_id);
                    engine.sprite(.{ .key = ts_types.NodeKey.sprite(sprite_namespace, @as(u32, @intCast(i + 1))), .image = image, .source_rect = .{ .x = sprite.source_rect.x, .y = sprite.source_rect.y, .w = sprite.source_rect.w, .h = sprite.source_rect.h }, .dest_rect = sprite.dest_rect, .z = sprite.z }) catch {};
                }
                engine.diff() catch |err| {
                    logger.writeFmt("katzensteg: scene diff failed: {any}", .{err});
                    state.copies.clearRetainingCapacity();
                    state.fills.clearRetainingCapacity();
                    state.lines.clearRetainingCapacity();
                    return;
                };
                if (scene_job.had_clear and engine.sprite_ops.items.len > 0) {
                    for (engine.sprite_ops.items) |op| {
                        if (op.key.namespace == bg_namespace and op.key.id == 1) {
                            logger.writeFmt("katzensteg: bg sprite op={s} total_sprite_ops={d}", .{ @tagName(op.tag), engine.sprite_ops.items.len });
                            break;
                        }
                    }
                }
                backend.applySpriteOps(engine.sprite_ops.items) catch |err| logger.writeFmt("katzensteg: applySpriteOps failed: {any}", .{err});
                engine.commit() catch |err| logger.writeFmt("katzensteg: scene commit failed: {any}", .{err});
                if (self.stats.enabled) {
                    self.stats.sprite_ops += engine.sprite_ops.items.len;
                }
            },
        }
        self.last_inspect_summary = self.buildInspectSummary(state, job);
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
    }

    pub fn presentationLayoutForRenderer(self: *FrameBuilder, tty: *const DirectTty, renderer: ?*sdl.SDL_Renderer) presentation_layout.PresentationLayout {
        var layout = presentation_layout.PresentationLayout{};
        const state = self.renderers.getPtr(ptrKey(renderer)) orelse return layout;
        if (!state.composite_mode_active) return layout;
        switch (self.composite_mode) {
            .fullscreen, .tiled_strip => layout.setSingleSdlRegion(fullscreenCompositePresentationRegion(state.window_w, state.window_h, tty)),
        }
        return layout;
    }

    pub fn presentationLayoutForExternalFramebuffer(self: *FrameBuilder, tty: *const DirectTty) presentation_layout.PresentationLayout {
        var layout = presentation_layout.PresentationLayout{};
        const state = self.renderers.getPtr(external_framebuffer_renderer_key) orelse return layout;
        if (!state.composite_mode_active) return layout;
        layout.setSingleSdlRegion(fullscreenCompositePresentationRegion(state.window_w, state.window_h, tty));
        return layout;
    }

    pub fn externalFramebufferUploadSize(self: *FrameBuilder, tty: *const DirectTty, source_w: i32, source_h: i32) PixelSize {
        _ = self;
        const dest = fullscreenCompositeCellRect(source_w, source_h, tty);
        return fullscreenCompositeUploadSize(dest, source_w, source_h, tty);
    }

    pub fn inspectSummary(self: *const FrameBuilder) InspectFrameSummary {
        return self.last_inspect_summary;
    }

    pub fn snapshotResources(self: *const FrameBuilder, allocator: std.mem.Allocator) ![]InspectResource {
        var list = std.ArrayList(InspectResource).empty;
        defer list.deinit(allocator);
        try self.appendSnapshotResources(allocator, &list);
        return list.toOwnedSlice(allocator);
    }

    pub fn appendSnapshotResources(self: *const FrameBuilder, allocator: std.mem.Allocator, list: *std.ArrayList(InspectResource)) !void {
        var it = self.textures.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const tex = entry.value_ptr.*;
            try list.append(allocator, .{
                .kind = .texture,
                .texture_key = key,
                .w = tex.w,
                .h = tex.h,
                .format = tex.format,
                .blend_mode = tex.blend_mode,
                .update_count = tex.update_count,
                .image_id = tex.image_id,
            });
        }
        var renderer_it = self.renderers.iterator();
        while (renderer_it.next()) |entry| {
            const state = entry.value_ptr.*;
            if (state.composite_image_id != 0) {
                try list.append(allocator, .{
                    .kind = .image,
                    .w = state.window_w,
                    .h = state.window_h,
                    .format = sdl.SDL_PIXELFORMAT_ABGR8888,
                    .blend_mode = sdl.SDL_BLENDMODE_NONE,
                    .update_count = 1,
                    .image_id = state.composite_image_id,
                });
            }
            if (state.composite_image_id != 0 and state.composite_placement_id != 0) {
                try list.append(allocator, .{
                    .kind = .placement,
                    .placement_id = state.composite_placement_id,
                    .w = state.window_w,
                    .h = state.window_h,
                    .format = sdl.SDL_PIXELFORMAT_ABGR8888,
                    .blend_mode = sdl.SDL_BLENDMODE_NONE,
                    .update_count = 1,
                    .image_id = state.composite_image_id,
                });
            }
            for (state.composite_tiles.items) |tile| {
                if (tile.image_id != 0) {
                    try list.append(allocator, .{
                        .kind = .image,
                        .w = tile.src_rect.w,
                        .h = tile.src_rect.h,
                        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
                        .blend_mode = sdl.SDL_BLENDMODE_NONE,
                        .update_count = 1,
                        .image_id = tile.image_id,
                    });
                }
                if (tile.image_id != 0 and tile.placement_id != 0) {
                    try list.append(allocator, .{
                        .kind = .placement,
                        .placement_id = tile.placement_id,
                        .w = tile.src_rect.w,
                        .h = tile.src_rect.h,
                        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
                        .blend_mode = sdl.SDL_BLENDMODE_NONE,
                        .update_count = 1,
                        .image_id = tile.image_id,
                    });
                }
            }
        }
    }

    fn buildInspectSummary(self: *const FrameBuilder, state: *const RendererState, job: *const PresentJob) InspectFrameSummary {
        var summary = InspectFrameSummary{
            .copies = @intCast(state.copies.items.len),
            .fills = @intCast(state.fills.items.len),
            .lines = @intCast(state.lines.items.len),
        };
        switch (job.*) {
            .framebuffer => |fb| {
                summary.render_strategy = switch (self.composite_mode) {
                    .fullscreen => "fullscreen_composite",
                    .tiled_strip => "tiled_strip",
                };
                summary.strategy_short = switch (self.composite_mode) {
                    .fullscreen => "composite",
                    .tiled_strip => "tiled",
                };
                if (self.composite_mode == .fullscreen) {
                    summary.uploads = 1;
                    summary.placements = 1;
                    summary.bytes_uploaded = @as(u64, @intCast(fb.width * fb.height * 4));
                    summary.image_id = state.composite_image_id;
                    summary.placement_id = state.composite_placement_id;
                }
            },
            .scene => {
                summary.render_strategy = "sprite";
                summary.strategy_short = "sprite";
            },
        }
        for (state.copies.items) |copy| {
            if (copy.blend_mode != sdl.SDL_BLENDMODE_NONE and copy.blend_mode != sdl.SDL_BLENDMODE_BLEND) {
                summary.fallback_texture_key = copy.texture_key;
                summary.fallback_reason = "unsupported_blend_mode";
                break;
            }
        }
        return summary;
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
        const dest = fullscreenCompositeCellRect(state.window_w, state.window_h, tty);
        const upload_size = fullscreenCompositeUploadSize(dest, state.window_w, state.window_h, tty);
        var scaled_buf: ?[]u8 = null;
        defer if (scaled_buf) |scratch| self.allocator.free(scratch);
        const upload_buf = if (upload_size.w == state.window_w and upload_size.h == state.window_h)
            buf
        else blk: {
            const scratch = try scaleRgbaNearest(self.allocator, buf, state.window_w, state.window_h, upload_size.w, upload_size.h);
            scaled_buf = scratch;
            break :blk scratch;
        };
        if (self.debug_composite) logger.writeFmt("katzensteg: composite fullscreen upload image_id={d} source={d}x{d} upload={d}x{d} cell={d},{d} {d}x{d}", .{ state.composite_image_id, state.window_w, state.window_h, upload_size.w, upload_size.h, dest.col, dest.row, dest.w, dest.h });
        try backend.registerRawImage(state.composite_image_id, upload_buf, upload_size.w, upload_size.h);
        try kitty_protocol.writePlace(tty.file.deprecatedWriter(), dest.row, dest.col, .{
            .image_id = state.composite_image_id,
            .placement_id = state.composite_placement_id,
            .cols = dest.w,
            .rows = dest.h,
            .src_x = 0,
            .src_y = 0,
            .src_w = upload_size.w,
            .src_h = upload_size.h,
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
            self.stats.texture_upload_bytes += upload_buf.len;
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
        // TODO: Tiled composition is currently optimistic about upload completion.
        // This is OK for direct APC and kitty file-offset transport in practice, but
        // ghostty file_whole showed missing tiles when rotating temp paths were
        // reused before the terminal had finished reading/accepting earlier uploads.
        //
        // A reliable high-traffic file transport needs an ACK-driven upload pipeline:
        // enable graphics replies for uploads, correlate replies by image_id, keep a
        // bounded set of file slots in flight, emit or retain dependent placements
        // only once the upload is accepted, and mark a file slot reusable only after
        // that ACK. When saturated, coalesce more tiles into larger strips, apply
        // backpressure, or fall back to fullscreen/direct APC. Without that, local
        // fsync only proves the file is durable locally, not that the terminal has
        // consumed it.
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
                self.retireCompositeTileImageIfUnreferenced(state, old_image_id);
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
            }
            const old_image_id = tile.image_id;
            tile.image_id = 0;
            tile.placement_id = 0;
            self.retireCompositeTileImageIfUnreferenced(state, old_image_id);
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
            const old_image_id = tile.image_id;
            tile.image_id = 0;
            tile.placement_id = 0;
            self.retireCompositeTileImageIfUnreferenced(state, old_image_id);
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
        if (state.fills.items.len + state.lines.items.len > primitive_composite_threshold) return true;
        for (state.copies.items) |copy| {
            const texture = self.textures.get(copy.texture_key) orelse continue;
            if (copy.blend_mode != sdl.SDL_BLENDMODE_NONE and copy.blend_mode != sdl.SDL_BLENDMODE_BLEND) return true;
            if (!std.meta.eql(copy.color_mod, texture.color_mod) or copy.alpha_mod != texture.alpha_mod) return true;
            if (copy.src.w != copy.dst.w or copy.src.h != copy.dst.h) return true;
        }
        return false;
    }

    fn presentDebugSignature(self: *FrameBuilder, state: *const RendererState, use_composite: bool) PresentDebugSignature {
        var signature = PresentDebugSignature{
            .use_composite = use_composite,
            .copies = state.copies.items.len,
            .fills = state.fills.items.len,
            .lines = state.lines.items.len,
        };
        if (state.copies.items.len > 0) {
            const first = state.copies.items[0];
            signature.first_copy_texture_key = first.texture_key;
            signature.first_copy_blend_mode = first.blend_mode;
            signature.first_copy_src = first.src;
            signature.first_copy_dst = first.dst;
        }
        for (state.copies.items) |copy| {
            const texture = self.textures.get(copy.texture_key) orelse {
                signature.missing_textures += 1;
                continue;
            };
            if (copy.blend_mode != sdl.SDL_BLENDMODE_NONE and copy.blend_mode != sdl.SDL_BLENDMODE_BLEND) signature.unsupported_copies += 1;
            if (!std.meta.eql(copy.color_mod, texture.color_mod) or copy.alpha_mod != texture.alpha_mod) signature.mod_mismatch_copies += 1;
            if (copy.src.w != copy.dst.w or copy.src.h != copy.dst.h) signature.scaled_copies += 1;
        }
        return signature;
    }

    fn shouldLogPresentDecision(self: *FrameBuilder, state: *RendererState, use_composite: bool) bool {
        return self.changedPresentDebugSignature(state, use_composite) != null;
    }

    fn changedPresentDebugSignature(self: *FrameBuilder, state: *RendererState, use_composite: bool) ?PresentDebugSignature {
        const signature = self.presentDebugSignature(state, use_composite);
        if (state.last_debug_present_signature) |last| {
            if (std.meta.eql(last, signature)) return null;
        }
        state.last_debug_present_signature = signature;
        return signature;
    }

    fn logPresentDecision(self: *FrameBuilder, logger: *Logger, state: *const RendererState, signature: PresentDebugSignature) void {
        _ = self;
        logger.writeFmt(
            "katzensteg: present decision composite={} copies={} fills={} lines={} unsupported_copies={} mod_mismatch_copies={} scaled_copies={} missing_textures={}",
            .{ signature.use_composite, state.copies.items.len, state.fills.items.len, state.lines.items.len, signature.unsupported_copies, signature.mod_mismatch_copies, signature.scaled_copies, signature.missing_textures },
        );
        const limit = @min(state.copies.items.len, 4);
        for (state.copies.items[0..limit], 0..) |copy, i| {
            logger.writeFmt(
                "katzensteg: present copy[{d}] tex={x} blend={s}({d}) mod=({d},{d},{d}) alpha={d} src={d},{d} {d}x{d} dst={d},{d} {d}x{d}",
                .{ i, copy.texture_key, blendModeName(copy.blend_mode), copy.blend_mode, copy.color_mod[0], copy.color_mod[1], copy.color_mod[2], copy.alpha_mod, copy.src.x, copy.src.y, copy.src.w, copy.src.h, copy.dst.x, copy.dst.y, copy.dst.w, copy.dst.h },
            );
        }
    }

    fn buildCompositeFrame(self: *FrameBuilder, logger: *Logger, state: *RendererState) !void {
        const pixel_count: usize = @intCast(state.window_w * state.window_h * 4);
        if (state.composite_rgba == null or state.composite_rgba.?.len != pixel_count) {
            if (state.composite_rgba) |buf| self.allocator.free(buf);
            state.composite_rgba = try self.allocator.alloc(u8, pixel_count);
        }
        const buf = state.composite_rgba.?;
        const first_copy_index = self.findLastFramebufferOverwriteCopy(state) orelse blk: {
            @call(.never_inline, clearFramebuffer, .{ buf, state.window_w, state.window_h, state.clear_color });
            for (state.fills.items) |fill| @call(.never_inline, compositeFill, .{ buf, state.window_w, state.window_h, fill.rect, fill.color });
            for (state.lines.items) |line| {
                const rect = sdl.SDL_Rect{ .x = @min(line.x1, line.x2), .y = @min(line.y1, line.y2), .w = @max(1, @max(line.x1, line.x2) - @min(line.x1, line.x2) + 1), .h = @max(1, @max(line.y1, line.y2) - @min(line.y1, line.y2) + 1) };
                @call(.never_inline, compositeFill, .{ buf, state.window_w, state.window_h, rect, line.color });
            }
            break :blk 0;
        };
        for (state.copies.items[first_copy_index..]) |copy| {
            const texture = self.textures.get(copy.texture_key) orelse continue;
            const src_rgba = texture.base_rgba orelse continue;
            @call(.never_inline, compositeCopy, .{
                buf,
                state.window_w,
                state.window_h,
                src_rgba,
                texture.w,
                texture.h,
                copy.base_opaque,
                copy.src,
                copy.dst,
                copy.blend_mode,
                copy.color_mod,
                copy.alpha_mod,
            });
        }
        const now = std.time.nanoTimestamp();
        if (self.dump_composites and now - self.last_composite_dump_ns >= 2 * std.time.ns_per_s) {
            self.dumpCompositeFrame(logger, buf, state.window_w, state.window_h);
            self.last_composite_dump_ns = now;
        }
        if (state.composite_last_presented) |last| {
            if (last.len == buf.len and std.mem.eql(u8, last, buf)) {
                if (self.debug_composite and !state.logged_debug_composite_unchanged) {
                    logger.write("katzensteg: composite unchanged; skipping tile uploads");
                    state.logged_debug_composite_unchanged = true;
                }
                return;
            }
        }
        state.logged_debug_composite_unchanged = false;
        if (self.debug_composite) _ = self.logCompositeStats(logger, buf, state.window_w, state.window_h);
    }

    fn findLastFramebufferOverwriteCopy(self: *FrameBuilder, state: *const RendererState) ?usize {
        var index = state.copies.items.len;
        while (index > 0) {
            index -= 1;
            const copy = state.copies.items[index];
            const texture = self.textures.get(copy.texture_key) orelse continue;
            if (!copyFullyOverwritesDestination(texture, copy)) continue;
            if (copy.dst.x > 0 or copy.dst.y > 0) continue;
            if (copy.dst.x + copy.dst.w < state.window_w) continue;
            if (copy.dst.y + copy.dst.h < state.window_h) continue;
            return index;
        }
        return null;
    }

    fn copyFullyOverwritesDestination(texture: TextureRecord, copy: RenderCopyOp) bool {
        const src_rect = copy.src;
        if (src_rect.x < 0 or src_rect.y < 0) return false;
        if (src_rect.x + src_rect.w > texture.w or src_rect.y + src_rect.h > texture.h) return false;
        return switch (copy.blend_mode) {
            sdl.SDL_BLENDMODE_NONE => true,
            sdl.SDL_BLENDMODE_BLEND => copy.base_opaque and copy.alpha_mod == 255,
            else => false,
        };
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

    fn compositeTileImageIsReferenced(state: *const RendererState, image_id: u32) bool {
        if (image_id == 0) return false;
        for (state.composite_tiles.items) |tile| {
            if (tile.image_id == image_id) return true;
        }
        return false;
    }

    fn retireCompositeTileImageIfUnreferenced(self: *FrameBuilder, state: *const RendererState, image_id: u32) void {
        if (!compositeTileImageIsReferenced(state, image_id)) self.retireImageId(image_id);
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

    fn allocAssetId(self: *FrameBuilder) u64 {
        const id = self.next_asset_id;
        self.next_asset_id +%= 1;
        if (self.next_asset_id == 0) self.next_asset_id = 1;
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

    fn geometryVertexIndex(indices: ?*const anyopaque, offset: usize, size_indices: usize) ?usize {
        const raw = indices orelse return offset;
        const bytes: [*]const u8 = @ptrCast(raw);
        return switch (size_indices) {
            1 => bytes[offset],
            2 => std.mem.readInt(u16, bytes[offset * 2 ..][0..2], .little),
            4 => std.mem.readInt(u32, bytes[offset * 4 ..][0..4], .little),
            else => null,
        };
    }

    fn readStridedF32Pair(values: [*]const f32, stride: usize, index: usize) [2]f32 {
        const bytes: [*]const u8 = @ptrCast(values);
        const base = index * stride;
        return .{
            @bitCast(std.mem.readInt(u32, bytes[base..][0..4], .little)),
            @bitCast(std.mem.readInt(u32, bytes[base + 4 ..][0..4], .little)),
        };
    }

    fn nearF32(a: f32, b: f32) bool {
        return @abs(a - b) <= 0.01;
    }

    fn floorToI32(value: f32) i32 {
        return @intFromFloat(@floor(value));
    }

    fn ceilToI32(value: f32) i32 {
        return @intFromFloat(@ceil(value));
    }

    fn clampI32(value: i32, low: i32, high: i32) i32 {
        return @max(low, @min(high, value));
    }

    fn convertTextureToRgba(dst: []u8, src: [*]u8, pitch: i32, w: i32, h: i32, format: sdl.Uint32) bool {
        if (w <= 0 or h <= 0 or pitch <= 0) return false;
        const src_bpp = textureFormatBytesPerPixel(format) orelse return false;
        const src_row_bytes: usize = @as(usize, @intCast(w)) * src_bpp;
        const dst_row_bytes: usize = @as(usize, @intCast(w)) * 4;
        if (@as(usize, @intCast(pitch)) < src_row_bytes) return false;
        if (dst.len < @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) return false;
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            const src_row = src[@as(usize, @intCast(y * pitch))..][0..src_row_bytes];
            const dst_row = dst[@as(usize, @intCast(y * w * 4))..][0..dst_row_bytes];
            switch (format) {
                sdl.SDL_PIXELFORMAT_ABGR8888 => {
                    // On little-endian systems this is already byte-wise RGBA.
                    std.mem.copyForwards(u8, dst_row, src_row);
                },
                sdl.SDL_PIXELFORMAT_ARGB8888 => {
                    var i: usize = 0;
                    while (i < dst_row_bytes) : (i += 4) {
                        dst_row[i + 0] = src_row[i + 2];
                        dst_row[i + 1] = src_row[i + 1];
                        dst_row[i + 2] = src_row[i + 0];
                        dst_row[i + 3] = src_row[i + 3];
                    }
                },
                sdl.SDL_PIXELFORMAT_XRGB8888 => {
                    var i: usize = 0;
                    while (i < dst_row_bytes) : (i += 4) {
                        dst_row[i + 0] = src_row[i + 2];
                        dst_row[i + 1] = src_row[i + 1];
                        dst_row[i + 2] = src_row[i + 0];
                        dst_row[i + 3] = 255;
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

    fn tryFastYuv420PlanesToRgba(dst: []u8, w: i32, h: i32, yplane: [*]const u8, ypitch: i32, uplane: [*]const u8, upitch: i32, vplane: [*]const u8, vpitch: i32) bool {
        if (comptime (builtin.os.tag == .macos and !builtin.is_test)) {
            return ks_fast_i420_to_rgba(dst.ptr, @intCast(w), @intCast(h), yplane, @intCast(ypitch), uplane, @intCast(upitch), vplane, @intCast(vpitch)) != 0;
        }
        return false;
    }

    fn tryFastNv12PlanesToRgba(dst: []u8, w: i32, h: i32, yplane: [*]const u8, ypitch: i32, uvplane: [*]const u8, uvpitch: i32) bool {
        if (comptime (builtin.os.tag == .macos and !builtin.is_test)) {
            return ks_fast_nv12_to_rgba(dst.ptr, @intCast(w), @intCast(h), yplane, @intCast(ypitch), uvplane, @intCast(uvpitch)) != 0;
        }
        return false;
    }

    fn convertYuv420PlanesToRgba(dst: []u8, w: i32, h: i32, yplane: [*]const u8, ypitch: i32, uplane: [*]const u8, upitch: i32, vplane: [*]const u8, vpitch: i32) void {
        const width: usize = @intCast(w);
        const height: usize = @intCast(h);
        const y_stride: usize = @intCast(ypitch);
        const u_stride: usize = @intCast(upitch);
        const v_stride: usize = @intCast(vpitch);

        var y: usize = 0;
        while (y < height) : (y += 2) {
            const chroma_y = y / 2;
            var x: usize = 0;
            while (x < width) : (x += 2) {
                const chroma_x = x / 2;
                const u = uplane[chroma_y * u_stride + chroma_x];
                const v = vplane[chroma_y * v_stride + chroma_x];
                const chroma = yuvChromaTerms(u, v);

                writeYuvPixelWithChroma(dst, (y * width + x) * 4, yplane[y * y_stride + x], chroma);
                if (x + 1 < width) {
                    writeYuvPixelWithChroma(dst, (y * width + x + 1) * 4, yplane[y * y_stride + x + 1], chroma);
                }
                if (y + 1 < height) {
                    writeYuvPixelWithChroma(dst, ((y + 1) * width + x) * 4, yplane[(y + 1) * y_stride + x], chroma);
                    if (x + 1 < width) {
                        writeYuvPixelWithChroma(dst, ((y + 1) * width + x + 1) * 4, yplane[(y + 1) * y_stride + x + 1], chroma);
                    }
                }
            }
        }
    }

    fn convertNv12PlanesToRgba(dst: []u8, w: i32, h: i32, yplane: [*]const u8, ypitch: i32, uvplane: [*]const u8, uvpitch: i32, swap_uv: bool) void {
        const width: usize = @intCast(w);
        const height: usize = @intCast(h);
        const y_stride: usize = @intCast(ypitch);
        const uv_stride: usize = @intCast(uvpitch);

        var y: usize = 0;
        while (y < height) : (y += 2) {
            const chroma_y = y / 2;
            var x: usize = 0;
            while (x < width) : (x += 2) {
                const chroma_x = x / 2;
                const uv_index = chroma_y * uv_stride + chroma_x * 2;
                const first = uvplane[uv_index];
                const second = uvplane[uv_index + 1];
                const u = if (swap_uv) second else first;
                const v = if (swap_uv) first else second;
                const chroma = yuvChromaTerms(u, v);

                writeYuvPixelWithChroma(dst, (y * width + x) * 4, yplane[y * y_stride + x], chroma);
                if (x + 1 < width) {
                    writeYuvPixelWithChroma(dst, (y * width + x + 1) * 4, yplane[y * y_stride + x + 1], chroma);
                }
                if (y + 1 < height) {
                    writeYuvPixelWithChroma(dst, ((y + 1) * width + x) * 4, yplane[(y + 1) * y_stride + x], chroma);
                    if (x + 1 < width) {
                        writeYuvPixelWithChroma(dst, ((y + 1) * width + x + 1) * 4, yplane[(y + 1) * y_stride + x + 1], chroma);
                    }
                }
            }
        }
    }

    fn writeYuvPixel(dst: []u8, offset: usize, y: u8, u: u8, v: u8) void {
        writeYuvPixelWithChroma(dst, offset, y, yuvChromaTerms(u, v));
    }

    const YuvChromaTerms = struct {
        r: i32,
        g: i32,
        b: i32,
    };

    fn yuvChromaTerms(u: u8, v: u8) YuvChromaTerms {
        const d: i32 = @as(i32, u) - 128;
        const e: i32 = @as(i32, v) - 128;
        return .{
            .r = 409 * e + 128,
            .g = -100 * d - 208 * e + 128,
            .b = 516 * d + 128,
        };
    }

    fn writeYuvPixelWithChroma(dst: []u8, offset: usize, y: u8, chroma: YuvChromaTerms) void {
        const c: i32 = @max(0, @as(i32, y) - 16);
        const luma = 298 * c;
        dst[offset + 0] = clampU8((luma + chroma.r) >> 8);
        dst[offset + 1] = clampU8((luma + chroma.g) >> 8);
        dst[offset + 2] = clampU8((luma + chroma.b) >> 8);
        dst[offset + 3] = 255;
    }

    fn clampU8(value: i32) u8 {
        return @intCast(@max(0, @min(255, value)));
    }

    fn isSupportedTextureFormat(format: sdl.Uint32) bool {
        return switch (format) {
            sdl.SDL_PIXELFORMAT_ABGR8888,
            sdl.SDL_PIXELFORMAT_ARGB8888,
            sdl.SDL_PIXELFORMAT_XRGB8888,
            sdl.SDL_PIXELFORMAT_RGB565,
            sdl.SDL_PIXELFORMAT_RGBA4444,
            => true,
            else => false,
        };
    }

    fn textureFormatBytesPerPixel(format: sdl.Uint32) ?usize {
        return switch (format) {
            sdl.SDL_PIXELFORMAT_ABGR8888,
            sdl.SDL_PIXELFORMAT_ARGB8888,
            sdl.SDL_PIXELFORMAT_XRGB8888,
            => 4,
            sdl.SDL_PIXELFORMAT_RGB565,
            sdl.SDL_PIXELFORMAT_RGBA4444,
            => 2,
            else => null,
        };
    }

    fn clearFramebuffer(buf: []u8, w: i32, h: i32, color: [4]u8) void {
        _ = w;
        _ = h;
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            buf[i + 0] = color[0];
            buf[i + 1] = color[1];
            buf[i + 2] = color[2];
            buf[i + 3] = 255;
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
                dst[di + 3] = 255;
            }
        }
    }

    const ScaledAxisStepper = struct {
        current: i32,
        quotient: i32,
        remainder: i32,
        remainder_step: i32,
        denominator: i32,

        fn init(src_origin: i32, src_len: i32, dst_len: i32, start: i32) ScaledAxisStepper {
            const product = @as(i64, start) * @as(i64, src_len);
            return .{
                .current = src_origin + @as(i32, @intCast(@divTrunc(product, dst_len))),
                .quotient = @divTrunc(src_len, dst_len),
                .remainder = @intCast(@rem(product, dst_len)),
                .remainder_step = @rem(src_len, dst_len),
                .denominator = dst_len,
            };
        }

        fn value(self: ScaledAxisStepper) i32 {
            return self.current;
        }

        fn advance(self: *ScaledAxisStepper) void {
            self.current += self.quotient;
            self.remainder += self.remainder_step;
            if (self.remainder >= self.denominator) {
                self.current += 1;
                self.remainder -= self.denominator;
            }
        }
    };

    const ScaledRunStepper = struct {
        src_offset: i32,
        run_end: i32,
        quotient: i32,
        remainder: i32,
        remainder_step: i32,
        denominator: i32,

        fn init(src_len: i32, dst_len: i32, start: i32) ScaledRunStepper {
            const src_offset: i32 = @intCast(@divTrunc(@as(i64, start) * @as(i64, src_len), @as(i64, dst_len)));
            const boundary_index = src_offset + 1;
            const quotient = @divTrunc(dst_len, src_len);
            const remainder_step = @rem(dst_len, src_len);
            return .{
                .src_offset = src_offset,
                .run_end = ceilDivPositiveI32(@as(i64, boundary_index) * @as(i64, dst_len), src_len),
                .quotient = quotient,
                .remainder = @intCast(@rem(@as(i64, boundary_index) * @as(i64, remainder_step) + src_len - 1, src_len)),
                .remainder_step = remainder_step,
                .denominator = src_len,
            };
        }

        fn advance(self: *ScaledRunStepper) void {
            self.src_offset += 1;
            self.run_end += self.quotient;
            self.remainder += self.remainder_step;
            if (self.remainder >= self.denominator) {
                self.run_end += 1;
                self.remainder -= self.denominator;
            }
        }
    };

    const max_precomputed_scaled_runs = 4096;

    const ScaledRun = struct {
        src_x_byte_offset: usize,
        pixels: usize,
    };

    fn scaleRgbaNearest(allocator: std.mem.Allocator, src: []const u8, src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) ![]u8 {
        const dst_len: usize = @intCast(dst_w * dst_h * 4);
        const dst = try allocator.alloc(u8, dst_len);
        const src_w_usize: usize = @intCast(src_w);
        const dst_w_usize: usize = @intCast(dst_w);
        var y: i32 = 0;
        while (y < dst_h) : (y += 1) {
            const src_y: i32 = @divTrunc(y * src_h, dst_h);
            var x: i32 = 0;
            while (x < dst_w) : (x += 1) {
                const src_x: i32 = @divTrunc(x * src_w, dst_w);
                const src_index = (@as(usize, @intCast(src_y)) * src_w_usize + @as(usize, @intCast(src_x))) * 4;
                const dst_index = (@as(usize, @intCast(y)) * dst_w_usize + @as(usize, @intCast(x))) * 4;
                @memcpy(dst[dst_index .. dst_index + 4], src[src_index .. src_index + 4]);
            }
        }
        return dst;
    }

    fn compositeCopy(dst: []u8, dst_w: i32, dst_h: i32, src: []const u8, src_w: i32, src_h: i32, src_opaque: bool, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, blend_mode: i32, color_mod: [3]u8, alpha_mod: u8) void {
        if (dst_rect.w <= 0 or dst_rect.h <= 0 or src_rect.w <= 0 or src_rect.h <= 0) return;
        const x_start = @max(0, -dst_rect.x);
        const y_start = @max(0, -dst_rect.y);
        const x_end = @min(dst_rect.w, dst_w - dst_rect.x);
        const y_end = @min(dst_rect.h, dst_h - dst_rect.y);
        if (x_start >= x_end or y_start >= y_end) return;

        const identity_mod = isIdentityMod(color_mod, alpha_mod);
        const effective_overwrite = blend_mode == sdl.SDL_BLENDMODE_NONE or (blend_mode == sdl.SDL_BLENDMODE_BLEND and src_opaque and alpha_mod == 255);
        if (identity_mod and effective_overwrite and src_rect.w == dst_rect.w and src_rect.h == dst_rect.h) {
            @call(.never_inline, compositeCopySameSizeNone, .{ dst, dst_w, src, src_w, src_h, src_opaque, src_rect, dst_rect, x_start, y_start, x_end, y_end });
            return;
        }
        if (identity_mod and effective_overwrite) {
            @call(.never_inline, compositeCopyScaledNone, .{ dst, dst_w, src, src_w, src_h, src_opaque, src_rect, dst_rect, x_start, y_start, x_end, y_end });
            return;
        }
        const x_start_stepper = ScaledAxisStepper.init(src_rect.x, src_rect.w, dst_rect.w, x_start);
        var y_stepper = ScaledAxisStepper.init(src_rect.y, src_rect.h, dst_rect.h, y_start);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const dy = dst_rect.y + y;
            const sy = y_stepper.value();
            y_stepper.advance();
            if (sy < 0 or sy >= src_h) continue;
            var x_stepper = x_start_stepper;
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const dx = dst_rect.x + x;
                const sx = x_stepper.value();
                x_stepper.advance();
                if (sx < 0 or sx >= src_w) continue;
                const si: usize = @intCast((sy * src_w + sx) * 4);
                const di: usize = @intCast((dy * dst_w + dx) * 4);
                switch (blend_mode) {
                    sdl.SDL_BLENDMODE_NONE => {
                        if (identity_mod) {
                            dst[di + 0] = src[si + 0];
                            dst[di + 1] = src[si + 1];
                            dst[di + 2] = src[si + 2];
                        } else {
                            dst[di + 0] = @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255);
                            dst[di + 1] = @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255);
                            dst[di + 2] = @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255);
                        }
                        dst[di + 3] = 255;
                    },
                    sdl.SDL_BLENDMODE_BLEND => {
                        if (identity_mod) {
                            blendPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            blendChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
                    sdl.SDL_BLENDMODE_ADD => {
                        if (identity_mod) {
                            addPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            addChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
                    else => {
                        if (identity_mod) {
                            blendPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            blendChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
                }
            }
        }
    }

    fn compositeCopyScaledNone(dst: []u8, dst_w: i32, src: []const u8, src_w: i32, src_h: i32, src_opaque: bool, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, x_start: i32, y_start: i32, x_end: i32, y_end: i32) void {
        _ = src_opaque;
        const dst_w_usize: usize = @intCast(dst_w);
        const src_w_usize: usize = @intCast(src_w);
        const src_x_fully_in_bounds = src_rect.x >= 0 and src_rect.x + src_rect.w <= src_w;
        const x_start_stepper = ScaledAxisStepper.init(src_rect.x, src_rect.w, dst_rect.w, x_start);
        var y_stepper = ScaledAxisStepper.init(src_rect.y, src_rect.h, dst_rect.h, y_start);
        var y = y_start;
        var previous_sy: ?i32 = null;
        var previous_row_start: usize = 0;
        const row_bytes: usize = @intCast((x_end - x_start) * 4);
        var precomputed_runs: [max_precomputed_scaled_runs]ScaledRun = undefined;
        var precomputed_run_count: usize = 0;
        const has_precomputed_runs = if (src_x_fully_in_bounds)
            precomputeScaledRuns(&precomputed_runs, &precomputed_run_count, src_rect, dst_rect, x_start, x_end)
        else
            false;
        while (y < y_end) : (y += 1) {
            const dy_i32 = dst_rect.y + y;
            const sy_i32 = y_stepper.value();
            y_stepper.advance();
            if (sy_i32 < 0 or sy_i32 >= src_h) continue;

            const dy: usize = @intCast(dy_i32);
            const sy: usize = @intCast(sy_i32);
            var di = (dy * dst_w_usize + @as(usize, @intCast(dst_rect.x + x_start))) * 4;
            const row_start = di;
            if (src_x_fully_in_bounds and previous_sy != null and previous_sy.? == sy_i32) {
                @memcpy(dst[row_start .. row_start + row_bytes], dst[previous_row_start .. previous_row_start + row_bytes]);
                continue;
            }
            var x_stepper = x_start_stepper;
            var x = x_start;
            if (has_precomputed_runs) {
                const src_row_start = sy * src_w_usize * 4;
                for (precomputed_runs[0..precomputed_run_count]) |run| {
                    const si = src_row_start + run.src_x_byte_offset;
                    const pixel = readOpaquePixel(src[si..][0..4]);
                    switch (run.pixels) {
                        1 => writeOpaquePixelValue(dst[di..][0..4], pixel),
                        2 => {
                            writeOpaquePixelValue(dst[di..][0..4], pixel);
                            writeOpaquePixelValue(dst[di + 4 ..][0..4], pixel);
                        },
                        else => writeOpaquePixelRun(dst[di .. di + run.pixels * 4], pixel, run.pixels),
                    }
                    di += run.pixels * 4;
                }
            } else if (src_x_fully_in_bounds) {
                var run_stepper = ScaledRunStepper.init(src_rect.w, dst_rect.w, x_start);
                while (x < x_end) {
                    while (run_stepper.run_end <= x) run_stepper.advance();
                    const sx: usize = @intCast(src_rect.x + run_stepper.src_offset);
                    var run_end = run_stepper.run_end;
                    if (run_end <= x) run_end = x + 1;
                    run_end = @min(run_end, x_end);
                    const run_pixels: usize = @intCast(run_end - x);
                    const si = (sy * src_w_usize + sx) * 4;
                    const pixel = readOpaquePixel(src[si..][0..4]);
                    switch (run_pixels) {
                        1 => writeOpaquePixelValue(dst[di..][0..4], pixel),
                        2 => {
                            writeOpaquePixelValue(dst[di..][0..4], pixel);
                            writeOpaquePixelValue(dst[di + 4 ..][0..4], pixel);
                        },
                        else => writeOpaquePixelRun(dst[di .. di + run_pixels * 4], pixel, run_pixels),
                    }
                    di += run_pixels * 4;
                    x = run_end;
                    if (x == run_stepper.run_end) run_stepper.advance();
                }
            } else {
                while (x < x_end) : (x += 1) {
                    const sx_i32 = x_stepper.value();
                    x_stepper.advance();
                    if (sx_i32 >= 0 and sx_i32 < src_w) {
                        const sx: usize = @intCast(sx_i32);
                        const si = (sy * src_w_usize + sx) * 4;
                        writeOpaquePixel(dst[di..][0..4], src[si..][0..4]);
                    }
                    di += 4;
                }
            }
            previous_sy = sy_i32;
            previous_row_start = row_start;
        }
    }

    fn precomputeScaledRuns(runs: []ScaledRun, run_count: *usize, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, x_start: i32, x_end: i32) bool {
        var stepper = ScaledRunStepper.init(src_rect.w, dst_rect.w, x_start);
        var x = x_start;
        var count: usize = 0;
        while (x < x_end) {
            if (count == runs.len) return false;
            while (stepper.run_end <= x) stepper.advance();
            var run_end = stepper.run_end;
            if (run_end <= x) run_end = x + 1;
            run_end = @min(run_end, x_end);
            runs[count] = .{
                .src_x_byte_offset = @intCast((src_rect.x + stepper.src_offset) * 4),
                .pixels = @intCast(run_end - x),
            };
            count += 1;
            x = run_end;
            if (x == stepper.run_end) stepper.advance();
        }
        run_count.* = count;
        return true;
    }

    fn ceilDivPositiveI32(numerator: i64, denominator: i32) i32 {
        const denom: i64 = denominator;
        return @intCast(@divTrunc(numerator + denom - 1, denom));
    }

    fn readOpaquePixel(src: *const [4]u8) u32 {
        return std.mem.readInt(u32, src, .little) | 0xff000000;
    }

    fn writeOpaquePixel(dst: *[4]u8, src: *const [4]u8) void {
        writeOpaquePixelValue(dst, readOpaquePixel(src));
    }

    fn writeOpaquePixelValue(dst: *[4]u8, pixel: u32) void {
        std.mem.writeInt(u32, dst, pixel, .little);
    }

    fn writeOpaquePixelRun(dst: []u8, pixel: u32, count: usize) void {
        const pair = @as(u64, pixel) | (@as(u64, pixel) << 32);
        var offset: usize = 0;
        var remaining = count;
        while (remaining >= 4) : (remaining -= 4) {
            std.mem.writeInt(u64, dst[offset..][0..8], pair, .little);
            std.mem.writeInt(u64, dst[offset + 8 ..][0..8], pair, .little);
            offset += 16;
        }
        if (remaining >= 2) {
            std.mem.writeInt(u64, dst[offset..][0..8], pair, .little);
            offset += 8;
            remaining -= 2;
        }
        if (remaining == 1) {
            std.mem.writeInt(u32, dst[offset..][0..4], pixel, .little);
        }
    }

    fn compositeCopyReference(dst: []u8, dst_w: i32, dst_h: i32, src: []const u8, src_w: i32, src_h: i32, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, blend_mode: i32, color_mod: [3]u8, alpha_mod: u8) void {
        if (dst_rect.w <= 0 or dst_rect.h <= 0 or src_rect.w <= 0 or src_rect.h <= 0) return;
        const x_start = @max(0, -dst_rect.x);
        const y_start = @max(0, -dst_rect.y);
        const x_end = @min(dst_rect.w, dst_w - dst_rect.x);
        const y_end = @min(dst_rect.h, dst_h - dst_rect.y);
        if (x_start >= x_end or y_start >= y_end) return;

        const identity_mod = isIdentityMod(color_mod, alpha_mod);
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const dy = dst_rect.y + y;
            const sy = src_rect.y + @divTrunc(y * src_rect.h, dst_rect.h);
            if (sy < 0 or sy >= src_h) continue;
            var x = x_start;
            while (x < x_end) : (x += 1) {
                const dx = dst_rect.x + x;
                const sx = src_rect.x + @divTrunc(x * src_rect.w, dst_rect.w);
                if (sx < 0 or sx >= src_w) continue;
                const si: usize = @intCast((sy * src_w + sx) * 4);
                const di: usize = @intCast((dy * dst_w + dx) * 4);
                switch (blend_mode) {
                    sdl.SDL_BLENDMODE_NONE => {
                        if (identity_mod) {
                            dst[di + 0] = src[si + 0];
                            dst[di + 1] = src[si + 1];
                            dst[di + 2] = src[si + 2];
                        } else {
                            dst[di + 0] = @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255);
                            dst[di + 1] = @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255);
                            dst[di + 2] = @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255);
                        }
                        dst[di + 3] = 255;
                    },
                    sdl.SDL_BLENDMODE_BLEND => {
                        if (identity_mod) {
                            blendPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            blendChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
                    sdl.SDL_BLENDMODE_ADD => {
                        if (identity_mod) {
                            addPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            addChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
                    else => {
                        if (identity_mod) {
                            blendPixelOpaque(dst[di .. di + 4], src[si .. si + 4]);
                        } else {
                            blendChannelsOpaque(
                                dst[di .. di + 4],
                                @intCast((@as(u16, src[si + 0]) * color_mod[0]) / 255),
                                @intCast((@as(u16, src[si + 1]) * color_mod[1]) / 255),
                                @intCast((@as(u16, src[si + 2]) * color_mod[2]) / 255),
                                @intCast((@as(u16, src[si + 3]) * alpha_mod) / 255),
                            );
                        }
                    },
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

    fn isIdentityMod(color_mod: [3]u8, alpha_mod: u8) bool {
        return color_mod[0] == 255 and color_mod[1] == 255 and color_mod[2] == 255 and alpha_mod == 255;
    }

    fn compositeCopySameSizeNone(dst: []u8, dst_w: i32, src: []const u8, src_w: i32, src_h: i32, src_opaque: bool, src_rect: sdl.SDL_Rect, dst_rect: sdl.SDL_Rect, x_start: i32, y_start: i32, x_end: i32, y_end: i32) void {
        const dst_w_usize: usize = @intCast(dst_w);
        const src_w_usize: usize = @intCast(src_w);
        const row_pixels: usize = @intCast(x_end - x_start);
        const row_bytes = row_pixels * 4;
        var y = y_start;
        while (y < y_end) : (y += 1) {
            const sy_i32 = src_rect.y + y;
            if (sy_i32 < 0 or sy_i32 >= src_h) continue;
            const sx_i32 = src_rect.x + x_start;
            if (sx_i32 < 0 or sx_i32 + @as(i32, @intCast(row_pixels)) > src_w) continue;
            const dy_i32 = dst_rect.y + y;
            const dx_i32 = dst_rect.x + x_start;
            const sy: usize = @intCast(sy_i32);
            const sx: usize = @intCast(sx_i32);
            const dy: usize = @intCast(dy_i32);
            const dx: usize = @intCast(dx_i32);
            const src_start = (sy * src_w_usize + sx) * 4;
            const dst_start = (dy * dst_w_usize + dx) * 4;
            if (src_opaque) {
                @memcpy(dst[dst_start .. dst_start + row_bytes], src[src_start .. src_start + row_bytes]);
            } else {
                var i: usize = 0;
                while (i < row_bytes) : (i += 4) {
                    dst[dst_start + i + 0] = src[src_start + i + 0];
                    dst[dst_start + i + 1] = src[src_start + i + 1];
                    dst[dst_start + i + 2] = src[src_start + i + 2];
                    dst[dst_start + i + 3] = 255;
                }
            }
        }
    }

    fn blendPixelOpaque(dst: []u8, src: []const u8) void {
        blendChannelsOpaque(dst, src[0], src[1], src[2], src[3]);
    }

    fn blendChannelsOpaque(dst: []u8, sr: u8, sg: u8, sb: u8, sa_u8: u8) void {
        const sa: u16 = sa_u8;
        const inv: u16 = 255 - sa;
        dst[0] = @intCast((@as(u16, sr) * sa + @as(u16, dst[0]) * inv) / 255);
        dst[1] = @intCast((@as(u16, sg) * sa + @as(u16, dst[1]) * inv) / 255);
        dst[2] = @intCast((@as(u16, sb) * sa + @as(u16, dst[2]) * inv) / 255);
        dst[3] = 255;
    }

    fn addPixelOpaque(dst: []u8, src: []const u8) void {
        addChannelsOpaque(dst, src[0], src[1], src[2], src[3]);
    }

    fn addChannelsOpaque(dst: []u8, sr: u8, sg: u8, sb: u8, sa_u8: u8) void {
        const sa: u16 = sa_u8;
        dst[0] = @intCast(@min(255, @as(u16, dst[0]) + (@as(u16, sr) * sa) / 255));
        dst[1] = @intCast(@min(255, @as(u16, dst[1]) + (@as(u16, sg) * sa) / 255));
        dst[2] = @intCast(@min(255, @as(u16, dst[2]) + (@as(u16, sb) * sa) / 255));
        dst[3] = 255;
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

    fn rgbaIsOpaque(rgba: []const u8) bool {
        var i: usize = 3;
        while (i < rgba.len) : (i += 4) {
            if (rgba[i] != 255) return false;
        }
        return true;
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

    fn fullscreenCompositeCellRect(window_w: i32, window_h: i32, tty: *const DirectTty) ts_types.CellRect {
        return containedCellRect(window_w, window_h, tty);
    }

    fn fullscreenCompositePresentationRegion(window_w: i32, window_h: i32, tty: *const DirectTty) presentation_layout.PresentationRegion {
        const dest = fullscreenCompositeCellRect(window_w, window_h, tty);
        return .{
            .kind = .sdl_window,
            .tty_rect = .{ .col = dest.col, .row = dest.row, .w = dest.w, .h = dest.h },
            .sdl_rect = .{ .x = 0, .y = 0, .w = window_w, .h = window_h },
            .z = 0,
        };
    }

    fn fullscreenCompositeUploadSize(dest: ts_types.CellRect, source_w: i32, source_h: i32, tty: *const DirectTty) PixelSize {
        const cols: i32 = @intCast(tty.cols);
        const rows: i32 = @intCast(tty.rows);
        if (tty.pixel_width == 0 or tty.pixel_height == 0 or cols <= 0 or rows <= 0) return .{ .w = source_w, .h = source_h };

        const term_w: i32 = @intCast(tty.pixel_width);
        const term_h: i32 = @intCast(tty.pixel_height);
        return .{
            .w = @max(1, divRound(dest.w * term_w, cols)),
            .h = @max(1, divRound(dest.h * term_h, rows)),
        };
    }

    fn divRound(numerator: i32, denominator: i32) i32 {
        if (denominator <= 0) return numerator;
        return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
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

test "texture mod state reports only real changes" {
    var record = TextureRecord{
        .w = 16,
        .h = 16,
        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
        .image_id = 0,
    };

    try std.testing.expect(!setTextureColorMod(&record, 255, 255, 255));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, record.color_mod);

    try std.testing.expect(setTextureColorMod(&record, 128, 255, 64));
    try std.testing.expectEqual([3]u8{ 128, 255, 64 }, record.color_mod);
    try std.testing.expect(!setTextureColorMod(&record, 128, 255, 64));

    try std.testing.expect(!setTextureAlphaMod(&record, 255));
    try std.testing.expect(setTextureAlphaMod(&record, 127));
    try std.testing.expectEqual(@as(u8, 127), record.alpha_mod);
    try std.testing.expect(!setTextureAlphaMod(&record, 127));
}

test "identity texture publication borrows base rgba without modulation copy" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    const base = try std.testing.allocator.alloc(u8, 8);
    @memcpy(base, &[_]u8{ 10, 20, 30, 255, 40, 50, 60, 255 });
    var record = TextureRecord{
        .w = 2,
        .h = 1,
        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
        .image_id = 0,
        .base_rgba = base,
        .base_opaque = true,
    };
    defer {
        if (record.publish_rgba_owned) {
            if (record.publish_rgba) |buf| std.testing.allocator.free(buf);
        }
        if (record.base_rgba) |buf| std.testing.allocator.free(buf);
    }

    try builder.ensureTexturePublication(&record);

    try std.testing.expectEqual(base.ptr, record.publish_rgba.?.ptr);
    try std.testing.expect(!record.publish_rgba_owned);
    try std.testing.expect(record.asset_id != 0);
}

test "modded texture publication owns modulated rgba copy" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    const base = try std.testing.allocator.alloc(u8, 4);
    @memcpy(base, &[_]u8{ 100, 80, 60, 200 });
    var record = TextureRecord{
        .w = 1,
        .h = 1,
        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
        .image_id = 0,
        .base_rgba = base,
        .color_mod = .{ 128, 255, 64 },
        .alpha_mod = 127,
    };
    defer {
        if (record.publish_rgba_owned) {
            if (record.publish_rgba) |buf| std.testing.allocator.free(buf);
        }
        if (record.base_rgba) |buf| std.testing.allocator.free(buf);
    }

    try builder.ensureTexturePublication(&record);

    try std.testing.expect(record.publish_rgba.?.ptr != base.ptr);
    try std.testing.expect(record.publish_rgba_owned);
    try std.testing.expectEqualSlices(u8, &.{ 50, 80, 15, 99 }, record.publish_rgba.?);
}

test "composite framebuffer writes final opaque alpha inline" {
    var dst = [_]u8{0} ** (2 * 2 * 4);
    FrameBuilder.clearFramebuffer(&dst, 2, 2, .{ 10, 20, 30, 17 });
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, dst[0..4]);

    FrameBuilder.compositeFill(&dst, 2, 2, .{ .x = 1, .y = 0, .w = 1, .h = 1 }, .{ 40, 50, 60, 23 });
    try std.testing.expectEqualSlices(u8, &.{ 40, 50, 60, 255 }, dst[4..8]);

    const src = [_]u8{
        100, 110, 120, 9,
    };
    FrameBuilder.compositeCopy(&dst, 2, 2, &src, 1, 1, false, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 0, .y = 1, .w = 1, .h = 1 }, sdl.SDL_BLENDMODE_NONE, .{ 255, 255, 255 }, 255);
    try std.testing.expectEqualSlices(u8, &.{ 100, 110, 120, 255 }, dst[8..12]);
}

test "scaled composite copy preserves nearest-neighbor mapping" {
    var dst = [_]u8{0} ** (4 * 2 * 4);
    var src = [_]u8{
        10, 0, 0, 255, 20, 0, 0, 255,
        30, 0, 0, 255, 40, 0, 0, 255,
    };

    FrameBuilder.compositeCopy(&dst, 4, 2, &src, 2, 2, true, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .{ .x = 0, .y = 0, .w = 4, .h = 2 }, sdl.SDL_BLENDMODE_NONE, .{ 255, 255, 255 }, 255);

    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 255 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 255 }, dst[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 0, 255 }, dst[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 0, 0, 255 }, dst[12..16]);
}

test "scaled axis stepper matches division mapping from clipped offset" {
    var stepper = FrameBuilder.ScaledAxisStepper.init(3, 5, 13, 4);
    var values: [6]i32 = undefined;
    for (&values) |*value| {
        value.* = stepper.value();
        stepper.advance();
    }
    try std.testing.expectEqualSlices(i32, &.{ 4, 4, 5, 5, 6, 6 }, &values);
}

test "scaled axis stepper matches division formula across small ranges" {
    var src_origin: i32 = -4;
    while (src_origin <= 4) : (src_origin += 1) {
        var src_len: i32 = 1;
        while (src_len <= 32) : (src_len += 1) {
            var dst_len: i32 = 1;
            while (dst_len <= 48) : (dst_len += 1) {
                var start: i32 = 0;
                while (start < dst_len) : (start += 1) {
                    var stepper = FrameBuilder.ScaledAxisStepper.init(src_origin, src_len, dst_len, start);
                    var x = start;
                    while (x < dst_len) : (x += 1) {
                        try std.testing.expectEqual(src_origin + @divTrunc(x * src_len, dst_len), stepper.value());
                        stepper.advance();
                    }
                }
            }
        }
    }
}

test "fixed-point scaled composite matches reference division loop" {
    const src_w = 5;
    const src_h = 4;
    const dst_w = 7;
    const dst_h = 6;
    var src: [src_w * src_h * 4]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @intCast((i * 37 + 11) % 251);
    var base_dst_a: [dst_w * dst_h * 4]u8 = undefined;
    var base_dst_b: [dst_w * dst_h * 4]u8 = undefined;
    for (&base_dst_a, 0..) |*byte, i| byte.* = @intCast((i * 19 + 3) % 251);

    const src_rects = [_]sdl.SDL_Rect{
        .{ .x = 0, .y = 0, .w = 5, .h = 4 },
        .{ .x = -1, .y = 0, .w = 5, .h = 4 },
        .{ .x = 1, .y = -1, .w = 3, .h = 4 },
        .{ .x = 2, .y = 1, .w = 2, .h = 2 },
    };
    const dst_rects = [_]sdl.SDL_Rect{
        .{ .x = 0, .y = 0, .w = 7, .h = 6 },
        .{ .x = -2, .y = 1, .w = 8, .h = 4 },
        .{ .x = 2, .y = -1, .w = 4, .h = 8 },
        .{ .x = 1, .y = 2, .w = 3, .h = 2 },
    };
    const modes = [_]i32{ sdl.SDL_BLENDMODE_NONE, sdl.SDL_BLENDMODE_BLEND, sdl.SDL_BLENDMODE_ADD };
    const mods = [_]struct { color: [3]u8, alpha: u8 }{
        .{ .color = .{ 255, 255, 255 }, .alpha = 255 },
        .{ .color = .{ 200, 180, 160 }, .alpha = 127 },
    };

    for (src_rects) |src_rect| {
        for (dst_rects) |dst_rect| {
            for (modes) |mode| {
                for (mods) |mod| {
                    base_dst_b = base_dst_a;
                    var actual = base_dst_a;
                    FrameBuilder.compositeCopyReference(&base_dst_b, dst_w, dst_h, &src, src_w, src_h, src_rect, dst_rect, mode, mod.color, mod.alpha);
                    FrameBuilder.compositeCopy(&actual, dst_w, dst_h, &src, src_w, src_h, false, src_rect, dst_rect, mode, mod.color, mod.alpha);
                    try std.testing.expectEqualSlices(u8, &base_dst_b, &actual);
                }
            }
        }
    }
}

test "opaque blend scaled composite matches overwrite semantics" {
    const src_w = 3;
    const src_h = 2;
    const dst_w = 7;
    const dst_h = 5;
    var src: [src_w * src_h * 4]u8 = undefined;
    var p: usize = 0;
    while (p < src.len) : (p += 4) {
        src[p + 0] = @intCast((p * 17 + 3) % 251);
        src[p + 1] = @intCast((p * 19 + 5) % 251);
        src[p + 2] = @intCast((p * 23 + 7) % 251);
        src[p + 3] = 255;
    }

    var expected: [dst_w * dst_h * 4]u8 = undefined;
    var actual: [dst_w * dst_h * 4]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = @intCast((i * 29 + 13) % 251);
    actual = expected;

    const src_rect = sdl.SDL_Rect{ .x = 0, .y = 0, .w = src_w, .h = src_h };
    const dst_rect = sdl.SDL_Rect{ .x = 0, .y = 0, .w = dst_w, .h = dst_h };
    FrameBuilder.compositeCopyReference(&expected, dst_w, dst_h, &src, src_w, src_h, src_rect, dst_rect, sdl.SDL_BLENDMODE_BLEND, .{ 255, 255, 255 }, 255);
    FrameBuilder.compositeCopy(&actual, dst_w, dst_h, &src, src_w, src_h, true, src_rect, dst_rect, sdl.SDL_BLENDMODE_BLEND, .{ 255, 255, 255 }, 255);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "effective overwrite fast paths match reference across clipped scaled copies" {
    const src_w = 6;
    const src_h = 5;
    const dst_w = 8;
    const dst_h = 7;
    var src: [src_w * src_h * 4]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        src[i + 0] = @intCast((i * 31 + 1) % 251);
        src[i + 1] = @intCast((i * 37 + 2) % 251);
        src[i + 2] = @intCast((i * 41 + 3) % 251);
        src[i + 3] = 255;
    }

    var base: [dst_w * dst_h * 4]u8 = undefined;
    for (&base, 0..) |*byte, idx| byte.* = @intCast((idx * 43 + 9) % 251);

    const src_rects = [_]sdl.SDL_Rect{
        .{ .x = 0, .y = 0, .w = 6, .h = 5 },
        .{ .x = 1, .y = 1, .w = 4, .h = 3 },
        .{ .x = -1, .y = 0, .w = 5, .h = 4 },
        .{ .x = 2, .y = -1, .w = 4, .h = 5 },
    };
    const dst_rects = [_]sdl.SDL_Rect{
        .{ .x = 0, .y = 0, .w = 8, .h = 7 },
        .{ .x = -2, .y = 1, .w = 9, .h = 4 },
        .{ .x = 2, .y = -2, .w = 5, .h = 9 },
        .{ .x = 1, .y = 2, .w = 3, .h = 3 },
    };
    const modes = [_]i32{ sdl.SDL_BLENDMODE_NONE, sdl.SDL_BLENDMODE_BLEND };

    for (src_rects) |src_rect| {
        for (dst_rects) |dst_rect| {
            for (modes) |mode| {
                var expected = base;
                var actual = base;
                FrameBuilder.compositeCopyReference(&expected, dst_w, dst_h, &src, src_w, src_h, src_rect, dst_rect, mode, .{ 255, 255, 255 }, 255);
                FrameBuilder.compositeCopy(&actual, dst_w, dst_h, &src, src_w, src_h, true, src_rect, dst_rect, mode, .{ 255, 255, 255 }, 255);
                try std.testing.expectEqualSlices(u8, &expected, &actual);
            }
        }
    }
}

test "fullscreen composite placement preserves source aspect in terminal cells" {
    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    const dest = FrameBuilder.fullscreenCompositeCellRect(320, 240, &tty);
    try std.testing.expectEqual(@as(i32, 1), dest.col);
    try std.testing.expectEqual(@as(i32, 2), dest.row);
    try std.testing.expectEqual(@as(i32, 100), dest.w);
    try std.testing.expectEqual(@as(i32, 38), dest.h);
}

test "fullscreen composite upload size matches destination cell pixels" {
    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    const dest = FrameBuilder.fullscreenCompositeCellRect(320, 240, &tty);
    const upload = FrameBuilder.fullscreenCompositeUploadSize(dest, 320, 240, &tty);
    try std.testing.expectEqual(@as(i32, 1000), upload.w);
    try std.testing.expectEqual(@as(i32, 760), upload.h);
}

test "fullscreen composite presentation region matches placed image rect" {
    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    const dest = FrameBuilder.fullscreenCompositeCellRect(320, 240, &tty);
    const region = FrameBuilder.fullscreenCompositePresentationRegion(320, 240, &tty);

    try std.testing.expectEqual(presentation_layout.CellRect{
        .col = dest.col,
        .row = dest.row,
        .w = dest.w,
        .h = dest.h,
    }, region.tty_rect);
    try std.testing.expectEqual(presentation_layout.SdlRect{ .x = 0, .y = 0, .w = 320, .h = 240 }, region.sdl_rect);
}

test "fullscreen composite upload size falls back to source without terminal pixels" {
    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 0;
    tty.pixel_height = 0;

    const dest = FrameBuilder.fullscreenCompositeCellRect(320, 240, &tty);
    const upload = FrameBuilder.fullscreenCompositeUploadSize(dest, 320, 240, &tty);
    try std.testing.expectEqual(@as(i32, 320), upload.w);
    try std.testing.expectEqual(@as(i32, 240), upload.h);
}

test "composite builder can start at last full framebuffer overwrite" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    try builder.textures.put(1, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_BLEND });
    try builder.textures.put(2, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_NONE });
    try builder.textures.put(3, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_NONE });
    try builder.textures.put(4, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_BLEND, .base_opaque = true });

    var state = RendererState.init(std.testing.allocator, 16, 16);
    defer state.deinit(std.testing.allocator);

    try state.copies.append(std.testing.allocator, .{ .texture_key = 1, .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .dst = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .blend_mode = sdl.SDL_BLENDMODE_BLEND });
    try std.testing.expectEqual(@as(?usize, null), builder.findLastFramebufferOverwriteCopy(&state));

    try state.copies.append(std.testing.allocator, .{ .texture_key = 2, .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .dst = .{ .x = 1, .y = 0, .w = 15, .h = 16 } });
    try std.testing.expectEqual(@as(?usize, null), builder.findLastFramebufferOverwriteCopy(&state));

    try state.copies.append(std.testing.allocator, .{ .texture_key = 3, .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .dst = .{ .x = 0, .y = 0, .w = 16, .h = 16 } });
    try std.testing.expectEqual(@as(?usize, 2), builder.findLastFramebufferOverwriteCopy(&state));

    try state.copies.append(std.testing.allocator, .{ .texture_key = 4, .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .dst = .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .blend_mode = sdl.SDL_BLENDMODE_BLEND, .base_opaque = true });
    try std.testing.expectEqual(@as(?usize, 3), builder.findLastFramebufferOverwriteCopy(&state));
}

test "framebuffer composite requirement is based on copy-time render state" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    try builder.renderers.put(1, RendererState.init(std.testing.allocator, 8, 8));
    try builder.textures.put(10, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_ADD });
    try builder.textures.put(20, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0, .blend_mode = sdl.SDL_BLENDMODE_BLEND });

    const state = builder.renderers.getPtr(1).?;
    try std.testing.expect(!builder.needsFramebufferComposite(state));

    try state.copies.append(std.testing.allocator, .{
        .texture_key = 20,
        .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .dst = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .blend_mode = sdl.SDL_BLENDMODE_BLEND,
    });
    try std.testing.expect(!builder.needsFramebufferComposite(state));

    state.copies.clearRetainingCapacity();
    try state.copies.append(std.testing.allocator, .{
        .texture_key = 10,
        .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .dst = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .blend_mode = sdl.SDL_BLENDMODE_ADD,
    });
    builder.textures.getPtr(10).?.blend_mode = sdl.SDL_BLENDMODE_BLEND;
    try std.testing.expect(builder.needsFramebufferComposite(state));

    state.copies.clearRetainingCapacity();
    try state.copies.append(std.testing.allocator, .{
        .texture_key = 20,
        .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .dst = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .blend_mode = sdl.SDL_BLENDMODE_NONE,
    });
    try std.testing.expect(builder.needsFramebufferComposite(state));

    state.copies.clearRetainingCapacity();
    try std.testing.expect(!builder.needsFramebufferComposite(state));
}

test "primitive-heavy frames force framebuffer composition" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    try builder.renderers.put(1, RendererState.init(std.testing.allocator, 640, 480));
    const state = builder.renderers.getPtr(1).?;

    try std.testing.expect(!builder.needsFramebufferComposite(state));
    var i: usize = 0;
    while (i <= primitive_composite_threshold) : (i += 1) {
        try state.fills.append(std.testing.allocator, .{
            .rect = .{ .x = @intCast(i), .y = 0, .w = 1, .h = 1 },
            .color = .{ 255, 255, 255, 255 },
        });
    }
    try std.testing.expect(builder.needsFramebufferComposite(state));
}

test "composite tile strip images retire only after all placements stop referencing them" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .tiled_strip, false, false);
    defer builder.deinit();

    var state = RendererState.init(std.testing.allocator, 64, 64);
    defer state.deinit(std.testing.allocator);

    try state.composite_tiles.append(std.testing.allocator, .{
        .src_rect = .{ .x = 0, .y = 0, .w = 32, .h = 64 },
        .dest_rect = .{ .col = 0, .row = 0, .w = 4, .h = 4 },
        .image_id = 77,
        .placement_id = 1,
    });
    try state.composite_tiles.append(std.testing.allocator, .{
        .src_rect = .{ .x = 32, .y = 0, .w = 32, .h = 64 },
        .dest_rect = .{ .col = 4, .row = 0, .w = 4, .h = 4 },
        .image_id = 77,
        .placement_id = 2,
    });

    state.composite_tiles.items[0].image_id = 88;
    builder.retireCompositeTileImageIfUnreferenced(&state, 77);
    try std.testing.expectEqual(@as(usize, 0), builder.retired_image_ids.items.len);

    state.composite_tiles.items[1].image_id = 89;
    builder.retireCompositeTileImageIfUnreferenced(&state, 77);
    try std.testing.expectEqual(@as(usize, 1), builder.retired_image_ids.items.len);
    try std.testing.expectEqual(@as(u32, 77), builder.retired_image_ids.items[0]);
}

test "present decision debug logging is change-driven" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, true);
    defer builder.deinit();

    try builder.renderers.put(1, RendererState.init(std.testing.allocator, 8, 8));
    try builder.textures.put(10, .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0 });

    const state = builder.renderers.getPtr(1).?;
    try std.testing.expect(builder.shouldLogPresentDecision(state, false));
    try std.testing.expect(!builder.shouldLogPresentDecision(state, false));

    try state.copies.append(std.testing.allocator, .{
        .texture_key = 10,
        .src = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .dst = .{ .x = 0, .y = 0, .w = 8, .h = 8 },
        .blend_mode = sdl.SDL_BLENDMODE_NONE,
    });
    try std.testing.expect(builder.shouldLogPresentDecision(state, false));
    try std.testing.expect(!builder.shouldLogPresentDecision(state, false));

    state.copies.items[0].dst.w = 16;
    try std.testing.expect(builder.shouldLogPresentDecision(state, true));
    try std.testing.expect(!builder.shouldLogPresentDecision(state, true));
}

test "recorded copy snapshots unsupported blend mode without sticking renderer" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    const texture: ?*sdl.SDL_Texture = @ptrFromInt(0x1000);
    const renderer: ?*sdl.SDL_Renderer = @ptrFromInt(0x2000);
    try builder.renderers.put(FrameBuilder.ptrKey(renderer), RendererState.init(std.testing.allocator, 8, 8));
    try builder.textures.put(FrameBuilder.ptrKey(texture), .{ .w = 8, .h = 8, .format = sdl.SDL_PIXELFORMAT_ABGR8888, .image_id = 0 });

    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();

    builder.onSetTextureBlendMode(&logger, texture, sdl.SDL_BLENDMODE_ADD);
    const state = builder.renderers.getPtr(FrameBuilder.ptrKey(renderer)).?;
    try std.testing.expect(!builder.needsFramebufferComposite(state));

    builder.recordRenderCopy(&logger, renderer, texture, null, null);
    builder.onSetTextureBlendMode(&logger, texture, sdl.SDL_BLENDMODE_BLEND);

    try std.testing.expectEqual(@as(usize, 1), state.copies.items.len);
    try std.testing.expectEqual(sdl.SDL_BLENDMODE_ADD, state.copies.items[0].blend_mode);
    try std.testing.expect(builder.needsFramebufferComposite(state));
}

test "rgba opacity detection distinguishes fully opaque textures" {
    try std.testing.expect(FrameBuilder.rgbaIsOpaque(&.{ 1, 2, 3, 255, 4, 5, 6, 255 }));
    try std.testing.expect(!FrameBuilder.rgbaIsOpaque(&.{ 1, 2, 3, 255, 4, 5, 6, 254 }));
}

test "texture conversion sizes source rows by pixel format" {
    var rgb565 = [_]u8{
        0x00, 0xf8, 0xe0, 0x07,
        0x1f, 0x00, 0xff, 0xff,
    };
    var dst = [_]u8{0} ** (2 * 2 * 4);

    try std.testing.expect(FrameBuilder.convertTextureToRgba(&dst, &rgb565, 4, 2, 2, sdl.SDL_PIXELFORMAT_RGB565));
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, dst[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, dst[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, dst[12..16]);

    try std.testing.expect(!FrameBuilder.convertTextureToRgba(&dst, &rgb565, 3, 2, 2, sdl.SDL_PIXELFORMAT_RGB565));
}

test "xrgb8888 texture conversion produces opaque rgba" {
    var xrgb = [_]u8{
        3,  2,  1,  0,
        30, 20, 10, 0,
    };
    var dst = [_]u8{0} ** (2 * 4);

    try std.testing.expect(FrameBuilder.convertTextureToRgba(&dst, &xrgb, 8, 2, 1, sdl.SDL_PIXELFORMAT_XRGB8888));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 10, 20, 30, 255 }, &dst);
}

test "texture capture reuses same-sized base storage and swaps on resize" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    var record = TextureRecord{
        .w = 2,
        .h = 1,
        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
        .image_id = 0,
    };
    defer if (record.base_rgba) |buf| std.testing.allocator.free(buf);

    var first_src = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    try builder.captureTexturePixelsIntoRecord(&record, &first_src, 8);
    const first = record.base_rgba.?;
    const first_ptr = first.ptr;
    try std.testing.expectEqualSlices(u8, &first_src, first);
    try std.testing.expect(record.base_opaque);

    var second_src = [_]u8{ 7, 8, 9, 255, 10, 11, 12, 254 };
    try builder.captureTexturePixelsIntoRecord(&record, &second_src, 8);
    const second = record.base_rgba.?;
    try std.testing.expectEqual(first_ptr, second.ptr);
    try std.testing.expectEqualSlices(u8, &second_src, second);
    try std.testing.expect(!record.base_opaque);

    record.w = 3;
    var third_src = [_]u8{ 13, 14, 15, 255, 16, 17, 18, 255, 19, 20, 21, 255 };
    try builder.captureTexturePixelsIntoRecord(&record, &third_src, 12);
    const third = record.base_rgba.?;
    try std.testing.expect(third.ptr != first_ptr);
    try std.testing.expectEqualSlices(u8, &third_src, third);
    try std.testing.expect(record.base_opaque);
}

test "unsupported texture capture preserves previous base storage" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    var record = TextureRecord{
        .w = 1,
        .h = 1,
        .format = sdl.SDL_PIXELFORMAT_ABGR8888,
        .image_id = 0,
    };
    defer if (record.base_rgba) |buf| std.testing.allocator.free(buf);

    var src = [_]u8{ 1, 2, 3, 255 };
    try builder.captureTexturePixelsIntoRecord(&record, &src, 4);
    const ptr = record.base_rgba.?.ptr;
    const updates = record.update_count;

    record.format = 0;
    var unsupported_src = [_]u8{ 9, 9, 9, 9 };
    try std.testing.expectError(error.UnsupportedTextureFormat, builder.captureTexturePixelsIntoRecord(&record, &unsupported_src, 4));
    try std.testing.expectEqual(ptr, record.base_rgba.?.ptr);
    try std.testing.expectEqualSlices(u8, &src, record.base_rgba.?);
    try std.testing.expectEqual(updates, record.update_count);
}

test "IYUV texture planes convert to RGBA texture storage" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    var record = TextureRecord{
        .w = 2,
        .h = 2,
        .format = sdl.SDL_PIXELFORMAT_IYUV,
        .image_id = 0,
    };
    defer if (record.base_rgba) |buf| std.testing.allocator.free(buf);

    var y = [_]u8{
        16,  81,
        145, 235,
    };
    var u = [_]u8{90};
    var v = [_]u8{240};

    try builder.captureYuvTexturePlanesIntoRecord(&record, null, &y, 2, &u, 1, &v, 1);

    try std.testing.expect(record.base_rgba != null);
    try std.testing.expectEqual(@as(usize, 16), record.base_rgba.?.len);
    try std.testing.expectEqual(@as(u64, 1), record.update_count);
    try std.testing.expect(!std.mem.allEqual(u8, record.base_rgba.?, 0));
}

test "NV12 texture planes convert to RGBA texture storage" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    var record = TextureRecord{
        .w = 2,
        .h = 2,
        .format = sdl.SDL_PIXELFORMAT_NV12,
        .image_id = 0,
    };
    defer if (record.base_rgba) |buf| std.testing.allocator.free(buf);

    var y = [_]u8{
        16,  81,
        145, 235,
    };
    var uv = [_]u8{ 90, 240 };

    try builder.captureNvTexturePlanesIntoRecord(&record, null, &y, 2, &uv, 2);

    try std.testing.expect(record.base_rgba != null);
    try std.testing.expectEqual(@as(usize, 16), record.base_rgba.?.len);
    try std.testing.expectEqual(@as(u64, 1), record.update_count);
    try std.testing.expect(!std.mem.allEqual(u8, record.base_rgba.?, 0));
}

test "YUV converters preserve output for padded odd-sized neutral chroma frames" {
    var builder = FrameBuilder.init(std.testing.allocator, false, .fullscreen, false, false);
    defer builder.deinit();

    var yuv_record = TextureRecord{
        .w = 3,
        .h = 3,
        .format = sdl.SDL_PIXELFORMAT_IYUV,
        .image_id = 0,
    };
    defer if (yuv_record.base_rgba) |buf| std.testing.allocator.free(buf);

    var nv_record = TextureRecord{
        .w = 3,
        .h = 3,
        .format = sdl.SDL_PIXELFORMAT_NV12,
        .image_id = 0,
    };
    defer if (nv_record.base_rgba) |buf| std.testing.allocator.free(buf);

    var y = [_]u8{
        16,  81,  145, 0,
        235, 81,  16,  0,
        145, 235, 81,  0,
    };
    var u = [_]u8{
        128, 128,
        128, 128,
    };
    var v = [_]u8{
        128, 128,
        128, 128,
    };
    var uv = [_]u8{
        128, 128, 128, 128,
        128, 128, 128, 128,
    };
    const expected = [_]u8{
        0,   0,   0,   255, 76,  76,  76,  255, 150, 150, 150, 255,
        255, 255, 255, 255, 76,  76,  76,  255, 0,   0,   0,   255,
        150, 150, 150, 255, 255, 255, 255, 255, 76,  76,  76,  255,
    };

    try builder.captureYuvTexturePlanesIntoRecord(&yuv_record, null, &y, 4, &u, 2, &v, 2);
    try builder.captureNvTexturePlanesIntoRecord(&nv_record, null, &y, 4, &uv, 4);

    try std.testing.expectEqualSlices(u8, &expected, yuv_record.base_rgba.?);
    try std.testing.expectEqualSlices(u8, &expected, nv_record.base_rgba.?);
}

test "axis-aligned render geometry raw maps textured quad to copy rect" {
    const xy = [_]f32{
        10, 20,
        42, 20,
        42, 52,
        10, 52,
    };
    const uv = [_]f32{
        0, 0,
        1, 0,
        1, 1,
        0, 1,
    };
    const indices = [_]u8{ 0, 1, 2, 0, 2, 3 };

    const copy = FrameBuilder.geometryRawAsCopy(
        xy[0..].ptr,
        @sizeOf(f32) * 2,
        uv[0..].ptr,
        @sizeOf(f32) * 2,
        4,
        &indices,
        indices.len,
        1,
        64,
        64,
    ) orelse return error.ExpectedGeometryCopy;

    try std.testing.expectEqual(sdl.SDL_Rect{ .x = 0, .y = 0, .w = 64, .h = 64 }, copy.src);
    try std.testing.expectEqual(sdl.SDL_Rect{ .x = 10, .y = 20, .w = 32, .h = 32 }, copy.dst);
}
