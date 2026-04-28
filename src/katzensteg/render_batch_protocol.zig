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
    fit,
    stretch,
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

pub const UploadProfile = enum {
    direct_apc,
    file_whole,
    file_offset_ring,
};

pub const UploadPolicy = struct {
    profile: UploadProfile,
    path: ?[]const u8 = null,
    high_water: u64 = 10 * 1024 * 1024,
};

pub const AttachMessage = struct {
    window_id: []const u8,
    rect_cells: PresentationRectCells,
    aspect: PresentationAspect,
    image_ids: IdRange,
    placement_ids: IdRange,
    upload: UploadPolicy,
};

pub const ViewportMessage = struct {
    window_id: []const u8,
    rect_cells: PresentationRectCells,
    aspect: PresentationAspect,
};

pub const DetachMessage = struct {
    window_id: []const u8,
};

pub const ControlMessage = union(enum) {
    attach: AttachMessage,
    viewport: ViewportMessage,
    detach: DetachMessage,
    shutdown,
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

pub fn writeDetachedJsonl(writer: anytype, window_id: []const u8) !void {
    try writer.writeAll("{\"type\":\"detached\",\"window_id\":");
    try writeJsonString(writer, window_id);
    try writer.writeAll("}\n");
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
    const control = try parseControlMessage(allocator, bytes);
    switch (control) {
        .attach => |attach| return attach,
        .viewport => return error.InvalidMessage,
        .detach => return error.InvalidMessage,
        .shutdown => return error.InvalidMessage,
    }
}

pub fn parseControlMessage(allocator: std.mem.Allocator, bytes: []const u8) !ControlMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const root = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;

    const type_value = root.get("type") orelse return error.InvalidMessage;
    if (type_value != .string) return error.InvalidMessage;

    if (std.mem.eql(u8, type_value.string, "shutdown")) {
        return .shutdown;
    }

    const window_value = root.get("window_id") orelse return error.InvalidMessage;
    if (window_value != .string) return error.InvalidMessage;
    if (!std.mem.eql(u8, window_value.string, "main")) return error.UnsupportedWindow;

    if (std.mem.eql(u8, type_value.string, "detach")) {
        return .{ .detach = .{ .window_id = "main" } };
    }

    const rect = try parseRect(root.get("rect_cells") orelse return error.InvalidMessage);
    const aspect_value = root.get("aspect") orelse return error.InvalidMessage;
    if (aspect_value != .string) return error.InvalidMessage;
    const aspect = parseAspect(aspect_value.string) orelse return error.InvalidMessage;

    if (std.mem.eql(u8, type_value.string, "viewport")) {
        return .{ .viewport = .{
            .window_id = "main",
            .rect_cells = rect,
            .aspect = aspect,
        } };
    }

    if (!std.mem.eql(u8, type_value.string, "attach")) return error.InvalidMessage;

    const id_ranges_value = root.get("id_ranges") orelse return error.InvalidMessage;
    if (id_ranges_value != .object) return error.InvalidMessage;
    const image_ids = try parseFirstIdRange(id_ranges_value.object.get("image") orelse return error.InvalidMessage);
    const placement_ids = try parseFirstIdRange(id_ranges_value.object.get("placement") orelse return error.InvalidMessage);
    const upload = try parseUploadPolicy(allocator, root.get("upload"));

    return .{ .attach = .{
        .window_id = "main",
        .rect_cells = rect,
        .aspect = aspect,
        .image_ids = image_ids,
        .placement_ids = placement_ids,
        .upload = upload,
    } };
}

pub fn deinitAttachMessage(allocator: std.mem.Allocator, attach: *AttachMessage) void {
    if (attach.upload.path) |path| allocator.free(path);
    attach.upload.path = null;
}

pub fn deinitControlMessage(allocator: std.mem.Allocator, control: *ControlMessage) void {
    switch (control.*) {
        .attach => |*attach| deinitAttachMessage(allocator, attach),
        .viewport, .detach => {},
        .shutdown => {},
    }
}

pub fn parseAspect(value: []const u8) ?PresentationAspect {
    if (std.mem.eql(u8, value, "fit")) return .fit;
    // Compatibility with the first draft of the embed protocol.
    if (std.mem.eql(u8, value, "contain")) return .fit;
    if (std.mem.eql(u8, value, "stretch")) return .stretch;
    if (std.mem.eql(u8, value, "cover")) return .cover;
    return null;
}

fn parseUploadProfile(value: []const u8) ?UploadProfile {
    if (std.mem.eql(u8, value, "direct_apc")) return .direct_apc;
    if (std.mem.eql(u8, value, "file_whole")) return .file_whole;
    if (std.mem.eql(u8, value, "file_offset_ring")) return .file_offset_ring;
    return null;
}

fn parseUploadPolicy(allocator: std.mem.Allocator, value: ?std.json.Value) !UploadPolicy {
    const upload_value = value orelse return .{ .profile = .direct_apc };
    if (upload_value != .object) return error.InvalidMessage;
    const profile_value = upload_value.object.get("profile") orelse return error.InvalidMessage;
    if (profile_value != .string) return error.InvalidMessage;
    const profile = parseUploadProfile(profile_value.string) orelse return error.InvalidMessage;
    const path: ?[]const u8 = if (upload_value.object.get("path")) |path_value| blk: {
        if (path_value != .string) return error.InvalidMessage;
        break :blk try allocator.dupe(u8, path_value.string);
    } else null;
    errdefer if (path) |owned_path| allocator.free(owned_path);
    if (profile != .direct_apc and path == null) return error.InvalidMessage;
    const high_water: u64 = if (upload_value.object.get("high_water")) |high_water_value|
        try jsonU64(high_water_value)
    else
        10 * 1024 * 1024;
    return .{ .profile = profile, .path = path, .high_water = high_water };
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

fn jsonU64(value: std.json.Value) !u64 {
    if (value != .integer) return error.InvalidMessage;
    if (value.integer < 0 or value.integer > std.math.maxInt(u64)) return error.InvalidMessage;
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

test "detached JSON names the completed window" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeDetachedJsonl(out.writer(std.testing.allocator), "main");

    try std.testing.expectEqualStrings("{\"type\":\"detached\",\"window_id\":\"main\"}\n", out.items);
}

test "attach message parses window geometry and id ranges" {
    const msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;

    var attach = try parseAttachMessage(std.testing.allocator, msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);

    try std.testing.expectEqualStrings("main", attach.window_id);
    try std.testing.expectEqual(PresentationAspect.fit, attach.aspect);
    try std.testing.expectEqual(PresentationRectCells{ .row = 4, .col = 1, .rows = 24, .cols = 80 }, attach.rect_cells);
    try std.testing.expectEqual(IdRange{ .start = 100000, .end = 199999 }, attach.image_ids);
    try std.testing.expectEqual(IdRange{ .start = 200000, .end = 299999 }, attach.placement_ids);
    try std.testing.expectEqual(UploadProfile.direct_apc, attach.upload.profile);
    try std.testing.expectEqual(@as(?[]const u8, null), attach.upload.path);
}

test "attach message parses host-selected file upload policy" {
    const msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]},"upload":{"profile":"file_whole","path":"/tmp/katzensteg-embed-upload","high_water":4096}}
    ;

    var attach = try parseAttachMessage(std.testing.allocator, msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);

    try std.testing.expectEqual(UploadProfile.file_whole, attach.upload.profile);
    try std.testing.expectEqualStrings("/tmp/katzensteg-embed-upload", attach.upload.path.?);
    try std.testing.expectEqual(@as(u64, 4096), attach.upload.high_water);
}

test "attach message accepts contain as fit compatibility alias" {
    const msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"contain","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;

    var attach = try parseAttachMessage(std.testing.allocator, msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);

    try std.testing.expectEqual(PresentationAspect.fit, attach.aspect);
}

test "control message parses viewport geometry without id ranges" {
    const msg =
        \\{"type":"viewport","window_id":"main","rect_cells":{"row":6,"col":10,"rows":20,"cols":64},"aspect":"cover"}
    ;

    var control = try parseControlMessage(std.testing.allocator, msg);
    defer deinitControlMessage(std.testing.allocator, &control);

    const viewport = control.viewport;
    try std.testing.expectEqualStrings("main", viewport.window_id);
    try std.testing.expectEqual(PresentationAspect.cover, viewport.aspect);
    try std.testing.expectEqual(PresentationRectCells{ .row = 6, .col = 10, .rows = 20, .cols = 64 }, viewport.rect_cells);
}

test "control message parses detach" {
    const msg =
        \\{"type":"detach","window_id":"main"}
    ;

    var control = try parseControlMessage(std.testing.allocator, msg);
    defer deinitControlMessage(std.testing.allocator, &control);

    try std.testing.expectEqualStrings("main", control.detach.window_id);
}

test "control message parses global shutdown without window id" {
    const msg =
        \\{"type":"shutdown"}
    ;

    var control = try parseControlMessage(std.testing.allocator, msg);
    defer deinitControlMessage(std.testing.allocator, &control);

    try std.testing.expectEqual(ControlMessage.shutdown, control);
}
