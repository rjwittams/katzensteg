const std = @import("std");
const attach_protocol = @import("attach_protocol.zig");
const terminal_batch_applier = @import("terminal_batch_applier.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;

pub const AttachOptions = struct {
    window_id: []const u8 = "main",
    rect_cells: render_batch_protocol.PresentationRectCells,
    image_ids: render_batch_protocol.IdRange = .{ .start = 100000, .end = 199999 },
    placement_ids: render_batch_protocol.IdRange = .{ .start = 200000, .end = 299999 },
};

pub fn writeInitialControl(writer: anytype, options: AttachOptions) !void {
    try writer.writeAll("{\"type\":\"hello\",\"protocol\":\"katzensteg.embed_jsonl\",\"version\":1}\n");
    try writer.writeAll("{\"type\":\"attach\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    try writer.writeAll(",\"rect_cells\":{");
    try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
    try writer.writeAll("},\"aspect\":\"contain\",\"id_ranges\":{\"image\":[[");
    try writer.print("{d},{d}", .{ options.image_ids.start, options.image_ids.end });
    try writer.writeAll("]],\"placement\":[[");
    try writer.print("{d},{d}", .{ options.placement_ids.start, options.placement_ids.end });
    try writer.writeAll("]]}}\n");
}

pub fn runExec(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    var tty = try DirectTty.init();
    defer tty.deinit();

    return runExecWithWriter(allocator, argv, tty.file.deprecatedWriter(), .{
        .rect_cells = .{
            .row = 1,
            .col = 1,
            .rows = tty.rows,
            .cols = tty.cols,
        },
    });
}

pub fn runExecWithWriter(allocator: std.mem.Allocator, argv: []const []const u8, writer: anytype, options: AttachOptions) !u8 {
    if (argv.len == 0) return 64;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (child.stdin) |stdin_file| {
        child.stdin = null;
        try writeInitialControl(stdin_file.deprecatedWriter(), options);
        stdin_file.close();
    }

    if (child.stdout) |stdout_file| {
        child.stdout = null;
        try applyPeerStdout(allocator, stdout_file, writer);
    }

    return childTermExitCode(try child.wait());
}

fn applyPeerStdout(allocator: std.mem.Allocator, stdout_file: std.fs.File, writer: anytype) !void {
    defer stdout_file.close();
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stdout_file.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                try applyPeerLine(allocator, writer, line.items);
                line.clearRetainingCapacity();
            } else if (byte != '\r') {
                try line.append(allocator, byte);
            }
        }
    }
    if (line.items.len > 0) try applyPeerLine(allocator, writer, line.items);
}

fn applyPeerLine(allocator: std.mem.Allocator, writer: anytype, line: []const u8) !void {
    var batch = attach_protocol.parseFrameBatch(allocator, line) catch return;
    defer batch.deinit(allocator);
    try terminal_batch_applier.applyFrameBatch(writer, .{
        .deletes = batch.groups.deletes,
        .uploads = batch.groups.uploads,
        .placements = batch.groups.placements,
        .after = batch.groups.after,
    });
}

fn childTermExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(@min(code, 255)),
        .Signal, .Stopped, .Unknown => 1,
    };
}

test "attach host writes hello and attach control messages" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeInitialControl(out.writer(std.testing.allocator), .{
        .window_id = "main",
        .rect_cells = .{ .row = 1, .col = 1, .rows = 24, .cols = 80 },
        .image_ids = .{ .start = 100000, .end = 199999 },
        .placement_ids = .{ .start = 200000, .end = 299999 },
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"attach\"") != null);
}

test "attach host exec loop applies fake peer frame batch" {
    const script_path = "/tmp/katzensteg-attach-fake-peer.py";
    {
        const file = try std.fs.createFileAbsolute(script_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            "import sys\n" ++ "sys.stdin.read()\n" ++ "sys.stdout.write('{\"type\":\"frame_batch\",\"window_id\":\"main\",\"seq\":1,\"groups\":{\"deletes\":[\"D\"],\"uploads\":[\"U\"],\"placements\":[\"P\"],\"after\":[\"A\"]}}\\n')\n" ++ "sys.stdout.flush()\n",
        );
    }
    defer std.fs.deleteFileAbsolute(script_path) catch {};

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const code = try runExecWithWriter(std.testing.allocator, &.{ "python3", script_path }, out.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 1, .col = 1, .rows = 24, .cols = 80 },
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("DUPA", out.items);
}
