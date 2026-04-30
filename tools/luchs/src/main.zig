const std = @import("std");

const CliOptions = struct {
    html_path: []const u8,
};

fn parseArgs(args: []const []const u8) !CliOptions {
    if (args.len != 2) return error.Usage;
    return .{ .html_path = args[1] };
}

test "luchs requires one html path" {
    try std.testing.expectError(error.Usage, parseArgs(&.{"luchs"}));
    const opts = try parseArgs(&.{ "luchs", "tools/luchs/testdata/static.html" });
    try std.testing.expectEqualStrings("tools/luchs/testdata/static.html", opts.html_path);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    _ = try parseArgs(args);
}
