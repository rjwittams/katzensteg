const std = @import("std");
const js = @import("jackstay");
test "optional Jackstay checks the exact ABI before use" {
    if (js.enabled) try js.checkAvailable() else try std.testing.expectError(error.JackstayUnavailable, js.checkAvailable());
}

test "cancellation interrupts a connection blocked in attach" {
    if (!js.enabled) return;
    const os = @import("platform");
    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer os.posix.close(fds[0]);
    var connection = try js.media.Connection.init(&fds[1]);
    defer connection.deinit();
    const Worker = struct {
        fn run(conn: *js.media.Connection) void {
            std.testing.expectError(error.Cancelled, conn.attach()) catch @panic("attach cancellation failed");
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&connection});
    os.time.sleep(10 * std.time.ns_per_ms);
    connection.cancel();
    worker.join();
}

test "cancellation interrupts a frame wait and producer drains after setup joins" {
    if (!js.enabled) return;
    const os = @import("platform");
    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    var producer = try js.media.Producer.init(4);
    var server = try producer.serve(&fds[0]);
    var connection = try js.media.Connection.init(&fds[1]);
    try connection.attach();
    const Worker = struct {
        fn run(conn: *js.media.Connection) void {
            while (true) {
                // cancel interrupts both setup and acquisition. Either the
                // server's close notification or the cancellation can win.
                if (conn.next(std.math.maxInt(u64)) catch |err| switch (err) {
                    error.Cancelled, error.Closed => return,
                    else => @panic("wait cancellation failed"),
                }) |acquired| {
                    var frame = acquired;
                    frame.release();
                    @panic("unexpected frame without publication");
                }
            }
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{&connection});
    os.time.sleep(10 * std.time.ns_per_ms);
    connection.cancel();
    worker.join();
    connection.deinit();
    server.close();
    for (0..100) |_| {
        if (try producer.close()) return;
        os.time.sleep(std.time.ns_per_ms);
    }
    return error.ProducerDidNotDrain;
}
