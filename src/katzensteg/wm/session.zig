//! Owner-thread cleat attachment and borrowed-update adapter. Presentation and
//! window policy remain with the desktop; the provider owns its reader thread.
const std = @import("std");
const cleat = @import("cleat");
const model = @import("session_mirror.zig");
const c = cleat.c;
const input = @import("../cleat_input_adapter.zig");
const images = @import("session_images.zig");

pub const Provider = cleat.Provider;
pub const pin = cleat.pin;
pub const OpenResult = cleat.OpenResult;
pub fn setWake(provider: Provider, callback: ?*const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) void {
    c.cleat_provider_set_wake_callback(provider.handle, callback, context);
}

pub const Content = struct {
    allocator: std.mem.Allocator,
    session: ?cleat.Session,
    mirror: model.Mirror,
    requested: model.Size,
    images: images.State = images.State.init(std.heap.page_allocator),
    closed: bool = false,
    established: bool = false,
    watching: bool = false,
    focused: bool = false,
    input: input.Adapter = .{},
    navigation: @import("session_navigation.zig").Navigation = .{},
    // Input can arrive as soon as chrome appears, before the async role grant.
    pending_input: std.ArrayList(PendingInput) = .empty,
    const PendingInput = union(enum) {
        bytes: struct { value: []u8, reports_events: bool },
        focus: bool,
    };
    pub fn attach(allocator: std.mem.Allocator, provider: Provider, id: []const u8, cols: u16, rows: u16) !*Content {
        const self = try allocator.create(Content);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = try provider.attach(id, cols, rows), .mirror = model.Mirror.init(allocator), .requested = .{ .cols = cols, .rows = rows }, .images = images.State.init(allocator) };
        return self;
    }
    pub fn create(allocator: std.mem.Allocator, provider: Provider, command: []const u8, cols: u16, rows: u16, foreground: ?[3]u8, background: ?[3]u8) !*Content {
        const self = try allocator.create(Content);
        errdefer allocator.destroy(self);
        var desc = std.mem.zeroes(c.cleat_session_desc);
        desc.cols = cols;
        desc.rows = rows;
        desc.role = c.CLEAT_ROLE_CONTROLLER;
        var colors = std.mem.zeroes(c.cleat_session_colors);
        colors.size = @sizeOf(c.cleat_session_colors);
        if (foreground) |rgb| {
            colors.has_foreground = true;
            colors.foreground = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
        if (background) |rgb| {
            colors.has_background = true;
            colors.background = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        }
        desc.colors = &colors;
        // A null command starts cleat's shell; a null id lets cleat allocate it.
        if (command.len > 0) {
            desc.command = command.ptr;
            desc.command_len = command.len;
        }
        self.* = .{ .allocator = allocator, .session = try provider.create(desc), .mirror = model.Mirror.init(allocator), .requested = .{ .cols = cols, .rows = rows }, .images = images.State.init(allocator) };
        return self;
    }
    pub fn detach(self: *Content) void {
        if (self.session) |session| session.destroy();
        self.session = null;
        self.closed = true;
    }
    pub fn deinit(self: *Content) void {
        self.detach();
        self.clearPendingInput();
        self.pending_input.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.mirror.deinit();
        self.images.deinit();
        self.allocator.destroy(self);
    }
    pub fn ended(self: *const Content) bool {
        return self.closed;
    }
    pub fn resize(self: *Content, cols: u16, rows: u16) !void {
        if (self.session) |session| {
            if (self.requested.cols == cols and self.requested.rows == rows) return;
            try session.resize(cols, rows);
            self.requested = .{ .cols = cols, .rows = rows };
        }
    }
    pub fn geometry(self: *Content, width: f32, height: f32) !void {
        if (width <= 0 or height <= 0) return;
        if (self.session) |session| {
            var value = std.mem.zeroes(c.cleat_terminal_geometry);
            value.cell_width_px = width;
            value.cell_height_px = height;
            value.content_width_px = width * @as(f32, @floatFromInt(self.requested.cols));
            value.content_height_px = height * @as(f32, @floatFromInt(self.requested.rows));
            try session.reportGeometry(value);
        }
    }
    pub fn focus(self: *Content, active: bool) !void {
        self.focused = active;
        if (self.session) |session| {
            const role = c.cleat_session_role(session.handle);
            try self.flushPendingInput(role);
            if (role == c.CLEAT_ROLE_UNKNOWN) {
                try self.pending_input.append(self.allocator, .{ .focus = active });
            } else try self.input.focus(active, self);
        }
    }
    pub fn sendBytes(self: *Content, bytes: []const u8, reports_events: bool) !void {
        if (self.session) |session| {
            const role = c.cleat_session_role(session.handle);
            try self.flushPendingInput(role);
            switch (role) {
                c.CLEAT_ROLE_UNKNOWN => {
                    const owned = try self.allocator.dupe(u8, bytes);
                    errdefer self.allocator.free(owned);
                    try self.pending_input.append(self.allocator, .{ .bytes = .{ .value = owned, .reports_events = reports_events } });
                },
                c.CLEAT_ROLE_CONTROLLER => try self.input.bytes(self.allocator, bytes, reports_events, self),
                else => {},
            }
        }
    }
    fn clearPendingInput(self: *Content) void {
        for (self.pending_input.items) |event| if (event == .bytes) self.allocator.free(event.bytes.value);
        self.pending_input.clearRetainingCapacity();
    }
    fn flushPendingInput(self: *Content, role: u32) !void {
        if (role == c.CLEAT_ROLE_UNKNOWN) return;
        defer self.clearPendingInput();
        if (role != c.CLEAT_ROLE_CONTROLLER) return;
        for (self.pending_input.items) |event| switch (event) {
            .bytes => |bytes| try self.input.bytes(self.allocator, bytes.value, bytes.reports_events, self),
            .focus => |active| try self.input.focus(active, self),
        };
    }
    /// Structured key routing also applies when draining pre-grant input.
    pub fn sendInput(self: *Content, event: c.cleat_input_event) !void {
        const session = self.session orelse return;
        try self.navigation.send(event, self.mirror.modes.alternate_screen, @intCast(self.requested.rows), session);
    }
    pub fn sendPointer(self: *Content, pointer: input.Pointer) !void {
        // Viewport navigation is local to this attachment, including watchers.
        // Watchers still cannot send tracked pointer events to the program.
        if (self.mirror.modes.mouse_tracking == .none) {
            if (self.session) |session| try self.navigation.pointer(pointer, session);
            return;
        }
        if (self.watching) return;
        if (self.session) |session| {
            const role = c.cleat_session_role(session.handle);
            if (role != c.CLEAT_ROLE_CONTROLLER) return;
            try self.flushPendingInput(role);
            try session.sendInput(input.mouseEvent(pointer));
        }
    }
    pub fn requestControl(self: *Content) !void {
        if (self.session) |session| {
            if (!c.cleat_session_take_control(session.handle)) return error.ControlFailed;
        }
    }
    /// Called only after a provider wake (and once after attachment). Copies
    /// every retained byte before releasing the provider's render borrow.
    pub fn pump(self: *Content) !bool {
        const session = self.session orelse return false;
        _ = c.cleat_session_poll(session.handle);
        const state = c.cleat_session_connection_state(session.handle);
        self.closed = state == c.CLEAT_SESSION_CLOSED;
        // A role grant also confirms acceptance when a short program exits
        // before the owner observes the intermediate streaming state.
        self.established = self.established or state == c.CLEAT_SESSION_STREAMING or c.cleat_session_role(session.handle) != c.CLEAT_ROLE_UNKNOWN;
        const role = c.cleat_session_role(session.handle);
        try self.flushPendingInput(role);
        const watching = if (role == c.CLEAT_ROLE_UNKNOWN) self.watching else role == c.CLEAT_ROLE_WATCHER;
        const role_changed = watching != self.watching;
        self.watching = watching;
        if (role_changed) try self.input.focus(!watching and self.focused, self);
        var update = session.pull() orelse return role_changed;
        defer session.release(&update);
        try self.applyImages(session, update);
        try self.apply(update);
        _ = c.cleat_session_mark_observed(session.handle, update.render_generation);
        return true;
    }
    fn applyImages(self: *Content, session: cleat.Session, update: c.cleat_render_update) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const resources = try a.alloc(images.Resource, update.image_resource_count);
        if (update.image_resource_count > 0) for (update.image_resources[0..update.image_resource_count], resources) |in, *out| {
            const old = self.images.find(in.image_id);
            const pixels = if (old != null and self.images.images.items[old.?].resource.generation == in.generation)
                self.images.images.items[old.?].resource.pixels
            else blk: {
                var copy = ImageCopy{ .allocator = a };
                if (!c.cleat_session_with_image_resource_data(session.handle, in.image_id, in.generation, copyImage, &copy)) return error.ImageDataUnavailable;
                break :blk copy.pixels;
            };
            if (in.compression != c.CLEAT_IMAGE_COMPRESSION_NONE) return error.CompressedImageData;
            out.* = .{ .id = in.image_id, .generation = in.generation, .width = in.width_px, .height = in.height_px, .format = switch (in.format) {
                c.CLEAT_IMAGE_FORMAT_RGB => 24,
                c.CLEAT_IMAGE_FORMAT_RGBA => 32,
                c.CLEAT_IMAGE_FORMAT_PNG => 100,
                else => return error.UnsupportedImageFormat,
            }, .pixels = pixels };
        };
        var placements: std.ArrayList(images.Placement) = .empty;
        if (update.image_placement_count > 0) for (update.image_placements[0..update.image_placement_count]) |in| {
            // Preserve #135's placeholder contract: never replay resolved strips.
            // Original virtual declarations will be supplied by cleat#317.
            if (in.flags & c.CLEAT_IMAGE_PLACEMENT_VIRTUAL != 0) continue;
            try placements.append(a, .{ .image = in.image_id, .col = in.viewport_col, .row = in.viewport_row, .cols = in.grid_cols, .rows = in.grid_rows, .z = in.z, .source_x = in.source_x, .source_y = in.source_y, .source_width = in.source_width, .source_height = in.source_height, .pixel_width = in.pixel_width, .pixel_height = in.pixel_height, .offset_x = in.x_offset_px, .offset_y = in.y_offset_px });
        };
        try self.images.replace(resources, placements.items);
        self.mirror.markAllDirty();
    }
    fn apply(self: *Content, update: c.cleat_render_update) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        try self.mirror.apply(.{ .size = .{ .cols = update.cols, .rows = update.rows } });
        if (update.op_count > 0) for (update.ops[0..update.op_count]) |op| {
            switch (op.kind) {
                c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE, c.CLEAT_RENDER_OP_ROW_REPLACE => {
                    if (op.kind == c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE) try self.mirror.apply(.{ .full_replace = &.{} });
                    var flat: usize = 0;
                    if (op.row_desc_count > 0) for (op.rows[0..op.row_desc_count]) |row| {
                        defer flat += row.cell_count;
                        const source = if (row.cells != null) row.cells else if (op.cells != null) op.cells + flat else continue;
                        try self.applyRow(arena.allocator(), row.row, source[0..row.cell_count]);
                    };
                },
                c.CLEAT_RENDER_OP_SCROLL_COPY => try self.mirror.apply(.{ .scroll_copy = .{ .src_row = op.src_row, .dst_row = op.dst_row, .row_count = op.row_count } }),
                else => {},
            }
        };
        try self.mirror.apply(.{ .cursor = .{
            .row = update.cursor.row,
            .col = update.cursor.col,
            .visible = update.cursor.visible,
            .shape = switch (update.cursor.style) {
                c.CLEAT_CURSOR_STYLE_BAR => .bar,
                c.CLEAT_CURSOR_STYLE_UNDERLINE => .underline,
                else => .block,
            },
            .blinking = update.cursor.blink,
        } });
        try self.mirror.apply(.{ .modes = .{
            .mouse_tracking = switch (update.terminal_modes.mouse_tracking_mode) {
                c.CLEAT_MOUSE_TRACKING_X10, c.CLEAT_MOUSE_TRACKING_NORMAL => .press,
                c.CLEAT_MOUSE_TRACKING_BUTTON => .button,
                c.CLEAT_MOUSE_TRACKING_ANY => .any,
                else => .none,
            },
            .mouse_encoding = switch (update.terminal_modes.mouse_report_format) {
                c.CLEAT_MOUSE_FORMAT_SGR => .sgr,
                c.CLEAT_MOUSE_FORMAT_SGR_PIXELS => .sgr_pixels,
                else => .legacy,
            },
            .alternate_screen = update.terminal_modes.active_alternate_screen,
        } });
        try self.mirror.apply(.{ .scrolled_back = update.viewport_kind == c.CLEAT_VIEWPORT_NORMAL_SCROLLBACK });
    }
    fn applyRow(self: *Content, a: std.mem.Allocator, row: usize, source: []const c.cleat_render_cell) !void {
        const cells = try a.alloc(model.Cell, source.len);
        for (source, cells) |in, *out| {
            var text = std.Io.Writer.Allocating.init(a);
            if (in.grapheme_count > 0) for (in.graphemes[0..in.grapheme_count]) |cp| {
                if (cp < 0x20 or cp > 0x10ffff) continue;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                try text.writer.writeAll(buf[0..len]);
            };
            out.* = .{
                .text = text.written(),
                .foreground = .{ .rgb = .{ in.style.fg.r, in.style.fg.g, in.style.fg.b }, .is_default = in.style.fg_color.tag == c.CLEAT_STYLE_COLOR_NONE },
                .background = .{ .rgb = .{ in.style.bg.r, in.style.bg.g, in.style.bg.b }, .is_default = in.style.bg_color.tag == c.CLEAT_STYLE_COLOR_NONE },
                .style_flags = in.style.flags,
                .width = switch (in.style.width) {
                    c.CLEAT_CELL_WIDTH_WIDE => .wide,
                    c.CLEAT_CELL_WIDTH_SPACER_HEAD => .spacer_head,
                    c.CLEAT_CELL_WIDTH_SPACER_TAIL => .spacer_tail,
                    else => .narrow,
                },
            };
        }
        try self.mirror.apply(.{ .row_replace = .{ .row = row, .cells = cells } });
    }
};

// Provider payloads are borrowed. The mirror must retain graphemes, colours,
// widths and metadata after a borrow is released, and full updates clear rows
// omitted by the provider. Generate both operation forms and every width.
test "render adapter owns borrowed cells and full replacement clears omissions" {
    const a = std.testing.allocator;
    var content = Content{ .allocator = a, .session = null, .mirror = model.Mirror.init(a), .requested = .{ .rows = 3, .cols = 4 } };
    defer content.mirror.deinit();
    var points = [_]u32{ 'a', 0x301, 0x1f600, 0x1b, 0xd800, 0x110000 };
    var cell = std.mem.zeroes(c.cleat_render_cell);
    cell.graphemes = &points;
    cell.grapheme_count = points.len;
    cell.style.fg_color.tag = c.CLEAT_STYLE_COLOR_RGB;
    cell.style.fg = .{ .r = 11, .g = 22, .b = 33 };
    var row = std.mem.zeroes(c.cleat_render_row);
    row.row = 1;
    row.cells = @ptrCast(&cell);
    row.cell_count = 1;
    var op = std.mem.zeroes(c.cleat_render_update_op);
    op.rows = @ptrCast(&row);
    op.row_desc_count = 1;
    var update = std.mem.zeroes(c.cleat_render_update);
    update.cols = 4;
    update.rows = 3;
    update.ops = @ptrCast(&op);
    update.op_count = 1;
    update.cursor.visible = true;
    update.cursor.row = 1;
    update.cursor.style = c.CLEAT_CURSOR_STYLE_UNDERLINE;
    update.terminal_modes.mouse_tracking_mode = c.CLEAT_MOUSE_TRACKING_ANY;
    update.terminal_modes.mouse_report_format = c.CLEAT_MOUSE_FORMAT_SGR_PIXELS;
    for ([_]u32{ c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE, c.CLEAT_RENDER_OP_ROW_REPLACE }) |kind| {
        op.kind = kind;
        for ([_]u32{ c.CLEAT_CELL_WIDTH_NARROW, c.CLEAT_CELL_WIDTH_WIDE, c.CLEAT_CELL_WIDTH_SPACER_HEAD, c.CLEAT_CELL_WIDTH_SPACER_TAIL }, [_]model.Width{ .narrow, .wide, .spacer_head, .spacer_tail }) |width, expected| {
            cell.style.width = width;
            try content.apply(update);
            const retained = content.mirror.row(1)[0];
            try std.testing.expectEqualStrings("a\u{301}\u{1f600}", retained.text);
            try std.testing.expectEqual(expected, retained.width);
            try std.testing.expectEqualDeep(model.Color{ .rgb = .{ 11, 22, 33 }, .is_default = false }, retained.foreground);
            try std.testing.expect(content.mirror.modes.mouse_tracking == .any);
            try std.testing.expect(content.mirror.cursor.shape == .underline);
            points[0] = 'b';
            try std.testing.expectEqualStrings("a\u{301}\u{1f600}", retained.text);
            points[0] = 'a';
        }
    }
    row.row = 2;
    op.kind = c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE;
    try content.apply(update);
    try std.testing.expectEqualStrings("", content.mirror.row(1)[0].text);
    try std.testing.expectEqualStrings("a\u{301}\u{1f600}", content.mirror.row(2)[0].text);
}

const ImageCopy = struct { allocator: std.mem.Allocator, pixels: []const u8 = &.{} };
fn copyImage(context: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) bool {
    const copy: *ImageCopy = @ptrCast(@alignCast(context.?));
    copy.pixels = copy.allocator.dupe(u8, data[0..len]) catch return false;
    return true;
}

// Empty C lists use null pointers, including when the last image disappears.
test "render image adapter accepts null empty lists and retires images" {
    const a = std.testing.allocator;
    var content = Content{ .allocator = a, .session = null, .mirror = model.Mirror.init(a), .requested = .{ .rows = 1, .cols = 1 }, .images = images.State.init(a) };
    defer content.mirror.deinit();
    defer content.images.deinit();
    try content.images.replace(&.{.{ .id = 7, .generation = 1, .width = 1, .height = 1, .pixels = &.{ 1, 2, 3, 255 } }}, &.{});
    content.images.images.items[0].outer = 100000;
    try content.applyImages(.{ .handle = undefined }, std.mem.zeroes(c.cleat_render_update));
    try std.testing.expectEqual(@as(usize, 0), content.images.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), content.images.placements.items.len);
    try std.testing.expectEqualSlices(u32, &.{100000}, content.images.deleted.items);
}
