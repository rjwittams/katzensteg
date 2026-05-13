const std = @import("std");
const input = @import("../input.zig");
const runtime_mod = @import("../runtime.zig");
const sdl = @import("katzensteg_sdl");
const real_sdl = @import("../real_sdl.zig");

pub fn popInputEvent(rt: *runtime_mod.Runtime, event: ?*sdl.SDL_Event) bool {
    if (!rt.input_enabled) return false;
    var cursor_event: ?sdl.SDL_Event = null;
    const popped = blk: {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        var parser = &(rt.input_parser orelse break :blk false);
        const input_event = parser.pop() orelse break :blk false;
        if (inputEventIsMouse(input_event)) rt.mouse_ownership.claimTerminal();
        if (event) |out| {
            fillSdlEvent(out, input_event);
            cursor_event = out.*;
        }
        break :blk true;
    };
    if (!popped) return false;
    if (cursor_event) |captured| noteCursorPositionFromSdlEvent(rt, &captured);
    return true;
}

pub fn popInputEventInRange(rt: *runtime_mod.Runtime, event: ?*sdl.SDL_Event, min_type: u32, max_type: u32) bool {
    if (!rt.input_enabled) return false;
    var cursor_event: ?sdl.SDL_Event = null;
    const popped = blk: {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        var parser = &(rt.input_parser orelse break :blk false);
        const input_event = parser.popSdlRange(min_type, max_type) orelse break :blk false;
        if (inputEventIsMouse(input_event)) rt.mouse_ownership.claimTerminal();
        if (event) |out| {
            fillSdlEvent(out, input_event);
            cursor_event = out.*;
        }
        break :blk true;
    };
    if (!popped) return false;
    if (cursor_event) |captured| noteCursorPositionFromSdlEvent(rt, &captured);
    return true;
}

pub fn noteRealEvent(rt: *runtime_mod.Runtime, event: *const sdl.SDL_Event) void {
    if (eventIsMouse(event.*)) {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        rt.mouse_ownership.claimRealWindow();
    }
    noteCursorPositionFromSdlEvent(rt, event);
}

pub fn mergedKeyboardState(rt: *runtime_mod.Runtime, real_state: ?[*]const u8, real_count: c_int, numkeys: ?*c_int) ?[*]const u8 {
    if (!rt.input_enabled) return real_state;
    rt.input_mutex.lock();
    defer rt.input_mutex.unlock();
    var parser = &(rt.input_parser orelse return real_state);
    @memset(&rt.keyboard_state, 0);
    if (real_state) |keys| {
        const n: usize = @min(rt.keyboard_state.len, @as(usize, @intCast(@max(0, real_count))));
        @memcpy(rt.keyboard_state[0..n], keys[0..n]);
    }
    var terminal_state = [_]u8{0} ** input.sdl_num_scancodes;
    parser.copyKeyboardState(&terminal_state, std.time.nanoTimestamp());
    for (&rt.keyboard_state, terminal_state) |*dst, src| dst.* |= src;
    if (numkeys) |out| out.* = @intCast(rt.keyboard_state.len);
    return &rt.keyboard_state;
}

pub fn claimedWindowFlags(rt: *const runtime_mod.Runtime, flags: u32) u32 {
    if (!rt.input_claimed or !rt.input_claim_focus) return flags;
    return flags | sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS;
}

pub fn shouldSuppressEvent(rt: *const runtime_mod.Runtime, event: *const sdl.SDL_Event) bool {
    if (!rt.input_claimed) return false;
    if (event.type != sdl.SDL_WINDOWEVENT) return false;
    return shouldSuppressClaimedWindowEvent(true, event.type, event.window.event);
}

fn inputEventIsMouse(event: input.InputEvent) bool {
    return switch (event) {
        .mouse_motion,
        .mouse_button,
        .mouse_wheel,
        => true,
        else => false,
    };
}

fn eventIsMouse(event: sdl.SDL_Event) bool {
    return switch (event.type) {
        sdl.SDL_MOUSEMOTION,
        sdl.SDL_MOUSEBUTTONDOWN,
        sdl.SDL_MOUSEBUTTONUP,
        sdl.SDL_MOUSEWHEEL,
        => true,
        else => false,
    };
}

fn noteCursorPositionFromSdlEvent(rt: *runtime_mod.Runtime, event: *const sdl.SDL_Event) void {
    switch (event.type) {
        sdl.SDL_MOUSEMOTION => rt.dispatchCursorPosition(.{ .x = event.motion.x, .y = event.motion.y }),
        sdl.SDL_MOUSEBUTTONDOWN,
        sdl.SDL_MOUSEBUTTONUP,
        => rt.dispatchCursorPosition(.{ .x = event.button.x, .y = event.button.y }),
        sdl.SDL_MOUSEWHEEL => rt.dispatchCursorPosition(.{ .x = event.wheel.mouseX, .y = event.wheel.mouseY }),
        sdl.SDL_WINDOWEVENT => switch (event.window.event) {
            sdl.SDL_WINDOWEVENT_LEAVE,
            sdl.SDL_WINDOWEVENT_FOCUS_LOST,
            => rt.dispatchCursorPosition(null),
            else => {},
        },
        else => {},
    }
}

fn fillSdlEvent(event: *sdl.SDL_Event, input_event: input.InputEvent) void {
    @memset(&event.padding, 0);
    const now = real_sdl.SDL_GetTicks();
    switch (input_event) {
        .key_down => |key| event.key = .{
            .type = sdl.SDL_KEYDOWN,
            .timestamp = now,
            .windowID = 0,
            .state = sdl.SDL_PRESSED,
            .repeat = 0,
            .keysym = .{ .scancode = key.scancode, .sym = key.keycode, .mod = key.mods, .unused = 0 },
        },
        .key_up => |key| event.key = .{
            .type = sdl.SDL_KEYUP,
            .timestamp = now,
            .windowID = 0,
            .state = sdl.SDL_RELEASED,
            .repeat = 0,
            .keysym = .{ .scancode = key.scancode, .sym = key.keycode, .mod = key.mods, .unused = 0 },
        },
        .text => |text| {
            event.text = .{ .type = sdl.SDL_TEXTINPUT, .timestamp = now, .windowID = 0, .text = text.buf };
        },
        .mouse_motion => |motion| event.motion = .{
            .type = sdl.SDL_MOUSEMOTION,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .state = motion.buttons,
            .x = motion.x,
            .y = motion.y,
            .xrel = motion.xrel,
            .yrel = motion.yrel,
        },
        .mouse_button => |button| event.button = .{
            .type = if (button.pressed) sdl.SDL_MOUSEBUTTONDOWN else sdl.SDL_MOUSEBUTTONUP,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .button = button.button,
            .state = if (button.pressed) sdl.SDL_PRESSED else sdl.SDL_RELEASED,
            .clicks = button.clicks,
            .x = button.x,
            .y = button.y,
        },
        .mouse_wheel => |wheel| event.wheel = .{
            .type = sdl.SDL_MOUSEWHEEL,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .x = wheel.x,
            .y = wheel.y,
            .direction = sdl.SDL_MOUSEWHEEL_NORMAL,
            .preciseX = @floatFromInt(wheel.x),
            .preciseY = @floatFromInt(wheel.y),
            .mouseX = wheel.mouse_x,
            .mouseY = wheel.mouse_y,
        },
    }
}

fn shouldSuppressClaimedWindowEvent(claimed: bool, event_type: u32, window_event: u8) bool {
    if (!claimed or event_type != sdl.SDL_WINDOWEVENT) return false;
    return switch (window_event) {
        sdl.SDL_WINDOWEVENT_FOCUS_LOST,
        sdl.SDL_WINDOWEVENT_LEAVE,
        => true,
        else => false,
    };
}

test "SDL mouse events are recognized for ownership handoff" {
    var event: sdl.SDL_Event = undefined;
    event.type = sdl.SDL_MOUSEMOTION;
    try std.testing.expect(eventIsMouse(event));
    event.type = sdl.SDL_KEYDOWN;
    try std.testing.expect(!eventIsMouse(event));
}

test "claimed input keeps SDL window focused locally" {
    var rt: runtime_mod.Runtime = undefined;
    rt.input_claimed = true;
    rt.input_claim_focus = true;

    try std.testing.expectEqual(
        @as(u32, sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS),
        claimedWindowFlags(&rt, 0),
    );
    rt.input_claimed = false;
    try std.testing.expectEqual(@as(u32, 0), claimedWindowFlags(&rt, 0));
    rt.input_claimed = true;
    rt.input_claim_focus = false;
    try std.testing.expectEqual(@as(u32, 0), claimedWindowFlags(&rt, 0));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_LEAVE));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_GAINED));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(false, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
}

const PopProbe = struct {
    rt: *runtime_mod.Runtime,
    done: *std.atomic.Value(bool),
};

fn popInputEventProbe(probe: PopProbe) void {
    var event: sdl.SDL_Event = undefined;
    _ = popInputEvent(probe.rt, &event);
    probe.done.store(true, .release);
}

const MouseStateProbe = struct {
    rt: *runtime_mod.Runtime,
    done: *std.atomic.Value(bool),
};

fn readMouseStateProbe(probe: MouseStateProbe) void {
    _ = probe.rt.terminalMouseState();
    probe.done.store(true, .release);
}

test "SDL input pop does not hold input mutex while queueing cursor position" {
    // Timing-based regression: if cursor dispatch still happens under
    // input_mutex, the mouse-state reader cannot complete while queue_mutex is
    // held by the test.
    var rt = runtime_mod.Runtime.initShutdownStub();
    defer rt.deinit();

    rt.input_enabled = true;
    rt.intercept_mode = .queued_replay;
    rt.input_parser = input.TerminalInputParser.init(rt.allocator);
    rt.input_parser.?.setTarget(.{ .cols = 80, .rows = 24, .w = 640, .h = 480 });
    try rt.input_parser.?.feed("\x1b[<35;11;11M");

    var pop_done = std.atomic.Value(bool).init(false);
    var read_done = std.atomic.Value(bool).init(false);

    rt.queue_mutex.lock();
    const pop_thread = try std.Thread.spawn(.{}, popInputEventProbe, .{PopProbe{ .rt = &rt, .done = &pop_done }});
    std.Thread.sleep(20 * std.time.ns_per_ms);

    const read_thread = try std.Thread.spawn(.{}, readMouseStateProbe, .{MouseStateProbe{ .rt = &rt, .done = &read_done }});
    std.Thread.sleep(10 * std.time.ns_per_ms);
    const input_read_completed_while_queue_blocked = read_done.load(.acquire);

    rt.queue_mutex.unlock();
    pop_thread.join();
    read_thread.join();

    try std.testing.expect(pop_done.load(.acquire));
    try std.testing.expect(input_read_completed_while_queue_blocked);
}
