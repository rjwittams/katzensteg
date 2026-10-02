//! PROTOTYPE — throwaway. Not for merging.
//!
//! Question (rjwittams/katzensteg#97): does painting a live cleat session as
//! cells in a rectangle of the desktop WM hold up? One cleat session, attached
//! through libcleat's C header, mirrored and painted as a window beside the
//! producer windows. No tests, no error handling, global state.
//!
//! Enabled by `-Dproto-cleat=<cleat checkout>` at build time and
//! `KATZENSTEG_PROTO_CLEAT=<session id>` at run time. Numbers land in
//! /tmp/katzensteg-proto-cells.log.
const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("cleat_provider.h");
});

pub const enabled = true;

pub const Rect = struct {
    row: i32,
    col: i32,
    rows: i32,
    cols: i32,

    fn contains(self: Rect, row: i32, col: i32) bool {
        return row >= self.row and row < self.row + self.rows and col >= self.col and col < self.col + self.cols;
    }
};

pub const Pointer = enum { pass, consumed, moved };
pub const Action = enum { down, repeat, up };

const flag_bold = 1 << 0;
const flag_italic = 1 << 1;
const flag_faint = 1 << 2;
const flag_inverse = 1 << 4;
const flag_invisible = 1 << 5;
const flag_strike = 1 << 6;
const flag_underline = 1 << 8;

const Cell = struct {
    text: [24]u8 = undefined,
    len: u8 = 0,
    fg: [3]u8 = .{ 0, 0, 0 },
    bg: [3]u8 = .{ 0, 0, 0 },
    fg_set: bool = false,
    bg_set: bool = false,
    flags: u32 = 0,
    width: u8 = 0,

    fn sameStyle(a: Cell, b: Cell) bool {
        return a.flags == b.flags and a.fg_set == b.fg_set and a.bg_set == b.bg_set and
            (!a.fg_set or std.mem.eql(u8, &a.fg, &b.fg)) and (!a.bg_set or std.mem.eql(u8, &a.bg, &b.bg));
    }
};

const Drag = enum { none, move, resize };

const State = struct {
    allocator: std.mem.Allocator,
    provider: *c.cleat_provider,
    session: *c.cleat_session,
    id: []const u8,
    outer: Rect,
    term_rows: i32,
    term_cols: i32,
    cell_w: f32,
    cell_h: f32,
    // Mirror of the visible grid.
    grid_cols: usize = 0,
    grid_rows: usize = 0,
    cells: []Cell = &.{},
    dirty: []bool = &.{},
    cursor: c.cleat_cursor = std.mem.zeroes(c.cleat_cursor),
    painted_cursor_row: ?usize = null,
    scrolled_back: bool = false,
    need_full: bool = true,
    focused: bool = false,
    on_top: bool = true,
    drag: Drag = .none,
    drag_row: i32 = 0,
    drag_col: i32 = 0,
    cleared: ?Rect = null,
    occluders: [32]Rect = undefined,
    occluder_count: usize = 0,
    wakes: std.atomic.Value(u32) = .init(0),
    log: ?*c.FILE = null,
    updates: u64 = 0,

    fn content(self: *const State) Rect {
        return .{ .row = self.outer.row + 3, .col = self.outer.col + 1, .rows = @max(0, self.outer.rows - 4), .cols = @max(0, self.outer.cols - 2) };
    }

    fn visible(self: *const State, row: i32, col: i32) bool {
        if (row < 1 or row > self.term_rows - 1 or col < 1 or col > self.term_cols) return false;
        if (self.on_top) return true;
        for (self.occluders[0..self.occluder_count]) |rect| if (rect.contains(row, col)) return false;
        return true;
    }
};

var state: ?*State = null;

fn nowMicros() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1_000_000 + @divTrunc(@as(i64, ts.tv_nsec), 1000);
}

fn logLine(s: *State, comptime fmt: []const u8, args: anytype) void {
    const file = s.log orelse return;
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = c.fwrite(text.ptr, 1, text.len, file);
    _ = c.fflush(file);
}

fn onWake(user: ?*anyopaque) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(user orelse return));
    _ = s.wakes.fetchAdd(1, .monotonic);
}

pub fn start(allocator: std.mem.Allocator, term_rows: i32, term_cols: i32, pixel_width: i32, pixel_height: i32) void {
    const id_z = c.getenv("KATZENSTEG_PROTO_CLEAT") orelse return;
    const id = std.mem.span(id_z);
    if (id.len == 0) return;
    var provider_desc = std.mem.zeroes(c.cleat_provider_desc);
    provider_desc.abi_version = c.CLEAT_PROVIDER_ABI_VERSION;
    provider_desc.requested_features = c.CLEAT_PROVIDER_FEATURE_CELL_SNAPSHOTS | c.CLEAT_PROVIDER_FEATURE_DAMAGE_ROWS |
        c.CLEAT_PROVIDER_FEATURE_STRUCTURED_MOUSE_INPUT | c.CLEAT_PROVIDER_FEATURE_RENDER_UPDATES | c.CLEAT_PROVIDER_FEATURE_IMAGE_STATE;
    provider_desc.backend = c.CLEAT_PROVIDER_BACKEND_DAEMON;
    const provider = c.cleat_provider_open(&provider_desc) orelse return;

    const s = allocator.create(State) catch return;
    const outer = Rect{ .row = 3, .col = @max(2, term_cols - 86), .rows = @min(28, term_rows - 4), .cols = @min(82, term_cols - 2) };
    s.* = .{
        .allocator = allocator,
        .provider = provider,
        .session = undefined,
        .id = id,
        .outer = outer,
        .term_rows = term_rows,
        .term_cols = term_cols,
        .cell_w = if (pixel_width > 0) @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(term_cols)) else 8,
        .cell_h = if (pixel_height > 0) @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(term_rows)) else 16,
    };
    s.log = c.fopen("/tmp/katzensteg-proto-cells.log", "w");
    c.cleat_provider_set_wake_callback(provider, onWake, s);

    var desc = std.mem.zeroes(c.cleat_session_desc);
    const area = s.content();
    desc.cols = @intCast(@max(1, area.cols));
    desc.rows = @intCast(@max(1, area.rows));
    desc.cell_width_px = s.cell_w;
    desc.cell_height_px = s.cell_h;
    desc.id = id.ptr;
    desc.id_len = id.len;
    desc.role = c.CLEAT_ROLE_CONTROLLER;
    const name = "katzensteg-wm-proto";
    desc.attachment_name = name;
    desc.attachment_name_len = name.len;
    s.session = c.cleat_session_attach(provider, &desc) orelse {
        logLine(s, "attach failed id={s}", .{id});
        c.cleat_provider_close(provider);
        allocator.destroy(s);
        return;
    };
    logLine(s, "attached id={s} size={d}x{d} cell={d:.1}x{d:.1}px abi={d}", .{ id, desc.cols, desc.rows, s.cell_w, s.cell_h, c.cleat_provider_abi_version() });
    state = s;
}

pub fn stop() void {
    const s = state orelse return;
    state = null;
    c.cleat_session_destroy(s.session);
    c.cleat_provider_close(s.provider);
    if (s.log) |file| _ = c.fclose(file);
}

pub fn active() bool {
    return state != null;
}

pub fn focused() bool {
    const s = state orelse return false;
    return s.focused;
}

/// The window's rectangle while it sits above the producers, so their images
/// are clipped under it.
pub fn topRect() ?Rect {
    const s = state orelse return null;
    return if (s.on_top) s.outer else null;
}

pub fn setOccluders(rects: []const Rect) void {
    const s = state orelse return;
    s.occluder_count = @min(rects.len, s.occluders.len);
    @memcpy(s.occluders[0..s.occluder_count], rects[0..s.occluder_count]);
}

pub fn takeCleared() ?Rect {
    const s = state orelse return null;
    defer s.cleared = null;
    return s.cleared;
}

fn ensureGrid(s: *State, cols: usize, rows: usize) void {
    if (cols == s.grid_cols and rows == s.grid_rows) return;
    s.allocator.free(s.cells);
    s.allocator.free(s.dirty);
    s.cells = s.allocator.alloc(Cell, cols * rows) catch &.{};
    s.dirty = s.allocator.alloc(bool, rows) catch &.{};
    if (s.cells.len == 0 or s.dirty.len == 0) {
        s.grid_cols = 0;
        s.grid_rows = 0;
        return;
    }
    @memset(s.cells, .{});
    @memset(s.dirty, true);
    s.grid_cols = cols;
    s.grid_rows = rows;
    s.need_full = true;
}

fn storeCell(out: *Cell, in: *const c.cleat_render_cell) void {
    out.* = .{};
    var len: usize = 0;
    if (in.graphemes != null) for (in.graphemes[0..in.grapheme_count]) |codepoint| {
        if (codepoint < 0x20 or codepoint > 0x10ffff) continue;
        const need = std.unicode.utf8CodepointSequenceLength(@intCast(codepoint)) catch continue;
        if (len + need > out.text.len) break;
        len += std.unicode.utf8Encode(@intCast(codepoint), out.text[len..]) catch continue;
    };
    out.len = @intCast(len);
    out.flags = in.style.flags;
    out.width = @intCast(in.style.width);
    out.fg_set = in.style.fg_color.tag != c.CLEAT_STYLE_COLOR_NONE;
    out.bg_set = in.style.bg_color.tag != c.CLEAT_STYLE_COLOR_NONE;
    out.fg = .{ in.style.fg.r, in.style.fg.g, in.style.fg.b };
    out.bg = .{ in.style.bg.r, in.style.bg.g, in.style.bg.b };
}

/// Pull whatever cleat has. True when something needs painting.
pub fn pump() bool {
    const s = state orelse return false;
    const wakes = s.wakes.swap(0, .monotonic);
    if (c.cleat_session_poll(s.session) == c.CLEAT_DIRTY_CLEAN) return s.need_full;
    var update = std.mem.zeroes(c.cleat_render_update);
    update.size = @sizeOf(c.cleat_render_update);
    if (!c.cleat_session_render_update(s.session, &update)) return s.need_full;
    defer c.cleat_session_release_render_update(s.session, &update);
    const started = nowMicros();
    ensureGrid(s, update.cols, update.rows);
    var full_ops: usize = 0;
    var row_ops: usize = 0;
    var scroll_ops: usize = 0;
    var rows_touched: usize = 0;
    if (update.ops != null) for (update.ops[0..update.op_count]) |op| {
        switch (op.kind) {
            c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE, c.CLEAT_RENDER_OP_ROW_REPLACE => {
                if (op.kind == c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE) full_ops += 1 else row_ops += 1;
                if (op.rows == null) continue;
                var flat: usize = 0;
                for (op.rows[0..op.row_desc_count]) |row| {
                    defer flat += row.cell_count;
                    if (row.row >= s.grid_rows) continue;
                    const source: [*c]const c.cleat_render_cell = if (row.cells != null) row.cells else if (op.cells != null) op.cells + flat else continue;
                    const target = s.cells[@as(usize, row.row) * s.grid_cols ..][0..s.grid_cols];
                    @memset(target, .{});
                    for (source[0..@min(row.cell_count, s.grid_cols)], 0..) |*cell, col| storeCell(&target[col], cell);
                    s.dirty[row.row] = true;
                    rows_touched += 1;
                }
            },
            c.CLEAT_RENDER_OP_SCROLL_COPY => {
                scroll_ops += 1;
                var i: usize = 0;
                while (i < op.row_count) : (i += 1) {
                    const down = op.dst_row > op.src_row;
                    const k = if (down) op.row_count - 1 - i else i;
                    const from = @as(usize, op.src_row) + k;
                    const to = @as(usize, op.dst_row) + k;
                    if (from >= s.grid_rows or to >= s.grid_rows) continue;
                    @memcpy(s.cells[to * s.grid_cols ..][0..s.grid_cols], s.cells[from * s.grid_cols ..][0..s.grid_cols]);
                    s.dirty[to] = true;
                    rows_touched += 1;
                }
            },
            else => {},
        }
    };
    if (update.cursor.row != s.cursor.row or update.cursor.col != s.cursor.col or update.cursor.visible != s.cursor.visible) {
        if (s.cursor.row < s.grid_rows) s.dirty[s.cursor.row] = true;
        if (update.cursor.row < s.grid_rows) s.dirty[update.cursor.row] = true;
    }
    s.cursor = update.cursor;
    s.scrolled_back = update.viewport_kind == c.CLEAT_VIEWPORT_NORMAL_SCROLLBACK;
    _ = c.cleat_session_mark_observed(s.session, update.render_generation);
    s.updates += 1;
    logLine(s, "update n={d} gen={d} grid={d}x{d} ops full={d} rows={d} scroll={d} rows_touched={d} images={d} placements={d} wakes={d} apply_us={d}", .{
        s.updates,             update.render_generation,     update.cols, update.rows, full_ops, row_ops, scroll_ops, rows_touched,
        update.image_resource_count, update.image_placement_count, wakes,       nowMicros() - started,
    });
    return true;
}

const Pen = struct {
    row: i32 = -1,
    col: i32 = -1,
    style: ?Cell = null,

    fn at(self: *Pen, writer: *std.Io.Writer, row: i32, col: i32) !void {
        if (self.row == row and self.col == col) return;
        try writer.print("\x1b[{d};{d}H", .{ row, col });
        self.row = row;
        self.col = col;
    }

    fn use(self: *Pen, writer: *std.Io.Writer, cell: Cell) !void {
        if (self.style) |current| if (current.sameStyle(cell)) return;
        try writer.writeAll("\x1b[0");
        if (cell.flags & flag_bold != 0) try writer.writeAll(";1");
        if (cell.flags & flag_faint != 0) try writer.writeAll(";2");
        if (cell.flags & flag_italic != 0) try writer.writeAll(";3");
        if (cell.flags & flag_underline != 0) try writer.writeAll(";4");
        if (cell.flags & flag_inverse != 0) try writer.writeAll(";7");
        if (cell.flags & flag_strike != 0) try writer.writeAll(";9");
        if (cell.fg_set) try writer.print(";38;2;{d};{d};{d}", .{ cell.fg[0], cell.fg[1], cell.fg[2] });
        if (cell.bg_set) try writer.print(";48;2;{d};{d};{d}", .{ cell.bg[0], cell.bg[1], cell.bg[2] });
        try writer.writeByte('m');
        self.style = cell;
    }
};

const Counts = struct { rows: usize = 0, cells: usize = 0 };

fn paintRow(s: *State, writer: *std.Io.Writer, pen: *Pen, grid_row: usize, counts: *Counts) !void {
    const area = s.content();
    const row = area.row + @as(i32, @intCast(grid_row));
    counts.rows += 1;
    var col_index: usize = 0;
    var wide_emitted = false;
    while (col_index < @as(usize, @intCast(area.cols))) : (col_index += 1) {
        const col = area.col + @as(i32, @intCast(col_index));
        if (!s.visible(row, col)) {
            wide_emitted = false;
            continue;
        }
        var cell: Cell = if (grid_row < s.grid_rows and col_index < s.grid_cols) s.cells[grid_row * s.grid_cols + col_index] else .{};
        if (cell.width == c.CLEAT_CELL_WIDTH_SPACER_TAIL and wide_emitted) {
            wide_emitted = false;
            continue;
        }
        wide_emitted = false;
        const is_cursor = s.focused and !s.scrolled_back and s.cursor.visible and s.cursor.row == grid_row and s.cursor.col == col_index;
        if (is_cursor) cell.flags ^= flag_inverse;
        var text: []const u8 = cell.text[0..cell.len];
        var advance: i32 = 1;
        if (cell.width == c.CLEAT_CELL_WIDTH_WIDE) {
            // A wide cell needs both of its columns inside the window and uncovered.
            if (col_index + 1 < @as(usize, @intCast(area.cols)) and s.visible(row, col + 1)) {
                advance = 2;
                wide_emitted = true;
            } else text = " ";
        } else if (cell.width != c.CLEAT_CELL_WIDTH_NARROW) text = " ";
        if (text.len == 0 or cell.flags & flag_invisible != 0) text = " ";
        try pen.at(writer, row, col);
        try pen.use(writer, cell);
        try writer.writeAll(text);
        pen.col += advance;
        counts.cells += 1;
    }
}

fn chromeCell(s: *State, writer: *std.Io.Writer, pen: *Pen, row: i32, col: i32, glyph: []const u8) !void {
    if (!s.visible(row, col)) return;
    try pen.at(writer, row, col);
    try writer.writeAll(glyph);
    pen.col += 1;
}

fn paintChrome(s: *State, writer: *std.Io.Writer, pen: *Pen) !void {
    const o = s.outer;
    if (o.rows < 5 or o.cols < 12) return;
    try writer.writeAll(if (s.focused) "\x1b[0;1;35m" else "\x1b[0;2m");
    pen.style = null;
    var title_buf: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " {s}cleat {s} {d}x{d}{s} ", .{
        if (s.focused) "*" else " ", s.id, s.grid_cols, s.grid_rows, if (s.scrolled_back) " (scrollback)" else "",
    }) catch "";
    // One pass per row, so the cursor only moves at each row's start.
    var line: i32 = 0;
    while (line < 4) : (line += 1) {
        const row = if (line == 3) o.row + o.rows - 1 else o.row + line;
        var i: i32 = 0;
        while (i < o.cols) : (i += 1) {
            const last = i == o.cols - 1;
            const glyph: []const u8 = switch (line) {
                0 => if (i == 0) "┌" else if (last) "┐" else "─",
                1 => if (i == 0 or last or i == 2) "│" else if (i == 1) (if (s.on_top) "▲" else "▼") else blk: {
                    const index: usize = @intCast(i - 3);
                    break :blk if (index < title.len) title[index .. index + 1] else " ";
                },
                2 => if (i == 0) "├" else if (last) "┤" else "─",
                else => if (i == 0) "└" else if (last) "◢" else "─",
            };
            try chromeCell(s, writer, pen, row, o.col + i, glyph);
        }
    }
    var r: i32 = 3;
    while (r < o.rows - 1) : (r += 1) {
        try chromeCell(s, writer, pen, o.row + r, o.col, "│");
        try chromeCell(s, writer, pen, o.row + r, o.col + o.cols - 1, "│");
    }
}

/// Paint what is dirty, or everything when `full` (after a desktop redraw
/// wiped or overdrew the window's area).
pub fn paint(out: *std.Io.Writer, full: bool) !void {
    const s = state orelse return;
    const started = nowMicros();
    var bytes = std.Io.Writer.Allocating.init(s.allocator);
    defer bytes.deinit();
    const writer = &bytes.writer;
    const everything = full or s.need_full;
    var pen = Pen{};
    var counts = Counts{};
    try writer.writeAll("\x1b[?2026h");
    if (everything) try paintChrome(s, writer, &pen);
    const area_rows: usize = @intCast(s.content().rows);
    var row: usize = 0;
    while (row < area_rows) : (row += 1) {
        const dirty = row < s.grid_rows and s.dirty[row];
        if (!everything and !dirty) continue;
        try paintRow(s, writer, &pen, row, &counts);
    }
    @memset(s.dirty, false);
    s.need_full = false;
    try writer.writeAll("\x1b[0m\x1b[?2026l");
    try out.writeAll(bytes.written());
    logLine(s, "paint full={} rows={d} cells={d} bytes={d} build_us={d}", .{ everything, counts.rows, counts.cells, bytes.written().len, nowMicros() - started });
}

fn resizeSession(s: *State) void {
    const area = s.content();
    _ = c.cleat_session_resize(s.session, @intCast(@max(1, area.cols)), @intCast(@max(1, area.rows)));
    logLine(s, "resize sent {d}x{d}", .{ area.cols, area.rows });
}

/// SGR mouse report in cells. `button` is the raw SGR button field.
pub fn pointer(row: i32, col: i32, button: i32, pressed: bool) Pointer {
    const s = state orelse return .pass;
    const motion = button & 32 != 0;
    const wheel = button & 64 != 0;
    if (s.drag != .none) {
        if (!pressed) {
            if (s.drag == .resize) resizeSession(s);
            s.drag = .none;
            return .consumed;
        }
        if (!motion) return .consumed;
        const previous = s.outer;
        switch (s.drag) {
            .move => {
                s.outer.row = std.math.clamp(row - s.drag_row, 1, @max(1, s.term_rows - 3));
                s.outer.col = std.math.clamp(col - s.drag_col, 3 - s.outer.cols, s.term_cols - 2);
            },
            .resize => {
                s.outer.rows = @max(6, row - s.outer.row + 1);
                s.outer.cols = @max(14, col - s.outer.col + 1);
            },
            .none => {},
        }
        if (std.meta.eql(previous, s.outer)) return .consumed;
        if (s.cleared == null) s.cleared = previous;
        s.need_full = true;
        return .moved;
    }
    const inside = s.outer.contains(row, col) and s.visible(row, col);
    if (wheel) {
        if (!inside) return .pass;
        var command = c.cleat_viewport_command{ .kind = c.CLEAT_VIEWPORT_COMMAND_DELTA_ROWS, .delta_rows = if (button & 1 == 0) -3 else 3 };
        var result = std.mem.zeroes(c.cleat_viewport_command_result);
        _ = c.cleat_session_scroll_viewport(s.session, &command, &result);
        return .consumed;
    }
    if (motion or !pressed) return if (inside and s.on_top) .consumed else .pass;
    if (button & 3 != 0) return if (inside) .consumed else .pass;
    if (!inside) {
        if (s.focused) {
            s.focused = false;
            s.need_full = true;
        }
        return .pass;
    }
    const was_focused = s.focused;
    s.focused = true;
    s.need_full = s.need_full or !was_focused;
    // The button lowers the window under the producers; a click on any part
    // still showing raises it again.
    if (!s.on_top or (row == s.outer.row + 1 and col == s.outer.col + 1)) {
        s.on_top = !s.on_top;
        s.cleared = s.outer;
        s.need_full = true;
        logLine(s, "z toggled on_top={}", .{s.on_top});
        return .moved;
    }
    if (row == s.outer.row + s.outer.rows - 1 and col >= s.outer.col + s.outer.cols - 2) {
        s.drag = .resize;
    } else if (row <= s.outer.row + 2) {
        s.drag = .move;
        s.drag_row = row - s.outer.row;
        s.drag_col = col - s.outer.col;
    }
    // A focus change repaints the chrome; the host does that through `moved`.
    return if (was_focused) .consumed else .moved;
}

const named_keys = [_]struct { name: []const u8, code: u32 }{
    .{ .name = "Enter", .code = c.CLEAT_KEY_ENTER },         .{ .name = "Escape", .code = c.CLEAT_KEY_ESCAPE },
    .{ .name = "Backspace", .code = c.CLEAT_KEY_BACKSPACE }, .{ .name = "Tab", .code = c.CLEAT_KEY_TAB },
    .{ .name = "Delete", .code = c.CLEAT_KEY_DELETE },       .{ .name = "Insert", .code = c.CLEAT_KEY_INSERT },
    .{ .name = "Home", .code = c.CLEAT_KEY_HOME },           .{ .name = "End", .code = c.CLEAT_KEY_END },
    .{ .name = "PageUp", .code = c.CLEAT_KEY_PAGE_UP },      .{ .name = "PageDown", .code = c.CLEAT_KEY_PAGE_DOWN },
    .{ .name = "ArrowUp", .code = c.CLEAT_KEY_ARROW_UP },    .{ .name = "ArrowDown", .code = c.CLEAT_KEY_ARROW_DOWN },
    .{ .name = "ArrowLeft", .code = c.CLEAT_KEY_ARROW_LEFT }, .{ .name = "ArrowRight", .code = c.CLEAT_KEY_ARROW_RIGHT },
};

/// A decoded key. `name` is a DOM key name or one character; `modifiers` uses
/// the shift/control/alt/super bit order both vocabularies share.
pub fn key(name: []const u8, modifiers: u32, action: Action, text: []const u8) void {
    const s = state orelse return;
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_KEY;
    event.focused = true;
    event.modifiers = @intCast(modifiers & 0xf);
    event.key_action = switch (action) {
        .down => c.CLEAT_KEY_ACTION_PRESS,
        .repeat => c.CLEAT_KEY_ACTION_REPEAT,
        .up => c.CLEAT_KEY_ACTION_RELEASE,
    };
    for (named_keys) |named| if (std.mem.eql(u8, named.name, name)) {
        event.key_kind = c.CLEAT_KEY_NAMED;
        event.key_code = named.code;
        break;
    };
    if (event.key_kind == 0) {
        const len = std.unicode.utf8ByteSequenceLength(if (name.len > 0) name[0] else return) catch return;
        if (len != name.len) return;
        event.key_kind = c.CLEAT_KEY_UNICODE_SCALAR;
        event.key_code = std.unicode.utf8Decode(name) catch return;
    }
    if (text.len > 0 and action != .up) {
        event.generated_text = text.ptr;
        event.generated_text_len = text.len;
    }
    _ = c.cleat_session_send_input(s.session, &event);
}

/// Plain text typed on a terminal that does not report keys as escapes.
pub fn typed(bytes: []const u8) void {
    const s = state orelse return;
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_TEXT;
    event.focused = true;
    event.text = bytes.ptr;
    event.text_len = bytes.len;
    _ = c.cleat_session_send_input(s.session, &event);
}

/// Legacy control bytes, passed straight to the session.
pub fn raw(bytes: []const u8) void {
    const s = state orelse return;
    _ = c.cleat_session_write_bytes(s.session, bytes.ptr, bytes.len);
}
