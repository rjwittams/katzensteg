const std = @import("std");

pub const BatchView = struct {
    window_id: []const u8,
    seq: u64,
    deletes: []const []const u8,
    uploads: []const []const u8,
    placements: []const []const u8,
    after: []const []const u8,
};

pub const PresentationAspect = enum {
    stretch,
    contain,
    cover,
};

pub const PresentationRectCells = struct {
    row: i32,
    col: i32,
    rows: i32,
    cols: i32,
};

pub const IdRange = struct {
    start: u32,
    end: u32,
};

pub const AttachMessage = struct {
    window_id: []const u8,
    rect_cells: PresentationRectCells,
    aspect: PresentationAspect,
    image_ids: IdRange,
    placement_ids: IdRange,
};

pub const ParseError = error{
    InvalidMessage,
    UnsupportedWindow,
};

pub fn writeFrameBatchJsonl(_: std.mem.Allocator, writer: anytype, batch: BatchView) !void {
    try writer.writeAll("{\"type\":\"frame_batch\",\"window_id\":");
    try writeJsonString(writer, batch.window_id);
    try writer.print(",\"seq\":{d},\"groups\":{{", .{batch.seq});
    try writeGroup(writer, "deletes", batch.deletes);
    try writer.writeAll(",");
    try writeGroup(writer, "uploads", batch.uploads);
    try writer.writeAll(",");
    try writeGroup(writer, "placements", batch.placements);
    try writer.writeAll(",");
    try writeGroup(writer, "after", batch.after);
    try writer.writeAll("}}\n");
}

fn writeGroup(writer: anytype, name: []const u8, chunks: []const []const u8) !void {
    try writeJsonString(writer, name);
    try writer.writeAll(":[");
    for (chunks, 0..) |chunk, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, chunk);
    }
    try writer.writeAll("]");
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        if (byte == '"') {
            try writer.writeAll("\\\"");
        } else if (byte == '\\') {
            try writer.writeAll("\\\\");
        } else if (byte == '\n') {
            try writer.writeAll("\\n");
        } else if (byte == '\r') {
            try writer.writeAll("\\r");
        } else if (byte == '\t') {
            try writer.writeAll("\\t");
        } else if (byte < 0x20) {
            try writer.print("\\u{x:0>4}", .{byte});
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeAll("\"");
}

pub fn parseAttachMessage(allocator: std.mem.Allocator, bytes: []const u8) !AttachMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;

    const type_value = root.get("type") orelse return error.InvalidMessage;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "attach")) return error.InvalidMessage;

    const window_value = root.get("window_id") orelse return error.InvalidMessage;
    if (window_value != .string) return error.InvalidMessage;
    if (!std.mem.eql(u8, window_value.string, "main")) return error.UnsupportedWindow;

    const rect = try parseRect(root.get("rect_cells") orelse return error.InvalidMessage);
    const aspect_value = root.get("aspect") orelse return error.InvalidMessage;
    if (aspect_value != .string) return error.InvalidMessage;
    const aspect = parseAspect(aspect_value.string) orelse return error.InvalidMessage;

    const id_ranges_value = root.get("id_ranges") orelse return error.InvalidMessage;
    if (id_ranges_value != .object) return error.InvalidMessage;
    const image_ids = try parseFirstIdRange(id_ranges_value.object.get("image") orelse return error.InvalidMessage);
    const placement_ids = try parseFirstIdRange(id_ranges_value.object.get("placement") orelse return error.InvalidMessage);

    return .{
        .window_id = "main",
        .rect_cells = rect,
        .aspect = aspect,
        .image_ids = image_ids,
        .placement_ids = placement_ids,
    };
}

fn parseAspect(value: []const u8) ?PresentationAspect {
    if (std.mem.eql(u8, value, "stretch")) return .stretch;
    if (std.mem.eql(u8, value, "contain")) return .contain;
    if (std.mem.eql(u8, value, "cover")) return .cover;
    return null;
}

fn parseRect(value: std.json.Value) !PresentationRectCells {
    if (value != .object) return error.InvalidMessage;
    return .{
        .row = try jsonI32(value.object.get("row") orelse return error.InvalidMessage),
        .col = try jsonI32(value.object.get("col") orelse return error.InvalidMessage),
        .rows = try jsonI32(value.object.get("rows") orelse return error.InvalidMessage),
        .cols = try jsonI32(value.object.get("cols") orelse return error.InvalidMessage),
    };
}

fn parseFirstIdRange(value: std.json.Value) !IdRange {
    if (value != .array or value.array.items.len == 0) return error.InvalidMessage;
    const first = value.array.items[0];
    if (first != .array or first.array.items.len != 2) return error.InvalidMessage;
    return .{
        .start = try jsonU32(first.array.items[0]),
        .end = try jsonU32(first.array.items[1]),
    };
}

fn jsonI32(value: std.json.Value) !i32 {
    if (value != .integer) return error.InvalidMessage;
    if (value.integer < std.math.minInt(i32) or value.integer > std.math.maxInt(i32)) return error.InvalidMessage;
    return @intCast(value.integer);
}

fn jsonU32(value: std.json.Value) !u32 {
    if (value != .integer) return error.InvalidMessage;
    if (value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.InvalidMessage;
    return @intCast(value.integer);
}

test "frame batch JSON escapes terminal control bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeFrameBatchJsonl(std.testing.allocator, out.writer(std.testing.allocator), .{
        .window_id = "main",
        .seq = 7,
        .deletes = &.{},
        .uploads = &.{"\x1b_Gq=2,a=t;\x1b\\"},
        .placements = &.{"\x1b[4;1H\x1b_Gq=2,a=p;\x1b\\"},
        .after = &.{},
    });

    try std.testing.expect(std.mem.endsWith(u8, out.items, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"frame_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\\u001b_G") != null);
}

test "attach message parses window geometry and id ranges" {
    const msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"contain","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;

    const attach = try parseAttachMessage(std.testing.allocator, msg);

    try std.testing.expectEqualStrings("main", attach.window_id);
    try std.testing.expectEqual(PresentationAspect.contain, attach.aspect);
    try std.testing.expectEqual(PresentationRectCells{ .row = 4, .col = 1, .rows = 24, .cols = 80 }, attach.rect_cells);
    try std.testing.expectEqual(IdRange{ .start = 100000, .end = 199999 }, attach.image_ids);
    try std.testing.expectEqual(IdRange{ .start = 200000, .end = 299999 }, attach.placement_ids);
}
