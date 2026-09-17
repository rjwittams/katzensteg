const render_batch_protocol = @import("../render_batch_protocol.zig");
const terminal_keys = @import("../terminal_keys.zig");
pub const TerminalSize = struct {
    rows: i32,
    cols: i32,
    pixel_width: i32 = 0,
    pixel_height: i32 = 0,
    /// Units of the terminal's SGR mouse reports, as confirmed by DECRQM.
    mouse_units: terminal_keys.MouseUnits = .cell,
    /// Coordinate of the first pixel in pixel reports (terminal quirk).
    pixel_origin: i32 = 1,

    pub fn pixelGridKnown(self: TerminalSize) bool {
        return self.cols > 0 and self.rows > 0 and self.pixel_width > 0 and self.pixel_height > 0;
    }

    /// Pixel offset of the left edge of a 1-based column, scaled by the whole
    /// grid so truncation cannot accumulate across columns.
    pub fn columnPixelOffset(self: TerminalSize, col: i32) i32 {
        if (self.cols <= 0) return 0;
        return @intCast(@divTrunc(@as(i64, col - 1) * self.pixel_width, self.cols));
    }

    pub fn rowPixelOffset(self: TerminalSize, row: i32) i32 {
        if (self.rows <= 0) return 0;
        return @intCast(@divTrunc(@as(i64, row - 1) * self.pixel_height, self.rows));
    }
};

pub const AttachOptions = struct {
    placeholder: ?render_batch_protocol.PlaceholderPresentation = null,
    window_id: []const u8 = "main",
    rect_cells: render_batch_protocol.PresentationRectCells,
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?TerminalSize = null,
    occlusion_rects: []const render_batch_protocol.PresentationRectCells = &.{},
    clip_cells: ?render_batch_protocol.PresentationRectCells = null,
    image_ids: render_batch_protocol.IdRange = .{ .start = 100000, .end = 199999 },
    placement_ids: render_batch_protocol.IdRange = .{ .start = 200000, .end = 299999 },
    upload: render_batch_protocol.UploadPolicy,
};

pub fn writeInitialControl(writer: anytype, options: AttachOptions) !void {
    try writer.writeAll("{\"type\":\"hello\",\"protocol\":\"katzensteg.embed_jsonl\",\"version\":1}\n");
    try writer.writeAll("{\"type\":\"attach\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    if (options.placeholder) |target| {
        try writePlaceholderField(writer, target);
    } else {
        try writer.writeAll(",\"rect_cells\":{");
        try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
        try writer.writeAll("},\"aspect\":");
        try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
        if (options.z_base != 0) try writer.print(",\"z_base\":{d}", .{options.z_base});
        try writeTerminalGeometryFields(writer, options.terminal);
        try writeOcclusionRectsField(writer, options.occlusion_rects);
        try writeClipCellsField(writer, options.clip_cells);
        try writer.writeAll(",\"id_ranges\":{\"image\":[[");
        try writer.print("{d},{d}", .{ options.image_ids.start, options.image_ids.end });
        try writer.writeAll("]],\"placement\":[[");
        try writer.print("{d},{d}", .{ options.placement_ids.start, options.placement_ids.end });
        try writer.writeAll("]]}");
    }
    try writer.writeAll(",\"upload\":{\"profile\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.upload.profile));
    if (options.upload.path) |path| {
        try writer.writeAll(",\"path\":");
        try render_batch_protocol.writeJsonString(writer, path);
    }
    try writer.print(",\"high_water\":{d}", .{options.upload.high_water});
    try writer.writeAll("}}\n");
}

pub const ViewportOptions = struct {
    refresh_placements: bool = false,
    placeholder: ?render_batch_protocol.PlaceholderPresentation = null,
    window_id: []const u8 = "main",
    rect_cells: render_batch_protocol.PresentationRectCells,
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?TerminalSize = null,
    occlusion_rects: []const render_batch_protocol.PresentationRectCells = &.{},
    clip_cells: ?render_batch_protocol.PresentationRectCells = null,
};

pub fn writeViewportControl(writer: anytype, options: ViewportOptions) !void {
    try writer.writeAll("{\"type\":\"viewport\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    if (options.placeholder) |target| {
        try writePlaceholderField(writer, target);
    } else {
        try writer.writeAll(",\"rect_cells\":{");
        try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
        try writer.writeAll("},\"aspect\":");
        try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
        if (options.z_base != 0) try writer.print(",\"z_base\":{d}", .{options.z_base});
        try writeTerminalGeometryFields(writer, options.terminal);
        try writeOcclusionRectsField(writer, options.occlusion_rects);
        try writeClipCellsField(writer, options.clip_cells);
    }
    if (options.refresh_placements) try writer.writeAll(",\"refresh_placements\":true");
    try writer.writeAll("}\n");
}

fn writePlaceholderField(writer: anytype, target: render_batch_protocol.PlaceholderPresentation) !void {
    try target.validate();
    try writer.print(",\"placeholder\":{{\"image_id\":{d},\"cols\":{d},\"rows\":{d}", .{ target.image_id, target.cols, target.rows });
    if (target.target_px) |pixels| try writer.print(",\"target_px\":{{\"w\":{d},\"h\":{d}}}", .{ pixels.w, pixels.h });
    try writer.writeAll("}");
}

fn writeTerminalGeometryFields(writer: anytype, terminal: ?TerminalSize) !void {
    const value = terminal orelse return;
    if (value.rows <= 0 or value.cols <= 0) return;
    try writer.print(",\"terminal_cells\":{{\"rows\":{d},\"cols\":{d}}}", .{ value.rows, value.cols });
    if (value.pixel_width > 0 and value.pixel_height > 0) {
        try writer.print(",\"terminal_px\":{{\"w\":{d},\"h\":{d}}}", .{ value.pixel_width, value.pixel_height });
    }
}

fn writeOcclusionRectsField(writer: anytype, occlusion_rects: []const render_batch_protocol.PresentationRectCells) !void {
    if (occlusion_rects.len == 0) return;
    try writer.writeAll(",\"occlusion_rects\":[");
    for (occlusion_rects, 0..) |rect, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}}}", .{ rect.row, rect.col, rect.rows, rect.cols });
    }
    try writer.writeAll("]");
}

fn writeClipCellsField(writer: anytype, clip: ?render_batch_protocol.PresentationRectCells) !void {
    const rect = clip orelse return;
    try writer.print(",\"clip_cells\":{{\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}}}", .{ rect.row, rect.col, rect.rows, rect.cols });
}

pub fn writeInputControl(writer: anytype, bytes: []const u8) !void {
    try writer.writeAll("{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":");
    try render_batch_protocol.writeJsonString(writer, bytes);
    try writer.writeAll("}\n");
}

pub fn writeShutdownControl(writer: anytype) !void {
    try writer.writeAll("{\"type\":\"shutdown\"}\n");
}
