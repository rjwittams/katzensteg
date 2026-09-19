const std = @import("std");
const ts = @import("termscene");
const menu = @import("command_menu.zig");

/// A separate text scene survives game scene replacement and idle producers.
/// The caller serializes this with other writes to the direct terminal.
pub const Overlay = struct {
    engine: ts.scene.SceneEngine,

    pub fn init(allocator: std.mem.Allocator) Overlay {
        return .{ .engine = ts.scene.SceneEngine.init(allocator) };
    }

    pub fn deinit(self: *Overlay) void {
        self.engine.deinit();
    }

    pub fn present(self: *Overlay, backend: *ts.kitty.Backend, snapshot: menu.Snapshot) !void {
        self.engine.beginScene();
        if (snapshot.region()) |region| {
            const buffer = try self.engine.allocator.alloc(u8, snapshot.cols);
            defer self.engine.allocator.free(buffer);
            try self.engine.text(.{
                .key = ts.types.NodeKey.text(0x4b5343, 1),
                .pos = .{ .col = region.tty_rect.col, .row = region.tty_rect.row },
                .content = snapshot.line(buffer),
                .z = region.z,
                .mode = .terminal,
                .style = .{ .fg = .{ .r = 255, .g = 255, .b = 255 }, .bg = .{ .r = 35, .g = 45, .b = 65 } },
            });
        }
        try self.engine.diff();
        try backend.applyTextOps(self.engine.text_ops.items);
        try self.engine.commit();
    }
};
