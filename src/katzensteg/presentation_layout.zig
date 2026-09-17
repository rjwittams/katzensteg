const std = @import("std");

pub const max_regions = 8;

pub const Point = struct {
    x: i32,
    y: i32,
};

/// Sub-cell position from a pixel-resolution report.
pub const PrecisePoint = struct {
    x: f32,
    y: f32,
};

pub const CellRect = struct {
    col: i32,
    row: i32,
    w: i32,
    h: i32,
};

pub const SdlRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const RegionKind = enum {
    sdl_window,
    chrome,
};

pub const PresentationRegion = struct {
    kind: RegionKind,
    tty_rect: CellRect,
    sdl_rect: SdlRect,
    z: i32 = 0,

    pub fn mapCellToSdl(self: PresentationRegion, cell_col: i32, cell_row: i32) ?Point {
        if (self.kind != .sdl_window) return null;
        if (self.tty_rect.w <= 0 or self.tty_rect.h <= 0 or self.sdl_rect.w <= 0 or self.sdl_rect.h <= 0) return null;
        if (cell_col < self.tty_rect.col or cell_row < self.tty_rect.row) return null;
        if (cell_col >= self.tty_rect.col + self.tty_rect.w or cell_row >= self.tty_rect.row + self.tty_rect.h) return null;

        const rel_col = cell_col - self.tty_rect.col;
        const rel_row = cell_row - self.tty_rect.row;
        const mapped_x = self.sdl_rect.x + @divTrunc(rel_col * self.sdl_rect.w, self.tty_rect.w);
        const mapped_y = self.sdl_rect.y + @divTrunc(rel_row * self.sdl_rect.h, self.tty_rect.h);
        return .{
            .x = std.math.clamp(mapped_x, self.sdl_rect.x, self.sdl_rect.x + self.sdl_rect.w - 1),
            .y = std.math.clamp(mapped_y, self.sdl_rect.y, self.sdl_rect.y + self.sdl_rect.h - 1),
        };
    }

    /// Map a fractional cell position (1-based; cell c spans [c, c+1)) to
    /// SDL coordinates, keeping the sub-cell precision of pixel reports.
    pub fn mapFractionalCellToSdl(self: PresentationRegion, col: f32, row: f32) ?PrecisePoint {
        if (self.kind != .sdl_window) return null;
        if (self.tty_rect.w <= 0 or self.tty_rect.h <= 0 or self.sdl_rect.w <= 0 or self.sdl_rect.h <= 0) return null;
        const col0: f32 = @floatFromInt(self.tty_rect.col);
        const row0: f32 = @floatFromInt(self.tty_rect.row);
        const cols: f32 = @floatFromInt(self.tty_rect.w);
        const rows: f32 = @floatFromInt(self.tty_rect.h);
        if (col < col0 or row < row0 or col >= col0 + cols or row >= row0 + rows) return null;
        const x0: f32 = @floatFromInt(self.sdl_rect.x);
        const y0: f32 = @floatFromInt(self.sdl_rect.y);
        const w: f32 = @floatFromInt(self.sdl_rect.w);
        const h: f32 = @floatFromInt(self.sdl_rect.h);
        return .{
            .x = std.math.clamp(x0 + (col - col0) * w / cols, x0, x0 + w - 1),
            .y = std.math.clamp(y0 + (row - row0) * h / rows, y0, y0 + h - 1),
        };
    }
};

pub const PresentationLayout = struct {
    regions: [max_regions]PresentationRegion = undefined,
    len: usize = 0,

    pub fn clear(self: *PresentationLayout) void {
        self.len = 0;
    }

    pub fn addRegion(self: *PresentationLayout, region: PresentationRegion) void {
        if (self.len >= self.regions.len) return;
        self.regions[self.len] = region;
        self.len += 1;
    }

    pub fn setSingleSdlRegion(self: *PresentationLayout, region: PresentationRegion) void {
        self.clear();
        self.addRegion(region);
    }

    pub fn mapCellToSdl(self: *const PresentationLayout, cell_col: i32, cell_row: i32) ?Point {
        var best_point: ?Point = null;
        var best_z: i32 = std.math.minInt(i32);
        for (self.regions[0..self.len]) |region| {
            const point = region.mapCellToSdl(cell_col, cell_row) orelse continue;
            if (best_point == null or region.z >= best_z) {
                best_point = point;
                best_z = region.z;
            }
        }
        return best_point;
    }

    pub fn mapFractionalCellToSdl(self: *const PresentationLayout, col: f32, row: f32) ?PrecisePoint {
        var best_point: ?PrecisePoint = null;
        var best_z: i32 = std.math.minInt(i32);
        for (self.regions[0..self.len]) |region| {
            const point = region.mapFractionalCellToSdl(col, row) orelse continue;
            if (best_point == null or region.z >= best_z) {
                best_point = point;
                best_z = region.z;
            }
        }
        return best_point;
    }
};

test "presentation region maps terminal cells to SDL coordinates" {
    const region = PresentationRegion{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    };

    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, region.mapCellToSdl(11, 6).?);
    try std.testing.expectEqual(Point{ .x = 316, .y = 232 }, region.mapCellToSdl(90, 35).?);
    try std.testing.expect(region.mapCellToSdl(10, 6) == null);
    try std.testing.expect(region.mapCellToSdl(91, 35) == null);
}

test "presentation layout maps through topmost SDL region" {
    var layout = PresentationLayout{};
    layout.addRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 1, .row = 1, .w = 20, .h = 10 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .z = 0,
    });
    layout.addRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 5, .row = 5, .w = 10, .h = 5 },
        .sdl_rect = .{ .x = 100, .y = 50, .w = 50, .h = 25 },
        .z = 10,
    });

    try std.testing.expectEqual(Point{ .x = 105, .y = 55 }, layout.mapCellToSdl(6, 6).?);
}

test "presentation region maps fractional cells with sub-cell precision" {
    const region = PresentationRegion{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    };
    const origin = region.mapFractionalCellToSdl(11, 6).?;
    try std.testing.expectEqual(@as(f32, 0), origin.x);
    try std.testing.expectEqual(@as(f32, 0), origin.y);
    const half = region.mapFractionalCellToSdl(11.5, 6.5).?;
    try std.testing.expectEqual(@as(f32, 2), half.x);
    try std.testing.expectEqual(@as(f32, 4), half.y);
    const edge = region.mapFractionalCellToSdl(90.999, 35.999).?;
    try std.testing.expect(edge.x <= 319 and edge.x > 318);
    try std.testing.expect(edge.y <= 239 and edge.y > 238);
    try std.testing.expect(region.mapFractionalCellToSdl(10.999, 6) == null);
    try std.testing.expect(region.mapFractionalCellToSdl(91, 6) == null);
    var layout = PresentationLayout{};
    layout.addRegion(region);
    layout.addRegion(.{ .kind = .chrome, .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 }, .sdl_rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .z = 5 });
    try std.testing.expectEqual(@as(f32, 2), layout.mapFractionalCellToSdl(11.5, 6).?.x);
}
