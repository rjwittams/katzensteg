const std = @import("std");

pub const BatchGroupsView = struct {
    deletes: []const []const u8,
    uploads: []const []const u8,
    placements: []const []const u8,
    after: []const []const u8,
};

pub fn applyFrameBatch(writer: anytype, groups: BatchGroupsView) !void {
    try writeGroup(writer, groups.deletes);
    try writeGroup(writer, groups.uploads);
    try writeGroup(writer, groups.placements);
    try writeGroup(writer, groups.after);
}

fn writeGroup(writer: anytype, chunks: []const []const u8) !void {
    for (chunks) |chunk| try writer.writeAll(chunk);
}

test "terminal batch applier writes groups in presentation order" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try applyFrameBatch(out.writer(std.testing.allocator), .{
        .deletes = &.{"D"},
        .uploads = &.{"U"},
        .placements = &.{"P"},
        .after = &.{"A"},
    });

    try std.testing.expectEqualStrings("DUPA", out.items);
}
