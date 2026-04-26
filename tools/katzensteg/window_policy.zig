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

pub fn defaultPolicy() WindowPresentationPolicy {
    return .mirror;
}

pub fn parse(value: []const u8) ?WindowPresentationPolicy {
    if (std.mem.eql(u8, value, "mirror")) return .mirror;
    if (std.mem.eql(u8, value, "terminal_only")) return .terminal_only;
    if (std.mem.eql(u8, value, "real_only")) return .real_only;
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
