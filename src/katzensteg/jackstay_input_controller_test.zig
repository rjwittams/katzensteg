const std = @import("std");
const os = @import("platform");
const js = @import("jackstay");
const input = @import("input.zig");
const Controller = @import("jackstay_input_controller.zig").Controller;
const Fixture = struct {
    target: js.input.Target,
    server: js.input.Server,
    controller: Controller,
    model: input.InputModel,
    fn init() !Fixture {
        return initWith(.{ .logical = true, .text = true, .pointer = true, .scroll = true });
    }
    fn initWith(capabilities: js.input.Capabilities) !Fixture {
        var target = try js.input.Target.init(.{ .capabilities = capabilities, .geometry = .{ .width = 1280, .height = 960 } });
        var fds: [2]i32 = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
        const server = try target.serve(&fds[0]);
        return .{ .target = target, .server = server, .controller = try Controller.init(try js.input.Client.connect(&fds[1], .cooperative)), .model = input.InputModel.init(std.testing.allocator) };
    }
    fn next(self: *Fixture) !js.input.Work {
        for (0..2000) |_| {
            try self.controller.pump(&self.model);
            if (try self.target.next()) |work| return work;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.NoWork;
    }
    fn settle(self: *Fixture) !void {
        for (0..2000) |_| {
            try self.controller.pump(&self.model);
            if (!self.controller.resetting and self.controller.outstanding.items.len == 0) return;
            os.time.sleep(std.time.ns_per_ms);
        }
        return error.NoResult;
    }
    fn finish(self: *Fixture) !void {
        self.controller.close();
        for (0..2000) |_| {
            if (try self.target.next()) |value| {
                var work = value;
                try work.complete(.executed);
            }
            try self.controller.poll(&self.model);
            if (self.controller.closed) break;
            os.time.sleep(std.time.ns_per_ms);
        }
        try std.testing.expect(self.controller.clean);
        self.controller.deinit();
        self.server.deinit();
        try self.target.deinit();
        self.model.deinit();
    }
};

test "presenter sends logical keys and intact UTF8 text with separate execution results" {
    var f = try Fixture.init();
    try f.model.feed("\xc3");
    try std.testing.expectEqual(@as(usize, 0), f.model.pendingCount());
    try f.model.feed("\xa9");
    var down = try f.next();
    const key = (try down.event()).key;
    try std.testing.expectEqual(js.input.KeyKind.logical, key.kind);
    try std.testing.expectEqualStrings("é", key.name);
    try std.testing.expect(f.controller.outstanding.items.len > 0);
    try down.complete(.executed);
    var text = try f.next();
    try std.testing.expectEqualStrings("é", (try text.event()).text);
    try text.complete(.executed);
    var up = try f.next();
    try std.testing.expectEqual(key.press, (try up.event()).key.press);
    try up.complete(.executed);
    try f.settle();
    try f.finish();
}

test "presenter maps source pixels to logical geometry and preserves fractional line scroll" {
    var f = try Fixture.init();
    try f.model.injectSourcePointer(.{ .x = 160, .y = 120, .width = 640, .height = 480, .kind = .pointerdown, .button = 2, .buttons = 2 });
    var work = try f.next();
    const button = (try work.event()).button;
    try std.testing.expectEqual(js.input.Button.secondary, button.button);
    try std.testing.expectEqual(@as(f64, 320), button.position.x);
    try std.testing.expectEqual(@as(f64, 240), button.position.y);
    try work.complete(.executed);
    try f.model.injectPointer(.{ .kind = .wheel, .button = -1, .buttons = 0, .col = 1, .row = 1, .delta_x = 0.25, .delta_y = -0.5 });
    work = try f.next();
    const scroll = (try work.event()).scroll;
    try std.testing.expectEqual(@as(f64, 0.25), scroll.x);
    try std.testing.expectEqual(@as(f64, -0.5), scroll.y);
    try work.complete(.executed);
    try f.settle();
    try f.finish();
}

test "presenter focus loss waits for cleanup before accepting fresh input" {
    var f = try Fixture.init();
    try f.model.injectKey(.{ .key = "enter", .action = .down });
    var down = try f.next();
    try f.model.feed("\x1b[O");
    try f.controller.pump(&f.model);
    try std.testing.expect(f.controller.resetting);
    try f.model.feed("x");
    try f.controller.pump(&f.model);
    try std.testing.expectEqual(@as(usize, 0), f.model.pendingCount());
    try down.complete(.executed);
    var cleanup = try f.next();
    try std.testing.expectEqual(js.input.Scope.all, (try cleanup.cleanup()).?.scope);
    try cleanup.complete(.executed);
    try f.settle();
    try f.model.injectKey(.{ .key = "enter", .action = .up });
    try f.controller.pump(&f.model);
    try std.testing.expectEqual(@as(usize, 0), f.controller.outstanding.items.len);
    try f.finish();
}

test "presenter geometry reset preserves confirmed keyboard holds and uses the new revision" {
    var f = try Fixture.init();
    try f.model.injectKey(.{ .key = "enter", .action = .down });
    var work = try f.next();
    const press = (try work.event()).key.press;
    try work.complete(.executed);
    try f.settle();
    try f.target.setGeometry(.{ .revision = 2, .width = 320, .height = 240 });
    work = try f.next();
    try std.testing.expectEqual(js.input.Scope.pointer, (try work.cleanup()).?.scope);
    try work.complete(.executed);
    for (0..2000) |_| {
        try f.controller.pump(&f.model);
        if (f.controller.admission.geometry.revision == 2) break;
        os.time.sleep(std.time.ns_per_ms);
    }
    try f.model.injectKey(.{ .key = "enter", .action = .up });
    work = try f.next();
    try std.testing.expectEqual(press, (try work.event()).key.press);
    try work.complete(.executed);
    try f.model.injectSourcePointer(.{ .x = 320, .y = 240, .width = 640, .height = 480, .kind = .pointermove });
    work = try f.next();
    const motion = (try work.event()).motion;
    try std.testing.expectEqual(@as(u64, 2), motion.revision);
    try std.testing.expectEqual(@as(f64, 160), motion.x);
    try work.complete(.executed);
    try f.settle();
    try f.finish();
}

test "presenter view mapping change releases pointer only and bounded admission waits for outcomes" {
    var f = try Fixture.init();
    try f.model.injectSourcePointer(.{ .x = 1, .y = 1, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
    var work = try f.next();
    try work.complete(.executed);
    try f.settle();
    var new_target = f.model.target;
    new_target.cols += 1;
    f.model.setTarget(new_target);
    try f.model.injectSourcePointer(.{ .x = 2, .y = 2, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
    work = try f.next();
    try std.testing.expectEqual(js.input.Action.up, (try work.event()).button.action);
    try work.complete(.executed);
    work = try f.next();
    try std.testing.expectEqual(js.input.Action.down, (try work.event()).button.action);
    try work.complete(.executed);
    try f.settle();
    try f.model.feed("abcdefghijklmnopqrstuvwxyz");
    try f.controller.pump(&f.model);
    try std.testing.expectEqual(@as(usize, 32), f.controller.outstanding.items.len);
    try std.testing.expect(f.model.pendingCount() > 0);
    try f.model.feed("\x1b[O");
    try f.controller.pump(&f.model);
    try f.finish();
}

test "presenter does not replay partial execution and source overflow requests cleanup" {
    var f = try Fixture.init();
    try f.model.injectKey(.{ .key = "enter", .action = .down });
    var work = try f.next();
    try work.complete(.partial);
    work = try f.next();
    try std.testing.expectEqual(js.input.Scope.all, (try work.cleanup()).?.scope);
    // The target can issue cleanup before the client worker delivers the
    // partial-result notification. Observe that notification before asking
    // the fixture to finish, so it does not initiate an unrelated user close.
    for (0..2000) |_| {
        try f.controller.poll(&f.model);
        if (f.controller.closing) break;
        os.time.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(f.controller.closing);
    try work.complete(.executed);
    try std.testing.expectEqual(@as(usize, 0), f.model.pendingCount());
    try f.finish();
    var overflow = try Fixture.init();
    try overflow.model.injectKey(.{ .key = "enter", .action = .down });
    work = try overflow.next();
    try work.complete(.executed);
    try overflow.settle();
    try overflow.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
    work = try overflow.next();
    try work.complete(.executed);
    try overflow.settle();
    overflow.model.queue_limit = 2;
    try std.testing.expectError(error.Capacity, overflow.model.feed("a"));
    work = try overflow.next();
    try std.testing.expectEqual(js.input.Scope.all, (try work.cleanup()).?.scope);
    try work.complete(.executed);
    try std.testing.expect(overflow.controller.closing);
    for (0..2000) |_| {
        try overflow.controller.pump(&overflow.model);
        if (overflow.controller.closed) break;
        os.time.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(overflow.controller.closed and overflow.controller.clean);
    overflow.model.queue_limit = 8192;
    try overflow.model.feed("x");
    try overflow.controller.pump(&overflow.model);
    try std.testing.expectEqual(@as(usize, 0), overflow.model.pendingCount());
    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    var fresh_server = try overflow.target.serve(&fds[0]);
    var fresh = try js.input.Client.connect(&fds[1], .cooperative);
    try std.testing.expect((try fresh.describe()).controller != overflow.controller.admission.controller);
    fresh.deinit();
    fresh_server.deinit();
    while (try overflow.target.next()) |value| {
        var cleanup = value;
        try cleanup.complete(.executed);
    }
    try overflow.finish();
}

test "presenter settles or cleans up a key release racing geometry without replay" {
    var f = try Fixture.init();
    try f.model.injectKey(.{ .key = "enter", .action = .down });
    var work = try f.next();
    const press = (try work.event()).key.press;
    try work.complete(.executed);
    try f.settle();
    try f.model.injectKey(.{ .key = "enter", .action = .up });
    try f.controller.pump(&f.model);
    try f.target.setGeometry(.{ .revision = 2, .width = 320, .height = 240 });
    work = try f.next();
    try std.testing.expect((try work.cleanup()) != null);
    try work.complete(.executed);
    // The old release either survived in the target queue or was refused as
    // stale in transit. The latter must request cleanup without requiring the
    // human to release the already-released key a second time.
    work = try f.next();
    if (try work.cleanup()) |cleanup| {
        try std.testing.expectEqual(js.input.Scope.all, cleanup.scope);
    } else {
        try std.testing.expectEqual(press, (try work.event()).key.press);
        try std.testing.expectEqual(js.input.Action.up, (try work.event()).key.action);
    }
    try work.complete(.executed);
    try f.settle();
    for (f.controller.presses) |held| try std.testing.expect(held == null);
    try f.finish();
}

test "presenter rejected button releases request cleanup including viewport releases" {
    for ([_]bool{ false, true }) |viewport| {
        var f = try Fixture.init();
        try f.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
        var work = try f.next();
        try work.complete(.executed);
        try f.settle();
        if (viewport) {
            var target = f.model.target;
            target.cols += 1;
            f.model.setTarget(target);
        } else {
            try f.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointerup, .button = 0, .buttons = 0 });
        }
        work = try f.next();
        try std.testing.expectEqual(js.input.Action.up, (try work.event()).button.action);
        try work.complete(.rejected);
        work = try f.next();
        try std.testing.expectEqual(js.input.Scope.all, (try work.cleanup()).?.scope);
        try work.complete(.executed);
        try f.settle();
        try f.finish();
    }
}

test "presenter waits for button outcomes before a subsequent click and suppresses rejected downs" {
    for ([_]js.input.Outcome{ .executed, .rejected }) |outcome| {
        var f = try Fixture.init();
        defer f.finish() catch unreachable;
        for (0..2) |_| {
            try f.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
            try f.model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointerup, .button = 0, .buttons = 0 });
        }
        for (0..2) |_| {
            var work = try f.next();
            try std.testing.expectEqual(js.input.Action.down, (try work.event()).button.action);
            try std.testing.expectEqual(@as(usize, 1), f.controller.outstanding.items.len);
            try work.complete(outcome);
            if (outcome == .executed) {
                work = try f.next();
                try std.testing.expectEqual(js.input.Action.up, (try work.event()).button.action);
                try std.testing.expectEqual(@as(u8, 1), f.controller.buttons);
                try work.complete(.executed);
            }
        }
        try f.settle();
        try std.testing.expectEqual(@as(u8, 0), f.controller.buttons);
    }
}

test "presenter sends positions as physical keys when the target executes them" {
    var f = try Fixture.initWith(.{ .physical = true, .logical = true, .text = true, .pointer = true, .scroll = true });
    try f.model.feed("\x1b[?31u\x1b[97::113;1;97u");
    var down = try f.next();
    const key = (try down.event()).key;
    try std.testing.expectEqual(js.input.KeyKind.physical, key.kind);
    try std.testing.expectEqualStrings("KeyQ", key.name);
    try std.testing.expectEqual(js.input.Action.down, key.action);
    try down.complete(.executed);
    var text = try f.next();
    try std.testing.expectEqualStrings("a", (try text.event()).text);
    try text.complete(.executed);
    try f.model.feed("\x1b[97::113;1:3u");
    var up = try f.next();
    try std.testing.expectEqual(js.input.Action.up, (try up.event()).key.action);
    try std.testing.expectEqual(key.press, (try up.event()).key.press);
    try up.complete(.executed);
    try f.settle();
    try f.finish();
    // A logical-only target still receives the key's meaning.
    var logical = try Fixture.init();
    try logical.model.feed("\x1b[?31u\x1b[97::113;1;97u\x1b[97::113;1:3u");
    var work = try logical.next();
    try std.testing.expectEqual(js.input.KeyKind.logical, (try work.event()).key.kind);
    try std.testing.expectEqualStrings("a", (try work.event()).key.name);
    try work.complete(.executed);
    work = try logical.next();
    try work.complete(.executed);
    work = try logical.next();
    try std.testing.expectEqual(js.input.Action.up, (try work.event()).key.action);
    try work.complete(.executed);
    try logical.settle();
    try logical.finish();
}
