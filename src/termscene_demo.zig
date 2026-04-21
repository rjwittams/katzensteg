const std = @import("std");
const termscene = @import("termscene/mod.zig");

const types = termscene.types;
const scene_mod = termscene.scene;
const kitty_mod = termscene.kitty;

fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

fn makeGradient(allocator: std.mem.Allocator, w: i32, h: i32, a_bias: u8) ![]u8 {
    const buf = try allocator.alloc(u8, @as(usize, @intCast(w * h * 4)));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx: usize = @intCast((y * w + x) * 4);
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w - 1, 1)));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h - 1, 1)));
            buf[idx] = @intFromFloat(255.0 * fx);
            buf[idx + 1] = @intFromFloat(255.0 * fy);
            buf[idx + 2] = @intFromFloat(255.0 * (1.0 - fx));
            const checker = if (@mod(@divTrunc(x, 8) + @divTrunc(y, 8), 2) == 0) a_bias else 255;
            buf[idx + 3] = checker;
        }
    }
    return buf;
}

fn buildFrame(engine: *scene_mod.SceneEngine, tick: usize) !void {
    const move_x: i32 = 3 + @as(i32, @intCast(@mod(tick, 12)));
    const atlas_frame_x: i32 = if (@mod(tick / 10, 2) == 0) 0 else 32;
    const show_extra = @mod(tick / 20, 2) == 0;

    engine.beginScene();
    try engine.text(.{
        .key = types.NodeKey.text(1, 1),
        .pos = .{ .col = 1, .row = 1 },
        .content = "termscene demo - animated add/update/remove",
        .style = .{ .fg = .{ .r = 180, .g = 230, .b = 255 } },
    });

    var status_buf: [96]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "tick={d}  sprite move/crop add/remove text diff  q quits", .{tick});
    try engine.text(.{
        .key = types.NodeKey.text(1, 2),
        .pos = .{ .col = 1, .row = 2 },
        .content = status,
        .style = .{ .fg = .{ .r = 220, .g = 220, .b = 220 } },
    });

    try engine.sprite(.{
        .key = types.NodeKey.sprite(1, 100),
        .image = @enumFromInt(3001),
        .source_rect = .{ .x = 0, .y = 0, .w = 64, .h = 32 },
        .dest_rect = .{ .col = move_x, .row = 6, .w = 14, .h = 7 },
        .z = 1,
    });
    try engine.sprite(.{
        .key = types.NodeKey.sprite(1, 101),
        .image = @enumFromInt(3002),
        .source_rect = .{ .x = 0, .y = 0, .w = 64, .h = 32 },
        .dest_rect = .{ .col = 24, .row = 6, .w = 14, .h = 7 },
        .z = 1,
    });
    try engine.sprite(.{
        .key = types.NodeKey.sprite(1, 102),
        .image = @enumFromInt(3003),
        .source_rect = .{ .x = atlas_frame_x, .y = 0, .w = 32, .h = 32 },
        .dest_rect = .{ .col = 45, .row = 6, .w = 10, .h = 4 },
        .z = 1,
    });

    if (show_extra) {
        try engine.sprite(.{
            .key = types.NodeKey.sprite(1, 103),
            .image = @enumFromInt(3003),
            .source_rect = .{ .x = 32, .y = 32, .w = 32, .h = 32 },
            .dest_rect = .{ .col = 24, .row = 16, .w = 14, .h = 7 },
            .z = 2,
        });
        try engine.text(.{
            .key = types.NodeKey.text(1, 3),
            .pos = .{ .col = 24, .row = 15 },
            .content = "extra sprite visible",
            .style = .{ .fg = .{ .r = 255, .g = 210, .b = 120 } },
        });
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    var writer = stdout_file.deprecatedWriter();
    const stdin_fd = std.fs.File.stdin().handle;
    const original_termios = try std.posix.tcgetattr(stdin_fd);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    if (!try kitty_mod.detectGraphicsSupport(allocator, writer)) {
        std.debug.print("termscene-demo: kitty graphics protocol not detected.\n", .{});
        return;
    }

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    var backend = kitty_mod.Backend.init(allocator, stdout_file);
    defer backend.deinit();
    var engine = scene_mod.SceneEngine.init(allocator);
    defer engine.deinit();

    const img1 = try makeGradient(allocator, 64, 32, 110);
    defer allocator.free(img1);
    const img2 = try makeGradient(allocator, 64, 32, 180);
    defer allocator.free(img2);
    const atlas = try makeGradient(allocator, 96, 64, 220);
    defer allocator.free(atlas);

    try clearScreen(writer);
    try backend.registerRawImage(3001, img1, 64, 32);
    try backend.registerRawImage(3002, img2, 64, 32);
    try backend.registerRawImage(3003, atlas, 96, 64);

    var tick: usize = 0;
    var reader = std.fs.File.stdin().deprecatedReader();
    var buf: [16]u8 = undefined;
    while (true) {
        try buildFrame(&engine, tick);
        try engine.diff();
        try backend.applySpriteOps(engine.sprite_ops.items);
        try backend.applyTextOps(engine.text_ops.items);
        try engine.commit();
        tick += 1;

        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            for (buf[0..n]) |ch| {
                if (ch == 'q' or ch == 'Q') return;
            }
        }
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }
}
