const std = @import("std");
const kitty_protocol = @import("termscene").kitty.protocol;
const render_batch_protocol = @import("render_batch_protocol.zig");

pub const RenderBatchSink = struct {
    allocator: std.mem.Allocator,
    window_id: []const u8,
    seq: u64 = 0,
    deletes: std.ArrayList([]u8) = .empty,
    uploads: std.ArrayList([]u8) = .empty,
    placements: std.ArrayList([]u8) = .empty,
    after: std.ArrayList([]u8) = .empty,
    attached: bool = false,
    rect_cells: render_batch_protocol.PresentationRectCells = .{ .row = 1, .col = 1, .rows = 1, .cols = 1 },

    pub fn init(allocator: std.mem.Allocator, window_id: []const u8) RenderBatchSink {
        return .{
            .allocator = allocator,
            .window_id = window_id,
        };
    }

    pub fn deinit(self: *RenderBatchSink) void {
        self.clearGroup(&self.deletes);
        self.clearGroup(&self.uploads);
        self.clearGroup(&self.placements);
        self.clearGroup(&self.after);
        self.deletes.deinit(self.allocator);
        self.uploads.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.after.deinit(self.allocator);
    }

    pub fn attach(self: *RenderBatchSink, rect_cells: render_batch_protocol.PresentationRectCells) void {
        self.rect_cells = rect_cells;
        self.attached = true;
    }

    pub fn isAttached(self: *const RenderBatchSink) bool {
        return self.attached;
    }

    pub fn presentationRect(self: *const RenderBatchSink) render_batch_protocol.PresentationRectCells {
        return self.rect_cells;
    }

    pub fn uploadRgba(self: *RenderBatchSink, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writeTransmitRgba(out.writer(self.allocator), image_id, rgba, w, h);
        try self.uploads.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn place(self: *RenderBatchSink, row: i32, col: i32, placement: kitty_protocol.Placement) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writePlace(out.writer(self.allocator), row, col, placement);
        try self.placements.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn deletePlacement(self: *RenderBatchSink, target: kitty_protocol.ExactPlacement) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writeDeleteExactPlacement(out.writer(self.allocator), target);
        try self.deletes.append(self.allocator, try out.toOwnedSlice(self.allocator));
    }

    pub fn deleteImageData(self: *RenderBatchSink, image_id: u32) !void {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try kitty_protocol.writeDeleteImageWithQuiet(out.writer(self.allocator), .suppress_fail, .free_data, image_id);
        try self.deletes.append(self.allocator, try out.toOwnedSlice(self.allocator));
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
};

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
