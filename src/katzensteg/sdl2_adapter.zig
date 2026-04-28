const std = @import("std");
const core = @import("core_types.zig");
const sdl = @import("sdl2.zig");

pub fn handleFromPtr(ptr: anytype) core.CoreHandle {
    return if (ptr) |p| @intFromPtr(p) else 0;
}

pub fn ptrFromHandle(comptime T: type, handle: core.CoreHandle) ?*T {
    return if (handle == 0) null else @ptrFromInt(handle);
}

pub fn rectFromSdl(rect: ?*const sdl.SDL_Rect) ?core.CoreRect {
    const r = rect orelse return null;
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

pub fn pointFromSdl(point: ?*const sdl.SDL_Point) ?core.CorePoint {
    const p = point orelse return null;
    return .{ .x = p.x, .y = p.y };
}

pub fn pixelFormatFromSdl2(format: u32) core.PixelFormat {
    const semantic: core.PixelSemanticFormat = switch (format) {
        sdl.SDL_PIXELFORMAT_ABGR8888 => .rgba8,
        sdl.SDL_PIXELFORMAT_ARGB8888 => .argb8888,
        sdl.SDL_PIXELFORMAT_XRGB8888 => .xrgb8888,
        sdl.SDL_PIXELFORMAT_RGB565 => .rgb565,
        sdl.SDL_PIXELFORMAT_RGBA4444 => .rgba4444,
        sdl.SDL_PIXELFORMAT_IYUV => .i420,
        sdl.SDL_PIXELFORMAT_YV12 => .yv12,
        sdl.SDL_PIXELFORMAT_NV12 => .nv12,
        sdl.SDL_PIXELFORMAT_NV21 => .nv21,
        else => .unknown,
    };
    return core.pixelFormat(semantic, .{ .sdl2 = format });
}

pub fn blendModeFromSdl2(mode: i32) core.BlendMode {
    const semantic: core.BlendSemanticMode = switch (mode) {
        sdl.SDL_BLENDMODE_NONE => .none,
        sdl.SDL_BLENDMODE_BLEND => .blend,
        sdl.SDL_BLENDMODE_ADD => .add,
        sdl.SDL_BLENDMODE_MOD => .mod,
        sdl.SDL_BLENDMODE_MUL => .mul,
        else => .unknown,
    };
    return core.blendMode(semantic, .{ .sdl2 = mode });
}

test "maps SDL pointer identity to core handle" {
    const texture: ?*sdl.SDL_Texture = @ptrFromInt(0x1234);
    try std.testing.expectEqual(@as(core.CoreHandle, 0x1234), handleFromPtr(texture));
    try std.testing.expectEqual(@as(core.CoreHandle, 0), handleFromPtr(@as(?*sdl.SDL_Texture, null)));
}

test "maps SDL rect and point to core values" {
    const rect = sdl.SDL_Rect{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const point = sdl.SDL_Point{ .x = 5, .y = 6 };

    try std.testing.expectEqual(core.CoreRect{ .x = 1, .y = 2, .w = 3, .h = 4 }, rectFromSdl(&rect).?);
    try std.testing.expectEqual(core.CorePoint{ .x = 5, .y = 6 }, pointFromSdl(&point).?);
    try std.testing.expectEqual(@as(?core.CoreRect, null), rectFromSdl(null));
    try std.testing.expectEqual(@as(?core.CorePoint, null), pointFromSdl(null));
}

test "maps known SDL2 pixel formats to semantic formats with source token" {
    const cases = [_]struct {
        raw: u32,
        semantic: core.PixelSemanticFormat,
    }{
        .{ .raw = sdl.SDL_PIXELFORMAT_ABGR8888, .semantic = .rgba8 },
        .{ .raw = sdl.SDL_PIXELFORMAT_ARGB8888, .semantic = .argb8888 },
        .{ .raw = sdl.SDL_PIXELFORMAT_XRGB8888, .semantic = .xrgb8888 },
        .{ .raw = sdl.SDL_PIXELFORMAT_RGB565, .semantic = .rgb565 },
        .{ .raw = sdl.SDL_PIXELFORMAT_RGBA4444, .semantic = .rgba4444 },
        .{ .raw = sdl.SDL_PIXELFORMAT_IYUV, .semantic = .i420 },
        .{ .raw = sdl.SDL_PIXELFORMAT_YV12, .semantic = .yv12 },
        .{ .raw = sdl.SDL_PIXELFORMAT_NV12, .semantic = .nv12 },
        .{ .raw = sdl.SDL_PIXELFORMAT_NV21, .semantic = .nv21 },
    };

    for (cases) |case| {
        const mapped = pixelFormatFromSdl2(case.raw);
        try std.testing.expectEqual(case.semantic, mapped.semantic);
        if (core.keep_producer_tokens) {
            try std.testing.expect(mapped.source != null);
            try std.testing.expectEqual(case.raw, mapped.source.?.sdl2);
        }
    }
}

test "maps unknown SDL2 pixel format to unknown with source token" {
    const mapped = pixelFormatFromSdl2(0x7fff_ffff);

    try std.testing.expectEqual(core.PixelSemanticFormat.unknown, mapped.semantic);
    if (core.keep_producer_tokens) {
        try std.testing.expect(mapped.source != null);
        try std.testing.expectEqual(@as(u32, 0x7fff_ffff), mapped.source.?.sdl2);
    }
}

test "maps SDL2 blend modes to semantic blend modes" {
    const cases = [_]struct {
        raw: i32,
        semantic: core.BlendSemanticMode,
    }{
        .{ .raw = sdl.SDL_BLENDMODE_NONE, .semantic = .none },
        .{ .raw = sdl.SDL_BLENDMODE_BLEND, .semantic = .blend },
        .{ .raw = sdl.SDL_BLENDMODE_ADD, .semantic = .add },
        .{ .raw = sdl.SDL_BLENDMODE_MOD, .semantic = .mod },
        .{ .raw = sdl.SDL_BLENDMODE_MUL, .semantic = .mul },
        .{ .raw = 0x7fff_ffff, .semantic = .unknown },
    };

    for (cases) |case| {
        const mapped = blendModeFromSdl2(case.raw);
        try std.testing.expectEqual(case.semantic, mapped.semantic);
        if (core.keep_producer_tokens) {
            try std.testing.expect(mapped.source != null);
            try std.testing.expectEqual(case.raw, mapped.source.?.sdl2);
        }
    }
}
