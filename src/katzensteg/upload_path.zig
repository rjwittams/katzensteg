const std = @import("std");
const system_io = @import("platform");

pub const rotating_file_count = 256;

pub fn makeUploadPath(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-katzensteg-{d}.rgba", .{ system_io.fs.tempDir(), system_io.process.id() });
}

pub fn makeRotatingFilePath(allocator: std.mem.Allocator, base_path: []const u8, index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, index });
}

pub fn deleteBasePath(io: std.Io, path: []const u8) void {
    system_io.fs.deleteFileAbsolute(io, path) catch {};
}

pub fn deleteRotatingFileWholeArtifacts(io: std.Io, allocator: std.mem.Allocator, base_path: []const u8) void {
    deleteBasePath(io, base_path);
    var index: usize = 0;
    while (index < rotating_file_count) : (index += 1) {
        const path = makeRotatingFilePath(allocator, base_path, index) catch continue;
        deleteBasePath(io, path);
        allocator.free(path);
    }
}
