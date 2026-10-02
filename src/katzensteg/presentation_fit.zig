//! Cell fitting shared by producer placement and desktop background painting.
const std = @import("std");
const CellRect = @import("termscene").types.CellRect;

pub const Grid = struct { cols: i32, rows: i32, pixel_width: i32, pixel_height: i32 };

pub fn containedCellRect(output_w: i32, output_h: i32, tty: Grid) CellRect {
    const cols: i32 = tty.cols;
    const rows: i32 = tty.rows;
    const avail_w = if (tty.pixel_width > 0) @as(f64, @floatFromInt(tty.pixel_width)) else @as(f64, @floatFromInt(cols));
    const avail_h = if (tty.pixel_height > 0) @as(f64, @floatFromInt(tty.pixel_height)) else @as(f64, @floatFromInt(rows));
    const scale = @min(avail_w / @as(f64, @floatFromInt(@max(output_w, 1))), avail_h / @as(f64, @floatFromInt(@max(output_h, 1))));
    const display_w = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(output_w)) * scale))));
    const display_h = @max(1, @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(output_h)) * scale))));
    const cell_w = if (tty.pixel_width > 0) @as(f64, @floatFromInt(tty.pixel_width)) / @as(f64, @floatFromInt(@max(cols, 1))) else 1.0;
    const cell_h = if (tty.pixel_height > 0) @as(f64, @floatFromInt(tty.pixel_height)) / @as(f64, @floatFromInt(@max(rows, 1))) else 1.0;
    const used_cols = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(display_w)) / cell_w))), 1, cols);
    const used_rows = std.math.clamp(@as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(display_h)) / cell_h))), 1, rows);
    return .{
        .col = 1 + @divTrunc(cols - used_cols, 2),
        .row = 1 + @divTrunc(rows - used_rows, 2),
        .w = used_cols,
        .h = used_rows,
    };
}
