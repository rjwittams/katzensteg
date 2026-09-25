//! Terminal adapter for programs that draw on the terminal they run in: raw
//! input mode and window size. POSIX uses termios and TIOCGWINSZ; Windows uses
//! console modes with virtual-terminal input and output enabled.
const std = @import("std");
const builtin = @import("builtin");
const File = @import("fs.zig").File;

const is_windows = builtin.os.tag == .windows;
const win = @import("windows.zig");
const raw = @import("posix.zig");

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
