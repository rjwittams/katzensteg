//! PROTOTYPE — throwaway. The cell window compiled out: every call is a no-op.
//! See proto_cleat_cells.zig.
const std = @import("std");

pub const enabled = false;
pub const Rect = struct { row: i32, col: i32, rows: i32, cols: i32 };
pub const Pointer = enum { pass, consumed, moved };
pub const Action = enum { down, repeat, up };

pub fn start(_: std.mem.Allocator, _: i32, _: i32, _: i32, _: i32) void {}
pub fn stop() void {}
pub fn active() bool {
    return false;
}
pub fn focused() bool {
    return false;
}
pub fn topRect() ?Rect {
    return null;
}
pub fn setOccluders(_: []const Rect) void {}
pub fn takeCleared() ?Rect {
    return null;
}
pub fn pump() bool {
    return false;
}
pub fn paint(_: *std.Io.Writer, _: bool) !void {}
pub fn pointer(_: i32, _: i32, _: i32, _: bool) Pointer {
    return .pass;
}
pub fn key(_: []const u8, _: u32, _: Action, _: []const u8) void {}
pub fn typed(_: []const u8) void {}
pub fn raw(_: []const u8) void {}
