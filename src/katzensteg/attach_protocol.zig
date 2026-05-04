const std = @import("std");
const render_batch_protocol = @import("render_batch_protocol.zig");

pub const PresentationRectCells = render_batch_protocol.PresentationRectCells;
pub const SourcePixels = render_batch_protocol.SourcePixels;

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

pub const Detached = struct {
    window_id: []const u8,

    pub fn deinit(self: *Detached, allocator: std.mem.Allocator) void {
        allocator.free(self.window_id);
        self.* = undefined;
    }
};

pub const PresentationStatus = struct {
    window_id: []const u8,
    ready_to_show: bool = false,
    source_px: ?SourcePixels = null,
    effective_rect_cells: ?PresentationRectCells = null,

    pub fn deinit(self: *PresentationStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.window_id);
        self.* = undefined;
    }
};

pub const PeerMessage = union(enum) {
    frame_batch: FrameBatch,
    detached: Detached,
    presentation_status: PresentationStatus,

    pub fn deinit(self: *PeerMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .frame_batch => |*batch| batch.deinit(allocator),
            .detached => |*detached| detached.deinit(allocator),
            .presentation_status => |*status| status.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ParseError = error{
    InvalidMessage,
};

pub fn parsePeerMessage(allocator: std.mem.Allocator, line: []const u8) !PeerMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;

    const type_value = root.get("type") orelse return error.InvalidMessage;
    if (type_value != .string) return error.InvalidMessage;

    if (std.mem.eql(u8, type_value.string, "frame_batch")) {
        return .{ .frame_batch = try parseFrameBatch(allocator, line) };
    }

    const window_value = root.get("window_id") orelse return error.InvalidMessage;
    if (window_value != .string) return error.InvalidMessage;
    const window_id = try allocator.dupe(u8, window_value.string);
    errdefer allocator.free(window_id);

    if (std.mem.eql(u8, type_value.string, "detached")) {
        return .{ .detached = .{ .window_id = window_id } };
    }

    if (std.mem.eql(u8, type_value.string, "presentation_status")) {
        return .{ .presentation_status = .{
            .window_id = window_id,
            .ready_to_show = if (root.get("ready_to_show")) |value| jsonBool(value) else false,
            .source_px = if (root.get("source_px")) |value| try parseSourcePixels(value) else null,
            .effective_rect_cells = if (root.get("effective_rect_cells")) |value| try parseRectCells(value) else null,
        } };
    }

    return error.InvalidMessage;
}

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

fn parseSourcePixels(value: std.json.Value) !SourcePixels {
    if (value != .object) return error.InvalidMessage;
    return .{
        .w = try jsonI32(value.object.get("w") orelse return error.InvalidMessage),
        .h = try jsonI32(value.object.get("h") orelse return error.InvalidMessage),
    };
}

fn parseRectCells(value: std.json.Value) !PresentationRectCells {
    if (value != .object) return error.InvalidMessage;
    return .{
        .row = try jsonI32(value.object.get("row") orelse return error.InvalidMessage),
        .col = try jsonI32(value.object.get("col") orelse return error.InvalidMessage),
        .rows = try jsonI32(value.object.get("rows") orelse return error.InvalidMessage),
        .cols = try jsonI32(value.object.get("cols") orelse return error.InvalidMessage),
    };
}

fn jsonI32(value: std.json.Value) !i32 {
    return switch (value) {
        .integer => |n| if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) @intCast(n) else error.InvalidMessage,
        else => error.InvalidMessage,
    };
}

fn jsonBool(value: std.json.Value) bool {
    return switch (value) {
        .bool => |b| b,
        else => false,
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

test "attach protocol parses presentation status from producer" {
    const line =
        \\{"type":"presentation_status","window_id":"main","ready_to_show":true,"source_px":{"w":320,"h":240},"effective_rect_cells":{"row":4,"col":2,"rows":18,"cols":64}}
    ;
    var message = try parsePeerMessage(std.testing.allocator, line);
    defer message.deinit(std.testing.allocator);

    const status = message.presentation_status;
    try std.testing.expectEqualStrings("main", status.window_id);
    try std.testing.expect(status.ready_to_show);
    try std.testing.expectEqual(SourcePixels{ .w = 320, .h = 240 }, status.source_px.?);
    try std.testing.expectEqual(PresentationRectCells{ .row = 4, .col = 2, .rows = 18, .cols = 64 }, status.effective_rect_cells.?);
}
