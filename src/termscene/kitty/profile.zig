const caps_mod = @import("capabilities.zig");
const backend = @import("backend.zig");

pub const OutputProfile = enum {
    direct_apc,
    file_whole,
    file_offset_ring,
};

pub fn choose(caps: caps_mod.Capabilities) OutputProfile {
    if (caps.file_regular_offset_rgba.enabled()) return .file_offset_ring;
    if (caps.file_regular_whole_rgba.enabled()) return .file_whole;
    return .direct_apc;
}

pub fn uploadMedium(profile: OutputProfile) backend.UploadMedium {
    return switch (profile) {
        .direct_apc => .direct,
        .file_whole => .file_whole,
        .file_offset_ring => .file_offset,
    };
}
