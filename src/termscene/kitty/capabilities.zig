const std = @import("std");
const system_io = @import("platform");
const detect = @import("detect.zig");

pub const ProbeState = enum {
    unsupported,
    supported,
};

pub const CompatState = enum {
    unknown,
    pass,
    partial,
    fail,
    avoid,
};

pub const Feature = struct {
    probe: ProbeState = .unsupported,
    compat: CompatState = .unknown,

    pub fn enabled(self: Feature) bool {
        return self.probe == .supported and self.compat != .fail and self.compat != .avoid;
    }
};

pub const TerminalIdentity = enum {
    unknown,
    kitty,
    ghostty,
};

pub const Capabilities = struct {
    terminal: TerminalIdentity = .unknown,
    graphics_basic: Feature = .{},
    shared_memory_rgba: Feature = .{},
    file_regular_whole_rgba: Feature = .{},
    file_regular_offset_rgba: Feature = .{},
};

pub fn detectTerminalIdentity() TerminalIdentity {
    if (std.c.getenv("TERM_PROGRAM")) |value| {
        const s = std.mem.span(value);
        if (std.mem.eql(u8, s, "ghostty")) return .ghostty;
        if (std.mem.eql(u8, s, "kitty")) return .kitty;
    }
    if (std.c.getenv("TERM")) |value| {
        const s = std.mem.span(value);
        if (std.mem.eql(u8, s, "xterm-kitty")) return .kitty;
        if (std.mem.eql(u8, s, "xterm-ghostty")) return .ghostty;
    }
    return .unknown;
}

pub fn applyKnownCompat(caps: *Capabilities) void {
    switch (caps.terminal) {
        .kitty => {
            caps.file_regular_whole_rgba.compat = .pass;
            caps.file_regular_offset_rgba.compat = .pass;
        },
        .ghostty => {
            caps.file_regular_whole_rgba.compat = .pass;
            caps.file_regular_offset_rgba.compat = .avoid;
        },
        .unknown => {},
    }
}

pub fn probe(allocator: std.mem.Allocator, tty: system_io.fs.File, path: []const u8) !Capabilities {
    var caps: Capabilities = .{ .terminal = detectTerminalIdentity() };
    caps.graphics_basic.probe = if (try detect.detectGraphicsSupportOnTty(allocator, tty)) .supported else .unsupported;
    caps.file_regular_whole_rgba.probe = if (try detect.detectFileTransmissionSupportWhole(allocator, tty, path)) .supported else .unsupported;
    caps.file_regular_offset_rgba.probe = if (try detect.detectFileTransmissionSupportOffset(allocator, tty, path)) .supported else .unsupported;
    caps.shared_memory_rgba.probe = if (try detect.detectSharedMemorySupport(allocator, tty)) .supported else .unsupported;
    applyKnownCompat(&caps);
    return caps;
}

/// The coordinate of the first pixel in SGR-pixel mouse reports (mode 1016).
/// xterm, which defined the mode, counts pixels from 1 like cells; kitty and
/// Ghostty round the pointer's 0-based position within the grid. All three
/// report the exact grid size as the pty pixel size.
pub fn mousePixelOrigin(identity: TerminalIdentity) i32 {
    return switch (identity) {
        .kitty, .ghostty => 0,
        .unknown => 1,
    };
}

test "pixel mouse origin follows the terminal's convention" {
    try std.testing.expectEqual(@as(i32, 0), mousePixelOrigin(.kitty));
    try std.testing.expectEqual(@as(i32, 0), mousePixelOrigin(.ghostty));
    try std.testing.expectEqual(@as(i32, 1), mousePixelOrigin(.unknown));
}
