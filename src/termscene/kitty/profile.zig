const caps_mod = @import("capabilities.zig");
const backend = @import("backend.zig");

pub const OutputProfile = enum {
    direct_apc,
    shm,
    file_whole,
    file_offset_ring,
};

pub fn choose(caps: caps_mod.Capabilities) OutputProfile {
    // Prefer SHM on macOS; retain the existing Linux ordering until measured.
    if (@import("builtin").os.tag == .macos and caps.shared_memory_rgba.enabled()) return .shm;
    if (caps.file_regular_offset_rgba.enabled()) return .file_offset_ring;
    if (caps.file_regular_whole_rgba.enabled()) return .file_whole;
    if (caps.shared_memory_rgba.enabled()) return .shm;
    return .direct_apc;
}

pub fn uploadMedium(profile: OutputProfile) backend.UploadMedium {
    return switch (profile) {
        .direct_apc => .direct,
        .shm => .shm,
        .file_whole => .file_whole,
        .file_offset_ring => .file_offset,
    };
}

test "automatic output prefers probed SHM on macOS and respects unavailable transports" {
    const std = @import("std");
    var caps = caps_mod.Capabilities{};
    try std.testing.expectEqual(OutputProfile.direct_apc, choose(caps));
    caps.file_regular_whole_rgba.probe = .supported;
    try std.testing.expectEqual(OutputProfile.file_whole, choose(caps));
    caps.shared_memory_rgba.probe = .supported;
    try std.testing.expectEqual(if (@import("builtin").os.tag == .macos) OutputProfile.shm else OutputProfile.file_whole, choose(caps));
    caps.shared_memory_rgba.compat = .avoid;
    try std.testing.expectEqual(OutputProfile.file_whole, choose(caps));
    caps.file_regular_whole_rgba.probe = .unsupported;
    try std.testing.expectEqual(OutputProfile.direct_apc, choose(caps));
    caps.shared_memory_rgba.compat = .unknown;
    try std.testing.expectEqual(OutputProfile.shm, choose(caps));
}
