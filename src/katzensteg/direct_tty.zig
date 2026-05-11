const std = @import("std");

pub const DirectTty = struct {
    const Size = struct { rows: u16, cols: u16, pixel_width: u16, pixel_height: u16 };

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

    pub fn refreshSize(self: *DirectTty) bool {
        return self.applySize(querySize(self.file.handle));
    }

    pub fn deinit(self: *DirectTty) void {
        self.disableInputCapture() catch {};
        self.drainInput();
        self.clearGraphics() catch {};
        std.posix.tcsetattr(self.file.handle, .FLUSH, self.original_termios) catch {};
        var writer = self.file.writerStreaming(&.{});
        writer.interface.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        writer.interface.writeAll(kittyGraphicsClearSequence()) catch {};
        writer.interface.flush() catch {};
        self.file.close();
    }

    pub fn enableInputCapture(self: *DirectTty) !void {
        var writer = self.file.writerStreaming(&.{});
        // Disable the legacy urxvt/SGR-pixel mouse-encoding modes (?1015, ?1016)
        // before enabling SGR (?1006) and tracking modes (?1000/1002/1003).
        // Terminals can have multiple encoders enabled simultaneously; resetting
        // the alternates first avoids stray reports in non-SGR formats.
        try writer.interface.writeAll("\x1b[?1015l\x1b[?1016l\x1b[?1006h\x1b[?1000h\x1b[?1002h\x1b[?1003h");
        try writer.interface.flush();
    }

    pub fn disableInputCapture(self: *DirectTty) !void {
        var writer = self.file.writerStreaming(&.{});
        try writer.interface.writeAll("\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?1004l");
        try writer.interface.flush();
    }

    pub fn clearGraphics(self: *DirectTty) !void {
        var writer = self.file.writerStreaming(&.{});
        try writer.interface.writeAll(kittyGraphicsClearSequence());
        try writer.interface.flush();
    }

    fn drainInput(self: *DirectTty) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.file.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return,
            };
            if (n == 0 or n < buf.len) return;
        }
    }

    fn applySize(self: *DirectTty, size: Size) bool {
        const changed = self.rows != size.rows or self.cols != size.cols or self.pixel_width != size.pixel_width or self.pixel_height != size.pixel_height;
        self.rows = size.rows;
        self.cols = size.cols;
        self.pixel_width = size.pixel_width;
        self.pixel_height = size.pixel_height;
        return changed;
    }

    fn querySize(fd: std.posix.fd_t) Size {
        var wsz: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (rc == 0 and wsz.row > 0 and wsz.col > 0) {
            return .{ .rows = wsz.row, .cols = wsz.col, .pixel_width = wsz.xpixel, .pixel_height = wsz.ypixel };
        }
        return .{ .rows = 24, .cols = 80, .pixel_width = 0, .pixel_height = 0 };
    }
};

fn kittyGraphicsClearSequence() []const u8 {
    // Delete all visible kitty graphics placements and request image data cleanup.
    // This is intentionally broad teardown cleanup; a future launcher can do a
    // second reset after abnormal exits, and a future protocol layer can make this
    // namespace/image-id scoped.
    return "\x1b_Gq=2,a=d,d=A;\x1b\\";
}

test "kitty graphics clear sequence frees visible placements" {
    try std.testing.expectEqualStrings("\x1b_Gq=2,a=d,d=A;\x1b\\", kittyGraphicsClearSequence());
}

test "direct tty size update reports only real geometry changes" {
    var tty: DirectTty = undefined;
    tty.rows = 24;
    tty.cols = 80;
    tty.pixel_width = 800;
    tty.pixel_height = 480;

    try std.testing.expect(!tty.applySize(.{ .rows = 24, .cols = 80, .pixel_width = 800, .pixel_height = 480 }));
    try std.testing.expect(tty.applySize(.{ .rows = 40, .cols = 120, .pixel_width = 1200, .pixel_height = 800 }));
    try std.testing.expectEqual(@as(u16, 40), tty.rows);
    try std.testing.expectEqual(@as(u16, 120), tty.cols);
    try std.testing.expectEqual(@as(u16, 1200), tty.pixel_width);
    try std.testing.expectEqual(@as(u16, 800), tty.pixel_height);
}
