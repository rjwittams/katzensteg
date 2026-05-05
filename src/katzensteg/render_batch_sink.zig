const std = @import("std");
const kitty_protocol = @import("termscene").kitty.protocol;
const render_batch_protocol = @import("render_batch_protocol.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;

const rotating_file_count = 256;

pub const RenderBatchSink = struct {
    const FileUploadState = struct {
        file: std.fs.File,
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
        file_whole: RotatingFileUploadState,
        file_offset_ring: FileUploadState,
    };

    allocator: std.mem.Allocator,
    window_id: []const u8,
    seq: u64 = 0,
    deletes: std.ArrayList([]u8) = .empty,
    uploads: std.ArrayList([]u8) = .empty,
    placements: std.ArrayList([]u8) = .empty,
    after: std.ArrayList([]u8) = .empty,
    attached: bool = false,
    rect_cells: render_batch_protocol.PresentationRectCells = .{ .row = 1, .col = 1, .rows = 1, .cols = 1 },
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?render_batch_protocol.TerminalGeometry = null,
    occlusion_rects: std.ArrayList(render_batch_protocol.PresentationRectCells) = .empty,
    upload: UploadState = .direct_apc,

    pub fn init(allocator: std.mem.Allocator, window_id: []const u8) RenderBatchSink {
        return .{
            .allocator = allocator,
            .window_id = window_id,
        };
    }

    pub fn deinit(self: *RenderBatchSink) void {
        self.deinitUploadState();
        self.clearGroup(&self.deletes);
        self.clearGroup(&self.uploads);
        self.clearGroup(&self.placements);
        self.clearGroup(&self.after);
        self.deletes.deinit(self.allocator);
        self.uploads.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.after.deinit(self.allocator);
        self.occlusion_rects.deinit(self.allocator);
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

    pub fn uploadRgba(self: *RenderBatchSink, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        switch (self.upload) {
            .direct_apc => try kitty_protocol.writeTransmitRgba(out.writer(self.allocator), image_id, rgba, w, h),
            .file_whole => |*state| {
                const index = state.next_index;
                state.next_index = (state.next_index + 1) % state.paths.len;
                var file = try std.fs.createFileAbsolute(state.paths[index], .{ .read = true, .truncate = false });
                defer file.close();
                try file.pwriteAll(rgba, 0);
                const rgba_len_u64: u64 = @intCast(rgba.len);
                if (rgba_len_u64 > state.file_lens[index]) {
                    try file.setEndPos(rgba.len);
                    state.file_lens[index] = rgba_len_u64;
                }
                try file.sync();
                try kitty_protocol.writeTransmitRgbaFileWhole(out.writer(self.allocator), image_id, state.paths[index], w, h);
            },
            .file_offset_ring => |*state| {
                const region = try reserveFileRegion(state, rgba.len);
                try state.file.pwriteAll(rgba, region.offset);
                try state.file.sync();
                try kitty_protocol.writeTransmitRgbaFileRegion(out.writer(self.allocator), image_id, state.path, region.offset, rgba.len, w, h);
            },
        }
        try self.uploads.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn place(self: *RenderBatchSink, row: i32, col: i32, placement: kitty_protocol.Placement) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var adjusted = placement;
        adjusted.z += self.z_base;
        try kitty_protocol.writePlace(out.writer(self.allocator), row, col, adjusted);
        try self.placements.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn deletePlacement(self: *RenderBatchSink, target: kitty_protocol.ExactPlacement) !void {
        try self.deletePlacementInto(&self.deletes, target);
    }

    pub fn deletePlacementAfter(self: *RenderBatchSink, target: kitty_protocol.ExactPlacement) !void {
        try self.deletePlacementInto(&self.after, target);
    }

    fn deletePlacementInto(self: *RenderBatchSink, group: *std.ArrayList([]u8), target: kitty_protocol.ExactPlacement) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writeDeleteExactPlacement(out.writer(self.allocator), target);
        try group.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn deleteImageData(self: *RenderBatchSink, image_id: u32) !void {
        try self.deleteImageDataInto(&self.deletes, image_id);
    }

    pub fn deleteImageDataAfter(self: *RenderBatchSink, image_id: u32) !void {
        try self.deleteImageDataInto(&self.after, image_id);
    }

    fn deleteImageDataInto(self: *RenderBatchSink, group: *std.ArrayList([]u8), image_id: u32) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writeDeleteImageWithQuiet(out.writer(self.allocator), .suppress_fail, .free_data, image_id);
        try group.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn flushFrame(self: *RenderBatchSink, writer: anytype) !void {
        self.seq += 1;
        try render_batch_protocol.writeFrameBatchJsonl(self.allocator, writer, .{
            .window_id = self.window_id,
            .seq = self.seq,
            .deletes = self.deletes.items,
            .uploads = self.uploads.items,
            .placements = self.placements.items,
            .after = self.after.items,
        });
        self.clearRetainingCapacity();
    }

    pub fn hasPendingBytes(self: *const RenderBatchSink) bool {
        return self.deletes.items.len != 0 or self.uploads.items.len != 0 or self.placements.items.len != 0 or self.after.items.len != 0;
    }

    pub fn clearRetainingCapacity(self: *RenderBatchSink) void {
        self.clearGroup(&self.deletes);
        self.clearGroup(&self.uploads);
        self.clearGroup(&self.placements);
        self.clearGroup(&self.after);
    }

    fn clearGroup(self: *RenderBatchSink, group: *std.ArrayList([]u8)) void {
        for (group.items) |bytes| self.allocator.free(bytes);
        group.clearRetainingCapacity();
    }

    fn initUploadState(self: *RenderBatchSink, policy: render_batch_protocol.UploadPolicy) !UploadState {
        return switch (policy.profile) {
            .direct_apc => .direct_apc,
            .file_whole => blk: {
                const path = policy.path orelse return error.MissingUploadFilePath;
                break :blk .{ .file_whole = try initRotatingFileUploadState(self.allocator, path) };
            },
            .file_offset_ring => blk: {
                const path = policy.path orelse return error.MissingUploadFilePath;
                break :blk .{ .file_offset_ring = try initSingleFileUploadState(self.allocator, path, policy.high_water) };
            },
        };
    }

    fn deinitUploadState(self: *RenderBatchSink) void {
        switch (self.upload) {
            .direct_apc => {},
            .file_whole => |*state| {
                for (&state.paths) |*path| {
                    std.fs.deleteFileAbsolute(path.*) catch {};
                    self.allocator.free(path.*);
                }
            },
            .file_offset_ring => |*state| {
                state.file.close();
                std.fs.deleteFileAbsolute(state.path) catch {};
                self.allocator.free(state.path);
            },
        }
        self.upload = .direct_apc;
    }

    fn initRotatingFileUploadState(allocator: std.mem.Allocator, base_path: []const u8) !RotatingFileUploadState {
        var paths: [rotating_file_count][]u8 = undefined;
        var initialized: usize = 0;
        errdefer {
            for (paths[0..initialized]) |path| {
                std.fs.deleteFileAbsolute(path) catch {};
                allocator.free(path);
            }
        }
        for (&paths, 0..) |*path, index| {
            path.* = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, index });
            initialized += 1;
            std.fs.deleteFileAbsolute(path.*) catch {};
        }
        return .{
            .paths = paths,
            .file_lens = [_]u64{0} ** rotating_file_count,
            .next_index = 0,
        };
    }

    fn initSingleFileUploadState(allocator: std.mem.Allocator, path: []const u8, high_water: u64) !FileUploadState {
        const duped_path = try allocator.dupe(u8, path);
        errdefer allocator.free(duped_path);
        const upload_file = try std.fs.createFileAbsolute(duped_path, .{ .read = true, .truncate = false });
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

fn divRound(numerator: i32, denominator: i32) i32 {
    if (denominator <= 0) return numerator;
    return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
}

test "batch sink groups upload place and delete bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var sink = RenderBatchSink.init(std.testing.allocator, "main");
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
    try sink.flushFrame(out.writer(std.testing.allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"uploads\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"placements\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"deletes\":[") != null);
}

test "batch sink viewport updates geometry without changing attach state" {
    var sink = RenderBatchSink.init(std.testing.allocator, "main");
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
    var sink = RenderBatchSink.init(std.testing.allocator, "main");
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
    var sink = RenderBatchSink.init(std.testing.allocator, "main");
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
    var sink = RenderBatchSink.init(std.testing.allocator, "main");
    defer sink.deinit();

    sink.attach(.{ .row = 1, .col = 1, .rows = 24, .cols = 80 });
    try sink.deletePlacement(.{ .image_id = 100000, .placement_id = 200000 });
    try std.testing.expect(sink.hasPendingBytes());

    sink.detach();
    try std.testing.expect(!sink.isAttached());
    try std.testing.expect(sink.hasPendingBytes());
}

test "batch sink file whole upload writes image bytes to path and emits file APC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "upload" });
    defer std.testing.allocator.free(path);
    const uploaded_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.0", .{path});
    defer std.testing.allocator.free(uploaded_path);

    var sink = RenderBatchSink.init(std.testing.allocator, "main");
    defer sink.deinit();
    try sink.setUploadPolicy(.{ .profile = .file_whole, .path = path, .high_water = 4096 });

    try sink.uploadRgba(100000, &[_]u8{ 255, 0, 0, 255 }, 1, 1);

    try std.testing.expectEqual(@as(usize, 1), sink.uploads.items.len);
    try std.testing.expect(std.mem.indexOf(u8, sink.uploads.items[0], "t=f") != null);
    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, uploaded_path, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, bytes);
}
