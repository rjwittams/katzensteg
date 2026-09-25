//! Win32 adapters behind the neutral platform API. Handles are the same
//! `std.posix.fd_t` values `fs.File` carries (HANDLE on Windows). Operations
//! mirror the POSIX adapter's names and results so `fs.File` selects either.
const std = @import("std");
const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = u32;

// WouldBlock is never returned here; it stays in the set so callers written
// against the POSIX adapter's nonblocking contract compile unchanged.
pub const ReadError = error{ WouldBlock, BrokenPipe, Unexpected };
pub const WriteError = error{ BrokenPipe, Unexpected };
pub const PReadError = ReadError || error{Unseekable};
pub const PWriteError = WriteError || error{Unseekable};

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const CP_UTF8: u32 = 65001;

const KEY_EVENT: u16 = 0x0001;
const ERROR_BROKEN_PIPE: DWORD = 109;
const ERROR_NO_DATA: DWORD = 232;
const ERROR_HANDLE_EOF: DWORD = 38;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ScreenBufferInfo = extern struct {
    size: Coord,
    cursor_position: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};
const KeyEventRecord = extern struct {
    key_down: BOOL,
    repeat_count: u16,
    virtual_key_code: u16,
    virtual_scan_code: u16,
    unicode_char: u16,
    control_key_state: DWORD,
};
const InputRecord = extern struct {
    event_type: u16,
    // The event union is 16 bytes and 4-byte aligned; only key events are read.
    event: extern union { key: KeyEventRecord, bytes: [16]u8 },
};
const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: DWORD,
    offset_high: DWORD,
    event: ?HANDLE = null,
};

const k32 = struct {
    extern "kernel32" fn GetConsoleMode(handle: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(handle: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(code_page: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(code_page: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(handle: HANDLE, info: *ScreenBufferInfo) callconv(.winapi) BOOL;
    extern "kernel32" fn GetNumberOfConsoleInputEvents(handle: HANDLE, count: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadConsoleInputW(handle: HANDLE, records: [*]InputRecord, len: DWORD, read: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetFilePointerEx(handle: HANDLE, distance: i64, new_position: ?*i64, method: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(handle: HANDLE, buffer: [*]u8, len: DWORD, read: *DWORD, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(handle: HANDLE, buffer: [*]const u8, len: DWORD, written: *DWORD, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
};

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_WRITE: DWORD = 0x2;
const OPEN_EXISTING: DWORD = 3;

pub const Console = enum { input, output };

/// Opens the console attached to this process, whatever its standard handles
/// point at: `CONIN$` for input records, `CONOUT$` for the active screen
/// buffer. These are the Windows counterparts of opening `/dev/tty`.
pub fn openConsole(which: Console) error{NoConsole}!HANDLE {
    const name = switch (which) {
        .input => std.unicode.utf8ToUtf16LeStringLiteral("CONIN$"),
        .output => std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
    };
    const handle = k32.CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.NoConsole;
    return handle;
}

fn ok(result: BOOL) bool {
    return @intFromEnum(result) != 0;
}

fn clampLen(len: usize) DWORD {
    return @intCast(@min(len, std.math.maxInt(DWORD)));
}

pub fn close(handle: HANDLE) void {
    _ = k32.CloseHandle(handle);
}

pub fn consoleMode(handle: HANDLE) ?DWORD {
    var mode: DWORD = 0;
    return if (ok(k32.GetConsoleMode(handle, &mode))) mode else null;
}

pub fn setConsoleMode(handle: HANDLE, mode: DWORD) error{NotATerminal}!void {
    if (!ok(k32.SetConsoleMode(handle, mode))) return error.NotATerminal;
}

pub const CodePages = struct { input: u32, output: u32 };

pub fn codePages() CodePages {
    return .{ .input = k32.GetConsoleCP(), .output = k32.GetConsoleOutputCP() };
}

pub fn setCodePages(pages: CodePages) void {
    _ = k32.SetConsoleCP(pages.input);
    _ = k32.SetConsoleOutputCP(pages.output);
}

pub const WindowSize = struct { rows: u16, cols: u16 };

/// Visible window of a console screen buffer, in cells. Consoles do not report
/// cell pixel sizes.
pub fn windowSize(handle: HANDLE) ?WindowSize {
    var info: ScreenBufferInfo = undefined;
    if (!ok(k32.GetConsoleScreenBufferInfo(handle, &info))) return null;
    const cols = @as(i32, info.window.right) - info.window.left + 1;
    const rows = @as(i32, info.window.bottom) - info.window.top + 1;
    if (rows <= 0 or cols <= 0) return null;
    return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
}

/// Reads with the semantics of the POSIX adapter. A console in raw mode (line
/// input off) behaves like termios VMIN=0/VTIME=0: it returns what is
/// available, or 0 when nothing is. Typed characters and, with
/// ENABLE_VIRTUAL_TERMINAL_INPUT, terminal replies arrive as key records;
/// other records are consumed and ignored. Cooked consoles, pipes and files
/// block, and a closed pipe reads as end of file.
pub fn read(handle: HANDLE, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    if (consoleMode(handle)) |mode| {
        if (mode & ENABLE_LINE_INPUT == 0) return readConsoleAvailable(handle, buf);
    }
    var n: DWORD = 0;
    if (!ok(k32.ReadFile(handle, buf.ptr, clampLen(buf.len), &n, null))) {
        if (k32.GetLastError() == ERROR_BROKEN_PIPE) return 0;
        return mapReadError();
    }
    return n;
}

fn mapReadError() ReadError {
    return switch (k32.GetLastError()) {
        ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF => error.BrokenPipe,
        else => error.Unexpected,
    };
}

fn readConsoleAvailable(handle: HANDLE, buf: []u8) ReadError!usize {
    var pending: DWORD = 0;
    if (!ok(k32.GetNumberOfConsoleInputEvents(handle, &pending))) return error.Unexpected;
    if (pending == 0) return 0;
    // Each UTF-16 unit encodes to at most three UTF-8 bytes; a surrogate pair
    // is two units producing four bytes, within that bound. So buf.len / 3
    // units always fit. A pair split across two reads decodes as two
    // replacement characters.
    var records: [128]InputRecord = undefined;
    const max_units = @min(records.len, @max(buf.len / 3, 1));
    const want = @min(@as(usize, pending), max_units);
    var got: DWORD = 0;
    if (!ok(k32.ReadConsoleInputW(handle, &records, @intCast(want), &got))) return error.Unexpected;
    var units: [128]u16 = undefined;
    var unit_count: usize = 0;
    for (records[0..got]) |record| {
        if (record.event_type != KEY_EVENT) continue;
        const key = record.event.key;
        if (!ok(key.key_down) or key.unicode_char == 0) continue;
        // Repeats beyond max_units are dropped with their consumed record.
        // Virtual-terminal input delivers one record per character, so
        // repeat counts above 1 come only from legacy key input.
        var repeat = @max(key.repeat_count, 1);
        while (repeat > 0 and unit_count < max_units) : (repeat -= 1) {
            units[unit_count] = key.unicode_char;
            unit_count += 1;
        }
    }
    return utf16ToUtf8Lossy(units[0..unit_count], buf);
}

/// Encodes UTF-16 as UTF-8, replacing unpaired surrogates, stopping before a
/// code point that would not fit.
pub fn utf16ToUtf8Lossy(units: []const u16, out: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < units.len) {
        var cp: u21 = units[i];
        var step: usize = 1;
        if (std.unicode.utf16IsHighSurrogate(units[i])) {
            if (i + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[i + 1])) {
                cp = std.unicode.utf16DecodeSurrogatePair(units[i .. i + 2]) catch std.unicode.replacement_character;
                step = 2;
            } else cp = std.unicode.replacement_character;
        } else if (std.unicode.utf16IsLowSurrogate(units[i])) cp = std.unicode.replacement_character;
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (n + len > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[n..][0..len]) catch unreachable;
        n += len;
        i += step;
    }
    return n;
}

pub fn write(handle: HANDLE, bytes: []const u8) WriteError!usize {
    var n: DWORD = 0;
    if (!ok(k32.WriteFile(handle, bytes.ptr, clampLen(bytes.len), &n, null))) return mapWriteError();
    return n;
}

fn mapWriteError() WriteError {
    return switch (k32.GetLastError()) {
        ERROR_BROKEN_PIPE, ERROR_NO_DATA => error.BrokenPipe,
        else => error.Unexpected,
    };
}

pub const Whence = enum(DWORD) { set = 0, current = 1, end = 2 };

pub fn seek(handle: HANDLE, offset: i64, whence: Whence) error{Unseekable}!void {
    if (!ok(k32.SetFilePointerEx(handle, offset, null, @intFromEnum(whence)))) return error.Unseekable;
}

fn offsetOverlapped(offset: u64) Overlapped {
    return .{ .offset = @truncate(offset), .offset_high = @truncate(offset >> 32) };
}

pub fn pread(handle: HANDLE, buf: []u8, offset: u64) PReadError!usize {
    var overlapped = offsetOverlapped(offset);
    var n: DWORD = 0;
    if (!ok(k32.ReadFile(handle, buf.ptr, clampLen(buf.len), &n, &overlapped))) {
        if (k32.GetLastError() == ERROR_HANDLE_EOF) return 0;
        return mapReadError();
    }
    return n;
}

pub fn pwrite(handle: HANDLE, bytes: []const u8, offset: u64) PWriteError!usize {
    var overlapped = offsetOverlapped(offset);
    var n: DWORD = 0;
    if (!ok(k32.WriteFile(handle, bytes.ptr, clampLen(bytes.len), &n, &overlapped))) return mapWriteError();
    return n;
}

test "UTF-16 console input encodes to UTF-8, pairing surrogates and bounding output" {
    var out: [16]u8 = undefined;
    const pair = [_]u16{ 'a', 0xD83D, 0xDE00, 'b' };
    const n = utf16ToUtf8Lossy(&pair, &out);
    try std.testing.expectEqualStrings("a\u{1F600}b", out[0..n]);
    const lone = [_]u16{ 0xD83D, 'x' };
    const m = utf16ToUtf8Lossy(&lone, &out);
    try std.testing.expectEqualStrings("\u{FFFD}x", out[0..m]);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), utf16ToUtf8Lossy(&pair, &small));
}
