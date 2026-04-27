const std = @import("std");

pub const CaptureMode = enum {
    disabled,
    sync,
    pbo,
};

pub const Buffers = struct {
    raw: []u8 = &.{},
    rgba: []u8 = &.{},
    len: usize = 0,

    pub fn ensure(self: *Buffers, allocator: std.mem.Allocator, len: usize) !void {
        if (self.len == len and self.raw.len == len and self.rgba.len == len) return;
        self.deinit(allocator);
        self.raw = try allocator.alloc(u8, len);
        errdefer {
            allocator.free(self.raw);
            self.raw = &.{};
        }
        self.rgba = try allocator.alloc(u8, len);
        self.len = len;
    }

    pub fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        if (self.raw.len > 0) allocator.free(self.raw);
        if (self.rgba.len > 0) allocator.free(self.rgba);
        self.* = .{};
    }
};

pub const PboState = struct {
    ids: [2]u32 = .{ 0, 0 },
    len: usize = 0,
    index: usize = 0,
    primed: bool = false,

    pub fn reset(self: *PboState) void {
        self.* = .{};
    }
};

pub const DownscaleState = struct {
    fbo: u32 = 0,
    texture: u32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn reset(self: *DownscaleState) void {
        self.* = .{};
    }
};

pub fn envEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    return !(std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off"));
}

pub fn modeFromEnv(value: ?[]const u8) CaptureMode {
    const raw = value orelse return .disabled;
    if (!envEnabled(raw)) return .disabled;
    if (std.ascii.eqlIgnoreCase(raw, "pbo")) return .pbo;
    if (std.ascii.eqlIgnoreCase(raw, "async")) return .pbo;
    return .sync;
}

test "gl capture buffers reuse same allocation for same size" {
    var buffers = Buffers{};
    defer buffers.deinit(std.testing.allocator);

    try buffers.ensure(std.testing.allocator, 16);
    const raw = buffers.raw.ptr;
    const rgba = buffers.rgba.ptr;

    try buffers.ensure(std.testing.allocator, 16);

    try std.testing.expectEqual(raw, buffers.raw.ptr);
    try std.testing.expectEqual(rgba, buffers.rgba.ptr);
}

test "gl capture mode selects sync and pbo modes" {
    try std.testing.expectEqual(CaptureMode.disabled, modeFromEnv(null));
    try std.testing.expectEqual(CaptureMode.disabled, modeFromEnv("0"));
    try std.testing.expectEqual(CaptureMode.sync, modeFromEnv("1"));
    try std.testing.expectEqual(CaptureMode.sync, modeFromEnv("true"));
    try std.testing.expectEqual(CaptureMode.pbo, modeFromEnv("pbo"));
    try std.testing.expectEqual(CaptureMode.pbo, modeFromEnv("async"));
}

pub fn flipRgbaRows(dst: []u8, src: []const u8, width: i32, height: i32) void {
    const row_len: usize = @intCast(width * 4);
    const h: usize = @intCast(height);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const src_y = h - 1 - y;
        @memcpy(dst[y * row_len .. (y + 1) * row_len], src[src_y * row_len .. (src_y + 1) * row_len]);
    }
}

test "gl capture env defaults off and accepts common opt-outs" {
    try std.testing.expect(!envEnabled(null));
    try std.testing.expect(envEnabled("1"));
    try std.testing.expect(envEnabled("true"));
    try std.testing.expect(envEnabled("yes"));
    try std.testing.expect(!envEnabled("0"));
    try std.testing.expect(!envEnabled("false"));
    try std.testing.expect(!envEnabled("no"));
    try std.testing.expect(!envEnabled("off"));
}

test "rgba row flip converts OpenGL bottom-left rows to top-left rows" {
    const src = [_]u8{
        1, 1, 1, 255, 2, 2, 2, 255,
        3, 3, 3, 255, 4, 4, 4, 255,
        5, 5, 5, 255, 6, 6, 6, 255,
    };
    var dst: [src.len]u8 = undefined;

    flipRgbaRows(&dst, &src, 2, 3);

    try std.testing.expectEqualSlices(u8, &.{
        5, 5, 5, 255, 6, 6, 6, 255,
        3, 3, 3, 255, 4, 4, 4, 255,
        1, 1, 1, 255, 2, 2, 2, 255,
    }, &dst);
}
