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

pub const SourcePixels = struct {
    w: i32,
    h: i32,
};

pub const TerminalCells = struct {
    rows: i32,
    cols: i32,
};

pub const TerminalPixels = struct {
    w: i32,
    h: i32,
};

pub const TerminalGeometry = struct {
    cells: TerminalCells,
    pixels: ?TerminalPixels = null,
};

pub const PresentationStatusView = struct {
    window_id: []const u8,
    ready_to_show: bool = false,
    source_px: ?SourcePixels = null,
    effective_rect_cells: ?PresentationRectCells = null,
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
    z_base: i32 = 0,
    terminal: ?TerminalGeometry = null,
    occlusion_rects: []PresentationRectCells = &.{},
    // Visible portion of the surface in terminal cell coords. When set, the
    // producer composes at full rect_cells size but only emits placements for
    // the intersection of rect_cells and clip_cells. Null = no clipping (the
    // whole rect_cells is the placement target).
    clip_cells: ?PresentationRectCells = null,
    image_ids: IdRange,
    placement_ids: IdRange,
    upload: UploadPolicy,
};

pub const ViewportMessage = struct {
    window_id: []const u8,
    rect_cells: PresentationRectCells,
    aspect: PresentationAspect,
    z_base: i32 = 0,
    terminal: ?TerminalGeometry = null,
    occlusion_rects: []PresentationRectCells = &.{},
    clip_cells: ?PresentationRectCells = null,
};

pub const DetachMessage = struct {
    window_id: []const u8,
};

pub const PointerEventKind = enum {
    pointerdown,
    pointermove,
    pointerup,
    wheel,
};

pub const PointerType = enum {
    mouse,
    pen,
    touch,
};

pub const DeltaMode = enum {
    pixel,
    line,
    page,
};

pub const PointerModifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
};

// Structured pointer event payload, mirroring DOM PointerEvent / WheelEvent
// shape but using terminal cells (1-indexed, matching rect_cells) as the
// canonical coordinate. Hosts that have pixel-precision data (SGR mode 1016
// today, pi-tui-with-pixel-mouse later) populate pixel_x/pixel_y so producers
// can prefer pixels when they need sub-cell precision.
//
// button is -1 for events with no specific button (pointermove, wheel);
// otherwise 0=left, 1=middle, 2=right, 3=back, 4=forward. The `buttons`
// bitmask uses the same numbering (bit N = button N currently held).
pub const PointerEventPayload = struct {
    kind: PointerEventKind,
    row: i32,
    col: i32,
    pixel_x: ?i32 = null,
    pixel_y: ?i32 = null,
    button: i32,
    buttons: u32,
    delta_x: f64 = 0,
    delta_y: f64 = 0,
    delta_mode: DeltaMode = .line,
    modifiers: PointerModifiers = .{},
    pointer_type: PointerType = .mouse,
};

pub const InputPayload = union(enum) {
    terminal_bytes: []const u8,
    pointer: PointerEventPayload,
};

pub const InputMessage = struct {
    window_id: []const u8,
    payload: InputPayload,
};

pub const ControlMessage = union(enum) {
    attach: AttachMessage,
    viewport: ViewportMessage,
    detach: DetachMessage,
    input: InputMessage,
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

pub fn writePresentationStatusJsonl(writer: anytype, status: PresentationStatusView) !void {
    try writer.writeAll("{\"type\":\"presentation_status\",\"window_id\":");
    try writeJsonString(writer, status.window_id);
    try writer.writeAll(",\"ready_to_show\":");
    try writer.writeAll(if (status.ready_to_show) "true" else "false");
    if (status.source_px) |source| {
        try writer.print(",\"source_px\":{{\"w\":{d},\"h\":{d}}}", .{ source.w, source.h });
    }
    if (status.effective_rect_cells) |rect| {
        try writer.print(",\"effective_rect_cells\":{{\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}}}", .{ rect.row, rect.col, rect.rows, rect.cols });
    }
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
        .input => return error.InvalidMessage,
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

    if (std.mem.eql(u8, type_value.string, "input")) {
        const event_value = root.get("event") orelse return error.InvalidMessage;
        if (event_value != .string) return error.InvalidMessage;
        if (std.mem.eql(u8, event_value.string, "terminal_bytes")) {
            const bytes_value = root.get("bytes") orelse return error.InvalidMessage;
            if (bytes_value != .string) return error.InvalidMessage;
            return .{ .input = .{
                .window_id = "main",
                .payload = .{ .terminal_bytes = try allocator.dupe(u8, bytes_value.string) },
            } };
        }
        if (std.mem.eql(u8, event_value.string, "pointer")) {
            return .{ .input = .{
                .window_id = "main",
                .payload = .{ .pointer = try parsePointerEvent(root) },
            } };
        }
        return error.InvalidMessage;
    }

    const rect = try parseRect(root.get("rect_cells") orelse return error.InvalidMessage);
    const aspect_value = root.get("aspect") orelse return error.InvalidMessage;
    if (aspect_value != .string) return error.InvalidMessage;
    const aspect = parseAspect(aspect_value.string) orelse return error.InvalidMessage;
    const z_base: i32 = if (root.get("z_base")) |z_value| try jsonI32(z_value) else 0;
    const terminal = try parseTerminalGeometry(root);
    const clip: ?PresentationRectCells = if (root.get("clip_cells")) |clip_value| try parseRect(clip_value) else null;

    if (std.mem.eql(u8, type_value.string, "viewport")) {
        return .{ .viewport = .{
            .window_id = "main",
            .rect_cells = rect,
            .aspect = aspect,
            .z_base = z_base,
            .terminal = terminal,
            .occlusion_rects = try parseOcclusionRects(allocator, root.get("occlusion_rects")),
            .clip_cells = clip,
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
        .z_base = z_base,
        .terminal = terminal,
        .occlusion_rects = try parseOcclusionRects(allocator, root.get("occlusion_rects")),
        .clip_cells = clip,
        .image_ids = image_ids,
        .placement_ids = placement_ids,
        .upload = upload,
    } };
}

pub fn deinitAttachMessage(allocator: std.mem.Allocator, attach: *AttachMessage) void {
    if (attach.upload.path) |path| allocator.free(path);
    attach.upload.path = null;
    if (attach.occlusion_rects.len > 0) allocator.free(attach.occlusion_rects);
    attach.occlusion_rects = &.{};
}

pub fn deinitControlMessage(allocator: std.mem.Allocator, control: *ControlMessage) void {
    switch (control.*) {
        .attach => |*attach| deinitAttachMessage(allocator, attach),
        .viewport => |*viewport| {
            if (viewport.occlusion_rects.len > 0) allocator.free(viewport.occlusion_rects);
            viewport.occlusion_rects = &.{};
        },
        .input => |*input| switch (input.payload) {
            .terminal_bytes => |bytes| {
                allocator.free(bytes);
                input.payload = .{ .terminal_bytes = "" };
            },
            .pointer => {},
        },
        .detach => {},
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

fn parseTerminalGeometry(root: std.json.ObjectMap) !?TerminalGeometry {
    const cells_value = root.get("terminal_cells") orelse return null;
    if (cells_value != .object) return error.InvalidMessage;
    const cells = TerminalCells{
        .rows = try jsonI32(cells_value.object.get("rows") orelse return error.InvalidMessage),
        .cols = try jsonI32(cells_value.object.get("cols") orelse return error.InvalidMessage),
    };
    const pixels = if (root.get("terminal_px")) |pixels_value| blk: {
        if (pixels_value != .object) return error.InvalidMessage;
        break :blk TerminalPixels{
            .w = try jsonI32(pixels_value.object.get("w") orelse return error.InvalidMessage),
            .h = try jsonI32(pixels_value.object.get("h") orelse return error.InvalidMessage),
        };
    } else null;
    return .{ .cells = cells, .pixels = pixels };
}

fn parseOcclusionRects(allocator: std.mem.Allocator, value: ?std.json.Value) ![]PresentationRectCells {
    const occlusions = value orelse return &.{};
    if (occlusions != .array) return error.InvalidMessage;
    if (occlusions.array.items.len == 0) return &.{};
    var out = try allocator.alloc(PresentationRectCells, occlusions.array.items.len);
    errdefer allocator.free(out);
    for (occlusions.array.items, 0..) |item, index| out[index] = try parseRect(item);
    return out;
}

fn parsePointerEvent(root: std.json.ObjectMap) !PointerEventPayload {
    const kind_value = root.get("kind") orelse return error.InvalidMessage;
    if (kind_value != .string) return error.InvalidMessage;
    const kind = parsePointerKind(kind_value.string) orelse return error.InvalidMessage;

    var payload = PointerEventPayload{
        .kind = kind,
        .row = try jsonI32(root.get("row") orelse return error.InvalidMessage),
        .col = try jsonI32(root.get("col") orelse return error.InvalidMessage),
        .button = try jsonI32(root.get("button") orelse return error.InvalidMessage),
        .buttons = try jsonU32(root.get("buttons") orelse return error.InvalidMessage),
    };
    if (root.get("pixel_x")) |v| payload.pixel_x = try jsonI32(v);
    if (root.get("pixel_y")) |v| payload.pixel_y = try jsonI32(v);
    if (root.get("delta_x")) |v| payload.delta_x = try jsonF64(v);
    if (root.get("delta_y")) |v| payload.delta_y = try jsonF64(v);
    if (root.get("delta_mode")) |v| {
        if (v != .string) return error.InvalidMessage;
        payload.delta_mode = parseDeltaMode(v.string) orelse return error.InvalidMessage;
    }
    if (root.get("pointer_type")) |v| {
        if (v != .string) return error.InvalidMessage;
        payload.pointer_type = parsePointerType(v.string) orelse return error.InvalidMessage;
    }
    if (root.get("modifiers")) |v| {
        if (v != .object) return error.InvalidMessage;
        payload.modifiers = .{
            .shift = try jsonBool(v.object.get("shift") orelse .{ .bool = false }),
            .ctrl = try jsonBool(v.object.get("ctrl") orelse .{ .bool = false }),
            .alt = try jsonBool(v.object.get("alt") orelse .{ .bool = false }),
            .meta = try jsonBool(v.object.get("meta") orelse .{ .bool = false }),
        };
    }
    return payload;
}

fn parsePointerKind(value: []const u8) ?PointerEventKind {
    if (std.mem.eql(u8, value, "pointerdown")) return .pointerdown;
    if (std.mem.eql(u8, value, "pointermove")) return .pointermove;
    if (std.mem.eql(u8, value, "pointerup")) return .pointerup;
    if (std.mem.eql(u8, value, "wheel")) return .wheel;
    return null;
}

fn parseDeltaMode(value: []const u8) ?DeltaMode {
    if (std.mem.eql(u8, value, "pixel")) return .pixel;
    if (std.mem.eql(u8, value, "line")) return .line;
    if (std.mem.eql(u8, value, "page")) return .page;
    return null;
}

fn parsePointerType(value: []const u8) ?PointerType {
    if (std.mem.eql(u8, value, "mouse")) return .mouse;
    if (std.mem.eql(u8, value, "pen")) return .pen;
    if (std.mem.eql(u8, value, "touch")) return .touch;
    return null;
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

fn jsonF64(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => error.InvalidMessage,
    };
}

fn jsonBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.InvalidMessage,
    };
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

test "presentation status JSON carries producer readiness and effective rect" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writePresentationStatusJsonl(out.writer(std.testing.allocator), .{
        .window_id = "main",
        .ready_to_show = true,
        .source_px = .{ .w = 320, .h = 240 },
        .effective_rect_cells = .{ .row = 4, .col = 2, .rows = 18, .cols = 64 },
    });

    try std.testing.expectEqualStrings(
        "{\"type\":\"presentation_status\",\"window_id\":\"main\",\"ready_to_show\":true,\"source_px\":{\"w\":320,\"h\":240},\"effective_rect_cells\":{\"row\":4,\"col\":2,\"rows\":18,\"cols\":64}}\n",
        out.items,
    );
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

test "attach and viewport messages parse terminal geometry" {
    const attach_msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","terminal_cells":{"rows":50,"cols":160},"terminal_px":{"w":1280,"h":1000},"id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;
    var attach = try parseAttachMessage(std.testing.allocator, attach_msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);
    try std.testing.expectEqual(TerminalGeometry{
        .cells = .{ .rows = 50, .cols = 160 },
        .pixels = .{ .w = 1280, .h = 1000 },
    }, attach.terminal.?);

    const viewport_msg =
        \\{"type":"viewport","window_id":"main","rect_cells":{"row":6,"col":10,"rows":20,"cols":64},"aspect":"fit","terminal_cells":{"rows":50,"cols":160},"terminal_px":{"w":1280,"h":1000}}
    ;
    var control = try parseControlMessage(std.testing.allocator, viewport_msg);
    defer deinitControlMessage(std.testing.allocator, &control);
    try std.testing.expectEqual(TerminalGeometry{
        .cells = .{ .rows = 50, .cols = 160 },
        .pixels = .{ .w = 1280, .h = 1000 },
    }, control.viewport.terminal.?);
}

test "attach and viewport messages parse optional clip rectangle" {
    const attach_msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":-2,"col":1,"rows":10,"cols":20},"aspect":"fit","clip_cells":{"row":1,"col":1,"rows":8,"cols":20},"id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;
    var attach = try parseAttachMessage(std.testing.allocator, attach_msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);
    try std.testing.expectEqual(@as(?PresentationRectCells, PresentationRectCells{ .row = 1, .col = 1, .rows = 8, .cols = 20 }), attach.clip_cells);

    const viewport_msg =
        \\{"type":"viewport","window_id":"main","rect_cells":{"row":-1,"col":2,"rows":10,"cols":20},"aspect":"fit","clip_cells":{"row":1,"col":2,"rows":9,"cols":20}}
    ;
    var control = try parseControlMessage(std.testing.allocator, viewport_msg);
    defer deinitControlMessage(std.testing.allocator, &control);
    try std.testing.expectEqual(@as(?PresentationRectCells, PresentationRectCells{ .row = 1, .col = 2, .rows = 9, .cols = 20 }), control.viewport.clip_cells);

    const attach_no_clip =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;
    var attach2 = try parseAttachMessage(std.testing.allocator, attach_no_clip);
    defer deinitAttachMessage(std.testing.allocator, &attach2);
    try std.testing.expectEqual(@as(?PresentationRectCells, null), attach2.clip_cells);
}

test "attach and viewport messages parse occlusion rectangles" {
    const attach_msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","occlusion_rects":[{"row":1,"col":1,"rows":3,"cols":20},{"row":8,"col":30,"rows":5,"cols":12}],"id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;
    var attach = try parseAttachMessage(std.testing.allocator, attach_msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);
    try std.testing.expectEqual(@as(usize, 2), attach.occlusion_rects.len);
    try std.testing.expectEqual(PresentationRectCells{ .row = 1, .col = 1, .rows = 3, .cols = 20 }, attach.occlusion_rects[0]);
    try std.testing.expectEqual(PresentationRectCells{ .row = 8, .col = 30, .rows = 5, .cols = 12 }, attach.occlusion_rects[1]);

    const viewport_msg =
        \\{"type":"viewport","window_id":"main","rect_cells":{"row":6,"col":10,"rows":20,"cols":64},"aspect":"fit","occlusion_rects":[{"row":4,"col":5,"rows":6,"cols":7}]}
    ;
    var control = try parseControlMessage(std.testing.allocator, viewport_msg);
    defer deinitControlMessage(std.testing.allocator, &control);
    try std.testing.expectEqual(@as(usize, 1), control.viewport.occlusion_rects.len);
    try std.testing.expectEqual(PresentationRectCells{ .row = 4, .col = 5, .rows = 6, .cols = 7 }, control.viewport.occlusion_rects[0]);
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

test "attach and viewport messages parse host z base" {
    const attach_msg =
        \\{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","z_base":2000,"id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
    ;
    var attach = try parseAttachMessage(std.testing.allocator, attach_msg);
    defer deinitAttachMessage(std.testing.allocator, &attach);
    try std.testing.expectEqual(@as(i32, 2000), attach.z_base);

    const viewport_msg =
        \\{"type":"viewport","window_id":"main","rect_cells":{"row":6,"col":10,"rows":20,"cols":64},"aspect":"cover","z_base":3000}
    ;
    var control = try parseControlMessage(std.testing.allocator, viewport_msg);
    defer deinitControlMessage(std.testing.allocator, &control);
    try std.testing.expectEqual(@as(i32, 3000), control.viewport.z_base);
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

test "control message parses terminal input bytes" {
    var control = try parseControlMessage(std.testing.allocator, "{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":\"\\u001b[<35;11;6M\"}");
    defer deinitControlMessage(std.testing.allocator, &control);

    const input = control.input;
    try std.testing.expectEqualStrings("main", input.window_id);
    try std.testing.expectEqualStrings("\x1b[<35;11;6M", input.payload.terminal_bytes);
}

test "control message parses structured pointerdown" {
    var control = try parseControlMessage(
        std.testing.allocator,
        \\{"type":"input","window_id":"main","event":"pointer","kind":"pointerdown","row":5,"col":10,"button":0,"buttons":1,"modifiers":{"shift":true,"ctrl":false,"alt":false,"meta":false}}
    );
    defer deinitControlMessage(std.testing.allocator, &control);

    const payload = control.input.payload.pointer;
    try std.testing.expectEqual(PointerEventKind.pointerdown, payload.kind);
    try std.testing.expectEqual(@as(i32, 5), payload.row);
    try std.testing.expectEqual(@as(i32, 10), payload.col);
    try std.testing.expectEqual(@as(i32, 0), payload.button);
    try std.testing.expectEqual(@as(u32, 1), payload.buttons);
    try std.testing.expect(payload.modifiers.shift);
    try std.testing.expect(!payload.modifiers.ctrl);
}

test "control message parses structured wheel with delta fields" {
    var control = try parseControlMessage(
        std.testing.allocator,
        \\{"type":"input","window_id":"main","event":"pointer","kind":"wheel","row":3,"col":4,"button":-1,"buttons":0,"delta_x":0,"delta_y":-1,"delta_mode":"line"}
    );
    defer deinitControlMessage(std.testing.allocator, &control);

    const payload = control.input.payload.pointer;
    try std.testing.expectEqual(PointerEventKind.wheel, payload.kind);
    try std.testing.expectEqual(@as(i32, -1), payload.button);
    try std.testing.expectEqual(@as(f64, -1), payload.delta_y);
    try std.testing.expectEqual(DeltaMode.line, payload.delta_mode);
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
