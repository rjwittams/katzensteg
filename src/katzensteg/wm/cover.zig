//! Desktop covering policy and the startup OSC 11 query. No process-global state.
const std = @import("std");
const platform = @import("platform");

pub const Color = [3]u8;
pub const Mode = enum { split, band };
pub const Policy = struct {
    mode: Mode = .split,
    background: ?Color = null,

    pub fn choose(force_split: bool, background: ?Color) Policy {
        return .{ .mode = if (!force_split and background != null) .band else .split, .background = background };
    }

    pub fn paintedBackground(self: Policy) ?Color {
        return if (self.background) |color| nudge(color) else null;
    }
};

pub fn nudge(color: Color) Color {
    var result = color;
    result[2] = if (color[2] == 255) color[2] - 1 else color[2] + 1;
    return result;
}

pub fn writeBackground(writer: anytype, color: Color) !void {
    try writer.print("\x1b[48;2;{d};{d};{d}m", .{ color[0], color[1], color[2] });
}

/// Accept X11 rgb replies (one to four hex digits/channel) with BEL or ST.
/// Partial and malformed replies cannot enable band mode.
pub fn parseBackground(bytes: []const u8) ?Color {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, offset, "\x1b]11;rgb:")) |start| {
        offset = start + 9;
        const rest = bytes[offset..];
        const end = std.mem.indexOfAny(u8, rest, "\x07\x1b") orelse return null;
        if (rest[end] == '\x1b' and (end + 1 >= rest.len or rest[end + 1] != '\\')) continue;
        var fields = std.mem.splitScalar(u8, rest[0..end], '/');
        var color: Color = undefined;
        var valid = true;
        for (&color) |*channel| {
            const field = fields.next() orelse {
                valid = false;
                break;
            };
            if (field.len == 0 or field.len > 4) {
                valid = false;
                break;
            }
            for (field) |ch| if (!std.ascii.isHex(ch)) {
                valid = false;
                break;
            };
            if (!valid) break;
            const value = std.fmt.parseInt(u32, field, 16) catch {
                valid = false;
                break;
            };
            const max: u32 = (@as(u32, 1) << @as(u5, @intCast(field.len * 4))) - 1;
            channel.* = @intCast((value * 255 + max / 2) / max);
        }
        if (valid and fields.next() == null) return color;
    }
    return null;
}

/// Before input capture, like the graphics probes: unrelated input is discarded.
/// A bounded read handles replies split across terminal reads.
pub fn queryBackground(tty: platform.terminal.Tty, timeout_ms: i64) ?Color {
    var output = tty.output.writerStreaming(&.{});
    output.interface.writeAll("\x1b]11;?\x1b\\") catch return null;
    output.interface.flush() catch return null;
    var replies: [512]u8 = undefined;
    var len: usize = 0;
    const deadline = platform.time.milliTimestamp() + timeout_ms;
    while (platform.time.milliTimestamp() < deadline and len < replies.len) {
        const n = tty.input.read(replies[len..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return null,
        };
        len += n;
        if (parseBackground(replies[0..len])) |color| return color;
        if (n == 0) platform.time.sleep(10 * std.time.ns_per_ms);
    }
    return null;
}

test "default background nudge changes only blue by one across all 8-bit values" {
    // #113: a covering default-colour cell must differ by one blue step.
    // Exhaustive generator covers blue 0, 254, 255 and every interior value.
    for (0..256) |blue| {
        const color: Color = .{ 17, 91, @intCast(blue) };
        const painted = nudge(color);
        try std.testing.expectEqual(color[0], painted[0]);
        try std.testing.expectEqual(color[1], painted[1]);
        try std.testing.expectEqual(@as(u8, @intCast(if (blue == 255) 254 else blue + 1)), painted[2]);
    }
}

test "unanswered colour query and forced fallback select splitting" {
    // #113: no reply must select splitting; an explicit fallback wins over a reply.
    for ([_]bool{ false, true }) |force| {
        try std.testing.expectEqual(Mode.split, Policy.choose(force, null).mode);
        try std.testing.expectEqual(if (force) Mode.split else Mode.band, Policy.choose(force, .{ 0, 0, 0 }).mode);
    }
}

test "OSC 11 parsing accepts complete replies and rejects partial or invalid colours" {
    // Protocol examples cover BEL, ST, hex widths, fragmented input and malformed replies.
    const reply = "noise\x1b]11;rgb:1212/3434/fefe\x1b\\";
    for (0..reply.len) |len| try std.testing.expectEqual(@as(?Color, null), parseBackground(reply[0..len]));
    try std.testing.expectEqual(@as(?Color, .{ 18, 52, 254 }), parseBackground(reply));
    try std.testing.expectEqual(@as(?Color, .{ 255, 0, 136 }), parseBackground("\x1b]11;rgb:f/0/8\x07"));
    try std.testing.expectEqual(@as(?Color, .{ 18, 52, 255 }), parseBackground("\x1b]11;rgb:12/34/ff\x07"));
    for ([_][]const u8{ "", "\x1b]10;rgb:00/00/00\x07", "\x1b]11;rgb:00/gg/00\x07", "\x1b]11;rgb:/00/00\x07", "\x1b]11;rgb:00000/00/00\x07", "\x1b]11;rgb:00/00/00/00\x07", "\x1b]11;rgb:00/00/00\x1bx" }) |bad| {
        try std.testing.expectEqual(@as(?Color, null), parseBackground(bad));
    }
}

test "startup query writes OSC 11 once and unanswered or malformed replies fall back" {
    // #113: query the terminal once; only a valid response enables band mode.
    // Real nonblocking pipes stand in for the terminal's input/output boundary.
    for ([_][]const u8{ "", "\x1b]11;rgb:bad\x07", "\x1b]11;rgb:12/34/ff\x07" }) |reply| {
        const input_pipe = try platform.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        const output_pipe = try platform.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        const input = platform.fs.File{ .io = std.testing.io, .handle = input_pipe[0] };
        defer input.close();
        const response = platform.fs.File{ .io = std.testing.io, .handle = input_pipe[1] };
        defer response.close();
        const output = platform.fs.File{ .io = std.testing.io, .handle = output_pipe[1] };
        defer output.close();
        const request = platform.fs.File{ .io = std.testing.io, .handle = output_pipe[0] };
        defer request.close();
        var writer = response.writerStreaming(&.{});
        try writer.interface.writeAll(reply);
        try writer.interface.flush();
        const background = queryBackground(.{ .input = input, .output = output }, 20);
        try std.testing.expectEqual(if (std.mem.eql(u8, reply, "\x1b]11;rgb:12/34/ff\x07")) Mode.band else Mode.split, Policy.choose(false, background).mode);
        var bytes: [64]u8 = undefined;
        try std.testing.expectEqualStrings("\x1b]11;?\x1b\\", bytes[0..try request.read(&bytes)]);
        try std.testing.expectError(error.WouldBlock, request.read(&bytes));
    }
}
