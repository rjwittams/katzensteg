const std = @import("std");

pub const FrameRecord = struct {
    id: u64 = 0,
    segment_id: u64 = 0,
    ts_ns: i128,
    present_ns: i128,
    queue_depth: usize,
    skipped_presents: u64,
    render_strategy: []const u8,
    strategy_short: []const u8,
    copies: u32,
    fills: u32,
    lines: u32,
    uploads: u32,
    placements: u32,
    bytes_uploaded: u64,
    fallback_texture_key: u64,
    fallback_reason: ?[]const u8,
    image_id: u32,
    placement_id: u32,
    first_event_seq: u64 = 0,
    last_event_seq: u64 = 0,
};

pub const ResourceKind = enum {
    texture,
    image,
    placement,
};

pub const ResourceRecord = struct {
    kind: ResourceKind,
    texture_key: u64,
    placement_id: u32,
    alias: [24]u8,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
    image_id: u32,
};

pub fn makeAlias(texture_key: u64) [24]u8 {
    var buf: [24]u8 = [_]u8{0} ** 24;
    const adjectives = [_][]const u8{ "amber", "cinder", "sable", "lunar", "brisk", "moss", "ember", "azure" };
    const animals = [_][]const u8{ "otter", "lark", "lynx", "quail", "stoat", "wren", "ibis", "yak" };
    const a = adjectives[@intCast(texture_key % adjectives.len)];
    const b = animals[@intCast((texture_key / 17) % animals.len)];
    _ = std.fmt.bufPrint(&buf, "tex-{s}-{s}-{x}", .{ a, b, texture_key & 0xff }) catch {};
    return buf;
}
