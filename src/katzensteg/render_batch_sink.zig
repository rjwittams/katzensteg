const std = @import("std");
const system_io = @import("platform");
const kitty_protocol = @import("termscene").kitty.protocol;
const blocking_trace = @import("blocking_trace.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;
const upload_path = @import("upload_path.zig");

const rotating_file_count = upload_path.rotating_file_count;
const log = std.log.scoped(.render_batch_sink);

// One placement per placeholder image: every refresh re-places under this id so
// the terminal replaces the placement instead of accumulating anonymous ones.
pub const placeholder_placement_id: u32 = 1;

pub const RenderBatchSink = struct {
    const PlacementTrace = struct {
        image_id: u32,
        placement_id: u32,
        row: i32 = 0,
        col: i32 = 0,
        rows: i32 = 0,
        cols: i32 = 0,
        src_x: i32 = 0,
        src_y: i32 = 0,
        src_w: i32 = 0,
        src_h: i32 = 0,
        z: i32 = 0,
    };

    const FileUploadState = struct {
        file: system_io.fs.File,
        path: []u8,
        high_water: u64,
        next_offset: u64,
        file_len: u64,
    };

    const RotatingFileUploadState = struct {
        paths: [rotating_file_count][]u8,
        file_lens: [rotating_file_count]u64,
        next_index: usize,
    };

    const UploadState = union(render_batch_protocol.UploadProfile) {
        direct_apc,
        shm,
        file_whole: RotatingFileUploadState,
        file_offset_ring: FileUploadState,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    window_id: []const u8,
    seq: u64 = 0,
    presentation_generation: u64 = 0,
    deletes: std.ArrayList([]u8) = .empty,
    uploads: std.ArrayList([]u8) = .empty,
    placements: std.ArrayList([]u8) = .empty,
    after: std.ArrayList([]u8) = .empty,
    frame_json: std.Io.Writer.Allocating,
    trace_placements: std.ArrayList(PlacementTrace) = .empty,
    trace_deletes: std.ArrayList(PlacementTrace) = .empty,
    trace_after_deletes: std.ArrayList(PlacementTrace) = .empty,
    attached: bool = false,
    rect_cells: render_batch_protocol.PresentationRectCells = .{ .row = 1, .col = 1, .rows = 1, .cols = 1 },
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?render_batch_protocol.TerminalGeometry = null,
    occlusion_rects: std.ArrayList(render_batch_protocol.PresentationRectCells) = .empty,
    // Optional visible clip in terminal cell coords. When set, placements are
    // emitted only for the intersection of rect_cells and clip_cells. Null
    // means no clip (whole rect_cells is the placement target).
    clip_cells: ?render_batch_protocol.PresentationRectCells = null,
    upload: UploadState = .direct_apc,
    // Lifetime is the producer connection, not the current attach policy.
    shm_pool: @import("termscene").kitty.shared_memory.Pool,
    placeholder: ?render_batch_protocol.PlaceholderPresentation = null,
    placeholder_uploaded: bool = false,
    placeholder_scaled: std.ArrayList(u8) = .empty,
    placeholder_frame: @import("frame_observation.zig").FrameObservation = .{},
    placement_trace_enabled: bool = false,
    blocking_trace_settings: blocking_trace.Settings = .{},

    pub fn init(io: std.Io, allocator: std.mem.Allocator, window_id: []const u8) RenderBatchSink {
        return .{
            .io = io,
            .allocator = allocator,
            .window_id = window_id,
            .shm_pool = .{ .allocator = allocator },
            .frame_json = .init(allocator),
        };
    }

    pub fn deinit(self: *RenderBatchSink) void {
        self.deinitUploadState();
        self.shm_pool.deinit();
        self.clearGroup(&self.deletes);
        self.clearGroup(&self.uploads);
        self.clearGroup(&self.placements);
        self.clearGroup(&self.after);
        self.deletes.deinit(self.allocator);
        self.uploads.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.after.deinit(self.allocator);
        self.frame_json.deinit();
        self.placeholder_frame.deinit(self.allocator);
        self.placeholder_scaled.deinit(self.allocator);
        self.trace_placements.deinit(self.allocator);
        self.trace_deletes.deinit(self.allocator);
        self.trace_after_deletes.deinit(self.allocator);
        self.occlusion_rects.deinit(self.allocator);
    }

    pub fn enablePlacementTrace(self: *RenderBatchSink) void {
        self.placement_trace_enabled = true;
    }

    pub fn enableBlockingTrace(self: *RenderBatchSink, settings: blocking_trace.Settings) void {
        self.blocking_trace_settings = settings;
    }

    pub fn attach(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells) void {
        self.attachWithAspect(rect_cells, .fit);
    }

    pub fn attachWithAspect(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells, aspect: render_batch_protocol.PresentationAspect) void {
        self.attachWithPresentation(rect_cells, aspect, self.z_base);
    }

    pub fn attachWithPresentation(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells, aspect: render_batch_protocol.PresentationAspect, z_base: i32) void {
        self.rect_cells = rect_cells;
        self.aspect = aspect;
        self.z_base = z_base;
        self.attached = true;
    }

    pub fn viewport(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells, aspect: render_batch_protocol.PresentationAspect) void {
        self.viewportWithPresentation(rect_cells, aspect, self.z_base);
    }

    pub fn viewportWithPresentation(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells, aspect: render_batch_protocol.PresentationAspect, z_base: i32) void {
        self.rect_cells = rect_cells;
        self.aspect = aspect;
        self.z_base = z_base;
    }

    pub fn detach(self: *RenderBatchSink) void {
        self.attached = false;
        self.occlusion_rects.clearRetainingCapacity();
    }

    pub fn setUploadPolicy(self: *RenderBatchSink, policy: render_batch_protocol.UploadPolicy) !void {
        const next_upload = try self.initUploadState(policy);
        self.deinitUploadState();
        self.upload = next_upload;
    }

    pub fn isAttached(self: *const RenderBatchSink) bool {
        return self.attached;
    }

    pub fn presentationRect(self: *const RenderBatchSink) render_batch_protocol.PresentationRectCells {
        return self.rect_cells;
    }

    pub fn presentationAspect(self: *const RenderBatchSink) render_batch_protocol.PresentationAspect {
        return self.aspect;
    }

    pub fn presentationZBase(self: *const RenderBatchSink) i32 {
        return self.z_base;
    }

    pub fn setTerminalGeometry(self: *RenderBatchSink, terminal: ?render_batch_protocol.TerminalGeometry) void {
        self.terminal = terminal;
    }

    pub fn terminalGeometry(self: *const RenderBatchSink) ?render_batch_protocol.TerminalGeometry {
        return self.terminal;
    }

    pub fn setOcclusionRects(self: *RenderBatchSink, occlusion_rects: []const render_batch_protocol.PresentationRectCells) !void {
        self.occlusion_rects.clearRetainingCapacity();
        try self.occlusion_rects.appendSlice(self.allocator, occlusion_rects);
    }

    pub fn occlusionRects(self: *const RenderBatchSink) []const render_batch_protocol.PresentationRectCells {
        return self.occlusion_rects.items;
    }

    pub fn setClipCells(self: *RenderBatchSink, clip: ?render_batch_protocol.PresentationRectCells) void {
        self.clip_cells = clip;
    }

    pub fn clipCells(self: *const RenderBatchSink) ?render_batch_protocol.PresentationRectCells {
        return self.clip_cells;
    }

    pub fn presentationTty(self: *const RenderBatchSink) DirectTty {
        var tty: DirectTty = undefined;
        const rect = self.presentationRect();
        tty.cols = clampU16(@max(1, rect.cols));
        tty.rows = clampU16(@max(1, rect.rows));
        if (self.terminal) |terminal| {
            if (terminal.pixels) |pixels| {
                tty.pixel_width = scaledPixelExtent(rect.cols, terminal.cells.cols, pixels.w);
                tty.pixel_height = scaledPixelExtent(rect.rows, terminal.cells.rows, pixels.h);
                return tty;
            }
        }
        tty.pixel_width = clampU16(@max(1, rect.cols) * 10);
        tty.pixel_height = clampU16(@max(1, rect.rows) * 20);
        return tty;
    }

    pub fn presentPlaceholder(self: *RenderBatchSink, rgba: []const u8, w: i32, h: i32) !void {
        if (self.placeholder == null) return error.NotPlaceholderPresentation;
        // Presentation owns a copy so a stationary producer can restore an
        // image lost by the terminal. This also covers external framebuffers
        // and does not depend on observation being enabled.
        try self.placeholder_frame.retain(self.allocator, w, h, rgba);
        try self.restorePlaceholder();
    }

    pub fn refreshPlaceholder(self: *RenderBatchSink) !void {
        const target = self.placeholder orelse return;
        if (!self.placeholder_uploaded) return;
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try kitty_protocol.writeVirtualPlace(&out.writer, target.image_id, placeholder_placement_id, target.cols, target.rows);
        try self.placements.append(self.allocator, try out.toOwnedSlice());
    }

    pub fn restorePlaceholder(self: *RenderBatchSink) !void {
        const target = self.placeholder orelse return;
        if (self.placeholder_frame.pixels.items.len == 0) return;
        const frame = &self.placeholder_frame;
        const size = target.uploadSize(.{ .w = frame.width, .h = frame.height });
        const pixels = if (size.w == frame.width and size.h == frame.height) frame.pixels.items else blk: {
            try self.placeholder_scaled.resize(self.allocator, @intCast(@as(i64, size.w) * size.h * 4));
            @import("rgba_scale.zig").into(self.placeholder_scaled.items, size.w, size.h, frame.pixels.items, frame.width, frame.height);
            break :blk self.placeholder_scaled.items;
        };
        try self.uploadRgba(target.image_id, pixels, size.w, size.h);
        self.placeholder_uploaded = true;
        try self.refreshPlaceholder();
    }

    pub fn deletePlaceholder(self: *RenderBatchSink) !void {
        self.placeholder_frame.pixels.clearRetainingCapacity();
        const target = self.placeholder orelse return;
        if (!self.placeholder_uploaded) return;
        try self.deleteImageData(target.image_id);
        self.placeholder_uploaded = false;
    }

    pub fn uploadRgba(self: *RenderBatchSink, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        const io = self.io;
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        const upload_start_ns = self.traceBlockingStart();
        switch (self.upload) {
            .direct_apc => try kitty_protocol.writeTransmitRgba(&out.writer, image_id, rgba, w, h),
            .shm => {
                const object = try self.shm_pool.create(rgba, self.seq + 1);
                try kitty_protocol.writeTransmitRgbaShm(&out.writer, .suppress_fail, image_id, object.name(), w, h);
            },
            .file_whole => |*state| {
                const index = state.next_index;
                state.next_index = (state.next_index + 1) % state.paths.len;
                var file = try system_io.fs.createFileAbsolute(io, state.paths[index], .{ .read = true, .truncate = false });
                defer file.close();
                const write_start_ns = self.traceBlockingStart();
                try file.pwriteAll(rgba, 0);
                self.traceBlockingWriteSince("upload_rgba_file_whole_pwrite", write_start_ns, rgba.len);
                const rgba_len_u64: u64 = @intCast(rgba.len);
                if (rgba_len_u64 > state.file_lens[index]) {
                    try file.setEndPos(rgba.len);
                    state.file_lens[index] = rgba_len_u64;
                }
                const sync_start_ns = self.traceBlockingStart();
                try file.sync();
                self.traceBlockingWriteSince("upload_rgba_file_whole_sync", sync_start_ns, rgba.len);
                try kitty_protocol.writeTransmitRgbaFileWhole(&out.writer, image_id, state.paths[index], w, h);
            },
            .file_offset_ring => |*state| {
                const region = try reserveFileRegion(state, rgba.len);
                const write_start_ns = self.traceBlockingStart();
                try state.file.pwriteAll(rgba, region.offset);
                self.traceBlockingWriteSince("upload_rgba_file_offset_pwrite", write_start_ns, rgba.len);
                const sync_start_ns = self.traceBlockingStart();
                try state.file.sync();
                self.traceBlockingWriteSince("upload_rgba_file_offset_sync", sync_start_ns, rgba.len);
                try kitty_protocol.writeTransmitRgbaFileRegion(&out.writer, image_id, state.path, region.offset, rgba.len, w, h);
            },
        }
        try self.uploads.append(self.allocator, try out.toOwnedSlice());
        self.traceBlockingWriteSince("upload_rgba_total", upload_start_ns, rgba.len);
    }

    pub fn place(self: *RenderBatchSink, row: i32, col: i32, placement: kitty_protocol.Placement) !void {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        var adjusted = placement;
        adjusted.z += self.z_base;
        try kitty_protocol.writePlace(&out.writer, row, col, adjusted);
        try self.placements.append(self.allocator, try out.toOwnedSlice());
        if (self.placement_trace_enabled) {
            try self.trace_placements.append(self.allocator, .{
                .image_id = adjusted.image_id,
                .placement_id = adjusted.placement_id,
                .row = row,
                .col = col,
                .rows = adjusted.rows,
                .cols = adjusted.cols,
                .src_x = adjusted.src_x,
                .src_y = adjusted.src_y,
                .src_w = adjusted.src_w,
                .src_h = adjusted.src_h,
                .z = adjusted.z,
            });
        }
    }

    pub fn deletePlacement(self: *RenderBatchSink, target: kitty_protocol.ExactPlacement) !void {
        if (self.placement_trace_enabled) try self.trace_deletes.append(self.allocator, .{
            .image_id = target.image_id,
            .placement_id = target.placement_id,
        });
        try self.deletePlacementInto(&self.deletes, target);
    }

    pub fn deletePlacementAfter(self: *RenderBatchSink, target: kitty_protocol.ExactPlacement) !void {
        if (self.placement_trace_enabled) try self.trace_after_deletes.append(self.allocator, .{
            .image_id = target.image_id,
            .placement_id = target.placement_id,
        });
        try self.deletePlacementInto(&self.after, target);
    }

    fn deletePlacementInto(self: *RenderBatchSink, group: *std.ArrayList([]u8), target: kitty_protocol.ExactPlacement) !void {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try kitty_protocol.writeDeleteExactPlacement(&out.writer, target);
        try group.append(self.allocator, try out.toOwnedSlice());
    }

    pub fn deleteImageData(self: *RenderBatchSink, image_id: u32) !void {
        try self.deleteImageDataInto(&self.deletes, image_id);
    }

    pub fn deleteImageDataAfter(self: *RenderBatchSink, image_id: u32) !void {
        try self.deleteImageDataInto(&self.after, image_id);
    }

    fn deleteImageDataInto(self: *RenderBatchSink, group: *std.ArrayList([]u8), image_id: u32) !void {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try kitty_protocol.writeDeleteImageWithQuiet(&out.writer, .suppress_fail, .free_data, image_id);
        try group.append(self.allocator, try out.toOwnedSlice());
    }

    pub fn flushFrame(self: *RenderBatchSink, writer: anytype) !void {
        const pending_bytes = self.pendingFrameBytes();
        self.seq += 1;
        // Never replay one-shot APCs after a possibly partial pipe write.
        defer self.clearRetainingCapacity();
        const start_ns = self.traceBlockingStart();
        // Runtime supplies an unbuffered pipe writer. Encode in memory so JSON
        // escaping does not turn each character into a separate pipe write.
        defer self.frame_json.clearRetainingCapacity();
        try render_batch_protocol.writeFrameBatchJsonl(self.allocator, &self.frame_json.writer, .{
            .window_id = self.window_id,
            .seq = self.seq,
            .presentation_generation = self.presentation_generation,
            .deletes = self.deletes.items,
            .uploads = self.uploads.items,
            .placements = self.placements.items,
            .after = self.after.items,
        });
        try writer.writeAll(self.frame_json.written());
        self.traceBlockingWriteSince("flush_frame_jsonl", start_ns, pending_bytes);
    }

    pub fn pendingFrameBytes(self: *const RenderBatchSink) usize {
        return groupBytes(self.deletes.items) +
            groupBytes(self.uploads.items) +
            groupBytes(self.placements.items) +
            groupBytes(self.after.items);
    }

    fn traceBlockingStart(self: *const RenderBatchSink) ?i128 {
        return blocking_trace.start(self.blocking_trace_settings);
    }

    fn traceBlockingWriteSince(self: *const RenderBatchSink, comptime context: []const u8, start_ns: ?i128, payload_bytes: usize) void {
        const duration_ns = blocking_trace.elapsedMaybe(start_ns) orelse return;
        self.traceBlockingWrite(context, duration_ns, payload_bytes);
    }

    fn traceBlockingWrite(self: *const RenderBatchSink, comptime context: []const u8, duration_ns: i128, payload_bytes: usize) void {
        const settings = self.blocking_trace_settings;
        if (!blocking_trace.shouldLog(settings.enabled, duration_ns, settings.threshold_ns)) return;
        log.info(
            "blocking trace context={s} window={s} seq={d} duration_us={d} payload_bytes={d} deletes={d} uploads={d} placements={d} after={d}",
            .{
                context,
                self.window_id,
                self.seq,
                blocking_trace.micros(duration_ns),
                payload_bytes,
                self.deletes.items.len,
                self.uploads.items.len,
                self.placements.items.len,
                self.after.items.len,
            },
        );
    }

    pub fn tracePlacementFrame(self: *const RenderBatchSink, logger: anytype, comptime op: []const u8, renderer: u64) void {
        if (!self.placement_trace_enabled) return;
        logger.writeFmtScoped(
            .info,
            .frame_builder,
            "placement trace op={s} renderer={x} window={s} next_seq={d} deletes={d} placements={d} after_deletes={d} occlusions={d} rect={d},{d} {d}x{d} z_base={d}",
            .{
                op,
                renderer,
                self.window_id,
                self.seq + 1,
                self.trace_deletes.items.len,
                self.trace_placements.items.len,
                self.trace_after_deletes.items.len,
                self.occlusion_rects.items.len,
                self.rect_cells.row,
                self.rect_cells.col,
                self.rect_cells.cols,
                self.rect_cells.rows,
                self.z_base,
            },
        );
        for (self.trace_deletes.items) |entry| {
            logger.writeFmtScoped(.info, .frame_builder, "placement trace delete op={s} renderer={x} image={d} placement={d}", .{ op, renderer, entry.image_id, entry.placement_id });
        }
        for (self.trace_placements.items) |entry| {
            logger.writeFmtScoped(
                .info,
                .frame_builder,
                "placement trace place op={s} renderer={x} image={d} placement={d} cell={d},{d} {d}x{d} src={d},{d} {d}x{d} z={d}",
                .{ op, renderer, entry.image_id, entry.placement_id, entry.row, entry.col, entry.cols, entry.rows, entry.src_x, entry.src_y, entry.src_w, entry.src_h, entry.z },
            );
        }
        for (self.trace_after_deletes.items) |entry| {
            logger.writeFmtScoped(.info, .frame_builder, "placement trace after_delete op={s} renderer={x} image={d} placement={d}", .{ op, renderer, entry.image_id, entry.placement_id });
        }
    }

    pub fn hasPendingBytes(self: *const RenderBatchSink) bool {
        return self.deletes.items.len != 0 or self.uploads.items.len != 0 or self.placements.items.len != 0 or self.after.items.len != 0;
    }

    pub fn uploadIsShm(self: *const RenderBatchSink) bool {
        return self.upload == .shm;
    }

    pub fn reserveUploads(self: *RenderBatchSink, count: usize, bytes: usize) !void {
        if (self.upload == .shm) try self.shm_pool.reserveBatch(count, bytes);
    }

    pub fn endUploadReservation(self: *RenderBatchSink) void {
        if (self.upload == .shm) self.shm_pool.endReservation();
    }

    pub fn discardBatch(self: *RenderBatchSink, seq: u64) void {
        if (seq <= self.seq) self.shm_pool.discard(seq);
    }

    pub fn clearRetainingCapacity(self: *RenderBatchSink) void {
        // Unsent composition (including a failed frame) owns the next sequence.
        self.shm_pool.discard(self.seq + 1);
        self.clearGroup(&self.deletes);
        self.clearGroup(&self.uploads);
        self.clearGroup(&self.placements);
        self.clearGroup(&self.after);
        self.trace_placements.clearRetainingCapacity();
        self.trace_deletes.clearRetainingCapacity();
        self.trace_after_deletes.clearRetainingCapacity();
    }

    fn clearGroup(self: *RenderBatchSink, group: *std.ArrayList([]u8)) void {
        for (group.items) |bytes| self.allocator.free(bytes);
        group.clearRetainingCapacity();
    }

    fn initUploadState(self: *RenderBatchSink, policy: render_batch_protocol.UploadPolicy) !UploadState {
        const io = self.io;
        return switch (policy.profile) {
            .direct_apc => .direct_apc,
            .shm => .shm,
            .file_whole => blk: {
                const path = policy.path orelse return error.MissingUploadFilePath;
                break :blk .{ .file_whole = try initRotatingFileUploadState(io, self.allocator, path) };
            },
            .file_offset_ring => blk: {
                const path = policy.path orelse return error.MissingUploadFilePath;
                break :blk .{ .file_offset_ring = try initSingleFileUploadState(io, self.allocator, path, policy.high_water) };
            },
        };
    }

    fn deinitUploadState(self: *RenderBatchSink) void {
        const io = self.io;
        switch (self.upload) {
            .direct_apc => {},
            .shm => {},
            .file_whole => |*state| {
                for (&state.paths) |*path| {
                    upload_path.deleteBasePath(io, path.*);
                    self.allocator.free(path.*);
                }
            },
            .file_offset_ring => |*state| {
                state.file.close();
                upload_path.deleteBasePath(io, state.path);
                self.allocator.free(state.path);
            },
        }
        self.upload = .direct_apc;
    }

    fn initRotatingFileUploadState(io: std.Io, allocator: std.mem.Allocator, base_path: []const u8) !RotatingFileUploadState {
        var paths: [rotating_file_count][]u8 = undefined;
        var initialized: usize = 0;
        errdefer {
            for (paths[0..initialized]) |path| {
                system_io.fs.deleteFileAbsolute(io, path) catch {};
                allocator.free(path);
            }
        }
        for (&paths, 0..) |*path, index| {
            path.* = try upload_path.makeRotatingFilePath(allocator, base_path, index);
            initialized += 1;
            upload_path.deleteBasePath(io, path.*);
        }
        return .{
            .paths = paths,
            .file_lens = [_]u64{0} ** rotating_file_count,
            .next_index = 0,
        };
    }

    fn initSingleFileUploadState(io: std.Io, allocator: std.mem.Allocator, path: []const u8, high_water: u64) !FileUploadState {
        const duped_path = try allocator.dupe(u8, path);
        errdefer allocator.free(duped_path);
        const upload_file = try system_io.fs.createFileAbsolute(io, duped_path, .{ .read = true, .truncate = false });
        return .{
            .file = upload_file,
            .path = duped_path,
            .high_water = high_water,
            .next_offset = 0,
            .file_len = 0,
        };
    }

    fn reserveFileRegion(state: *FileUploadState, byte_len: usize) !struct { offset: u64 } {
        const byte_len_u64: u64 = @intCast(byte_len);
        if (byte_len_u64 > state.high_water or state.next_offset + byte_len_u64 > state.high_water) {
            state.next_offset = 0;
        }
        const offset = state.next_offset;
        state.next_offset += byte_len_u64;
        if (state.next_offset > state.file_len) {
            try state.file.setEndPos(state.next_offset);
            state.file_len = state.next_offset;
        }
        return .{ .offset = offset };
    }
};

fn scaledPixelExtent(rect_cells: i32, terminal_cells: i32, terminal_pixels: i32) u16 {
    if (terminal_cells <= 0 or terminal_pixels <= 0) return 0;
    return clampU16(@max(1, divRound(rect_cells * terminal_pixels, terminal_cells)));
}

fn clampU16(value: i32) u16 {
    return @intCast(std.math.clamp(value, 0, @as(i32, std.math.maxInt(u16))));
}

fn groupBytes(group: []const []u8) usize {
    var total: usize = 0;
    for (group) |item| total += item.len;
    return total;
}

fn divRound(numerator: i32, denominator: i32) i32 {
    if (denominator <= 0) return numerator;
    return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
}

test "batch sink groups upload place and delete bytes" {
    const io = std.testing.io;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    try sink.uploadRgba(100000, &[_]u8{ 255, 0, 0, 255 }, 1, 1);
    try sink.place(4, 1, .{
        .image_id = 100000,
        .placement_id = 200000,
        .cols = 1,
        .rows = 1,
        .src_x = 0,
        .src_y = 0,
        .src_w = 1,
        .src_h = 1,
        .z = 100,
    });
    try sink.deletePlacement(.{ .image_id = 100000, .placement_id = 200000 });
    try sink.flushFrame(&out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"uploads\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"placements\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"deletes\":[") != null);
}

test "batch sink reports pending frame byte count" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    try std.testing.expectEqual(@as(usize, 0), sink.pendingFrameBytes());
    try sink.deleteImageData(42);
    try std.testing.expect(sink.pendingFrameBytes() > 0);
}

test "batch sink placement trace records and clears frame operations" {
    const io = std.testing.io;
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    sink.enablePlacementTrace();

    try sink.place(4, 1, .{
        .image_id = 100000,
        .placement_id = 200000,
        .cols = 2,
        .rows = 3,
        .src_x = 0,
        .src_y = 0,
        .src_w = 20,
        .src_h = 30,
        .z = 100,
    });
    try sink.deletePlacement(.{ .image_id = 100000, .placement_id = 200001 });
    try sink.deletePlacementAfter(.{ .image_id = 100000, .placement_id = 200002 });

    try std.testing.expectEqual(@as(usize, 1), sink.trace_placements.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink.trace_deletes.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink.trace_after_deletes.items.len);
    try std.testing.expectEqual(@as(u32, 200000), sink.trace_placements.items[0].placement_id);
    try std.testing.expectEqual(@as(u32, 200001), sink.trace_deletes.items[0].placement_id);
    try std.testing.expectEqual(@as(u32, 200002), sink.trace_after_deletes.items[0].placement_id);

    try sink.flushFrame(&out.writer);

    try std.testing.expectEqual(@as(usize, 0), sink.trace_placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), sink.trace_deletes.items.len);
    try std.testing.expectEqual(@as(usize, 0), sink.trace_after_deletes.items.len);
}

test "batch sink viewport updates geometry without changing attach state" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    try std.testing.expect(!sink.isAttached());
    sink.viewport(.{ .row = 6, .col = 10, .rows = 20, .cols = 64 }, .cover);
    try std.testing.expect(!sink.isAttached());
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 6, .col = 10, .rows = 20, .cols = 64 }, sink.presentationRect());
    try std.testing.expectEqual(render_batch_protocol.PresentationAspect.cover, sink.presentationAspect());

    sink.attach(.{ .row = 1, .col = 1, .rows = 24, .cols = 80 });
    sink.viewport(.{ .row = 3, .col = 5, .rows = 12, .cols = 40 }, .stretch);
    try std.testing.expect(sink.isAttached());
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 3, .col = 5, .rows = 12, .cols = 40 }, sink.presentationRect());
    try std.testing.expectEqual(render_batch_protocol.PresentationAspect.stretch, sink.presentationAspect());
}

test "batch sink derives presentation tty pixels from host terminal geometry" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    sink.attach(.{ .row = 3, .col = 5, .rows = 20, .cols = 40 });
    sink.setTerminalGeometry(.{
        .cells = .{ .rows = 40, .cols = 160 },
        .pixels = .{ .w = 1280, .h = 800 },
    });

    const tty = sink.presentationTty();
    try std.testing.expectEqual(@as(u16, 40), tty.cols);
    try std.testing.expectEqual(@as(u16, 20), tty.rows);
    try std.testing.expectEqual(@as(u16, 320), tty.pixel_width);
    try std.testing.expectEqual(@as(u16, 400), tty.pixel_height);
}

test "batch sink applies presentation z base to placements" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    sink.attachWithPresentation(.{ .row = 1, .col = 1, .rows = 24, .cols = 80 }, .fit, 2000);
    try sink.place(4, 1, .{
        .image_id = 100000,
        .placement_id = 200000,
        .cols = 1,
        .rows = 1,
        .src_x = 0,
        .src_y = 0,
        .src_w = 1,
        .src_h = 1,
        .z = 100,
    });

    try std.testing.expect(std.mem.indexOf(u8, sink.placements.items[0], "z=2100") != null);
}

test "batch sink detach suppresses attachment without clearing pending deletes" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();

    sink.attach(.{ .row = 1, .col = 1, .rows = 24, .cols = 80 });
    try sink.deletePlacement(.{ .image_id = 100000, .placement_id = 200000 });
    try std.testing.expect(sink.hasPendingBytes());

    sink.detach();
    try std.testing.expect(!sink.isAttached());
    try std.testing.expect(sink.hasPendingBytes());
}

test "batch sink file whole upload writes image bytes to path and emits file APC" {
    const io = std.testing.io;
    var tmp = system_io.fs.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "upload" });
    defer std.testing.allocator.free(path);
    const uploaded_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.0", .{path});
    defer std.testing.allocator.free(uploaded_path);

    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    try sink.setUploadPolicy(.{ .profile = .file_whole, .path = path, .high_water = 4096 });

    try sink.uploadRgba(100000, &[_]u8{ 255, 0, 0, 255 }, 1, 1);

    try std.testing.expectEqual(@as(usize, 1), sink.uploads.items.len);
    try std.testing.expect(std.mem.indexOf(u8, sink.uploads.items[0], "t=f") != null);
    const bytes = try system_io.fs.cwd(io).readFileAlloc(std.testing.allocator, uploaded_path, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, bytes);
}

test "batch sink writes a complete JSON frame at once and handles partial writes" {
    const io = std.testing.io;
    const Output = struct {
        bytes: std.ArrayList(u8) = .empty,
        calls: usize = 0,
        max_write: usize = std.math.maxInt(usize),

        output: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

        fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("output", interface);
            for (data, 0..) |bytes, i| {
                if (i == data.len - 1 and splat == 0) break;
                if (bytes.len == 0) continue;
                self.calls += 1;
                const count = @min(self.max_write, bytes.len);
                self.bytes.appendSlice(std.testing.allocator, bytes[0..count]) catch return error.WriteFailed;
                return count;
            }
            return 0;
        }

        fn writer(self: *@This()) *std.Io.Writer {
            return &self.output;
        }
    };
    var output: Output = .{};
    defer output.bytes.deinit(std.testing.allocator);
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    try sink.deleteImageData(42);
    try sink.flushFrame(output.writer());
    try std.testing.expectEqual(@as(usize, 1), output.calls);
    try std.testing.expectEqual(@as(usize, 0), sink.pendingFrameBytes());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.bytes.items, "\n"));
    const first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.bytes.items, .{});
    defer first.deinit();
    try std.testing.expectEqual(@as(i64, 1), first.value.object.get("seq").?.integer);
    try std.testing.expectEqualStrings("\x1b_Gq=2,a=d,d=I,i=42;\x1b\\", first.value.object.get("groups").?.object.get("deletes").?.array.items[0].string);

    output.bytes.clearRetainingCapacity();
    output.calls = 0;
    output.max_write = 7;
    try sink.deleteImageData(43);
    try sink.flushFrame(output.writer());
    try std.testing.expectEqual(std.math.divCeil(usize, output.bytes.items.len, 7) catch unreachable, output.calls);
    const second = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.bytes.items, .{});
    defer second.deinit();
    try std.testing.expectEqual(@as(i64, 2), second.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(usize, 1), second.value.object.get("groups").?.object.get("deletes").?.array.items.len);
}

test "placeholder frames keep one id with only upload and virtual placement" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    sink.placeholder = .{ .image_id = 777, .cols = 60, .rows = 20 };
    sink.attach(sink.placeholder.?.localRect());
    const rgba = [_]u8{ 12, 34, 56, 255 };
    for (0..3) |_| {
        try sink.presentPlaceholder(&rgba, 1, 1);
        try std.testing.expectEqual(@as(usize, 1), sink.uploads.items.len);
        try std.testing.expectEqual(@as(usize, 1), sink.placements.items.len);
        try std.testing.expectEqual(@as(usize, 0), sink.deletes.items.len);
        try std.testing.expectEqual(@as(usize, 0), sink.after.items.len);
        try std.testing.expect(std.mem.indexOf(u8, sink.uploads.items[0], "i=777") != null);
        try std.testing.expectEqualStrings("\x1b_Ga=p,U=1,i=777,p=1,c=60,r=20,q=2;\x1b\\", sink.placements.items[0]);
        sink.clearRetainingCapacity();
    }
    // A stationary source can resize its virtual placement without reuploading.
    sink.placeholder.?.cols = 40;
    try sink.refreshPlaceholder();
    try std.testing.expectEqual(@as(usize, 0), sink.uploads.items.len);
    try std.testing.expectEqualStrings("\x1b_Ga=p,U=1,i=777,p=1,c=40,r=20,q=2;\x1b\\", sink.placements.items[0]);
    sink.clearRetainingCapacity();
    try sink.deletePlaceholder();
    try sink.deletePlaceholder();
    try std.testing.expectEqual(@as(usize, 1), sink.deletes.items.len);
    try std.testing.expectEqualStrings("\x1b_Gq=2,a=d,d=I,i=777;\x1b\\", sink.deletes.items[0]);
}

test "placeholder restore owns pixels and retransmits after a terminal clear" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    sink.placeholder = .{ .image_id = 77, .cols = 3, .rows = 2 };
    var rgba = [_]u8{ 1, 2, 3, 255 };
    try sink.presentPlaceholder(&rgba, 1, 1);
    const upload = try std.testing.allocator.dupe(u8, sink.uploads.items[0]);
    defer std.testing.allocator.free(upload);
    @memset(&rgba, 0);
    sink.clearRetainingCapacity();
    try sink.restorePlaceholder();
    try std.testing.expectEqual(@as(u64, 1), sink.placeholder_frame.frame_id);
    try std.testing.expectEqual(@as(usize, 1), sink.uploads.items.len);
    try std.testing.expectEqualStrings(upload, sink.uploads.items[0]);
    try std.testing.expectEqual(@as(usize, 1), sink.placements.items.len);
    try sink.deletePlaceholder();
    sink.clearRetainingCapacity();
    try sink.restorePlaceholder();
    try std.testing.expect(!sink.hasPendingBytes());
}

test "placeholder upload bounds leave native framebuffer available for observation and resize" {
    const io = std.testing.io;
    var sink = RenderBatchSink.init(io, std.testing.allocator, "main");
    defer sink.deinit();
    sink.placeholder = .{ .image_id = 77, .cols = 2, .rows = 1, .target_px = .{ .w = 2, .h = 1 } };
    const rgba = [_]u8{255} ** (4 * 2 * 4);
    try sink.presentPlaceholder(&rgba, 4, 2);
    try std.testing.expect(std.mem.indexOf(u8, sink.uploads.items[0], "s=2,v=1,i=77") != null);
    try std.testing.expectEqual(@as(i32, 4), sink.placeholder_frame.width);
    try std.testing.expectEqualSlices(u8, &rgba, sink.placeholder_frame.pixels.items);
    sink.clearRetainingCapacity();
    sink.placeholder.?.target_px = .{ .w = 8, .h = 4 };
    try sink.restorePlaceholder();
    try std.testing.expect(std.mem.indexOf(u8, sink.uploads.items[0], "s=4,v=2,i=77") != null);
    try std.testing.expectEqual(@as(u64, 1), sink.placeholder_frame.frame_id);
}

test "SHM batches keep sent uploads alive and discard only unsent or host-rejected frames" {
    var sink = RenderBatchSink.init(std.testing.io, std.testing.allocator, "main");
    defer sink.deinit();
    try sink.setUploadPolicy(.{ .profile = .shm });
    var wire = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer wire.deinit();

    try sink.uploadRgba(100000, &.{ 1, 2, 3, 255 }, 1, 1);
    const sent = sink.shm_pool.objects.items[0];
    try sink.flushFrame(&wire.writer);
    try std.testing.expect(!sent.consumed());
    try std.testing.expect(std.mem.indexOf(u8, wire.written(), "t=s") != null);
    try sink.uploadRgba(100000, &.{ 4, 5, 6, 255 }, 1, 1);
    const unsent = sink.shm_pool.objects.items[1];
    sink.clearRetainingCapacity();
    try std.testing.expect(unsent.consumed());
    try std.testing.expect(!sent.consumed());
    // Submission to a host is not submission to the terminal.
    sink.discardBatch(1);
    try std.testing.expect(sent.consumed());
    try std.testing.expectEqual(@as(usize, 0), sink.shm_pool.len);

    try sink.uploadRgba(100000, &.{ 7, 8, 9, 255 }, 1, 1);
    const next = sink.shm_pool.objects.items[0];
    try std.testing.expect(!std.mem.eql(u8, sent.name(), next.name()));
    try sink.flushFrame(&wire.writer);
    sink.discardBatch(1); // An old discard cannot release a newer frame.
    try std.testing.expect(!next.consumed());
    next.unlink(); // Terminal opens/maps and unlinks the name.
    sink.shm_pool.reap();
    try std.testing.expectEqual(@as(usize, 0), sink.shm_pool.len);
}

test "changing upload policy does not unlink a previously submitted SHM object" {
    var sink = RenderBatchSink.init(std.testing.io, std.testing.allocator, "main");
    defer sink.deinit();
    try sink.setUploadPolicy(.{ .profile = .shm });
    try sink.uploadRgba(1, &.{ 1, 2, 3, 255 }, 1, 1);
    const sent = sink.shm_pool.objects.items[0];
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try sink.flushFrame(&out.writer);
    try sink.setUploadPolicy(.{ .profile = .direct_apc });
    try std.testing.expect(!sent.consumed());
    sink.discardBatch(1);
    try std.testing.expect(sent.consumed());
}

test "failed output never replays SHM APCs or assumes that partial writes were consumed" {
    const FailingWriter = struct {
        fn writeAll(_: @This(), _: []const u8) error{BrokenPipe}!void {
            return error.BrokenPipe;
        }
    };
    var sink = RenderBatchSink.init(std.testing.io, std.testing.allocator, "main");
    defer sink.deinit();
    try sink.setUploadPolicy(.{ .profile = .shm });
    try sink.uploadRgba(1, &.{ 1, 2, 3, 255 }, 1, 1);
    const sent = sink.shm_pool.objects.items[0];
    try std.testing.expectError(error.BrokenPipe, sink.flushFrame(FailingWriter{}));
    try std.testing.expect(!sink.hasPendingBytes());
    try std.testing.expect(!sent.consumed());
}
