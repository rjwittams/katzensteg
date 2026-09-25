//! Terminal adapter for programs that draw on the terminal they run in: raw
//! input mode and window size. POSIX uses termios and TIOCGWINSZ; Windows uses
//! console modes with virtual-terminal input and output enabled.
const std = @import("std");
const builtin = @import("builtin");
const File = @import("fs.zig").File;

const is_windows = builtin.os.tag == .windows;
const win = @import("windows.zig");
const raw = @import("posix.zig");
const time = @import("time.zig");

/// The terminal this process draws on, independent of its standard streams:
/// `/dev/tty` on POSIX (one descriptor for both directions) and the attached
/// console on Windows (`CONIN$` for input, `CONOUT$` for output).
pub const Tty = struct {
    input: File,
    output: File,

    pub fn open(io: std.Io) !Tty {
        if (is_windows) {
            const input = try win.openConsole(.input);
            errdefer win.close(input);
            const output = try win.openConsole(.output);
            return .{ .input = .{ .handle = input, .io = io }, .output = .{ .handle = output, .io = io } };
        }
        const file = try @import("fs.zig").openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write });
        return .{ .input = file, .output = file };
    }

    /// Wraps one descriptor used in both directions, such as a pipe pair's
    /// end in tests or an already opened POSIX terminal.
    pub fn fromFile(file: File) Tty {
        return .{ .input = file, .output = file };
    }

    pub fn close(self: Tty) void {
        self.input.close();
        if (self.output.handle != self.input.handle) self.output.close();
    }
};

pub const Size = struct {
    rows: u16,
    cols: u16,
    /// Zero when the terminal does not report pixel dimensions.
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// Window size of the terminal behind `file`, or null when it is not a terminal.
pub fn size(file: File) ?Size {
    if (is_windows) {
        const window = win.windowSize(file.handle) orelse return null;
        return .{ .rows = window.rows, .cols = window.cols };
    }
    var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc != 0 or wsz.row == 0 or wsz.col == 0) return null;
    return .{ .rows = wsz.row, .cols = wsz.col, .xpixel = wsz.xpixel, .ypixel = wsz.ypixel };
}

/// Whether `size` reports pixel dimensions. Windows consoles have none, so
/// programs that need them ask the terminal with `queryPixelSize`.
pub const size_reports_pixels = !is_windows;

pub const PixelSize = struct { width: u16, height: u16 };

/// Asks the terminal for its text area in pixels with XTWINOPS `CSI 14 t`
/// (reply `CSI 4 ; height ; width t`), and for its cell size with `CSI 16 t`
/// (reply `CSI 6 ; height ; width t`), which `cols` and `rows` scale up.
/// Waits up to `timeout_ms`; `tty.input` must be in raw mode. Input read
/// meanwhile is discarded, as the graphics capability probes do.
pub fn queryPixelSize(tty: Tty, cols: u16, rows: u16, timeout_ms: i64) ?PixelSize {
    var output = tty.output.writerStreaming(&.{});
    output.interface.writeAll("\x1b[14t\x1b[16t") catch return null;
    output.interface.flush() catch return null;
    var replies: [256]u8 = undefined;
    var len: usize = 0;
    const deadline = time.milliTimestamp() + timeout_ms;
    while (time.milliTimestamp() < deadline and len < replies.len) {
        const n = tty.input.read(replies[len..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return null,
        };
        len += n;
        if (parsePixelReply(replies[0..len], cols, rows)) |pixels| return pixels;
        if (n == 0) time.sleep(10 * std.time.ns_per_ms);
    }
    return null;
}

/// The text-area size from a `CSI 4 ; h ; w t` reply, or from a
/// `CSI 6 ; h ; w t` cell-size reply times the grid.
pub fn parsePixelReply(bytes: []const u8, cols: u16, rows: u16) ?PixelSize {
    var from_cells: ?PixelSize = null;
    var rest = bytes;
    while (std.mem.indexOf(u8, rest, "\x1b[")) |start| {
        rest = rest[start + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, 't') orelse return from_cells;
        var fields = std.mem.splitScalar(u8, rest[0..end], ';');
        const kind = fields.next() orelse continue;
        const height = std.fmt.parseInt(u16, fields.next() orelse continue, 10) catch continue;
        const width = std.fmt.parseInt(u16, fields.next() orelse continue, 10) catch continue;
        if (fields.next() != null or width == 0 or height == 0) continue;
        if (std.mem.eql(u8, kind, "4")) return .{ .width = width, .height = height };
        if (std.mem.eql(u8, kind, "6")) from_cells = .{
            .width = std.math.lossyCast(u16, @as(u32, width) * cols),
            .height = std.math.lossyCast(u16, @as(u32, height) * rows),
        };
    }
    return from_cells;
}

/// Unbuffered, unechoed input without signal generation; reads on `input`
/// return what is available and report `WouldBlock` when nothing is.
/// `output` interprets escape sequences. `restore` puts both back.
pub const RawMode = if (is_windows) WindowsRawMode else PosixRawMode;

const PosixRawMode = struct {
    input: File,
    original: std.posix.termios,

    pub fn enter(input: File, output: File) !PosixRawMode {
        _ = output;
        const original = try raw.tcgetattr(input.handle);
        var mode = original;
        mode.lflag.ECHO = false;
        mode.lflag.ICANON = false;
        mode.lflag.ISIG = false;
        mode.iflag.IXON = false;
        mode.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        mode.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try raw.tcsetattr(input.handle, .FLUSH, mode);
        return .{ .input = input, .original = original };
    }

    pub fn restore(self: PosixRawMode) void {
        raw.tcsetattr(self.input.handle, .FLUSH, self.original) catch {};
    }
};

const WindowsRawMode = struct {
    input: File,
    output: File,
    input_mode: u32,
    output_mode: u32,
    code_pages: win.CodePages,

    pub fn enter(input: File, output: File) error{NotATerminal}!WindowsRawMode {
        const input_mode = win.consoleMode(input.handle) orelse return error.NotATerminal;
        const output_mode = win.consoleMode(output.handle) orelse return error.NotATerminal;
        const code_pages = win.codePages();
        try win.setConsoleMode(output.handle, output_mode | win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        const cooked = win.ENABLE_LINE_INPUT | win.ENABLE_ECHO_INPUT | win.ENABLE_PROCESSED_INPUT;
        win.setConsoleMode(input.handle, (input_mode & ~cooked) | win.ENABLE_VIRTUAL_TERMINAL_INPUT) catch |err| {
            win.setConsoleMode(output.handle, output_mode) catch {};
            return err;
        };
        win.setCodePages(.{ .input = win.CP_UTF8, .output = win.CP_UTF8 });
        return .{ .input = input, .output = output, .input_mode = input_mode, .output_mode = output_mode, .code_pages = code_pages };
    }

    pub fn restore(self: WindowsRawMode) void {
        win.setConsoleMode(self.input.handle, self.input_mode) catch {};
        win.setConsoleMode(self.output.handle, self.output_mode) catch {};
        win.setCodePages(self.code_pages);
    }
};
