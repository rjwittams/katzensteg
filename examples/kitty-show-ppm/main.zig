const std = @import("std");
const termscene = @import("termscene");

const kitty = termscene.kitty;
const protocol = kitty.protocol;

const image_id: u32 = 9201;
const placement_id: u32 = 1;

fn querySize(fd: std.posix.fd_t) struct { rows: u16, cols: u16 } {
    var wsz: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0 and wsz.row > 0 and wsz.col > 0) return .{ .rows = wsz.row, .cols = wsz.col };
    return .{ .rows = 24, .cols = 80 };
}

fn skipWsAndComments(data: []const u8, index: *usize) void {
    while (index.* < data.len) {
        const ch = data[index.*];
        if (ch == '#') {
            while (index.* < data.len and data[index.*] != '\n') index.* += 1;
            continue;
        }
        if (std.ascii.isWhitespace(ch)) {
            index.* += 1;
            continue;
        }
        break;
    }
}

fn nextToken(data: []const u8, index: *usize) ![]const u8 {
    skipWsAndComments(data, index);
    if (index.* >= data.len) return error.UnexpectedEof;
    const start = index.*;
    while (index.* < data.len and !std.ascii.isWhitespace(data[index.*]) and data[index.*] != '#') index.* += 1;
    return data[start..index.*];
}

fn loadPpmRgba(allocator: std.mem.Allocator, path: []const u8) !struct { rgba: []u8, w: i32, h: i32 } {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    errdefer allocator.free(bytes);

    var index: usize = 0;
    const magic = try nextToken(bytes, &index);
    if (!std.mem.eql(u8, magic, "P6")) return error.UnsupportedPpm;

    const w_tok = try nextToken(bytes, &index);
    const h_tok = try nextToken(bytes, &index);
    const max_tok = try nextToken(bytes, &index);
    const w = try std.fmt.parseInt(i32, w_tok, 10);
    const h = try std.fmt.parseInt(i32, h_tok, 10);
    const max = try std.fmt.parseInt(i32, max_tok, 10);
    if (max != 255) return error.UnsupportedPpm;

    skipWsAndComments(bytes, &index);
    const rgb = bytes[index..];
    const expected_rgb_len: usize = @intCast(w * h * 3);
    if (rgb.len < expected_rgb_len) return error.UnexpectedEof;

    const rgba = try allocator.alloc(u8, @intCast(w * h * 4));
    errdefer allocator.free(rgba);
    var si: usize = 0;
    var di: usize = 0;
    while (si < expected_rgb_len) : ({ si += 3; di += 4; }) {
        rgba[di + 0] = rgb[si + 0];
        rgba[di + 1] = rgb[si + 1];
        rgba[di + 2] = rgb[si + 2];
        rgba[di + 3] = 255;
    }

    allocator.free(bytes);
    return .{ .rgba = rgba, .w = w, .h = h };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("usage: kitty-show-ppm <path-to-p6-ppm>\n", .{});
        return;
    }

    const loaded = try loadPpmRgba(allocator, args[1]);
    defer allocator.free(loaded.rgba);

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

    if (!try kitty.detectGraphicsSupport(allocator, writer)) {
        std.debug.print("kitty-show-ppm: kitty graphics protocol not detected.\n", .{});
        return;
    }

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer writer.writeAll("\x1b[0m\x1b[?25h\x1b_Ga=d,d=I,i=9201;\x1b\\\x1b[?1049l") catch {};

    const size = querySize(stdout_file.handle);
    try protocol.writeTransmitRgba(writer, image_id, loaded.rgba, loaded.w, loaded.h);
    try protocol.writePlace(writer, 1, 1, .{
        .image_id = image_id,
        .placement_id = placement_id,
        .cols = size.cols,
        .rows = size.rows,
        .src_x = 0,
        .src_y = 0,
        .src_w = loaded.w,
        .src_h = loaded.h,
        .z = 100,
    });
    try protocol.moveCursor(writer, 1, 1);
    try writer.print("kitty-show-ppm  {s}  {d}x{d}  q quits", .{ args[1], loaded.w, loaded.h });

    var reader = std.fs.File.stdin().deprecatedReader();
    var buf: [16]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            for (buf[0..n]) |ch| {
                if (ch == 'q' or ch == 'Q') return;
            }
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}
