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

pub fn applyFrameBatchCoalesced(allocator: std.mem.Allocator, writer: anytype, groups: BatchGroupsView) !void {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try appendGroup(allocator, &bytes, groups.deletes);
    try appendGroup(allocator, &bytes, groups.uploads);
    try appendGroup(allocator, &bytes, groups.placements);
    try appendGroup(allocator, &bytes, groups.after);
    if (bytes.items.len > 0) try writer.writeAll(bytes.items);
}

fn writeGroup(writer: anytype, chunks: []const []const u8) !void {
    for (chunks) |chunk| try writer.writeAll(chunk);
}

fn appendGroup(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), chunks: []const []const u8) !void {
    for (chunks) |chunk| try bytes.appendSlice(allocator, chunk);
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

test "terminal batch applier can coalesce frame batch into one write" {
    const OneWriteWriter = struct {
        const Error = error{TooManyWrites};

        writes: usize = 0,
        bytes: std.ArrayList(u8) = .empty,

        fn writeAll(self: *@This(), bytes: []const u8) Error!void {
            self.writes += 1;
            if (self.writes > 1) return error.TooManyWrites;
            self.bytes.appendSlice(std.testing.allocator, bytes) catch return error.TooManyWrites;
        }
    };

    var writer = OneWriteWriter{};
    defer writer.bytes.deinit(std.testing.allocator);

    try applyFrameBatchCoalesced(std.testing.allocator, &writer, .{
        .deletes = &.{"D"},
        .uploads = &.{"U"},
        .placements = &.{"P"},
        .after = &.{"A"},
    });

    try std.testing.expectEqual(@as(usize, 1), writer.writes);
    try std.testing.expectEqualStrings("DUPA", writer.bytes.items);
}
