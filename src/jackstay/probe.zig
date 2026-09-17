//! Cross-process connector fixture; its pipes are test coordination, not media.
const std = @import("std");
const os = @import("platform");
const js = @import("jackstay");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len != 3) return error.Usage;
    if (std.mem.startsWith(u8, args[1], "publish")) {
        const publisher = try js.Publisher.create(init.io, a, args[2], if (std.mem.eql(u8, args[1], "publish-small")) .{ .memory_budget = 384 * 1024 } else .{}, null);
        try reply("ready\n");
        while (try line()) |command| {
            var words = std.mem.tokenizeScalar(u8, command, ' ');
            const width = try std.fmt.parseInt(u32, words.next() orelse return error.Usage, 10);
            const value = try std.fmt.parseInt(u8, words.next() orelse return error.Usage, 10);
            const pixels = try a.alloc(u8, @as(usize, width) * 4);
            defer a.free(pixels);
            @memset(pixels, value);
            const published = try publisher.publish(.{ .width = width, .height = 1, .stride = width * 4, .format = .rgba8, .pixels = pixels });
            try reply(if (published) "published\n" else "dropped\n");
        }
        try publisher.close();
    } else {
        var fd = try js.endpoint.connect(args[2]);
        defer if (fd >= 0) os.posix.close(fd);
        _ = try js.bootstrap.connect(&fd, .observe);
        var connection = try js.media.Connection.init(&fd);
        defer connection.deinit();
        try connection.attachHolding(if (std.mem.eql(u8, args[1], "consume-one")) 1 else 2);
        var held: ?js.media.Frame = null;
        defer if (held) |*frame| frame.release();
        try reply("ready\n");
        while (try line()) |command| {
            if (std.mem.eql(u8, command, "close")) {
                connection.cancel();
                connection.deinit();
                try reply("closed\n");
                continue;
            }
            if (std.mem.eql(u8, command, "held")) {
                const image = try held.?.image();
                var buf: [80]u8 = undefined;
                try reply(try std.fmt.bufPrint(&buf, "{d} {d}\n", .{ image.width, image.pixels[0] }));
                continue;
            }
            if (std.mem.eql(u8, command, "release")) {
                if (held) |*frame| frame.release();
                held = null;
                try reply("released\n");
                continue;
            }
            if (std.mem.eql(u8, command, "poll")) {
                if (connection.next(20 * std.time.ns_per_ms) catch |err| switch (err) {
                    error.Timeout => null,
                    else => return err,
                }) |acquired| {
                    var frame = acquired;
                    frame.release();
                }
                try reply("polled\n");
                continue;
            }
            var frame = while (true) {
                if (try connection.next(std.time.ns_per_s)) |frame| break frame;
            };
            const image = try frame.image();
            var buf: [80]u8 = undefined;
            try reply(try std.fmt.bufPrint(&buf, "{d} {d}\n", .{ image.width, image.pixels[0] }));
            if (std.mem.eql(u8, command, "hold")) {
                if (held) |*old| old.release();
                held = frame;
            } else frame.release();
        }
    }
}

var buffer: [256]u8 = undefined;
fn line() !?[]const u8 {
    var count: usize = 0;
    while (count < buffer.len) : (count += 1) {
        const n = try os.posix.read(0, buffer[count..][0..1]);
        if (n == 0) return null;
        if (buffer[count] == '\n') return buffer[0..count];
    }
    return error.LineTooLong;
}
fn reply(bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len != 0) rest = rest[try os.posix.write(1, rest)..];
}
