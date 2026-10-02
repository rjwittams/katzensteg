//! Per-session visible grid; owns retained text and has no cleat ABI or
//! presentation dependency. Update payloads are borrowed only during apply().
const std = @import("std");
pub const Color = struct { rgb: [3]u8 = .{ 0, 0, 0 }, is_default: bool = true };
pub const Width = enum { narrow, wide, spacer_head, spacer_tail };
pub const Cell = struct {
    /// UTF-8 grapheme including all combining codepoints, without a length cap.
    text: []const u8 = "",
    foreground: Color = .{},
    background: Color = .{},
    /// Adapter-supplied style bits, preserved without interpretation.
    style_flags: u32 = 0,
    width: Width = .narrow,
};
pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    visible: bool = false,
    shape: enum { block, underline, bar } = .block,
    blinking: bool = false,
};
pub const Modes = struct {
    mouse_tracking: enum { none, press, button, any } = .none,
    mouse_encoding: enum { legacy, utf8, sgr, urxvt, sgr_pixels } = .legacy,
    alternate_screen: bool = false,
};
pub const Size = struct { cols: usize, rows: usize };
pub const Row = struct { row: usize, cells: []const Cell };
pub const ScrollCopy = struct { src_row: usize, dst_row: usize, row_count: usize };
/// Zero-based coordinates. Short rows are padded with empty default cells;
/// full replacement clears omitted rows. Scroll copies only destinations;
/// exposed rows arrive separately. Changed size discards the old grid.
pub const Update = union(enum) {
    full_replace: []const Row,
    row_replace: Row,
    scroll_copy: ScrollCopy,
    cursor: Cursor,
    modes: Modes,
    size: Size,
    scrolled_back: bool,
};
pub const Mirror = struct {
    allocator: std.mem.Allocator,
    size: Size = .{ .cols = 0, .rows = 0 },
    cursor: Cursor = .{},
    modes: Modes = .{},
    scrolled_back: bool = false,
    grid: [][]Cell = &.{},
    dirty: []bool = &.{},
    pub fn init(allocator: std.mem.Allocator) Mirror {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Mirror) void {
        for (self.grid) |cells| self.freeRow(cells);
        self.allocator.free(self.grid);
        self.allocator.free(self.dirty);
        self.grid = &.{};
        self.dirty = &.{};
    }
    /// Borrowed until the next successful grid update or deinit.
    pub fn row(self: *const Mirror, index: usize) []const Cell {
        return self.grid[index];
    }
    pub fn dirtyRows(self: *const Mirror) []const bool {
        return self.dirty;
    }
    /// Clear only after successfully repainting the changed rows.
    pub fn clearDirty(self: *Mirror) void {
        @memset(self.dirty, false);
    }
    pub fn markAllDirty(self: *Mirror) void {
        @memset(self.dirty, true);
    }
    /// Each operation is atomic on error. Apply adapter operations in order;
    /// on failure request a fresh full update before acknowledging generation.
    pub fn apply(self: *Mirror, update: Update) !void {
        switch (update) {
            .size => |size| {
                if (std.meta.eql(size, self.size)) return;
                _ = std.math.mul(usize, size.cols, size.rows) catch return error.InvalidSize;
                var next = try self.emptyGrid(size);
                next.cursor = self.cursor;
                next.modes = self.modes;
                next.scrolled_back = self.scrolled_back;
                self.deinit();
                self.* = next;
            },
            .full_replace => |rows| {
                for (rows) |r| try self.validateRow(r);
                var next = try self.emptyGrid(self.size);
                errdefer next.deinit();
                for (rows) |r| try next.replaceRow(r);
                next.cursor = self.cursor;
                next.modes = self.modes;
                next.scrolled_back = self.scrolled_back;
                self.deinit();
                self.* = next;
            },
            .row_replace => |r| try self.replaceRow(r),
            .scroll_copy => |copy| {
                if (copy.src_row > self.size.rows or copy.dst_row > self.size.rows or
                    copy.row_count > self.size.rows - copy.src_row or
                    copy.row_count > self.size.rows - copy.dst_row) return error.InvalidScroll;
                // Snapshot all sources before replacing overlapping destinations.
                const pending = try self.allocator.alloc([]Cell, copy.row_count);
                defer self.allocator.free(pending);
                var initialized: usize = 0;
                errdefer for (pending[0..initialized]) |cells| self.freeRow(cells);
                for (pending, 0..) |*cells, i| {
                    cells.* = try self.cloneRow(self.grid[copy.src_row + i]);
                    initialized += 1;
                }
                for (pending, 0..) |cells, i| {
                    const dst = copy.dst_row + i;
                    self.freeRow(self.grid[dst]);
                    self.grid[dst] = cells;
                    self.dirty[dst] = true;
                }
            },
            .cursor => |cursor| {
                if (!std.meta.eql(self.cursor, cursor)) {
                    self.markRow(self.cursor.row);
                    self.markRow(cursor.row);
                    self.cursor = cursor;
                }
            },
            .modes => |modes| self.modes = modes,
            .scrolled_back => |value| {
                if (self.scrolled_back != value) {
                    self.markRow(self.cursor.row);
                    self.scrolled_back = value;
                }
            },
        }
    }
    fn markRow(self: *Mirror, index: usize) void {
        if (index < self.dirty.len) self.dirty[index] = true;
    }
    fn validateRow(self: *const Mirror, r: Row) !void {
        if (r.row >= self.size.rows) return error.InvalidRow;
        if (r.cells.len > self.size.cols) return error.TooManyCells;
    }
    fn replaceRow(self: *Mirror, r: Row) !void {
        try self.validateRow(r);
        const cells = try self.cloneRow(r.cells);
        self.freeRow(self.grid[r.row]);
        self.grid[r.row] = cells;
        self.dirty[r.row] = true;
    }
    fn cloneRow(self: *Mirror, source: []const Cell) ![]Cell {
        const cells = try self.allocator.alloc(Cell, self.size.cols);
        @memset(cells, .{});
        errdefer self.freeRow(cells);
        for (source, 0..) |cell, col| {
            const text = try self.allocator.dupe(u8, cell.text);
            cells[col] = cell;
            cells[col].text = text;
        }
        return cells;
    }
    fn freeRow(self: *Mirror, cells: []Cell) void {
        for (cells) |cell| self.allocator.free(cell.text);
        self.allocator.free(cells);
    }
    fn emptyGrid(self: *const Mirror, size: Size) !Mirror {
        var next = Mirror.init(self.allocator);
        next.size = size;
        next.grid = try self.allocator.alloc([]Cell, size.rows);
        var initialized: usize = 0;
        errdefer {
            for (next.grid[0..initialized]) |cells| next.freeRow(cells);
            next.allocator.free(next.grid);
        }
        for (next.grid) |*cells| {
            cells.* = try next.cloneRow(&.{});
            initialized += 1;
        }
        next.dirty = try self.allocator.alloc(bool, size.rows);
        next.markAllDirty();
        return next;
    }
};
const testing = std.testing;
// Issue #115: full replacement owns graphemes and attributes, including wide
// and spacer cells, and clears omitted rows and short-row tails.
test "replacements own complete cell data and invalidate only replaced rows" {
    var mirror = Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .cols = 4, .rows = 3 } });
    var text = "e\xcc\x81\xcc\x88".*;
    const styled = Cell{ .text = &text, .foreground = .{ .rgb = .{ 1, 2, 3 }, .is_default = false }, .background = .{ .rgb = .{ 4, 5, 6 } }, .style_flags = 0x1234, .width = .wide };
    try mirror.apply(.{ .full_replace = &.{ .{ .row = 0, .cells = &.{ styled, .{ .width = .spacer_tail }, .{ .width = .spacer_head } } }, .{ .row = 2, .cells = &.{.{ .text = "old" }} } } });
    text[0] = 'x';
    try testing.expectEqualStrings("e\xcc\x81\xcc\x88", mirror.row(0)[0].text);
    try testing.expectEqual(styled.foreground, mirror.row(0)[0].foreground);
    try testing.expectEqual(styled.background, mirror.row(0)[0].background);
    try testing.expectEqual(styled.style_flags, mirror.row(0)[0].style_flags);
    try testing.expectEqual(Width.wide, mirror.row(0)[0].width);
    try testing.expectEqual(Width.spacer_tail, mirror.row(0)[1].width);
    try testing.expectEqual(Width.spacer_head, mirror.row(0)[2].width);
    try testing.expectEqualDeep(Cell{}, mirror.row(0)[3]);
    try testing.expectEqualSlices(bool, &.{ true, true, true }, mirror.dirtyRows());
    mirror.clearDirty();
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "new" }} } });
    try testing.expectEqualSlices(bool, &.{ true, false, false }, mirror.dirtyRows());
    try testing.expectEqualDeep(Cell{}, mirror.row(0)[1]);
    try testing.expectEqualStrings("old", mirror.row(2)[0].text);
    try mirror.apply(.{ .full_replace = &.{} });
    for (0..3) |r| for (mirror.row(r)) |cell| try testing.expectEqualDeep(Cell{}, cell);
}
// Issue #115: copying in either direction uses a source snapshot. Enumerate
// every valid source/destination/count for zero to six rows: overlap, identity,
// empty copies and boundaries. Read every row after each operation.
test "generated scroll copies preserve snapshot rows and dirty destinations" {
    for (0..7) |rows| for (0..rows + 1) |src| for (0..rows + 1) |dst| {
        for (0..@min(rows - src, rows - dst) + 1) |count| {
            var mirror = Mirror.init(testing.allocator);
            defer mirror.deinit();
            try mirror.apply(.{ .size = .{ .cols = 2, .rows = rows } });
            for (0..rows) |r| {
                const text = [_]u8{@intCast('a' + r)};
                try mirror.apply(.{ .row_replace = .{ .row = r, .cells = &.{ .{ .text = &text, .width = .wide }, .{ .width = .spacer_tail } } } });
            }
            mirror.clearDirty();
            try mirror.apply(.{ .scroll_copy = .{ .src_row = src, .dst_row = dst, .row_count = count } });
            for (0..rows) |r| {
                const copied = r >= dst and r - dst < count;
                const expected = [_]u8{@intCast('a' + (if (copied) src + r - dst else r))};
                try testing.expectEqualStrings(&expected, mirror.row(r)[0].text);
                try testing.expectEqual(Width.spacer_tail, mirror.row(r)[1].width);
                try testing.expectEqual(copied, mirror.dirtyRows()[r]);
            }
        }
    };
}
// Issue #115: resizing allocates a blank grid and dirties all rows; cursor
// changes dirty both rows, and session metadata survives grid changes.
test "size cursor modes and viewport transitions" {
    var mirror = Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .cols = 2, .rows = 4 } });
    try mirror.apply(.{ .cursor = .{ .row = 1, .col = 1, .visible = true } });
    mirror.clearDirty();
    try mirror.apply(.{ .cursor = .{ .row = 3, .visible = true } });
    try testing.expectEqualSlices(bool, &.{ false, true, false, true }, mirror.dirtyRows());
    mirror.clearDirty();
    try mirror.apply(.{ .cursor = mirror.cursor });
    try testing.expectEqualSlices(bool, &.{ false, false, false, false }, mirror.dirtyRows());
    try mirror.apply(.{ .scrolled_back = true });
    try testing.expectEqualSlices(bool, &.{ false, false, false, true }, mirror.dirtyRows());
    const modes = Modes{ .mouse_tracking = .any, .mouse_encoding = .sgr_pixels, .alternate_screen = true };
    try mirror.apply(.{ .modes = modes });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "old" }} } });
    const previous = mirror.row(0).ptr;
    try mirror.apply(.{ .size = .{ .cols = 3, .rows = 2 } });
    try testing.expect(previous != mirror.row(0).ptr);
    try testing.expectEqualSlices(bool, &.{ true, true }, mirror.dirtyRows());
    for (0..2) |r| for (mirror.row(r)) |cell| try testing.expectEqualDeep(Cell{}, cell);
    try testing.expectEqual(modes, mirror.modes);
    try testing.expect(mirror.scrolled_back);
    try testing.expectEqual(@as(usize, 3), mirror.cursor.row);
    mirror.clearDirty();
    try mirror.apply(.{ .size = mirror.size });
    try testing.expectEqualSlices(bool, &.{ false, false }, mirror.dirtyRows());
    try mirror.apply(.{ .size = .{ .cols = 0, .rows = 0 } });
    try mirror.apply(.{ .cursor = .{ .row = 100 } });
    try testing.expectEqual(@as(usize, 0), mirror.dirtyRows().len);
}
// Invalid input must leave cells and dirtiness unchanged.
test "invalid updates leave state unchanged" {
    var mirror = Mirror.init(testing.allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .cols = 1, .rows = 1 } });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "kept" }} } });
    mirror.clearDirty();
    try testing.expectError(error.InvalidRow, mirror.apply(.{ .row_replace = .{ .row = 1, .cells = &.{} } }));
    try testing.expectError(error.TooManyCells, mirror.apply(.{ .full_replace = &.{.{ .row = 0, .cells = &.{ .{}, .{} } }} }));
    try testing.expectError(error.InvalidScroll, mirror.apply(.{ .scroll_copy = .{ .src_row = 0, .dst_row = 1, .row_count = 1 } }));
    try testing.expectError(error.InvalidSize, mirror.apply(.{ .size = .{ .cols = std.math.maxInt(usize), .rows = 2 } }));
    try testing.expectEqualStrings("kept", mirror.row(0)[0].text);
    try testing.expectEqualSlices(bool, &.{false}, mirror.dirtyRows());
}
fn allocationScenario(allocator: std.mem.Allocator) !void {
    var mirror = Mirror.init(allocator);
    defer mirror.deinit();
    try mirror.apply(.{ .size = .{ .cols = 3, .rows = 3 } });
    try mirror.apply(.{ .full_replace = &.{.{ .row = 0, .cells = &.{.{ .text = "long grapheme: 👩‍👩‍👧‍👦" }} }} });
    try mirror.apply(.{ .row_replace = .{ .row = 1, .cells = &.{.{ .text = "second" }} } });
    try mirror.apply(.{ .scroll_copy = .{ .src_row = 0, .dst_row = 1, .row_count = 2 } });
    try mirror.apply(.{ .size = .{ .cols = 4, .rows = 2 } });
}
// Allocation failures at every allocation site must release owned text/rows.
test "allocation failure cleanup" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

// Replacements may borrow the mirror itself; cloning must precede releasing
// old storage, and long graphemes must survive repeated overlapping copies.
test "self borrowed replacements and uncapped graphemes" {
    var mirror = Mirror.init(testing.allocator);
    defer mirror.deinit();
    const grapheme = "👩‍👩‍👧‍👦";
    try mirror.apply(.{ .size = .{ .cols = 1, .rows = 2 } });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = grapheme }} } });
    try mirror.apply(.{ .row_replace = .{ .row = 0, .cells = mirror.row(0) } });
    try testing.expectEqualStrings(grapheme, mirror.row(0)[0].text);
    try mirror.apply(.{ .full_replace = &.{.{ .row = 1, .cells = mirror.row(0) }} });
    try testing.expectEqualStrings(grapheme, mirror.row(1)[0].text);
    try testing.expectEqualStrings("", mirror.row(0)[0].text);
    for (0..8) |i| {
        const src = (i + 1) % 2;
        try mirror.apply(.{ .scroll_copy = .{ .src_row = src, .dst_row = 1 - src, .row_count = 1 } });
        try testing.expectEqualStrings(grapheme, mirror.row(0)[0].text);
        try testing.expectEqualStrings(grapheme, mirror.row(1)[0].text);
    }
}

// Each fallible update must preserve the entire previous grid and dirty set
// when any of its allocation sites fails. Generate the failure index until
// the operation succeeds, using real allocation/free rather than a row fake.
test "allocation failures preserve previous state" {
    const updates = [_]Update{
        .{ .size = .{ .cols = 3, .rows = 3 } },
        .{ .full_replace = &.{.{ .row = 0, .cells = &.{.{ .text = "replacement" }} }} },
        .{ .row_replace = .{ .row = 0, .cells = &.{.{ .text = "replacement" }} } },
        .{ .scroll_copy = .{ .src_row = 0, .dst_row = 1, .row_count = 1 } },
    };
    for (updates) |update| {
        var offset: usize = 0;
        while (true) : (offset += 1) {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var mirror = Mirror.init(failing.allocator());
            defer mirror.deinit();
            try mirror.apply(.{ .size = .{ .cols = 2, .rows = 2 } });
            try mirror.apply(.{ .full_replace = &.{ .{ .row = 0, .cells = &.{.{ .text = "first" }} }, .{ .row = 1, .cells = &.{.{ .text = "second" }} } } });
            mirror.clearDirty();
            failing.fail_index = failing.alloc_index + offset;
            mirror.apply(update) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqual(Size{ .cols = 2, .rows = 2 }, mirror.size);
                try testing.expectEqualStrings("first", mirror.row(0)[0].text);
                try testing.expectEqualStrings("second", mirror.row(1)[0].text);
                try testing.expectEqualSlices(bool, &.{ false, false }, mirror.dirtyRows());
                continue;
            };
            break;
        }
    }
}
