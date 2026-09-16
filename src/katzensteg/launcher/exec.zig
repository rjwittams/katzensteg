const std = @import("std");
const system_io = @import("platform");
const profiles = @import("../launcher_profiles.zig");

pub fn ensureSeedFiles(io: std.Io, allocator: std.mem.Allocator, seed_files: []const profiles.SeedFile) !void {
    for (seed_files) |entry| {
        if (try fileExists(io, entry.path)) continue;
        const bytes = if (entry.content) |content|
            content
        else blk: {
            const source = entry.source orelse return error.InvalidSeedFile;
            break :blk try readWholeFile(io, allocator, source);
        };
        defer if (entry.content == null) allocator.free(bytes);
        const file = try createOutputFile(io, entry.path);
        defer file.close();
        try file.writeAll(bytes);
    }
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    const file = if (std.fs.path.isAbsolute(path))
        system_io.fs.openFileAbsolute(io, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    else
        system_io.fs.cwd(io).openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    file.close();
    return true;
}

fn createOutputFile(io: std.Io, path: []const u8) !system_io.fs.File {
    if (std.fs.path.dirname(path)) |parent| {
        try system_io.fs.cwd(io).makePath(parent);
    }
    if (std.fs.path.isAbsolute(path)) return system_io.fs.createFileAbsolute(io, path, .{ .truncate = true, .read = false });
    return system_io.fs.cwd(io).createFile(path, .{ .truncate = true, .read = false });
}

pub fn readWholeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try system_io.fs.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close();
        return file.readToEndAlloc(allocator, 1024 * 1024);
    }
    return system_io.fs.cwd(io).readFileAlloc(allocator, path, 1024 * 1024);
}

test "launcher exec writes inline seed file content" {
    const io = std.testing.io;
    const path = "/tmp/katzensteg-launcher-exec-seed-test.json";
    system_io.fs.deleteFileAbsolute(io, path) catch {};
    defer system_io.fs.deleteFileAbsolute(io, path) catch {};

    const seed_files = &[_]profiles.SeedFile{
        .{ .path = path, .content = "{\"ok\":true}\n" },
    };

    try ensureSeedFiles(io, std.testing.allocator, seed_files);

    const bytes = try readWholeFile(io, std.testing.allocator, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", bytes);
}
