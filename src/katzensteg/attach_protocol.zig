const std = @import("std");

pub const FrameBatchGroups = struct {
    deletes: []const []const u8,
    uploads: []const []const u8,
    placements: []const []const u8,
    after: []const []const u8,

    fn deinit(self: *FrameBatchGroups, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.deletes);
        freeStringList(allocator, self.uploads);
        freeStringList(allocator, self.placements);
        freeStringList(allocator, self.after);
        self.* = undefined;
    }
};

pub const FrameBatch = struct {
    window_id: []const u8,
    seq: u64,
    groups: FrameBatchGroups,

    pub fn deinit(self: *FrameBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.window_id);
        self.groups.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidMessage,
};

pub fn parseFrameBatch(allocator: std.mem.Allocator, line: []const u8) !FrameBatch {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;

    const type_value = root.get("type") orelse return error.InvalidMessage;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "frame_batch")) return error.InvalidMessage;

    const window_value = root.get("window_id") orelse return error.InvalidMessage;
    if (window_value != .string) return error.InvalidMessage;

    const seq_value = root.get("seq") orelse return error.InvalidMessage;
    const seq: u64 = switch (seq_value) {
        .integer => |value| if (value >= 0) @intCast(value) else return error.InvalidMessage,
        else => return error.InvalidMessage,
    };

    const groups_value = root.get("groups") orelse return error.InvalidMessage;
    if (groups_value != .object) return error.InvalidMessage;

    const window_id = try allocator.dupe(u8, window_value.string);
    errdefer allocator.free(window_id);

    var groups = FrameBatchGroups{
        .deletes = try parseStringList(allocator, groups_value.object.get("deletes") orelse return error.InvalidMessage),
        .uploads = &.{},
        .placements = &.{},
        .after = &.{},
    };
    errdefer groups.deinit(allocator);
    groups.uploads = try parseStringList(allocator, groups_value.object.get("uploads") orelse return error.InvalidMessage);
    groups.placements = try parseStringList(allocator, groups_value.object.get("placements") orelse return error.InvalidMessage);
    groups.after = try parseStringList(allocator, groups_value.object.get("after") orelse return error.InvalidMessage);

    return .{
        .window_id = window_id,
        .seq = seq,
        .groups = groups,
    };
}

fn parseStringList(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return error.InvalidMessage;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    errdefer allocator.free(out);
    for (value.array.items, 0..) |item, index| {
        if (item != .string) return error.InvalidMessage;
        out[index] = try allocator.dupe(u8, item.string);
    }
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

test "attach protocol parses frame batch groups" {
    const line =
        \\{"type":"frame_batch","window_id":"main","seq":2,"groups":{"deletes":["\u001b_Ga=d;\u001b\\"],"uploads":["\u001b_Ga=t;\u001b\\"],"placements":["\u001b[1;1H\u001b_Ga=p;\u001b\\"],"after":[]}}
    ;
    var batch = try parseFrameBatch(std.testing.allocator, line);
    defer batch.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("main", batch.window_id);
    try std.testing.expectEqual(@as(u64, 2), batch.seq);
    try std.testing.expectEqual(@as(usize, 1), batch.groups.uploads.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, batch.groups.uploads[0], 0x1b) != null);
}
