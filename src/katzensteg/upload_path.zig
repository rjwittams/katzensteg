const std = @import("std");

pub fn makeUploadPath(allocator: std.mem.Allocator) ![]u8 {
    const tmpdir = if (std.c.getenv("TMPDIR")) |value| std.mem.span(value) else "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-katzensteg-{d}.rgba", .{ tmpdir, std.c.getpid() });
}
