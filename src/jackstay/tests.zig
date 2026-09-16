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

const InputFixture = if (js.enabled) struct {
    target: js.input.Target,
    server: js.input.Server,
    client: js.input.Client,

    fn init() !@This() {
        const os = @import("platform");
        var target = try js.input.Target.init(.{
            .capabilities = .{ .physical = true, .logical = true, .text = true, .pointer = true, .scroll = true },
            .geometry = .{ .width = 640, .height = 480 },
        });
        errdefer target.deinit() catch {};
        var fds: [2]i32 = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        defer for (fds) |fd| {
            if (fd >= 0) os.posix.close(fd);
        };
        var server = try target.serve(&fds[0]);
        errdefer server.deinit();
        const client = try js.input.Client.connect(&fds[1], .cooperative);
        try std.testing.expectEqual([2]i32{ -1, -1 }, fds);
        return .{ .target = target, .server = server, .client = client };
    }
    fn work(self: *@This()) !js.input.Work {
        const os = @import("platform");
        for (0..1000) |_| {
            if (try self.target.next()) |item| return item;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.WorkTimeout;
    }
    fn status(self: *@This()) !js.input.Status {
        const os = @import("platform");
        for (0..1000) |_| {
            if (try self.client.poll()) |item| return item;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.StatusTimeout;
    }
    fn finish(self: *@This()) !void {
        self.client.close();
        var cleanup = try self.work();
        try std.testing.expect((try cleanup.cleanup()) != null);
        try cleanup.complete(.executed);
        const closed = try self.status();
        try std.testing.expect(closed == .closed);
        try std.testing.expect(closed.closed.clean);
        self.client.deinit();
        self.server.deinit();
        try self.target.deinit();
    }
} else struct {};

test "shared input copies long text and reports execution only after work completes" {
    if (!js.enabled) return;
    var fixture = try InputFixture.init();
    const admission = try fixture.client.describe();
    try std.testing.expect(admission.controller != 0);
    try std.testing.expectEqual(@as(u32, 16384), admission.max_text_bytes);
    try std.testing.expect(!(try fixture.server.finished()));
    var text = [_]u8{'x'} ** 1024;
    text[31] = 0; // Length-delimited text is not a C/SDL string.
    const sequence = try fixture.client.send(.{ .text = &text });
    @memset(&text, 'y');
    var work = try fixture.work();
    const event = try work.event();
    try std.testing.expect(event == .text);
    try std.testing.expectEqual(@as(usize, 1024), event.text.len);
    try std.testing.expectEqual(@as(u8, 0), event.text[31]);
    try std.testing.expectEqual(@as(u8, 'x'), event.text[500]);
    try std.testing.expectEqual(sequence, work.sequence());
    try std.testing.expectEqual(admission.controller, work.controller());
    try std.testing.expectEqual(admission.epoch, work.epoch());
    try std.testing.expectEqual(js.input.Mode.cooperative, try work.mode());
    try std.testing.expectEqual(@as(?js.input.Status, null), try fixture.client.poll());
    try work.complete(.executed);
    const result = try fixture.status();
    try std.testing.expectEqual(sequence, result.completed.sequence);
    try std.testing.expectEqual(js.input.Outcome.executed, result.completed.outcome);
    try fixture.finish();
}

test "shared input geometry cleanup waits for in-flight work and preserves pointer scope" {
    if (!js.enabled) return;
    var fixture = try InputFixture.init();
    _ = try fixture.client.send(.{ .key = .{ .kind = .physical, .name = "ShiftLeft", .press = 1, .action = .down } });
    var key = try fixture.work();
    try std.testing.expectEqualStrings("ShiftLeft", (try key.event()).key.name);
    try key.complete(.executed);
    _ = try fixture.status();
    _ = try fixture.client.send(.{ .button = .{ .button = .secondary, .action = .down, .position = .{ .x = 10.5, .y = 20, .revision = 1 } } });
    var button = try fixture.work();
    try std.testing.expectEqual(js.input.Button.secondary, (try button.event()).button.button);
    try fixture.target.setGeometry(.{ .revision = 2, .width = 800, .height = 600 });
    try std.testing.expectEqual(@as(?js.input.Work, null), try fixture.target.next());
    try button.complete(.executed);
    var cleanup = try fixture.work();
    const description = (try cleanup.cleanup()).?;
    try std.testing.expectEqual(js.input.Scope.pointer, description.scope);
    try std.testing.expectEqual(js.input.Reason.geometry, description.reason);
    try cleanup.complete(.executed);
    var reset_seen = false;
    for (0..3) |_| {
        const result = try fixture.status();
        if (result == .reset) {
            try std.testing.expectEqual(@as(u64, 2), result.reset.geometry.revision);
            reset_seen = true;
            break;
        }
    }
    try std.testing.expect(reset_seen);
    _ = try fixture.client.send(.{ .key = .{ .kind = .physical, .name = "ShiftLeft", .press = 1, .action = .up } });
    var release = try fixture.work();
    try std.testing.expectEqual(js.input.Action.up, (try release.event()).key.action);
    try release.complete(.executed);
    _ = try fixture.status();
    try fixture.finish();
}

test "shared input destruction does not assert cleanup and failed cleanup retains target" {
    if (!js.enabled) return;
    var fixture = try InputFixture.init();
    fixture.client.deinit();
    fixture.server.deinit();
    try std.testing.expectError(error.Draining, fixture.target.deinit());
    var cleanup = try fixture.work();
    try std.testing.expectEqual(js.input.Scope.all, (try cleanup.cleanup()).?.scope);
    // Completion consumes work even when executor cleanup failed.
    cleanup.complete(.uncertain) catch |err| {
        try std.testing.expectEqual(error.RecoveryRequired, err);
    };
    try std.testing.expect(cleanup.handle == null);
    try std.testing.expectError(error.RecoveryRequired, fixture.target.deinit());
    // This fixture has no native state; rebuilding/resolving it is explicit.
    try fixture.target.resolveFailedCleanup();
    try fixture.target.deinit();
}

test "shared input preserves fractional scroll and clean rejection allows later events" {
    if (!js.enabled) return;
    var fixture = try InputFixture.init();
    _ = try fixture.client.send(.{ .key = .{ .kind = .logical, .name = "Unmapped", .press = 9, .action = .down, .modifiers = .{ .control = true } } });
    var key = try fixture.work();
    try std.testing.expect((try key.event()).key.modifiers.control);
    try key.complete(.unsupported);
    try std.testing.expectEqual(js.input.Outcome.unsupported, (try fixture.status()).completed.outcome);
    _ = try fixture.client.send(.{ .scroll = .{ .x = 0.25, .y = -0.5, .unit = .pixel, .position = .{ .x = 10, .y = 20, .revision = 1 } } });
    var scroll = try fixture.work();
    const event = (try scroll.event()).scroll;
    try std.testing.expectEqual(@as(f64, 0.25), event.x);
    try std.testing.expectEqual(@as(f64, -0.5), event.y);
    try std.testing.expectEqual(js.input.ScrollUnit.pixel, event.unit);
    try std.testing.expectEqual(@as(f64, 20), event.position.y);
    try scroll.complete(.executed);
    _ = try fixture.status();
    const before = try fixture.client.describe();
    try fixture.client.reset();
    var cleanup = try fixture.work();
    try std.testing.expectEqual(js.input.Reason.focus, (try cleanup.cleanup()).?.reason);
    try cleanup.complete(.executed);
    const reset = try fixture.status();
    try std.testing.expect(reset.reset.epoch > before.epoch);
    _ = try fixture.client.send(.{ .motion = .{ .x = 10.25, .y = 20.5, .revision = 1 } });
    var motion = try fixture.work();
    try std.testing.expectEqual(@as(f64, 10.25), (try motion.event()).motion.x);
    try motion.complete(.executed);
    _ = try fixture.status();
    try fixture.finish();
}
