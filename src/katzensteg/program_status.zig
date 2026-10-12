const std = @import("std");

pub const State = enum { working, idle, @"error", clear };
pub const Report = struct {
    state: State,
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
};

/// Validates the complete report before writing any bytes. Text is truncated
/// at a UTF-8 boundary; invalid UTF-8 and C0/C1 controls are rejected.
pub fn write(writer: *std.Io.Writer, report: Report) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    if (report.id) |id| {
        if (id.len == 0 or id.len > 128) return error.InvalidId;
        var parts = std.mem.splitScalar(u8, id, '/');
        var depth: usize = 0;
        while (parts.next()) |part| {
            depth += 1;
            if (part.len == 0 or part.len > 32 or depth > 8) return error.InvalidId;
            for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '+' or c == '-')) return error.InvalidId;
        }
    }
    const title = if (report.title) |v| try textPrefix(v, 192) else null;
    const msg = if (report.msg) |v| try textPrefix(v, 2048) else null;
    try out.writeAll("\x1b]7501;state=");
    try out.writeAll(@tagName(report.state));
    try out.writeAll(":app=katzensteg");
    if (report.id) |id| try out.print(":id={s}", .{id});
    if (title) |v| try textPair(&out, "title", v);
    if (msg) |v| try textPair(&out, "msg", v);
    try out.writeAll("\x1b\\");
    try writer.writeAll(out.buffered());
}

fn textPrefix(value: []const u8, limit: usize) ![]const u8 {
    var view = try std.unicode.Utf8View.init(value);
    var iter = view.iterator();
    var end: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        if (cp < 32 or (cp >= 127 and cp <= 159)) return error.ControlCharacter;
        if (iter.i <= limit) end = iter.i;
    }
    return value[0..end];
}

fn textPair(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    // Standard base64 needs ceil(2048 / 3) * 4 bytes for the maximum message.
    var encoded: [2732]u8 = undefined;
    try writer.print(":{s}={s}", .{ key, std.base64.standard.Encoder.encode(&encoded, value) });
}

// OSC 7501 uses standard base64, includes app on every record, and has no progress for startup.
test "report bytes encode UTF-8 text and child identity" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .state = .working, .id = "window-1", .title = "猫", .msg = "Starting" });
    try std.testing.expectEqualStrings("\x1b]7501;state=working:app=katzensteg:id=window-1:title=54yr:msg=U3RhcnRpbmc=\x1b\\", out.written());
}

// Generate C0/C1 controls, invalid ids and UTF-8 size boundaries; rejection is atomic.
test "text controls and invalid ids are rejected before output" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (0..160) |cp| {
        if (cp >= 32 and cp < 127) continue;
        var bytes: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(@intCast(cp), &bytes);
        try std.testing.expectError(error.ControlCharacter, write(&out.writer, .{ .state = .idle, .title = bytes[0..n] }));
    }
    for ([_][]const u8{ "", "a/", "/a", "a:b", "a b", "a/b/c/d/e/f/g/h/i", "abcdefghijklmnopqrstuvwxyz1234567" }) |id|
        try std.testing.expectError(error.InvalidId, write(&out.writer, .{ .state = .idle, .id = id }));
    try std.testing.expectError(error.InvalidUtf8, write(&out.writer, .{ .state = .idle, .title = "\xff" }));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

// Both text limits truncate at a codepoint boundary, even with a multibyte character crossing it.
test "text limits preserve UTF-8 and sequence cap" {
    for ([_]usize{ 0, 191, 192, 193, 2047, 2048, 2049 }) |n| {
        const text = try std.testing.allocator.alloc(u8, n + 3);
        defer std.testing.allocator.free(text);
        @memset(text[0..n], 'x');
        @memcpy(text[n..], "猫");
        const prefix = try textPrefix(text, 192);
        try std.testing.expect(prefix.len <= 192);
        try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
        try std.testing.expectEqual(@min(n, 192) + @as(usize, if (n + 3 <= 192) 3 else 0), prefix.len);
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write(&out.writer, .{ .state = .@"error", .title = text, .msg = text });
        try std.testing.expect(out.written().len <= 4096);
        const bytes = out.written();
        const title_start = std.mem.indexOf(u8, bytes, ":title=").? + 7;
        const msg_marker = std.mem.indexOf(u8, bytes, ":msg=").?;
        const fields = [_][]const u8{ bytes[title_start..msg_marker], bytes[msg_marker + 5 .. bytes.len - 2] };
        for (fields, [_]usize{ 192, 2048 }) |encoded, limit| {
            var decoded: [2052]u8 = undefined;
            const len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
            try std.base64.standard.Decoder.decode(decoded[0..len], encoded);
            try std.testing.expectEqualStrings(try textPrefix(text, limit), decoded[0..len]);
        }

        try std.testing.expect((try textPrefix(text, 2048)).len <= 2048);
    }
}

/// The runtime calls this under its presentation lock, after drawing a frame.
pub fn ready(writer: *std.Io.Writer, title: []const u8, reported: *bool) !void {
    if (reported.*) return;
    try write(writer, .{ .state = .idle, .title = title });
    reported.* = true;
}

pub fn exited(code: u8, title: []const u8, reason: ?[]const u8) Report {
    return .{ .state = if (code == 0) .clear else .@"error", .title = title, .msg = if (code == 0) null else reason };
}

// The standalone writer handoff is working -> one runtime idle -> launcher clear/error.
test "standalone lifecycle bytes retain failures and clear clean exits" {
    for ([_]u8{ 0, 1, 127, 139, 255 }) |code| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write(&out.writer, .{ .state = .working, .title = "probe", .msg = "Starting probe" });
        var reported = false;
        try ready(&out.writer, "probe", &reported);
        const after_ready = out.written().len;
        try ready(&out.writer, "probe", &reported);
        try std.testing.expectEqual(after_ready, out.written().len);
        try std.testing.expect(std.mem.endsWith(u8, out.written(), "\x1b]7501;state=idle:app=katzensteg:title=cHJvYmU=\x1b\\"));
        out.clearRetainingCapacity();
        try write(&out.writer, exited(code, "probe", "Failed"));
        try std.testing.expectEqualStrings(if (code == 0)
            "\x1b]7501;state=clear:app=katzensteg:title=cHJvYmU=\x1b\\"
        else
            "\x1b]7501;state=error:app=katzensteg:title=cHJvYmU=:msg=RmFpbGVk\x1b\\", out.written());
    }
}
