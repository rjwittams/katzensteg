const std = @import("std");

pub const WindowPresentationPolicy = enum {
    mirror,
    terminal_only,
    real_only,

    pub fn terminalEnabled(self: WindowPresentationPolicy) bool {
        return switch (self) {
            .mirror, .terminal_only => true,
            .real_only => false,
        };
    }

    pub fn realWindowEnabled(self: WindowPresentationPolicy) bool {
        _ = self;
        return true;
    }

    pub fn realRenderEnabled(self: WindowPresentationPolicy) bool {
        return switch (self) {
            .mirror, .real_only => true,
            .terminal_only => false,
        };
    }
};

pub const RealWindowAction = enum {
    none,
    show,
    hide,
    minimize,
    restore,
};

pub const RealWindowVisibility = enum {
    show,
    hide,
    minimize,

    pub fn createAction(self: RealWindowVisibility) RealWindowAction {
        return switch (self) {
            .show => .show,
            .hide => .hide,
            .minimize => .minimize,
        };
    }

    pub fn showAction(self: RealWindowVisibility) RealWindowAction {
        return switch (self) {
            .show => .show,
            .hide => .hide,
            .minimize => .minimize,
        };
    }

    pub fn restoreAction(self: RealWindowVisibility) RealWindowAction {
        return switch (self) {
            .show => .restore,
            .hide => .hide,
            .minimize => .minimize,
        };
    }
};

pub fn defaultPolicy() WindowPresentationPolicy {
    return .mirror;
}

pub fn defaultRealWindowVisibility() RealWindowVisibility {
    return .show;
}

pub fn parse(value: []const u8) ?WindowPresentationPolicy {
    if (std.mem.eql(u8, value, "mirror")) return .mirror;
    if (std.mem.eql(u8, value, "terminal_only")) return .terminal_only;
    if (std.mem.eql(u8, value, "real_only")) return .real_only;
    return null;
}

pub fn parseRealWindowVisibility(value: []const u8) ?RealWindowVisibility {
    if (std.mem.eql(u8, value, "show")) return .show;
    if (std.mem.eql(u8, value, "hide")) return .hide;
    if (std.mem.eql(u8, value, "minimize")) return .minimize;
    return null;
}

test "window policy predicates describe rendering routes" {
    try std.testing.expectEqual(WindowPresentationPolicy.mirror, defaultPolicy());
    try std.testing.expect(parse("mirror").?.terminalEnabled());
    try std.testing.expect(parse("mirror").?.realWindowEnabled());
    try std.testing.expect(parse("mirror").?.realRenderEnabled());
    try std.testing.expect(parse("terminal_only").?.terminalEnabled());
    try std.testing.expect(parse("terminal_only").?.realWindowEnabled());
    try std.testing.expect(!parse("terminal_only").?.realRenderEnabled());
    try std.testing.expect(!parse("real_only").?.terminalEnabled());
    try std.testing.expect(parse("real_only").?.realWindowEnabled());
    try std.testing.expect(parse("real_only").?.realRenderEnabled());
    try std.testing.expect(parse("nonsense") == null);
}

test "real window visibility parses requested SDL action" {
    try std.testing.expectEqual(RealWindowVisibility.show, defaultRealWindowVisibility());
    try std.testing.expectEqual(RealWindowVisibility.show, parseRealWindowVisibility("show").?);
    try std.testing.expectEqual(RealWindowVisibility.hide, parseRealWindowVisibility("hide").?);
    try std.testing.expectEqual(RealWindowVisibility.minimize, parseRealWindowVisibility("minimize").?);
    try std.testing.expect(parseRealWindowVisibility("nonsense") == null);
    try std.testing.expectEqual(RealWindowAction.show, RealWindowVisibility.show.createAction());
    try std.testing.expectEqual(RealWindowAction.hide, RealWindowVisibility.hide.createAction());
    try std.testing.expectEqual(RealWindowAction.minimize, RealWindowVisibility.minimize.createAction());
    try std.testing.expectEqual(RealWindowAction.hide, RealWindowVisibility.hide.showAction());
    try std.testing.expectEqual(RealWindowAction.show, RealWindowVisibility.show.showAction());
    try std.testing.expectEqual(RealWindowAction.restore, RealWindowVisibility.show.restoreAction());
}
