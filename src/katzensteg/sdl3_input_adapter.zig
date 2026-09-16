// SDL3 frontend plumbing currently reuses SDL2 input/event projection.
const std = @import("std");
const system_io = @import("platform");
const input = @import("input.zig");
const runtime_mod = @import("runtime.zig");
const sdl = @import("katzensteg_sdl");
const real_sdl = @import("real_sdl3.zig");

threadlocal var synthetic_text_buf: [16385]u8 = [_]u8{0} ** 16385;

pub fn popInputEvent(rt: *runtime_mod.Runtime, event: ?*sdl.SDL_Event) bool {
    if (!rt.input_enabled) return false;
    var cursor_event: ?sdl.SDL_Event = null;
    const popped = blk: {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        var parser = &(rt.input_parser orelse break :blk false);
        if (event == null) break :blk parser.pendingCount() > 0;
        const input_event = parser.popForAdapter(16384, 0, std.math.maxInt(u32)) orelse break :blk false;
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
        const input_event = parser.popForAdapter(16384, min_type, max_type) orelse break :blk false;
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

pub fn noteRealEvent(rt: *runtime_mod.Runtime, event: *sdl.SDL_Event) void {
    if (rt.hasRemoteInput()) {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        if (rt.input_parser) |*model| {
            if (event.type == sdl.SDL_MOUSEMOTION) event.motion.state |= model.remote_buttons;
            if (event.type == sdl.SDL_KEYDOWN or event.type == sdl.SDL_KEYUP) event.key.mod |= model.heldModifiers();
        }
    }
    if (eventIsMouse(event.*)) {
        rt.input_mutex.lock();
        defer rt.input_mutex.unlock();
        rt.mouse_ownership.claimRealWindow();
    }
    noteCursorPositionFromSdlEvent(rt, event);
}

pub fn mergedKeyboardState(rt: *runtime_mod.Runtime, real_state: ?[*]const sdl.SDL_bool, real_count: c_int, numkeys: ?*c_int) ?[*]const sdl.SDL_bool {
    if (!rt.input_enabled) return real_state;
    rt.input_mutex.lock();
    defer rt.input_mutex.unlock();
    var parser = &(rt.input_parser orelse return real_state);
    @memset(&rt.keyboard_state, 0);
    if (real_state) |keys| {
        const n: usize = @min(rt.keyboard_state.len, @as(usize, @intCast(@max(0, real_count))));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            rt.keyboard_state[i] = @intFromBool(keys[i]);
        }
    }
    var terminal_state = [_]u8{0} ** input.sdl_num_scancodes;
    parser.copyKeyboardState(&terminal_state, system_io.time.nanoTimestamp());
    for (&rt.keyboard_state, terminal_state) |*dst, src| dst.* |= src;
    parser.observeState(.keyboard);
    if (numkeys) |out| out.* = @intCast(rt.keyboard_state.len);
    return @ptrCast(&rt.keyboard_state[0]);
}

pub fn claimedWindowFlags(rt: *const runtime_mod.Runtime, flags: sdl.SDL_WindowFlags) sdl.SDL_WindowFlags {
    if (!rt.input_claimed or !rt.input_claim_focus) return flags;
    return flags | sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS;
}

pub fn shouldSuppressEvent(rt: *runtime_mod.Runtime, event: *const sdl.SDL_Event) bool {
    if (shouldSuppressRemoteRelease(rt, event)) return true;
    if (!rt.input_claimed) return false;
    return shouldSuppressClaimedWindowEvent(true, event.type);
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
        sdl.SDL_MOUSEMOTION => rt.dispatchCursorPosition(.{ .x = @intFromFloat(event.motion.x), .y = @intFromFloat(event.motion.y) }),
        sdl.SDL_MOUSEBUTTONDOWN,
        sdl.SDL_MOUSEBUTTONUP,
        => rt.dispatchCursorPosition(.{ .x = @intFromFloat(event.button.x), .y = @intFromFloat(event.button.y) }),
        sdl.SDL_MOUSEWHEEL => rt.dispatchCursorPosition(.{ .x = @intFromFloat(event.wheel.mouse_x), .y = @intFromFloat(event.wheel.mouse_y) }),
        sdl.SDL_WINDOWEVENT_LEAVE,
        sdl.SDL_WINDOWEVENT_FOCUS_LOST,
        => rt.dispatchCursorPosition(null),
        else => {},
    }
}

fn fillSdlEvent(event: *sdl.SDL_Event, input_event: input.InputEvent) void {
    @memset(&event.padding, 0);
    const now = real_sdl.SDL_GetTicks();
    switch (input_event) {
        .key_down => |key| event.key = .{
            .type = sdl.SDL_KEYDOWN,
            .reserved = 0,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .scancode = key.scancode,
            .key = key.keycode,
            .mod = key.mods,
            .raw = 0,
            .down = true,
            .repeat = key.repeat,
        },
        .key_up => |key| event.key = .{
            .type = sdl.SDL_KEYUP,
            .reserved = 0,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .scancode = key.scancode,
            .key = key.keycode,
            .mod = key.mods,
            .raw = 0,
            .down = false,
            .repeat = false,
        },
        .text => |text| {
            @memset(&synthetic_text_buf, 0);
            var i: usize = 0;
            while (i + 1 < synthetic_text_buf.len and i < text.buf.len and text.buf[i] != 0) : (i += 1) synthetic_text_buf[i] = text.buf[i];
            event.text = .{ .type = sdl.SDL_TEXTINPUT, .reserved = 0, .timestamp = now, .windowID = 0, .text = @ptrCast(&synthetic_text_buf) };
        },
        .text_commit => |text| {
            @memcpy(synthetic_text_buf[0..text.len], text);
            synthetic_text_buf[text.len] = 0;
            event.text = .{ .type = sdl.SDL_TEXTINPUT, .reserved = 0, .timestamp = now, .windowID = 0, .text = @ptrCast(&synthetic_text_buf) };
        },
        .mouse_motion => |motion| event.motion = .{
            .type = sdl.SDL_MOUSEMOTION,
            .reserved = 0,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .state = motion.buttons,
            .x = motion.precise_x orelse @floatFromInt(motion.x),
            .y = motion.precise_y orelse @floatFromInt(motion.y),
            .xrel = motion.precise_xrel orelse @floatFromInt(motion.xrel),
            .yrel = motion.precise_yrel orelse @floatFromInt(motion.yrel),
        },
        .mouse_button => |button| event.button = .{
            .type = if (button.pressed) sdl.SDL_MOUSEBUTTONDOWN else sdl.SDL_MOUSEBUTTONUP,
            .reserved = 0,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .button = button.button,
            .down = button.pressed,
            .clicks = button.clicks,
            .padding = 0,
            .x = button.precise_x orelse @floatFromInt(button.x),
            .y = button.precise_y orelse @floatFromInt(button.y),
        },
        .mouse_wheel => |wheel| event.wheel = .{
            .type = sdl.SDL_MOUSEWHEEL,
            .reserved = 0,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .x = wheel.precise_x orelse @floatFromInt(wheel.x),
            .y = wheel.precise_y orelse @floatFromInt(wheel.y),
            .direction = sdl.SDL_MOUSEWHEEL_NORMAL,
            .mouse_x = wheel.precise_mouse_x orelse @floatFromInt(wheel.mouse_x),
            .mouse_y = wheel.precise_mouse_y orelse @floatFromInt(wheel.mouse_y),
            .integer_x = wheel.x,
            .integer_y = wheel.y,
        },
    }
}

fn shouldSuppressClaimedWindowEvent(claimed: bool, event_type: u32) bool {
    if (!claimed) return false;
    return switch (event_type) {
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
        @as(sdl.SDL_WindowFlags, sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS),
        claimedWindowFlags(&rt, 0),
    );
    rt.input_claimed = false;
    try std.testing.expectEqual(@as(sdl.SDL_WindowFlags, 0), claimedWindowFlags(&rt, 0));
    rt.input_claimed = true;
    rt.input_claim_focus = false;
    try std.testing.expectEqual(@as(sdl.SDL_WindowFlags, 0), claimedWindowFlags(&rt, 0));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT_LEAVE));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT_FOCUS_GAINED));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(false, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
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
    system_io.time.sleep(20 * std.time.ns_per_ms);

    const read_thread = try std.Thread.spawn(.{}, readMouseStateProbe, .{MouseStateProbe{ .rt = &rt, .done = &read_done }});
    system_io.time.sleep(10 * std.time.ns_per_ms);
    const input_read_completed_while_queue_blocked = read_done.load(.acquire);

    rt.queue_mutex.unlock();
    pop_thread.join();
    read_thread.join();

    try std.testing.expect(pop_done.load(.acquire));
    try std.testing.expect(input_read_completed_while_queue_blocked);
}

// App-side source ingestion. Network processing is independent of presentation;
// native snapshots are read here, never by the frame/composite path.
pub fn refreshInput(rt: *runtime_mod.Runtime) void {
    rt.pollTerminalInput();
    if (@import("jackstay").enabled) {
        if (rt.input_executor) |executor| {
            rt.input_mutex.lock();
            defer rt.input_mutex.unlock();
            const model = &(rt.input_parser orelse return);
            var count: c_int = 0;
            @memset(&model.native_keys, 0);
            if (real_sdl.SDL_GetKeyboardState(&count)) |keys| {
                const n: usize = @min(model.native_keys.len, @as(usize, @intCast(@max(0, count))));
                for (0..n) |i| model.native_keys[i] = @intFromBool(keys[i]);
            }
            var native_x: f32 = 0;
            var native_y: f32 = 0;
            const buttons = real_sdl.SDL_GetMouseState(&native_x, &native_y);
            const x: f32 = native_x;
            const y: f32 = native_y;
            if (model.native_mouse_x == null or model.native_mouse_x.? != x or model.native_mouse_y.? != y or buttons != model.native_buttons) rt.mouse_ownership.claimRealWindow();
            model.native_mouse_x = x;
            model.native_mouse_y = y;
            model.native_buttons = buttons;
            executor.pump(model, @import("sdl_input_binding.zig").bind) catch |err| {
                std.log.err("Jackstay input execution failed: {any}", .{err});
            };
            if (model.takeMouseActivity()) rt.mouse_ownership.claimTerminal();
        }
    }
}

pub fn shouldSuppressRemoteRelease(rt: *runtime_mod.Runtime, event: *const sdl.SDL_Event) bool {
    if (!rt.hasRemoteInput()) return false;
    rt.input_mutex.lock();
    defer rt.input_mutex.unlock();
    const model = &(rt.input_parser orelse return false);
    if (event.type == sdl.SDL_KEYUP) return model.remoteScanHeld(event.key.scancode);
    if (event.type == sdl.SDL_MOUSEBUTTONUP and event.button.button >= 1 and event.button.button <= 5) {
        return model.remote_buttons & (@as(u32, 1) << @as(u5, @intCast(event.button.button - 1))) != 0;
    }
    return false;
}

pub fn mergedModifiers(rt: *runtime_mod.Runtime, native: u16) u16 {
    rt.input_mutex.lock();
    defer rt.input_mutex.unlock();
    const model = &(rt.input_parser orelse return native);
    model.observeModifiers();
    return native | model.heldModifiers();
}
