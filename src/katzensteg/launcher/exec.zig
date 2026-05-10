const std = @import("std");
const profiles = @import("../launcher_profiles.zig");

pub fn ensureSeedFiles(allocator: std.mem.Allocator, seed_files: []const profiles.SeedFile) !void {
    for (seed_files) |entry| {
        if (try fileExists(entry.path)) continue;
        const bytes = if (entry.content) |content|
            content
        else blk: {
            const source = entry.source orelse return error.InvalidSeedFile;
            break :blk try readWholeFile(allocator, source);
        };
        defer if (entry.content == null) allocator.free(bytes);
        const file = try createOutputFile(entry.path);
        defer file.close();
        try file.writeAll(bytes);
    }
}

fn fileExists(path: []const u8) !bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    else
        std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    file.close();
    return true;
}

fn createOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true, .read = false });
    return std.fs.cwd().createFile(path, .{ .truncate = true, .read = false });
}

pub fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        defer file.close();
        return file.readToEndAlloc(allocator, 1024 * 1024);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

test "launcher exec writes inline seed file content" {
    const path = "/tmp/katzensteg-launcher-exec-seed-test.json";
    std.fs.deleteFileAbsolute(path) catch {};
    defer std.fs.deleteFileAbsolute(path) catch {};

    const seed_files = &[_]profiles.SeedFile{
        .{ .path = path, .content = "{\"ok\":true}\n" },
    };

    try ensureSeedFiles(std.testing.allocator, seed_files);

    const bytes = try readWholeFile(std.testing.allocator, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", bytes);
}
