const std = @import("std");

pub const keep_producer_tokens = true;

pub const CoreHandle = usize;

pub const CoreRect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const CorePoint = extern struct {
    x: i32,
    y: i32,
};

pub const CoreColor = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const ProducerApi = enum {
    sdl2,
    sdl3,
    gl,
    vulkan,
    external,
};

pub const PixelSemanticFormat = enum {
    rgba8,
    bgra8,
    xrgb8888,
    argb8888,
    rgb565,
    rgba4444,
    i420,
    yv12,
    nv12,
    nv21,
    a2b10g10r10_unorm_pack32,
    unknown,
};

pub const ProducerFormatToken = union(enum) {
    sdl2: u32,
    sdl3: u32,
    vulkan: u32,
    gl: struct {
        format: u32,
        type: u32,
    },
};

pub const PixelFormat = if (keep_producer_tokens)
    struct {
        semantic: PixelSemanticFormat,
        source: ?ProducerFormatToken = null,
    }
else
    struct {
        semantic: PixelSemanticFormat,
    };

pub const BlendSemanticMode = enum {
    none,
    blend,
    add,
    mod,
    mul,
    unknown,
};

pub const ProducerBlendToken = union(enum) {
    sdl2: i32,
    sdl3: u32,
};

pub const BlendMode = if (keep_producer_tokens)
    struct {
        semantic: BlendSemanticMode,
        source: ?ProducerBlendToken = null,
    }
else
    struct {
        semantic: BlendSemanticMode,
    };

pub fn pixelFormat(semantic: PixelSemanticFormat, source: ?ProducerFormatToken) PixelFormat {
    return if (keep_producer_tokens)
        .{ .semantic = semantic, .source = source }
    else
        .{ .semantic = semantic };
}

pub fn blendMode(semantic: BlendSemanticMode, source: ?ProducerBlendToken) BlendMode {
    return if (keep_producer_tokens)
        .{ .semantic = semantic, .source = source }
    else
        .{ .semantic = semantic };
}

test "pixel format preserves semantic format and producer token" {
    const format = pixelFormat(.nv12, .{ .sdl2 = 0x3231564e });

    try std.testing.expectEqual(PixelSemanticFormat.nv12, format.semantic);
    if (keep_producer_tokens) {
        try std.testing.expect(format.source != null);
        try std.testing.expectEqual(@as(u32, 0x3231564e), format.source.?.sdl2);
    }
}

test "unknown pixel format can retain original producer token" {
    const format = pixelFormat(.unknown, .{ .vulkan = 0x7fff_ffff });

    try std.testing.expectEqual(PixelSemanticFormat.unknown, format.semantic);
    if (keep_producer_tokens) {
        try std.testing.expect(format.source != null);
        try std.testing.expectEqual(@as(u32, 0x7fff_ffff), format.source.?.vulkan);
    }
}

test "blend mode preserves semantic mode and producer token" {
    const mode = blendMode(.blend, .{ .sdl2 = 1 });

    try std.testing.expectEqual(BlendSemanticMode.blend, mode.semantic);
    if (keep_producer_tokens) {
        try std.testing.expect(mode.source != null);
        try std.testing.expectEqual(@as(i32, 1), mode.source.?.sdl2);
    }
}
