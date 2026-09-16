const std = @import("std");
const system_io = @import("platform");
const termscene = @import("termscene");

const kitty = termscene.kitty;
const protocol = kitty.protocol;

const red_image_id: u32 = 9001;
const blue_image_id: u32 = 9002;

const ActivePlacement = struct {
    image_id: u32,
    placement_id: u32,
};

fn querySize(fd: std.posix.fd_t) struct { rows: u16, cols: u16 } {
    var wsz: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0 and wsz.row > 0 and wsz.col > 0) return .{ .rows = wsz.row, .cols = wsz.col };
    return .{ .rows = 24, .cols = 80 };
}

fn writeStatus(out: *std.Io.Writer, frame: usize, active: ActivePlacement, rows: u16, cols: u16) !void {
    try out.writeAll("\x1b[0m");
    try protocol.moveCursor(out, 1, 1);
    try out.print("kitty-placement-repro  q quits  frame={d}  image={d}  placement={d}", .{ frame, active.image_id, active.placement_id });
    try protocol.moveCursor(out, 2, 1);
    try out.print("strategy: delete exact old (image, placement) pair, then place new image with fresh placement id  terminal={d}x{d}", .{ cols, rows });
}

pub fn main(process_init: std.process.Init) !void {
    const io = process_init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const stdout_file = system_io.fs.File.stdout(io);
    var writer_state = stdout_file.writerStreaming(&.{});
    const writer = &writer_state.interface;
    const stdin_fd = system_io.fs.File.stdin(io).handle;
    const original_termios = try system_io.posix.tcgetattr(stdin_fd);
    defer system_io.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};

    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try system_io.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    if (!try kitty.detectGraphicsSupport(io, allocator, writer)) {
        std.debug.print("kitty-placement-repro: kitty graphics protocol not detected.\n", .{});
        return;
    }

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    const red = [_]u8{ 255, 40, 40, 255 };
    const blue = [_]u8{ 40, 80, 255, 255 };
    try protocol.writeTransmitRgba(writer, red_image_id, &red, 1, 1);
    try protocol.writeTransmitRgba(writer, blue_image_id, &blue, 1, 1);

    const size = querySize(stdout_file.handle);
    var placement_counter: u32 = 1;
    var active: ?ActivePlacement = null;
    var frame: usize = 0;
    var reader = system_io.fs.File.stdin(io);
    var buf: [16]u8 = undefined;

    while (true) {
        const next_image_id = if (@mod(frame, 2) == 0) red_image_id else blue_image_id;
        const next = ActivePlacement{ .image_id = next_image_id, .placement_id = placement_counter };
        placement_counter += 1;

        if (active) |old| {
            try protocol.writeDeleteExactPlacement(writer, .{ .image_id = old.image_id, .placement_id = old.placement_id });
        }

        try protocol.writePlace(writer, 3, 1, .{
            .image_id = next.image_id,
            .placement_id = next.placement_id,
            .cols = size.cols,
            .rows = @max(1, size.rows - 2),
            .src_x = 0,
            .src_y = 0,
            .src_w = 1,
            .src_h = 1,
            .z = -100,
        });
        active = next;
        try writeStatus(writer, frame, next, size.rows, size.cols);

        frame += 1;

        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            for (buf[0..n]) |ch| {
                if (ch == 'q' or ch == 'Q') return;
            }
        }
        system_io.time.sleep(300 * std.time.ns_per_ms);
    }
}
