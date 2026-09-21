const std = @import("std");
const layout = @import("presentation_layout.zig");

pub const Action = enum { quit, cancel };

/// Immutable input-owned state sent to presentation; coordinates are terminal cells.
pub const Snapshot = struct {
    active: bool = false,
    desktop: bool = false,
    hint: bool = false,
    quitting: bool = false,
    binding: u8 = ']',
    cols: u16 = 0,
    rows: u16 = 0,

    pub fn region(self: Snapshot) ?layout.PresentationRegion {
        if (!self.active or self.cols == 0 or self.rows == 0) return null;
        return .{ .kind = .chrome, .tty_rect = .{ .col = 1, .row = self.rows, .w = self.cols, .h = 1 }, .sdl_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .z = std.math.maxInt(i32) };
    }

    pub fn withChrome(self: Snapshot, content: layout.PresentationLayout) layout.PresentationLayout {
        var result = content;
        if (self.region()) |chrome| result.addRegion(chrome);
        return result;
    }

    pub fn line(self: Snapshot, buffer: []u8) []const u8 {
        const out = buffer[0..@min(buffer.len, self.cols)];
        @memset(out, ' ');
        // Fill the terminal-width slice directly. A full writer means the
        // visible prefix is complete; the remaining text is simply clipped.
        var writer = std.Io.Writer.fixed(out);
        if (self.desktop and self.hint) {
            writer.writeAll(" q Quit | Esc Return | Unknown key") catch {};
        } else if (self.desktop) {
            writer.print(" q Quit | Esc Return | n Launch | Tab Next | Q Quit WM | hjkl Move | HJKL Resize | c/t Layout | ^{c} Literal", .{std.ascii.toUpper(self.binding)}) catch {};
        } else if (self.quitting) {
            writer.writeAll(" Quitting... waiting for app") catch {};
        } else {
            writer.print(" q Quit | Esc Return | ^{c} Literal{s}", .{ std.ascii.toUpper(self.binding), if (self.hint) " | Unknown key" else "" }) catch {};
        }
        return out;
    }

    pub fn hit(self: Snapshot, col: i32, row: i32) ?Action {
        if (!self.active or self.quitting or row != self.rows or col < 1 or col > self.cols) return null;
        if (self.cols >= 7 and col >= 2 and col <= 7) return .quit;
        if (self.cols >= 20 and col >= 11 and col <= 20) return .cancel;
        return null;
    }
};

/// Kitty images below this threshold are covered by non-default text backgrounds.
/// Direct game z values occupy a reserved band, retaining their relative order.
pub fn contentZ(z: i32) i32 {
    return -1_610_612_736 + std.math.clamp(z, -536_870_912, 536_870_911);
}

test "command chrome covers the last row without refitting content" {
    var content = layout.PresentationLayout{};
    content.addRegion(.{ .kind = .sdl_window, .tty_rect = .{ .col = 1, .row = 1, .w = 80, .h = 24 }, .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 200 } });
    const menu = Snapshot{ .active = true, .cols = 80, .rows = 24 };
    const combined = menu.withChrome(content);
    try std.testing.expectEqualDeep(content.regions[0], combined.regions[0]);
    try std.testing.expectEqual(@as(usize, 2), combined.len);
    try std.testing.expectEqual(layout.CellRect{ .col = 1, .row = 24, .w = 80, .h = 1 }, combined.regions[1].tty_rect);
    try std.testing.expect(combined.regions[1].z > combined.regions[0].z);
    const inactive = (Snapshot{}).withChrome(content);
    try std.testing.expectEqual(content.len, inactive.len);
    try std.testing.expectEqualDeep(content.regions[0], inactive.regions[0]);
}

test "command menu clips safely and only offers visible click targets" {
    const menu = Snapshot{ .active = true, .cols = 80, .rows = 24, .binding = 'a' };
    var buffer: [80]u8 = undefined;
    const line = menu.line(&buffer);
    try std.testing.expectEqual(@as(usize, 80), line.len);
    try std.testing.expect(std.mem.indexOf(u8, line, "^A Literal") != null);
    try std.testing.expectEqual(Action.quit, menu.hit(3, 24).?);
    try std.testing.expectEqual(Action.cancel, menu.hit(13, 24).?);
    try std.testing.expect(menu.hit(3, 23) == null);
    try std.testing.expect((Snapshot{ .active = true, .cols = 4, .rows = 24 }).hit(3, 24) == null);
    try std.testing.expectEqual(@as(usize, 0), menu.line(buffer[0..0]).len);
}

test "direct content stays below text backgrounds in its original order" {
    try std.testing.expect(contentZ(0) < contentZ(100));
    try std.testing.expectEqual(@as(i32, 100), contentZ(100) - contentZ(0));
    try std.testing.expect(contentZ(std.math.maxInt(i32)) < @divExact(std.math.minInt(i32), 2));
    try std.testing.expectEqual(std.math.minInt(i32), contentZ(std.math.minInt(i32)));
}

test "menu text clips at each terminal width and pads the whole row" {
    const cases = .{
        .{ Snapshot{}, " q Quit | Esc Return | ^] Literal" },
        .{ Snapshot{ .hint = true }, " q Quit | Esc Return | ^] Literal | Unknown key" },
        .{ Snapshot{ .quitting = true }, " Quitting... waiting for app" },
        .{ Snapshot{ .desktop = true }, " q Quit | Esc Return | n Launch | Tab Next | Q Quit WM | hjkl Move | HJKL Resize | c/t Layout | ^] Literal" },
        .{ Snapshot{ .desktop = true, .hint = true }, " q Quit | Esc Return | Unknown key" },
    };
    inline for (cases) |case| {
        var snapshot = case[0];
        var buffer: [300]u8 = undefined;
        for (0..buffer.len + 1) |width| {
            snapshot.cols = @intCast(width);
            const line = snapshot.line(&buffer);
            try std.testing.expectEqual(width, line.len);
            const visible = @min(width, case[1].len);
            try std.testing.expectEqualStrings(case[1][0..visible], line[0..visible]);
            for (line[visible..]) |char| try std.testing.expectEqual(@as(u8, ' '), char);
        }
    }
}
