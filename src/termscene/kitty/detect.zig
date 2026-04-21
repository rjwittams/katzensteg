const std = @import("std");

pub fn readReplies(allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var reader = std.fs.File.stdin().deprecatedReader();
    const start = std.time.milliTimestamp();
    var buf: [512]u8 = undefined;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try list.appendSlice(allocator, buf[0..n]);
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn detectGraphicsSupport(allocator: std.mem.Allocator, writer: anytype) !bool {
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readReplies(allocator, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "_Gi=31;OK") != null;
}
