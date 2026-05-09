const std = @import("std");

pub const rotating_file_count = 256;

pub fn makeUploadPath(allocator: std.mem.Allocator) ![]u8 {
    const tmpdir = if (std.c.getenv("TMPDIR")) |value| std.mem.span(value) else "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-katzensteg-{d}.rgba", .{ tmpdir, std.c.getpid() });
}

pub fn makeRotatingFilePath(allocator: std.mem.Allocator, base_path: []const u8, index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, index });
}

pub fn deleteBasePath(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

pub fn deleteRotatingFileWholeArtifacts(allocator: std.mem.Allocator, base_path: []const u8) void {
    deleteBasePath(base_path);
    var index: usize = 0;
    while (index < rotating_file_count) : (index += 1) {
        const path = makeRotatingFilePath(allocator, base_path, index) catch continue;
        deleteBasePath(path);
        allocator.free(path);
    }
}
