const std = @import("std");
const terminal_keys = @import("terminal_keys.zig");
const system_io = @import("platform");

pub const DirectTty = struct {
    const Size = struct { rows: u16, cols: u16, pixel_width: u16, pixel_height: u16 };

    /// Output: graphics, text and terminal queries go here.
    file: system_io.fs.File,
    /// Input: key and mouse reports and query replies. The same descriptor as
    /// `file` for POSIX `/dev/tty`; the console input buffer on Windows.
    input: system_io.fs.File,
    raw_mode: system_io.terminal.RawMode,
    rows: u16,
    cols: u16,
    pixel_width: u16,
    pixel_height: u16,
    /// Kitty keyboard protocol flags the terminal confirmed in reply to the
    /// query sent by `enableInputCapture`; zero on terminals without it.
    /// The tty reader records the reply here so hosts can pass it on.
    keyboard_protocol_flags: u32 = 0,
    /// Units of SGR mouse reports the terminal confirmed by DECRQM after
    /// `enableInputCapture` asked for pixels; cells until then.
    mouse_units: terminal_keys.MouseUnits = .cell,

    pub fn init(io: std.Io) !DirectTty {
        const tty = try system_io.terminal.Tty.open(io);
        errdefer tty.close();
        const raw_mode = try system_io.terminal.RawMode.enter(tty.input, tty.output);
        errdefer raw_mode.restore();

        var writer = tty.output.writerStreaming(&.{});
        try writer.interface.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
        try writer.interface.flush();

        var size = querySize(tty.output);
        // Windows consoles report cells only; without pixels the layout
        // would treat cells as square and distort the image.
        if (!system_io.terminal.size_reports_pixels and size.pixel_width == 0) {
            if (system_io.terminal.queryPixelSize(tty, size.cols, size.rows, 250)) |pixels| {
                size.pixel_width = pixels.width;
                size.pixel_height = pixels.height;
            }
        }
        return .{ .file = tty.output, .input = tty.input, .raw_mode = raw_mode, .rows = size.rows, .cols = size.cols, .pixel_width = size.pixel_width, .pixel_height = size.pixel_height };
    }

    /// Both directions, for the terminal capability probes.
    pub fn terminal(self: *const DirectTty) system_io.terminal.Tty {
        return .{ .input = self.input, .output = self.file };
    }

    pub fn refreshSize(self: *DirectTty) bool {
        return self.applySize(querySize(self.file));
    }

    pub fn deinit(self: *DirectTty) void {
        self.disableInputCapture() catch {};
        self.drainInput();
        self.clearGraphics() catch {};
        self.raw_mode.restore();
        var writer = self.file.writerStreaming(&.{});
        writer.interface.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        writer.interface.writeAll(kittyGraphicsClearSequence()) catch {};
        writer.interface.flush() catch {};
        self.terminal().close();
    }

    pub fn enableInputCapture(self: *DirectTty) !void {
        var writer = self.file.writerStreaming(&.{});
        // Disable the legacy urxvt mouse encoding (?1015) before enabling SGR
        // (?1006) and tracking modes (?1000/1002/1003). Terminals can have
        // multiple encoders enabled simultaneously; resetting the alternate
        // first avoids stray reports in non-SGR formats.
        try writer.interface.writeAll("\x1b[?1015l\x1b[?1006h\x1b[?1000h\x1b[?1002h\x1b[?1003h");
        // SGR-pixel reports (?1016) when the terminal told us its pixel size,
        // so reports can be mapped back through the cell grid. DECRQM confirms
        // whether the terminal switched; without the mode it keeps reporting
        // cells and ignores both sequences.
        if (self.pixel_width > 0 and self.pixel_height > 0) try writer.interface.writeAll(sgr_pixel_mouse_enable ++ sgr_pixel_mouse_query);
        // Kitty keyboard protocol: disambiguate escapes, report event types,
        // alternate keys, all keys as escape codes, and associated text. The
        // flag stack is per screen, so this only affects the alternate screen
        // entered above. The query's reply tells the parser which flags took
        // effect; terminals without the protocol ignore both sequences.
        try writer.interface.writeAll(kitty_keyboard_push ++ kitty_keyboard_query ++ "\x1b[?2004h");
        try writer.interface.flush();
    }

    pub fn disableInputCapture(self: *DirectTty) !void {
        var writer = self.file.writerStreaming(&.{});
        try writer.interface.writeAll(kitty_keyboard_pop ++ "\x1b[?2004l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?1004l");
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
            const n = self.input.read(&buf) catch |err| switch (err) {
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

    fn querySize(output: system_io.fs.File) Size {
        const size = system_io.terminal.size(output) orelse return .{ .rows = 24, .cols = 80, .pixel_width = 0, .pixel_height = 0 };
        return .{ .rows = size.rows, .cols = size.cols, .pixel_width = size.xpixel, .pixel_height = size.ypixel };
    }
};

pub const kitty_keyboard_flags = 31;
pub const kitty_keyboard_push = std.fmt.comptimePrint("\x1b[>{d}u", .{kitty_keyboard_flags});
pub const kitty_keyboard_query = "\x1b[?u";
pub const kitty_keyboard_pop = "\x1b[<u";
pub const sgr_pixel_mouse_enable = "\x1b[?1016h";
pub const sgr_pixel_mouse_query = "\x1b[?1016$p";

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
