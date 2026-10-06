//! Owned session images and pure explicit-placement geometry. Original virtual
//! declarations are unavailable until cleat#317; resolved strips are ignored.
const std = @import("std");
const cells = @import("session_cells.zig");
const kitty = @import("termscene").kitty;

pub const Resource = struct {
    id: u32,
    generation: u64,
    width: u32,
    height: u32,
    format: u32 = 32,
    pixels: []const u8,
};
pub const Placement = struct {
    image: u32,
    col: i32,
    row: i32,
    cols: u32,
    rows: u32,
    z: i32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    pixel_width: u32,
    pixel_height: u32,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
};
pub const Image = struct {
    resource: Resource,
    outer: ?u32 = null,
    uploaded: bool = false,
};
pub const State = struct {
    allocator: std.mem.Allocator,
    images: std.ArrayList(Image) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    deleted: std.ArrayList(u32) = .empty,
    uploads: kitty.shared_memory.Pool,
    pending: bool = false,

    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a, .uploads = .{ .allocator = a } };
    }
    pub fn deinit(self: *State) void {
        for (self.images.items) |image| self.allocator.free(image.resource.pixels);
        self.images.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.deleted.deinit(self.allocator);
        self.uploads.deinit();
    }
    pub fn find(self: *const State, id: u32) ?usize {
        for (self.images.items, 0..) |image, i| if (image.resource.id == id) return i;
        return null;
    }
    /// The adapter passes a full resource list. Retain IDs across generations;
    /// disappearance schedules outer deletion before the ID can be reused.
    pub fn replace(self: *State, resources: []const Resource, placements: []const Placement) !void {
        var next: std.ArrayList(Image) = .empty;
        errdefer {
            for (next.items) |image| self.allocator.free(image.resource.pixels);
            next.deinit(self.allocator);
        }
        for (resources) |resource| {
            for (next.items) |image| if (image.resource.id == resource.id) return error.DuplicateImage;
            var image = Image{ .resource = resource };
            if (self.find(resource.id)) |i| {
                image.outer = self.images.items[i].outer;
                image.uploaded = self.images.items[i].uploaded and self.images.items[i].resource.generation == resource.generation;
            }
            image.resource.pixels = try self.allocator.dupe(u8, resource.pixels);
            next.append(self.allocator, image) catch |err| {
                self.allocator.free(image.resource.pixels);
                return err;
            };
        }
        var next_placements: std.ArrayList(Placement) = .empty;
        errdefer next_placements.deinit(self.allocator);
        try next_placements.appendSlice(self.allocator, placements);
        try self.deleted.ensureUnusedCapacity(self.allocator, self.images.items.len);
        for (self.images.items) |image| {
            const retained = for (next.items) |candidate| {
                if (candidate.resource.id == image.resource.id) break true;
            } else false;
            if (!retained) if (image.outer) |outer| self.deleted.appendAssumeCapacity(outer);
            self.allocator.free(image.resource.pixels);
        }
        self.images.deinit(self.allocator);
        self.placements.deinit(self.allocator);
        self.images = next;
        self.placements = next_placements;
    }
    pub fn allocate(self: *State, start: u32, end: u32) !void {
        for (self.images.items) |*image| {
            if (image.outer != null) continue;
            var id = start;
            while (true) {
                const used = for (self.images.items) |other| {
                    if (other.outer == id) break true;
                } else false;
                if (!used) break;
                if (id == end) return error.ImageRangeExhausted;
                id += 1;
            }
            image.outer = id;
        }
    }
    pub fn paint(self: *State, out: *std.Io.Writer, start: u32, end: u32, options: Geometry) !bool {
        var count: usize = 0;
        var bytes: usize = 0;
        for (self.images.items) |image| if (!image.uploaded) {
            count += 1;
            bytes = try std.math.add(usize, bytes, image.resource.pixels.len);
        };
        self.uploads.reserveBatch(count, bytes) catch |err| switch (err) {
            error.UploadBackpressure => {
                self.pending = true;
                return false;
            },
            else => return err,
        };
        defer self.uploads.endReservation();
        self.pending = false;
        try self.allocate(start, end);
        for (self.deleted.items) |id| try kitty.protocol.writeDeleteImageWithQuiet(out, .suppress_fail, .free_data, id);
        self.deleted.clearRetainingCapacity();
        for (self.images.items) |*image| {
            if (!image.uploaded) {
                const object = try self.uploads.create(image.resource.pixels, image.resource.generation);
                var header: [192]u8 = undefined;
                const prefix = try std.fmt.bufPrint(&header, "a=t,t=s,f={d},s={d},v={d},i={d},S={d},q=2", .{ image.resource.format, image.resource.width, image.resource.height, image.outer.?, image.resource.pixels.len });
                var encoded: [48]u8 = undefined;
                const payload = std.base64.standard.Encoder.encode(&encoded, object.name());
                try out.print("\x1b_G{s};{s}\x1b\\", .{ prefix, payload });
                image.uploaded = true;
            }
            // Rebuild placements after geometry/order changes, including ones
            // which have disappeared. Lowercase i keeps the resource storage.
            try kitty.protocol.writeDeleteImageWithQuiet(out, .suppress_fail, .keep_data, image.outer.?);
        }
        // Rank by the program's z, with stable input order breaking ties. Each
        // window owns 1000 low-band layers; rank does not project arbitrary
        // program z into another window.
        var fragments: std.ArrayList(cells.Rect) = .empty;
        defer fragments.deinit(self.allocator);
        try fragments.append(self.allocator, options.content);
        for (options.higher) |cutter| {
            var next: std.ArrayList(cells.Rect) = .empty;
            errdefer next.deinit(self.allocator);
            for (fragments.items) |rect| try subtract(&next, self.allocator, rect, cutter);
            fragments.deinit(self.allocator);
            fragments = next;
        }
        var placement_id: u32 = end;
        for (self.placements.items, 0..) |placement, i| {
            const index = self.find(placement.image) orelse continue;
            var rank: i32 = 0;
            for (self.placements.items, 0..) |other, j| {
                if (other.z < placement.z or (other.z == placement.z and j < i)) rank += 1;
            }
            if (rank >= 1000) return error.WindowLayerRangeExhausted;
            for (fragments.items) |fragment| {
                var clipped = options;
                clipped.clip = fragment;
                const planned = plan(placement, clipped) orelse continue;
                if (placement_id == end + 100000) return error.PlacementRangeExhausted;
                placement_id += 1;
                try out.print("\x1b[{d};{d}H\x1b_Ga=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},X={d},Y={d},z={d},q=2;\x1b\\", .{
                    planned.row + 1,       planned.col + 1,       self.images.items[index].outer.?, placement_id,
                    planned.cols,          planned.rows,          planned.source_x,                 planned.source_y,
                    planned.source_width,  planned.source_height, planned.offset_x,                 planned.offset_y,
                    options.z_base + rank,
                });
            }
        }
        return true;
    }
};

pub const Geometry = struct {
    content: cells.Rect,
    terminal: cells.TerminalSize,
    cell_width: u32,
    cell_height: u32,
    z_base: i32,
    higher: []const cells.Rect = &.{},
    clip: ?cells.Rect = null,
};
pub const Planned = struct {
    row: i64,
    col: i64,
    rows: u32,
    cols: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    offset_x: u32,
    offset_y: u32,
};
/// Clip in pixels before deriving cursor position, offsets and source crop.
pub fn plan(p: Placement, g: Geometry) ?Planned {
    if (g.cell_width == 0 or g.cell_height == 0 or p.pixel_width == 0 or p.pixel_height == 0) return null;
    const cw: i64 = g.cell_width;
    const ch: i64 = g.cell_height;
    const x = (@as(i64, g.content.col) + p.col) * cw + p.offset_x;
    const y = (@as(i64, g.content.row) + p.row) * ch + p.offset_y;
    const clip = g.clip orelse g.content;
    const left = @max(x, @as(i64, @max(0, @max(g.content.col, clip.col))) * cw);
    const top = @max(y, @as(i64, @max(0, @max(g.content.row, clip.row))) * ch);
    const right = @min(x + p.pixel_width, @min(@min(@as(i64, g.content.col) + g.content.cols, @as(i64, clip.col) + clip.cols), g.terminal.cols) * cw);
    const bottom = @min(y + p.pixel_height, @min(@min(@as(i64, g.content.row) + g.content.rows, @as(i64, clip.row) + clip.rows), g.terminal.rows) * ch);
    if (right <= left or bottom <= top) return null;
    const sx = @as(u64, @intCast(left - x)) * p.source_width / p.pixel_width;
    const sy = @as(u64, @intCast(top - y)) * p.source_height / p.pixel_height;
    const ex = std.math.divCeil(u64, @as(u64, @intCast(right - x)) * p.source_width, p.pixel_width) catch unreachable;
    const ey = std.math.divCeil(u64, @as(u64, @intCast(bottom - y)) * p.source_height, p.pixel_height) catch unreachable;
    if (sx == ex or sy == ey) return null;
    return .{
        .row = @divTrunc(top, ch),
        .col = @divTrunc(left, cw),
        .rows = @intCast(@divTrunc(bottom + ch - 1, ch) - @divTrunc(top, ch)),
        .cols = @intCast(@divTrunc(right + cw - 1, cw) - @divTrunc(left, cw)),
        .source_x = std.math.cast(u32, p.source_x + sx) orelse return null,
        .source_y = std.math.cast(u32, p.source_y + sy) orelse return null,
        .source_width = @intCast(ex - sx),
        .source_height = @intCast(ey - sy),
        .offset_x = @intCast(@mod(left, cw)),
        .offset_y = @intCast(@mod(top, ch)),
    };
}

fn subtract(out: *std.ArrayList(cells.Rect), a: std.mem.Allocator, rect: cells.Rect, cutter: cells.Rect) !void {
    const left: i64 = @max(rect.col, cutter.col);
    const top: i64 = @max(rect.row, cutter.row);
    const right = @min(@as(i64, rect.col) + rect.cols, @as(i64, cutter.col) + cutter.cols);
    const bottom = @min(@as(i64, rect.row) + rect.rows, @as(i64, cutter.row) + cutter.rows);
    if (right <= left or bottom <= top) return out.append(a, rect);
    const candidates = [_]cells.Rect{
        .{ .row = rect.row, .col = rect.col, .rows = @intCast(top - rect.row), .cols = rect.cols },
        .{ .row = @intCast(bottom), .col = rect.col, .rows = @intCast(@as(i64, rect.row) + rect.rows - bottom), .cols = rect.cols },
        .{ .row = @intCast(top), .col = rect.col, .rows = @intCast(bottom - top), .cols = @intCast(left - rect.col) },
        .{ .row = @intCast(top), .col = @intCast(right), .rows = @intCast(bottom - top), .cols = @intCast(@as(i64, rect.col) + rect.cols - right) },
    };
    for (candidates) |candidate| if (candidate.rows != 0 and candidate.cols != 0) try out.append(a, candidate);
}

// #121: generation replacement keeps a window-owned ID; disappearance schedules
// deletion before reuse. Generate resource reorder, replacement, removal and empty.
test "owned IDs survive generations and resources delete before reuse" {
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    var pixels = [_]u8{ 1, 2, 3, 255 };
    const resource = Resource{ .id = 0xffffffff, .generation = 1, .width = 1, .height = 1, .pixels = &pixels };
    try state.replace(&.{resource}, &.{});
    try state.allocate(100000, 100001);
    pixels[0] = 9;
    try std.testing.expectEqual(@as(u8, 1), state.images.items[0].resource.pixels[0]);
    try std.testing.expectEqual(@as(?u32, 100000), state.images.items[0].outer);
    var changed = resource;
    changed.generation = 2;
    var second = resource;
    second.id = 2;
    for (0..4) |step| {
        const list: []const Resource = switch (step) {
            0 => &.{ second, changed },
            1 => &.{ changed, second },
            2 => &.{second},
            else => &.{},
        };
        try state.replace(list, &.{});
        try state.allocate(100000, 100001);
        if (step < 2) {
            try std.testing.expectEqual(@as(?u32, 100000), state.images.items[state.find(changed.id).?].outer);
            try std.testing.expectEqual(@as(?u32, 100001), state.images.items[state.find(second.id).?].outer);
        } else {
            try std.testing.expectEqualSlices(u32, if (step == 2) &.{100000} else &.{ 100000, 100001 }, state.deleted.items);
        }
    }
    try state.replace(&.{resource}, &.{});
    try state.allocate(100000, 100000);
    try std.testing.expectEqual(@as(?u32, 100000), state.images.items[0].outer);
    try std.testing.expectError(error.DuplicateImage, state.replace(&.{ resource, resource }, &.{}));
    try std.testing.expectEqual(@as(usize, 1), state.images.items.len);
    try state.replace(&.{ resource, second }, &.{});
    try std.testing.expectError(error.ImageRangeExhausted, state.allocate(100000, 100000));
}

fn samplePlacement() Placement {
    return .{ .image = 7, .col = 0, .row = 0, .cols = 4, .rows = 2, .z = -1, .source_x = 0, .source_y = 0, .source_width = 80, .source_height = 80, .pixel_width = 40, .pixel_height = 40 };
}
fn geometry() Geometry {
    return .{ .content = .{ .row = 3, .col = 2, .rows = 4, .cols = 8 }, .terminal = .{ .rows = 10, .cols = 20 }, .cell_width = 10, .cell_height = 20, .z_base = -1610612736 };
}

// #121: positions are content-origin relative, clips crop the source rather
// than move it. Enumerate both edges, offscreen, exact fit and negative origins.
test "explicit position and pixel crop obey content and terminal bounds" {
    for ([_]i32{ -8, -1, 0, 1, 7, 8 }) |col| {
        for ([_]i32{ -4, -1, 0, 1, 3, 4 }) |row| {
            var p = samplePlacement();
            p.col = col;
            p.row = row;
            const g = geometry();
            const expected_left = @max(col, 0);
            const expected_right = @min(col + 4, 8);
            const expected_top = @max(row, 0);
            const expected_bottom = @min(row + 2, 4);
            const got = plan(p, g);
            if (expected_left >= expected_right or expected_top >= expected_bottom) {
                try std.testing.expect(got == null);
            } else {
                const actual = got.?;
                try std.testing.expectEqual(@as(i64, 2 + expected_left), actual.col);
                try std.testing.expectEqual(@as(i64, 3 + expected_top), actual.row);
                try std.testing.expectEqual(@as(u32, @intCast((expected_left - col) * 20)), actual.source_x);
                try std.testing.expectEqual(@as(u32, @intCast((expected_top - row) * 40)), actual.source_y);
                try std.testing.expectEqual(@as(u32, @intCast((expected_right - expected_left) * 20)), actual.source_width);
                try std.testing.expectEqual(@as(u32, @intCast((expected_bottom - expected_top) * 40)), actual.source_height);
            }
        }
    }
    var g = geometry();
    g.content.row = -1;
    g.content.col = -1;
    const clipped = plan(samplePlacement(), g).?;
    try std.testing.expectEqual(@as(i64, 0), clipped.row);
    try std.testing.expectEqual(@as(i64, 0), clipped.col);
    try std.testing.expectEqual(@as(u32, 20), clipped.source_x);
    try std.testing.expectEqual(@as(u32, 40), clipped.source_y);
    g = geometry();
    g.terminal.rows = 4;
    g.terminal.cols = 3;
    const terminal_clip = plan(samplePlacement(), g).?;
    try std.testing.expectEqual(@as(u32, 20), terminal_clip.source_width);
    try std.testing.expectEqual(@as(u32, 40), terminal_clip.source_height);
    g.cell_width = 0;
    try std.testing.expect(plan(samplePlacement(), g) == null);
}

// #121: uploads use a name, not inline pixels, and the outer placement and
// deletion refer to allocated IDs. The real SHM object is the collaborator.
test "graphics bytes upload shared memory place ordered images and delete" {
    if (!@import("platform").shm.supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    const resource = Resource{ .id = 7, .generation = 1, .width = 1, .height = 1, .pixels = &.{ 12, 34, 56, 255 } };
    var p = samplePlacement();
    var upper = p;
    upper.z = 100;
    try state.replace(&.{resource}, &.{ upper, p });
    try std.testing.expect(try state.paint(&out.writer, 100000, 199999, geometry()));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=t,t=s,f=32,s=1,v=1,i=100000,S=4,q=2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[4;3H\x1b_Ga=p,C=1,i=100000,p=200000,c=4,r=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "z=-1610612735") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "z=-1610612736") != null);
    // A non-image update does not resend the same generation.
    out.clearRetainingCapacity();
    try std.testing.expect(try state.paint(&out.writer, 100000, 199999, geometry()));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=t") == null);
    try state.replace(&.{}, &.{});
    out.clearRetainingCapacity();
    try std.testing.expect(try state.paint(&out.writer, 100000, 199999, geometry()));
    try std.testing.expectEqualStrings("\x1b_Gq=2,a=d,d=I,i=100000;\x1b\\", out.written());
    p.offset_x = 3;
    p.offset_y = 2;
    const offset = plan(p, geometry()).?;
    try std.testing.expectEqual(@as(u32, 3), offset.offset_x);
    try std.testing.expectEqual(@as(u32, 2), offset.offset_y);
}

// Occlusion subtraction conserves visible area, never emits overlapping pieces,
// and remains safe for cutters disjoint from or covering the whole rectangle.
test "higher rectangles split explicit images without leaking through" {
    const a = std.testing.allocator;
    for ([_]i32{ -2, 0, 2, 5 }) |row| {
        for ([_]i32{ -2, 0, 2, 5 }) |col| {
            var fragments: std.ArrayList(cells.Rect) = .empty;
            defer fragments.deinit(a);
            const area = cells.Rect{ .row = 0, .col = 0, .rows = 4, .cols = 4 };
            const cutter = cells.Rect{ .row = row, .col = col, .rows = 3, .cols = 3 };
            try subtract(&fragments, a, area, cutter);
            for (0..4) |r| for (0..4) |c| {
                var count: usize = 0;
                for (fragments.items) |fragment| if (fragment.contains(@intCast(r), @intCast(c))) {
                    count += 1;
                };
                try std.testing.expectEqual(@as(usize, if (cutter.contains(@intCast(r), @intCast(c))) 0 else 1), count);
            };
        }
    }
}

// A busy outer terminal must not expose half an upload batch or lose damage.
// Once the real SHM name disappears, the same newest frame becomes paintable.
test "shared memory pressure defers the batch until consumption" {
    if (!@import("platform").shm.supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var state = State.init(a);
    defer state.deinit();
    const pixels = [_]u8{ 1, 2, 3, 255 };
    for (0..kitty.shared_memory.Pool.max_objects) |i| _ = try state.uploads.create(&pixels, i);
    const resource = Resource{ .id = 7, .generation = 1, .width = 1, .height = 1, .pixels = &pixels };
    try state.replace(&.{resource}, &.{samplePlacement()});
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try std.testing.expect(!try state.paint(&out.writer, 100000, 199999, geometry()));
    try std.testing.expect(state.pending);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(!state.images.items[0].uploaded);
    state.uploads.objects.items[0].unlink();
    try std.testing.expect(try state.paint(&out.writer, 100000, 199999, geometry()));
    try std.testing.expect(!state.pending);
    try std.testing.expect(state.images.items[0].uploaded);
}

// Clipping a scaled one-pixel image must keep it visible, even when the
// destination clip spans less than a full source pixel.
test "subpixel source crops retain a visible pixel" {
    var p = samplePlacement();
    p.source_width = 1;
    p.source_height = 1;
    var g = geometry();
    g.terminal.cols = 3;
    g.terminal.rows = 4;
    const clipped = plan(p, g).?;
    try std.testing.expectEqual(@as(u32, 1), clipped.source_width);
    try std.testing.expectEqual(@as(u32, 1), clipped.source_height);
    try std.testing.expectEqual(@as(u32, 1), clipped.cols);
    try std.testing.expectEqual(@as(u32, 1), clipped.rows);
}

test "source crop rejects coordinates outside Kitty u32 range" {
    for ([_]bool{ false, true }) |vertical| {
        var p = samplePlacement();
        if (vertical) {
            p.row = -1;
            p.source_y = std.math.maxInt(u32);
        } else {
            p.col = -1;
            p.source_x = std.math.maxInt(u32);
        }
        try std.testing.expect(plan(p, geometry()) == null);
    }
}
