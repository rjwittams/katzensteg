const std = @import("std");

pub const DirectTty = struct {
    file: std.fs.File,
    original_termios: std.posix.termios,
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,

    pub fn init() !DirectTty {
        const file = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
        const original_termios = try std.posix.tcgetattr(file.handle);

        var raw = original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(file.handle, .FLUSH, raw);

        var writer = file.writerStreaming(&.{});
        try writer.interface.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
        try writer.interface.flush();

        const size = querySize(file.handle);
        return .{ .file = file, .original_termios = original_termios, .rows = size.rows, .cols = size.cols, .pixel_width = size.pixel_width, .pixel_height = size.pixel_height };
    }

    pub fn deinit(self: *DirectTty) void {
        std.posix.tcsetattr(self.file.handle, .FLUSH, self.original_termios) catch {};
        var writer = self.file.writerStreaming(&.{});
        writer.interface.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        writer.interface.flush() catch {};
        self.file.close();
    }

    fn querySize(fd: std.posix.fd_t) struct { rows: u16, cols: u16, pixel_width: u16, pixel_height: u16 } {
        var wsz: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (rc == 0 and wsz.row > 0 and wsz.col > 0) {
            return .{ .rows = wsz.row, .cols = wsz.col, .pixel_width = wsz.xpixel, .pixel_height = wsz.ypixel };
        }
        return .{ .rows = 24, .cols = 80, .pixel_width = 0, .pixel_height = 0 };
    }
};
