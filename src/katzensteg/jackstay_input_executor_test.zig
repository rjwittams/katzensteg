const std = @import("std");
const js = @import("jackstay");
const os = @import("platform");
const input = @import("input.zig");
const executor_mod = if (js.enabled) @import("jackstay_input_executor.zig") else struct {};

const Fixture = if (js.enabled) struct {
    executor: *executor_mod.Executor,
    client: js.input.Client,
    model: input.InputModel,

    fn init() !@This() {
        const executor = try executor_mod.Executor.create(std.testing.allocator);
        const client = try connect(executor);
        return .{ .executor = executor, .client = client, .model = input.InputModel.init(std.testing.allocator) };
    }
    fn connect(executor: *executor_mod.Executor) !js.input.Client {
        var fds: [2]i32 = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        defer for (fds) |fd| {
            if (fd >= 0) os.posix.close(fd);
        };
        var server = try executor.target.serve(&fds[0]);
        executor.servers.adopt(server) catch |err| {
            server.deinit();
            return err;
        };
        return js.input.Client.connect(&fds[1], .cooperative);
    }
    fn bind(key: js.input.Key) !input.KeyEvent {
        if (!std.mem.eql(u8, key.name, "KeyA")) return error.Unsupported;
        return .{ .scancode = 4, .keycode = 'a' };
    }
    fn pump(self: *@This()) !void {
        try self.executor.pump(&self.model, bind);
    }
    fn queued(self: *@This()) !void {
        for (0..1000) |_| {
            try self.pump();
            if (self.model.pendingCount() > 0) return;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.NoDelivery;
    }
    fn status(self: *@This()) !js.input.Status {
        for (0..1000) |_| {
            try self.pump();
            if (try self.client.poll()) |result| return result;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.NoResult;
    }
    fn sendKey(self: *@This(), action: js.input.Action, identity: u64) !void {
        _ = try self.client.send(.{ .key = .{ .kind = .physical, .name = "KeyA", .press = identity, .action = action } });
    }
    fn finish(self: *@This()) !void {
        self.client.close();
        var confirmed = false;
        for (0..1000) |_| {
            try self.pump();
            while (self.model.pop()) |_| {}
            if (try self.client.poll()) |result| {
                if (result == .closed) {
                    confirmed = result.closed.clean;
                    break;
                }
            }
            os.time.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(confirmed);
        self.client.deinit();
        try self.executor.close();
        self.model.deinit();
    }
} else struct {};

test "cooperative executor waits for app delivery and retains the down binding for repeat and up" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    try f.sendKey(.down, 1);
    try f.queued();
    try std.testing.expectEqual(@as(?js.input.Status, null), try f.client.poll());
    try std.testing.expectEqual(@as(i32, 'a'), f.model.pop().?.key_down.keycode);
    try std.testing.expectEqual(js.input.Outcome.executed, (try f.status()).completed.outcome);
    // Unknown release/repeat names must not be remapped: press identity wins.
    _ = try f.client.send(.{ .key = .{ .kind = .physical, .name = "DifferentLayout", .press = 1, .action = .repeat, .modifiers = .{ .control = true } } });
    try f.queued();
    const repeated = f.model.pop().?.key_down;
    try std.testing.expect(repeated.repeat);
    try std.testing.expectEqual(@as(i32, 'a'), repeated.keycode);
    try std.testing.expectEqual(@as(u16, 0x40), repeated.mods);
    _ = try f.status();
    try f.sendKey(.up, 1);
    try f.queued();
    try std.testing.expectEqual(@as(i32, 'a'), f.model.pop().?.key_up.keycode);
    _ = try f.status();
    try f.finish();
}

test "cooperative focus reset settles delayed delivery and discards old queued work" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    try f.sendKey(.down, 1);
    try f.queued(); // in-flight, app has not read it yet
    try f.sendKey(.down, 2); // still queued inside Jackstay
    try f.client.reset();
    os.time.sleep(30 * std.time.ns_per_ms);
    try f.pump();
    try std.testing.expect(f.executor.pending != null);
    _ = f.model.pop(); // settle the one in-flight delivery
    var reset = false;
    var ups: usize = 0;
    for (0..1000) |_| {
        try f.pump();
        while (f.model.pop()) |event| {
            try std.testing.expect(event == .key_up);
            ups += 1;
        }
        if (try f.client.poll()) |result| if (result == .reset) {
            reset = true;
            break;
        };
        os.time.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(reset);
    try std.testing.expectEqual(@as(usize, 1), ups);
    try std.testing.expect(f.model.pressSlot((try f.client.describe()).controller, 1) == null);
    try f.finish();
}

test "cooperative pointer cleanup preserves remote keyboard and local holds" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    try f.sendKey(.down, 1);
    try f.queued();
    _ = f.model.pop();
    _ = try f.status();
    _ = try f.client.send(.{ .button = .{ .button = .secondary, .action = .down, .position = .{ .x = 40, .y = 50, .revision = 1 } } });
    try f.queued();
    try std.testing.expectEqual(@as(u8, 3), f.model.pop().?.mouse_button.button);
    _ = try f.status();
    f.model.native_keys[4] = 1;
    f.model.native_buttons = 1;
    try f.executor.setSize(800, 600);
    try f.queued();
    const released = f.model.pop().?.mouse_button;
    try std.testing.expect(!released.pressed);
    try std.testing.expectEqual(@as(u32, 1), released.buttons);
    try std.testing.expect((try f.status()) == .reset);
    var state = [_]u8{0} ** input.sdl_num_scancodes;
    f.model.copyKeyboardState(&state, os.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 1), state[4]);
    try std.testing.expectEqual(@as(u32, 1), f.model.mouseState().buttons);
    try f.client.reset();
    try std.testing.expect((try f.status()) == .reset); // native held key suppresses a synthetic up
    try std.testing.expectEqual(@as(u8, 1), f.model.native_keys[4]);
    try std.testing.expectEqual(@as(u32, 1), f.model.native_buttons);
    try f.finish();
}

test "cooperative text has no model SDL size limit and is split without breaking UTF8" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    const text = "hello 🐈 日本語 " ** 100;
    _ = try f.client.send(.{ .text = text });
    try f.queued();
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(std.testing.allocator);
    f.model.observeState(.keyboard);
    try std.testing.expect(!f.model.deliveryFinished());
    while (f.model.popForAdapter(31, 0, std.math.maxInt(u32))) |event| {
        try std.testing.expect(event.text_commit.len <= 31);
        try std.testing.expect(std.unicode.utf8ValidateSlice(event.text_commit));
        try received.appendSlice(std.testing.allocator, event.text_commit);
    }
    try std.testing.expectEqualStrings(text, received.items);
    try std.testing.expectEqual(js.input.Outcome.executed, (try f.status()).completed.outcome);
    _ = try f.client.send(.{ .text = "before\x00after" });
    try std.testing.expectEqual(js.input.Outcome.unsupported, (try f.status()).completed.outcome);
    try f.finish();
}

test "cooperative state polling settles transitions but not scroll and cleanup drops stale events" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    try f.sendKey(.down, 1);
    try f.queued();
    f.model.observeState(.keyboard);
    _ = try f.status();
    try std.testing.expectEqual(@as(usize, 1), f.model.pendingCount());
    try f.client.reset();
    try f.pump();
    for (0..1000) |_| {
        try f.pump();
        if (f.model.delivery != null and f.model.delivery.?.kind == .cleanup) break;
        os.time.sleep(std.time.ns_per_ms);
    }
    // The unread down was invalidated, leaving only its release.
    try std.testing.expect(f.model.pop().? == .key_up);
    try std.testing.expect(f.model.pop() == null);
    try std.testing.expect((try f.status()) == .reset);
    _ = try f.client.send(.{ .scroll = .{ .x = 0.25, .y = 0.5, .unit = .line, .position = .{ .x = 40, .y = 50, .revision = 1 } } });
    try f.queued();
    f.model.observeState(.pointer);
    try std.testing.expect(!f.model.deliveryFinished());
    const scroll = f.model.pop().?.mouse_wheel;
    try std.testing.expectEqual(@as(?f32, 0.25), scroll.precise_x);
    try std.testing.expectEqual(@as(?f32, -0.5), scroll.precise_y);
    _ = try f.status();
    try f.finish();
}

test "cooperative cleanup allocation failure quarantines the executor instead of confirming release" {
    if (!js.enabled) return;
    var f = try Fixture.init();
    try f.sendKey(.down, 1);
    try f.queued();
    _ = f.model.pop();
    _ = try f.status();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    f.model.allocator = failing.allocator();
    f.client.close();
    for (0..1000) |_| {
        f.pump() catch |err| {
            try std.testing.expectEqual(error.RecoveryRequired, err);
            break;
        };
        os.time.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(f.model.remoteScanHeld(4));
    f.client.deinit();
    f.executor.stopTransport();
    try std.testing.expectError(error.RecoveryRequired, f.executor.target.deinit());
    // Only this test owns a synthetic executor with no application side effects.
    f.model.deinit();
    try f.executor.target.resolveFailedCleanup();
    try f.executor.target.deinit();
    std.testing.allocator.destroy(f.executor);
}

test "executor native motion controls ordinary release and cleanup coordinates" {
    if (!js.enabled) return;
    for ([_]bool{ false, true }) |reset| {
        var f = try Fixture.init();
        _ = f.model.updateNativeMouse(0, 0, 0);
        _ = try f.client.send(.{ .button = .{ .button = .primary, .action = .down, .position = .{ .x = 10, .y = 10, .revision = 1 } } });
        try f.queued();
        _ = f.model.pop();
        _ = try f.status();
        try std.testing.expect(f.model.updateNativeMouse(100.5, 120.25, 0));
        if (reset) {
            try f.client.reset();
        } else {
            _ = try f.client.send(.{ .button = .{ .button = .primary, .action = .up, .position = .{ .x = 10, .y = 10, .revision = 1 } } });
        }
        try f.queued();
        const up = f.model.pop().?.mouse_button;
        try std.testing.expect(!up.pressed);
        try std.testing.expectEqual(@as(i32, 100), up.x);
        try std.testing.expectEqual(@as(i32, 120), up.y);
        try std.testing.expectEqual(@as(?f32, 100.5), up.precise_x);
        try std.testing.expectEqual(@as(?f32, 120.25), up.precise_y);
        _ = try f.status();
        try std.testing.expectEqual(@as(i32, 100), f.model.mouseState().x);
        try f.finish();
    }
}

test "executor capacity on key or button release ends assignment and admits after cleanup" {
    if (!js.enabled) return;
    for ([_]bool{ false, true }) |release_button| {
        var f = try Fixture.init();
        const previous = (try f.client.describe()).controller;
        try f.sendKey(.down, 1);
        try f.queued();
        _ = f.model.pop();
        _ = try f.status();
        _ = try f.client.send(.{ .button = .{ .button = .primary, .action = .down, .position = .{ .x = 10, .y = 10, .revision = 1 } } });
        try f.queued();
        _ = f.model.pop();
        _ = try f.status();
        // Unobserved local events cannot be evicted to make room for remote work.
        for (0..768) |_| try f.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointermove });
        if (release_button) {
            _ = try f.client.send(.{ .button = .{ .button = .primary, .action = .up, .position = .{ .x = 10, .y = 10, .revision = 1 } } });
        } else try f.sendKey(.up, 1);
        var cleaned = false;
        for (0..2000) |_| {
            try f.pump();
            f.model.observeState(.keyboard);
            f.model.observeState(.pointer);
            if (!f.model.remoteScanHeld(4) and f.model.remote_buttons == 0 and f.executor.pending == null) {
                cleaned = true;
                break;
            }
            os.time.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(cleaned);
        // Existing unobserved local transitions survived controller cleanup.
        for (0..768) |_| try std.testing.expect(f.model.pop().? == .mouse_motion);
        while (f.model.pop()) |_| {}
        f.client.deinit();
        f.client = try Fixture.connect(f.executor);
        try std.testing.expect((try f.client.describe()).controller != previous);
        try f.sendKey(.down, 2);
        try f.queued();
        try std.testing.expect(f.model.pop().? == .key_down);
        try std.testing.expectEqual(js.input.Outcome.executed, (try f.status()).completed.outcome);
        try f.finish();
    }
}
