const std = @import("std");

pub const TimerKind = enum {
    redraw,
    housekeeping,
};

pub const WmEvent = union(enum) {
    tty_input: []const u8,
    client_closed: u32,
    timer: TimerKind,
    shutdown_requested,
};

pub const Effect = union(enum) {
    terminal_write: []const u8,
    client_write: struct {
        session_id: u32,
        bytes: []const u8,
    },
    close_session: u32,
    request_shutdown,
};

pub const Effects = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(Effect) = .empty,
    items: []const Effect = &.{},

    pub fn init(allocator: std.mem.Allocator) Effects {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Effects) void {
        self.list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Effects, effect: Effect) !void {
        try self.list.append(self.allocator, effect);
        self.items = self.list.items;
    }
};

test "effects collect terminal write requests" {
    var effects = Effects.init(std.testing.allocator);
    defer effects.deinit();

    try effects.append(.{ .terminal_write = "abc" });

    try std.testing.expectEqual(@as(usize, 1), effects.items.len);
    try std.testing.expectEqualStrings("abc", effects.items[0].terminal_write);
}
