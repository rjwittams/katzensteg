//! Pure session-cell presentation. Coordinates are zero-based; output uses CUP.
//! The caller owns damage acknowledgement and repaints fully after changes to
//! focus, mirror size, covering windows, terminal size or the supplied default
//! background. The first presentation must also be full.
const std = @import("std");
const model = @import("session_mirror.zig");

pub const Rect = struct {
    row: i32,
    col: i32,
    rows: u32,
    cols: u32,

    fn contains(self: Rect, row: i64, col: i64) bool {
        return row >= self.row and col >= self.col and
            row < @as(i64, self.row) + self.rows and col < @as(i64, self.col) + self.cols;
    }
};
pub const TerminalSize = struct { rows: u32, cols: u32 };
/// Style bits from the cleat cell vocabulary used by the prototype. Unknown
/// bits are ignored; the mirror retains them for other presentations.
pub const Style = struct {
    pub const bold: u32 = 1 << 0;
    pub const italic: u32 = 1 << 1;
    pub const faint: u32 = 1 << 2;
    pub const inverse: u32 = 1 << 4;
    pub const invisible: u32 = 1 << 5;
    pub const strike: u32 = 1 << 6;
    pub const underline: u32 = 1 << 8;
};
pub const Options = struct {
    content: Rect,
    terminal: TerminalSize,
    higher: []const Rect = &.{},
    focused: bool = false,
    default_background: [3]u8,
    full: bool = false,
    /// Moving/resizing forces a full paint and clears the visible old-minus-new
    /// area with the outer terminal's default background, in the same update.
    previous: ?Rect = null,

    fn visible(self: Options, row: i64, col: i64) bool {
        if (row < 0 or col < 0 or row >= self.terminal.rows or col >= self.terminal.cols) return false;
        for (self.higher) |rect| if (rect.contains(row, col)) return false;
        return true;
    }
};

const Pen = struct {
    row: i64 = -1,
    col: i64 = -1,
    style: ?model.Cell = null,

    fn at(self: *Pen, out: *std.Io.Writer, row: i64, col: i64) !void {
        if (self.row != row or self.col != col) try out.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
        self.row = row;
        self.col = col;
    }
    fn use(self: *Pen, out: *std.Io.Writer, cell: model.Cell) !void {
        if (self.style) |old| {
            if (old.style_flags == cell.style_flags and std.meta.eql(old.foreground, cell.foreground) and
                std.meta.eql(old.background, cell.background)) return;
        }
        try out.writeAll("\x1b[0");
        const flags = [_]u32{ Style.bold, Style.faint, Style.italic, Style.underline, Style.inverse, Style.invisible, Style.strike };
        const codes = [_]u8{ 1, 2, 3, 4, 7, 8, 9 };
        for (flags, codes) |flag, code| if (cell.style_flags & flag != 0) try out.print(";{d}", .{code});
        if (!cell.foreground.is_default) try out.print(";38;2;{d};{d};{d}", .{ cell.foreground.rgb[0], cell.foreground.rgb[1], cell.foreground.rgb[2] });
        if (!cell.background.is_default) try out.print(";48;2;{d};{d};{d}", .{ cell.background.rgb[0], cell.background.rgb[1], cell.background.rgb[2] });
        try out.writeByte('m');
        self.style = cell;
    }
};

/// Build a complete synchronized update before exposing bytes. Never consumes
/// mirror dirty rows: clear them only after the caller successfully writes the
/// result. Empty damage returns no bytes. The returned slice is allocator-owned.
pub fn paint(allocator: std.mem.Allocator, mirror: *const model.Mirror, options: Options) std.mem.Allocator.Error![]u8 {
    // The allocating writer reports allocation failure as WriteFailed.
    return build(allocator, mirror, options) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
    };
}

fn build(allocator: std.mem.Allocator, mirror: *const model.Mirror, options: Options) ![]u8 {
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    const out = &bytes.writer;
    var pen = Pen{};
    try out.writeAll("\x1b[?2026h\x1b[?25l");
    const prefix_len = bytes.written().len;
    if (options.previous) |old| {
        const end_row = @min(@as(i64, old.row) + old.rows, options.terminal.rows);
        const end_col = @min(@as(i64, old.col) + old.cols, options.terminal.cols);
        var row: i64 = @max(@as(i64, old.row), 0);
        while (row < end_row) : (row += 1) {
            var col: i64 = @max(@as(i64, old.col), 0);
            while (col < end_col) : (col += 1) {
                if (options.content.contains(row, col) or !options.visible(row, col)) continue;
                try pen.at(out, row, col);
                try pen.use(out, .{});
                try out.writeByte(' ');
                pen.col += 1;
            }
        }
    }
    const area = options.content;
    const end_row = @min(@as(i64, area.row) + area.rows, options.terminal.rows);
    const end_col = @min(@as(i64, area.col) + area.cols, options.terminal.cols);
    var row: i64 = @max(@as(i64, area.row), 0);
    while (row < end_row) : (row += 1) {
        const r: usize = @intCast(row - area.row);
        if (!options.full and options.previous == null and (r >= mirror.size.rows or !mirror.dirtyRows()[r])) continue;
        var col: i64 = @max(@as(i64, area.col), 0);
        while (col < end_col) {
            defer col += 1;
            if (!options.visible(row, col)) continue;
            const c: usize = @intCast(col - area.col);
            var cell: model.Cell = if (r < mirror.size.rows and c < mirror.size.cols) mirror.row(r)[c] else .{};
            var text = if (cell.text.len == 0) " " else cell.text;
            const wide = cell.width == .wide and col + 1 < end_col and options.visible(row, col + 1);
            if (wide and cell.text.len == 0) text = "  ";
            if (cell.width == .wide and !wide or cell.width == .spacer_head or cell.width == .spacer_tail) text = " ";
            // A cursor reported on the continuation column inverts the whole glyph.
            if (options.focused and !mirror.scrolled_back and mirror.cursor.visible and
                r < mirror.size.rows and mirror.cursor.row == r and mirror.cursor.col < mirror.size.cols and
                (mirror.cursor.col == c or (wide and mirror.cursor.col == c + 1))) cell.style_flags ^= Style.inverse;
            if (cell.foreground.is_default) cell.foreground.rgb = .{ 0, 0, 0 };
            if (cell.background.is_default) cell.background = .{ .rgb = options.default_background, .is_default = false };
            try pen.at(out, row, col);
            try pen.use(out, cell);
            try out.writeAll(text);
            pen.col += if (wide) @as(i64, 2) else 1;
            if (wide) col += 1;
        }
    }
    if (bytes.written().len == prefix_len) return allocator.dupe(u8, "");
    try out.writeAll("\x1b[0m\x1b[?2026l");
    return allocator.dupe(u8, bytes.written());
}

const testing = std.testing;
const prefix = "\x1b[?2026h\x1b[?25l";
const suffix = "\x1b[0m\x1b[?2026l";
const background = "\x1b[0;48;2;10;20;31m";
fn fixture() !model.Mirror {
    var mirror = model.Mirror.init(testing.allocator);
    errdefer mirror.deinit();
    try mirror.apply(.{ .size = .{ .rows = 2, .cols = 3 } });
    try mirror.apply(.{ .full_replace = &.{
        .{ .row = 0, .cells = &.{ .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" } } },
        .{ .row = 1, .cells = &.{ .{ .text = "d" }, .{ .text = "e" }, .{ .text = "f" } } },
    } });
    return mirror;
}
fn defaults(area: Rect) Options {
    return .{ .content = area, .terminal = .{ .rows = 6, .cols = 8 }, .default_background = .{ 10, 20, 31 } };
}

// #116: dirty painting emits only changed rows, full painting includes blank
// padding, and larger grids show their top-left part. Exact bytes are the API.
test "dirty full padding and crop bytes" {
    var mirror = try fixture();
    defer mirror.deinit();
    var options = defaults(.{ .row = 1, .col = 2, .rows = 3, .cols = 4 });
    mirror.clearDirty();
    var bytes = try paint(testing.allocator, &mirror, options);
    try testing.expectEqualStrings("", bytes);
    testing.allocator.free(bytes);
    try mirror.apply(.{ .row_replace = .{ .row = 1, .cells = mirror.row(1) } });
    bytes = try paint(testing.allocator, &mirror, options);
    try testing.expectEqualStrings(prefix ++ "\x1b[3;3H" ++ background ++ "def " ++ suffix, bytes);
    testing.allocator.free(bytes);
    try testing.expectEqualSlices(bool, &.{ false, true }, mirror.dirtyRows());
    options.full = true;
    bytes = try paint(testing.allocator, &mirror, options);
    try testing.expectEqualStrings(prefix ++ "\x1b[2;3H" ++ background ++ "abc \x1b[3;3Hdef \x1b[4;3H    " ++ suffix, bytes);
    testing.allocator.free(bytes);
    options.content.rows = 1;
    options.content.cols = 2;
    bytes = try paint(testing.allocator, &mirror, options);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(prefix ++ "\x1b[2;3H" ++ background ++ "ab" ++ suffix, bytes);
}

// #116: glyphs (including combining codepoints), explicit colours and style
// survive presentation; only default backgrounds use the supplied nudge.
test "colours styles and graphemes" {
    var mirror = model.Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .rows = 1, .cols = 2 } });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{
        .{ .text = "e\xcc\x81", .foreground = .{ .rgb = .{ 1, 2, 3 }, .is_default = false }, .background = .{ .rgb = .{ 4, 5, 6 }, .is_default = false }, .style_flags = Style.bold | Style.faint | Style.italic | Style.underline | Style.inverse | Style.invisible | Style.strike },
        .{ .text = "x", .background = .{ .rgb = .{ 99, 98, 97 } } },
    } } });
    const bytes = try paint(testing.allocator, &mirror, defaults(.{ .row = 0, .col = 0, .rows = 1, .cols = 2 }));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(prefix ++ "\x1b[1;1H\x1b[0;1;2;3;4;7;8;9;38;2;1;2;3;48;2;4;5;6me\xcc\x81" ++ background ++ "x" ++ suffix, bytes);
}

// Small terminal emulator for this module's emitted subset, independent of
// its visibility and rectangle logic. Tracks every write, including clears.
const Grid = struct {
    glyph: [6][8]u21 = @splat(@splat('#')),
    writes: [6][8]u8 = @splat(@splat(0)),
    inverted: [6][8]bool = @splat(@splat(false)),
    default_bg: [6][8]bool = @splat(@splat(true)),
    fn parse(bytes: []const u8) !Grid {
        var grid = Grid{};
        var row: usize = 0;
        var col: usize = 0;
        var inverse = false;
        var default_bg = true;
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (bytes[offset] == 0x1b) {
                try testing.expectEqual(@as(u8, '['), bytes[offset + 1]);
                const start = offset + 2;
                var end = start;
                while (end < bytes.len and !std.ascii.isAlphabetic(bytes[end])) : (end += 1) {}
                const args = bytes[start..end];
                if (bytes[end] == 'H') {
                    var fields = std.mem.splitScalar(u8, args, ';');
                    row = (try std.fmt.parseInt(usize, fields.next().?, 10)) - 1;
                    col = (try std.fmt.parseInt(usize, fields.next().?, 10)) - 1;
                } else if (bytes[end] == 'm') {
                    // Each style starts with 0; RGB channels aren't SGR codes.
                    inverse = false;
                    default_bg = true;
                    var fields = std.mem.splitScalar(u8, args, ';');
                    while (fields.next()) |field| {
                        const code = try std.fmt.parseInt(u8, field, 10);
                        if (code == 7) inverse = true;
                        if (code == 38 or code == 48) {
                            if (code == 48) default_bg = false;
                            for (0..4) |_| _ = fields.next().?;
                        }
                    }
                }
                offset = end + 1;
                continue;
            }
            const len = try std.unicode.utf8ByteSequenceLength(bytes[offset]);
            const glyph = try std.unicode.utf8Decode(bytes[offset..][0..len]);
            const width: usize = if (glyph == '界') 2 else 1;
            try testing.expect(row < 6 and col + width <= 8);
            for (0..width) |i| {
                grid.glyph[row][col + i] = if (i == 0) glyph else 0;
                grid.writes[row][col + i] += 1;
                grid.inverted[row][col + i] = inverse;
                grid.default_bg[row][col + i] = default_bg;
            }
            col += width;
            offset += len;
        }
        return grid;
    }
};

// #116: only cells inside the terminal/content and outside all higher windows
// are painted. Exhaustive small rectangles cross every edge, include empty
// areas, negative origins and duplicate occluders; grid sizing is independent.
test "generated terminal and higher window clipping" {
    var mirror = try fixture();
    defer mirror.deinit();
    for (0..7) |origin| for (0..5) |extent| for (0..5) |cover_col| {
        const start: i32 = @as(i32, @intCast(origin)) - 2;
        const area = Rect{ .row = start, .col = start, .rows = @intCast(extent), .cols = @intCast(extent) };
        const cover = Rect{ .row = 1, .col = @intCast(cover_col), .rows = 2, .cols = 1 };
        var options = defaults(area);
        options.full = true;
        options.higher = &.{ cover, cover };
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        const grid = try Grid.parse(bytes);
        for (0..6) |r| for (0..8) |c| {
            const rr: i64 = @intCast(r);
            const cc: i64 = @intCast(c);
            const inside = rr >= start and rr < start + @as(i64, @intCast(extent)) and cc >= start and cc < start + @as(i64, @intCast(extent));
            const covered = r >= 1 and r < 3 and c == cover_col;
            const painted = inside and !covered;
            try testing.expectEqual(@as(u8, if (painted) 1 else 0), grid.writes[r][c]);
            if (painted) {
                const mr: usize = @intCast(rr - start);
                const mc: usize = @intCast(cc - start);
                const expected: u21 = if (mr < 2 and mc < 3) mirror.row(mr)[mc].text[0] else ' ';
                try testing.expectEqual(expected, grid.glyph[r][c]);
                try testing.expect(!grid.default_bg[r][c]);
            }
        };
    };
}

// #116: both columns must be visible for a wide glyph. Cover either half,
// clip on either terminal edge, crop at the window edge, and expose spacers.
test "wide glyph visibility and spacer cells" {
    var mirror = model.Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .rows = 1, .cols = 4 } });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{ .{ .text = "界", .width = .wide }, .{ .width = .spacer_tail }, .{ .width = .spacer_head }, .{ .text = "z" } } } });
    for ([_]i32{ -1, 0, 7 }) |origin| for ([_]u32{ 1, 2, 4 }) |cols| for (0..3) |cover| {
        var options = defaults(.{ .row = 0, .col = origin, .rows = 1, .cols = cols });
        const higher = Rect{ .row = 0, .col = @as(i32, @intCast(cover)) - 1, .rows = 1, .cols = 1 };
        options.higher = if (cover == 0) &.{} else &.{higher};
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        const grid = try Grid.parse(bytes);
        const both = origin >= 0 and origin + 1 < 8 and cols >= 2 and
            (cover == 0 or (higher.col != origin and higher.col != origin + 1));
        for (0..8) |c| {
            const cc: i32 = @intCast(c);
            const visible = cc >= origin and cc < origin + @as(i64, cols) and (cover == 0 or cc != higher.col);
            try testing.expectEqual(@as(u8, if (visible) 1 else 0), grid.writes[0][c]);
            if (visible) {
                const expected: u21 = if (both and cc == origin) '界' else if (both and cc == origin + 1) 0 else if (cc == origin + 3) 'z' else ' ';
                try testing.expectEqual(expected, grid.glyph[0][c]);
            }
        }
    };
}

// #116: the focused live cursor XORs inverse, including an already inverse
// cell. Unfocused, hidden, scrolled-back and out-of-grid cursors do not paint.
test "cursor inversion and viewport suppression" {
    var mirror = try fixture();
    defer mirror.deinit();
    for ([_]bool{ false, true }) |focused| for ([_]bool{ false, true }) |visible| for ([_]bool{ false, true }) |scrolled| for ([_]u32{ 0, Style.inverse }) |style| {
        try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "a", .style_flags = style }} } });
        try mirror.apply(.{ .cursor = .{ .row = 0, .col = 0, .visible = visible } });
        try mirror.apply(.{ .scrolled_back = scrolled });
        var options = defaults(.{ .row = 0, .col = 0, .rows = 2, .cols = 4 });
        options.focused = focused;
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        const grid = try Grid.parse(bytes);
        try testing.expectEqual((style != 0) != (focused and visible and !scrolled), grid.inverted[0][0]);
        try testing.expect(!grid.inverted[0][1]);
    };
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "a" }} } });
    try mirror.apply(.{ .scrolled_back = false });
    for ([_]model.Cursor{ .{ .row = 99, .visible = true }, .{ .row = 2, .visible = true }, .{ .col = 3, .visible = true } }) |cursor| {
        try mirror.apply(.{ .cursor = cursor });
        var options = defaults(.{ .row = 0, .col = 0, .rows = 3, .cols = 4 });
        options.full = true;
        options.focused = true;
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        const grid = try Grid.parse(bytes);
        for (grid.inverted) |row| for (row) |inverse| try testing.expect(!inverse);
    }
}

// #116: move/resize clears exactly old-minus-new, never covered cells, and
// paints the entire new area despite clean damage, in one synchronized update.
// Generated origins/sizes include overlap, disjoint, shrink, grow and empty.
test "generated move and resize clear only exposed old cells" {
    var mirror = try fixture();
    defer mirror.deinit();
    mirror.clearDirty();
    const old = Rect{ .row = 1, .col = 1, .rows = 3, .cols = 4 };
    const higher = Rect{ .row = 2, .col = 2, .rows = 1, .cols = 2 };
    for (0..5) |origin| for (0..5) |extent| {
        const start: i32 = @as(i32, @intCast(origin)) - 1;
        const area = Rect{ .row = start, .col = start, .rows = @intCast(extent), .cols = @intCast(extent) };
        var options = defaults(area);
        options.previous = old;
        options.higher = &.{higher};
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?2026h"));
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?2026l"));
        const grid = try Grid.parse(bytes);
        for (0..6) |r| for (0..8) |c| {
            const rr: i64 = @intCast(r);
            const cc: i64 = @intCast(c);
            const in_new = rr >= start and cc >= start and rr < start + @as(i64, @intCast(extent)) and cc < start + @as(i64, @intCast(extent));
            const in_old = r >= 1 and r < 4 and c >= 1 and c < 5;
            const covered = r == 2 and c >= 2 and c < 4;
            const painted = (in_old or in_new) and !covered;
            try testing.expectEqual(@as(u8, if (painted) 1 else 0), grid.writes[r][c]);
            if (painted) {
                try testing.expectEqual(!in_new, grid.default_bg[r][c]);
                if (!in_new) try testing.expectEqual(@as(u21, ' '), grid.glyph[r][c]);
            }
        };
    };
}

fn allocatingPaint(allocator: std.mem.Allocator) !void {
    var mirror = try fixture();
    defer mirror.deinit();
    const bytes = try paint(allocator, &mirror, defaults(.{ .row = 0, .col = 0, .rows = 2, .cols = 3 }));
    defer allocator.free(bytes);
    try testing.expectEqualSlices(bool, &.{ true, true }, mirror.dirtyRows());
}
// Allocation errors release partial output and leave damage available to retry.
test "paint allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, allocatingPaint, .{});
}

// A wide cursor is rendered across its glyph, even when reported on its tail;
// an empty wide cell blanks both columns instead of leaving stale text behind.
test "wide cursor and empty wide cell" {
    var mirror = model.Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .rows = 1, .cols = 2 } });
    var options = defaults(.{ .row = 0, .col = 0, .rows = 1, .cols = 2 });
    options.focused = true;
    for ([_][]const u8{ "界", "" }) |text| for (0..2) |cursor_col| {
        try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{ .{ .text = text, .width = .wide }, .{ .width = .spacer_tail } } } });
        try mirror.apply(.{ .cursor = .{ .col = cursor_col, .visible = true } });
        const bytes = try paint(testing.allocator, &mirror, options);
        defer testing.allocator.free(bytes);
        const grid = try Grid.parse(bytes);
        try testing.expectEqual(@as(u21, if (text.len == 0) ' ' else '界'), grid.glyph[0][0]);
        try testing.expectEqual(@as(u21, if (text.len == 0) ' ' else 0), grid.glyph[0][1]);
        try testing.expect(grid.inverted[0][0] and grid.inverted[0][1]);
    };
}

// Empty mirrors still fill a full window, zero-size terminals emit nothing,
// and extreme rectangles clip before iterating, without coordinate overflow.
test "empty mirror terminal and extreme rectangles" {
    var mirror = model.Mirror.init(testing.allocator);
    defer mirror.deinit();
    var options = defaults(.{ .row = 0, .col = 0, .rows = 1, .cols = 2 });
    options.full = true;
    var bytes = try paint(testing.allocator, &mirror, options);
    try testing.expectEqualStrings(prefix ++ "\x1b[1;1H" ++ background ++ "  " ++ suffix, bytes);
    testing.allocator.free(bytes);
    options.terminal.rows = 0;
    bytes = try paint(testing.allocator, &mirror, options);
    try testing.expectEqualStrings("", bytes);
    testing.allocator.free(bytes);
    options.terminal = .{ .rows = 6, .cols = 8 };
    options.content = .{ .row = std.math.maxInt(i32), .col = std.math.maxInt(i32), .rows = std.math.maxInt(u32), .cols = std.math.maxInt(u32) };
    options.previous = .{ .row = std.math.minInt(i32), .col = std.math.minInt(i32), .rows = std.math.maxInt(u32), .cols = std.math.maxInt(u32) };
    bytes = try paint(testing.allocator, &mirror, options);
    defer testing.allocator.free(bytes);
    const grid = try Grid.parse(bytes);
    for (0..6) |r| for (0..8) |c| {
        try testing.expectEqual(@as(u8, 1), grid.writes[r][c]);
        try testing.expectEqual(@as(u21, ' '), grid.glyph[r][c]);
        try testing.expect(grid.default_bg[r][c]);
    };
}
