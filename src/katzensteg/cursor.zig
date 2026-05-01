const std = @import("std");

pub const Image = struct {
    width: i32,
    height: i32,
    hot_x: i32,
    hot_y: i32,
    rgba: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
        self.* = undefined;
    }
};

pub const Position = struct {
    x: i32,
    y: i32,
};

pub const Snapshot = struct {
    image: *const Image,
    position: Position,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cursors: std.AutoHashMap(usize, Image),
    active_cursor: usize = 0,
    visible: bool = true,
    position: ?Position = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .cursors = std.AutoHashMap(usize, Image).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.cursors.valueIterator();
        while (it.next()) |image| image.deinit(self.allocator);
        self.cursors.deinit();
        self.* = undefined;
    }

    pub fn createColorCursor(self: *State, cursor_handle: usize, width: i32, height: i32, hot_x: i32, hot_y: i32, rgba: []const u8) void {
        if (cursor_handle == 0 or width <= 0 or height <= 0) return;
        const owned = self.allocator.dupe(u8, rgba) catch return;
        const result = self.cursors.getOrPut(cursor_handle) catch {
            self.allocator.free(owned);
            return;
        };
        if (result.found_existing) result.value_ptr.deinit(self.allocator);
        result.value_ptr.* = .{
            .width = width,
            .height = height,
            .hot_x = hot_x,
            .hot_y = hot_y,
            .rgba = owned,
        };
    }

    pub fn setCursor(self: *State, cursor_handle: usize) void {
        self.active_cursor = cursor_handle;
    }

    pub fn showCursor(self: *State, visible: bool) void {
        self.visible = visible;
    }

    pub fn freeCursor(self: *State, cursor_handle: usize) void {
        if (cursor_handle == 0) return;
        if (self.active_cursor == cursor_handle) self.active_cursor = 0;
        if (self.cursors.fetchRemove(cursor_handle)) |entry| {
            var image = entry.value;
            image.deinit(self.allocator);
        }
    }

    pub fn setPosition(self: *State, position: ?Position) void {
        self.position = position;
    }

    pub fn snapshot(self: *const State) ?Snapshot {
        if (!self.visible or self.active_cursor == 0) return null;
        const position = self.position orelse return null;
        const image = self.cursors.getPtr(self.active_cursor) orelse return null;
        return .{ .image = image, .position = position };
    }
};

pub fn blendRgba(
    dst: []u8,
    dst_width: i32,
    dst_height: i32,
    src: []const u8,
    src_width: i32,
    src_height: i32,
    src_pitch: i32,
    mouse_x: i32,
    mouse_y: i32,
    hot_x: i32,
    hot_y: i32,
) void {
    if (dst_width <= 0 or dst_height <= 0 or src_width <= 0 or src_height <= 0 or src_pitch < src_width * 4) return;
    const dst_expected: usize = @as(usize, @intCast(dst_width)) * @as(usize, @intCast(dst_height)) * 4;
    const src_expected: usize = @as(usize, @intCast(src_pitch)) * @as(usize, @intCast(src_height));
    if (dst.len < dst_expected or src.len < src_expected) return;

    const origin_x = mouse_x - hot_x;
    const origin_y = mouse_y - hot_y;
    const start_x = @max(0, -origin_x);
    const start_y = @max(0, -origin_y);
    const end_x = @min(src_width, dst_width - origin_x);
    const end_y = @min(src_height, dst_height - origin_y);
    if (start_x >= end_x or start_y >= end_y) return;

    var sy = start_y;
    while (sy < end_y) : (sy += 1) {
        var sx = start_x;
        while (sx < end_x) : (sx += 1) {
            const src_idx: usize = @as(usize, @intCast(sy)) * @as(usize, @intCast(src_pitch)) + @as(usize, @intCast(sx)) * 4;
            const alpha = src[src_idx + 3];
            if (alpha == 0) continue;

            const dx = origin_x + sx;
            const dy = origin_y + sy;
            const dst_idx: usize = (@as(usize, @intCast(dy)) * @as(usize, @intCast(dst_width)) + @as(usize, @intCast(dx))) * 4;
            if (alpha == 255) {
                dst[dst_idx + 0] = src[src_idx + 0];
                dst[dst_idx + 1] = src[src_idx + 1];
                dst[dst_idx + 2] = src[src_idx + 2];
                dst[dst_idx + 3] = src[src_idx + 3];
                continue;
            }

            const inv_alpha: u16 = 255 - alpha;
            dst[dst_idx + 0] = blendChannel(src[src_idx + 0], alpha, dst[dst_idx + 0], inv_alpha);
            dst[dst_idx + 1] = blendChannel(src[src_idx + 1], alpha, dst[dst_idx + 1], inv_alpha);
            dst[dst_idx + 2] = blendChannel(src[src_idx + 2], alpha, dst[dst_idx + 2], inv_alpha);
            dst[dst_idx + 3] = blendChannel(255, alpha, dst[dst_idx + 3], inv_alpha);
        }
    }
}

fn blendChannel(src: u8, alpha: u8, dst: u8, inv_alpha: u16) u8 {
    return @intCast((@as(u16, src) * @as(u16, alpha) + @as(u16, dst) * inv_alpha + 127) / 255);
}

test "cursor blend overwrites opaque pixels at hotspot-adjusted position" {
    var dst = [_]u8{0} ** (4 * 4 * 4);
    var src = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };

    blendRgba(&dst, 4, 4, &src, 2, 2, 8, 2, 2, 1, 1);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, dst[(1 * 4 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, dst[(2 * 4 + 2) * 4 ..][0..4]);
}

test "cursor blend alpha-composites over framebuffer" {
    var dst = [_]u8{ 100, 100, 100, 255 };
    const src = [_]u8{ 200, 0, 0, 128 };

    blendRgba(&dst, 1, 1, &src, 1, 1, 4, 0, 0, 0, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 150, 50, 50, 255 }, &dst);
}

test "cursor blend clips against framebuffer edges" {
    var dst = [_]u8{0} ** (2 * 2 * 4);
    const src = [_]u8{
        10, 20, 30, 255, 40, 50, 60, 255,
        70, 80, 90, 255, 1,  2,  3,  255,
    };

    blendRgba(&dst, 2, 2, &src, 2, 2, 8, 0, 0, 1, 1);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 255 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, dst[4..8]);
}
