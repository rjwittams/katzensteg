const std = @import("std");
const sdl = @import("katzensteg_sdl");

const usage =
    \\usage: katzensteg-input-probe-sdl3 [--log-events] [--custom-cursor] [--frames N]
;

fn expectSdlTrue(name: []const u8, value: sdl.SDL_bool) !void {
    if (value) return;
    std.debug.print("{s} failed: {s}\n", .{ name, sdl.sdlError() });
    return error.SDLCallFailed;
}

fn expectCondition(name: []const u8, ok: bool) !void {
    if (ok) return;
    std.debug.print("{s} assertion failed\n", .{name});
    return error.ProbeAssertionFailed;
}

pub fn main() !void {
    var log_events = false;
    var custom_cursor = false;
    var max_frames: i32 = 240;

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--log-events")) {
            log_events = true;
        } else if (std.mem.eql(u8, arg, "--custom-cursor")) {
            custom_cursor = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFramesValue;
            max_frames = std.fmt.parseInt(i32, value, 10) catch return error.InvalidFramesValue;
            if (max_frames <= 0) return error.InvalidFramesValue;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else {
            std.debug.print("unknown arg: {s}\n{s}", .{ arg, usage });
            return error.UnknownArgument;
        }
    }

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_EVENTS)) {
        std.debug.print("SDL_Init failed: {s}\n", .{sdl.sdlError()});
        return error.SDLInitFailed;
    }
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("katzensteg-input-probe-sdl3", 800, 480, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{sdl.sdlError()});
        return error.SDLCreateWindowFailed;
    };
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{sdl.sdlError()});
        return error.SDLCreateRendererFailed;
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    var custom_cursor_surface: ?*sdl.SDL_Surface = null;
    var custom_cursor_handle: ?*sdl.SDL_Cursor = null;
    var custom_cursor_pixels: [16 * 16 * 4]u8 = undefined;

    try expectSdlTrue("SDL_StartTextInput", sdl.SDL_StartTextInput(window));
    try expectCondition("SDL_TextInputActive after start", sdl.SDL_TextInputActive(window));
    const text_input_rect = sdl.SDL_Rect{ .x = 24, .y = 36, .w = 180, .h = 28 };
    try expectSdlTrue("SDL_SetTextInputArea", sdl.SDL_SetTextInputArea(window, &text_input_rect, 11));
    var got_text_input_rect: sdl.SDL_Rect = undefined;
    var got_text_input_cursor: c_int = 0;
    try expectSdlTrue("SDL_GetTextInputArea", sdl.SDL_GetTextInputArea(window, &got_text_input_rect, &got_text_input_cursor));
    try expectCondition("SDL_GetTextInputArea x", got_text_input_rect.x == text_input_rect.x);
    try expectCondition("SDL_GetTextInputArea y", got_text_input_rect.y == text_input_rect.y);
    try expectCondition("SDL_GetTextInputArea w", got_text_input_rect.w == text_input_rect.w);
    try expectCondition("SDL_GetTextInputArea h", got_text_input_rect.h == text_input_rect.h);
    try expectCondition("SDL_GetTextInputArea cursor", got_text_input_cursor == 11);
    try expectSdlTrue("SDL_StopTextInput", sdl.SDL_StopTextInput(window));
    try expectCondition("SDL_TextInputActive after stop", !sdl.SDL_TextInputActive(window));

    const has_keyboard = sdl.SDL_HasKeyboard();
    if (log_events) {
        std.debug.print("SDL_HasKeyboard={}\n", .{has_keyboard});
    }
    _ = sdl.SDL_GetKeyboardFocus();

    const mod_before = sdl.SDL_GetModState();
    sdl.SDL_SetModState(sdl.SDL_KMOD_LSHIFT);
    const mod_shift = sdl.SDL_GetModState();
    try expectCondition("SDL_GetModState after set includes LSHIFT", (mod_shift & sdl.SDL_KMOD_LSHIFT) != 0);
    sdl.SDL_SetModState(sdl.SDL_KMOD_NONE);
    const mod_none = sdl.SDL_GetModState();
    try expectCondition("SDL_GetModState after clear excludes SHIFT", (mod_none & sdl.SDL_KMOD_SHIFT) == 0);
    sdl.SDL_SetModState(mod_before);

    const textinput_enabled_before = sdl.SDL_EventEnabled(sdl.SDL_TEXTINPUT);
    sdl.SDL_SetEventEnabled(sdl.SDL_TEXTINPUT, false);
    try expectCondition("SDL_EventEnabled textinput disabled", !sdl.SDL_EventEnabled(sdl.SDL_TEXTINPUT));
    sdl.SDL_SetEventEnabled(sdl.SDL_TEXTINPUT, true);
    try expectCondition("SDL_EventEnabled textinput enabled", sdl.SDL_EventEnabled(sdl.SDL_TEXTINPUT));
    sdl.SDL_SetEventEnabled(sdl.SDL_TEXTINPUT, textinput_enabled_before);

    try expectSdlTrue("SDL_SetWindowRelativeMouseMode(true)", sdl.SDL_SetWindowRelativeMouseMode(window, true));
    try expectCondition("SDL_GetWindowRelativeMouseMode after enable", sdl.SDL_GetWindowRelativeMouseMode(window));
    try expectSdlTrue("SDL_SetWindowRelativeMouseMode(false)", sdl.SDL_SetWindowRelativeMouseMode(window, false));
    try expectCondition("SDL_GetWindowRelativeMouseMode after disable", !sdl.SDL_GetWindowRelativeMouseMode(window));

    const capture_enabled = sdl.SDL_CaptureMouse(true);
    const capture_disabled = sdl.SDL_CaptureMouse(false);
    try expectCondition("SDL_CaptureMouse disable succeeds after enable", !capture_enabled or capture_disabled);
    if (log_events and (!capture_enabled or !capture_disabled)) {
        std.debug.print(
            "SDL_CaptureMouse returned enable={} disable={} err={s}\n",
            .{ capture_enabled, capture_disabled, sdl.sdlError() },
        );
    }

    if (custom_cursor) {
        for (&custom_cursor_pixels, 0..) |*byte, idx| {
            const channel = idx % 4;
            byte.* = switch (channel) {
                0 => 240,
                1 => 80,
                2 => 32,
                3 => 255,
                else => 0,
            };
        }
        const surface = sdl.SDL_CreateRGBSurfaceWithFormatFrom(@ptrCast(&custom_cursor_pixels), 16, 16, 32, 16 * 4, sdl.SDL_PIXELFORMAT_ABGR8888) orelse {
            std.debug.print("custom cursor install failed: SDL_CreateRGBSurfaceWithFormatFrom: {s}\n", .{sdl.sdlError()});
            return error.SDLCustomCursorSurfaceFailed;
        };
        custom_cursor_surface = surface;
        const cursor = sdl.SDL_CreateColorCursor(surface, 1, 1) orelse {
            std.debug.print("custom cursor install failed: SDL_CreateColorCursor: {s}\n", .{sdl.sdlError()});
            return error.SDLCustomCursorCreateFailed;
        };
        custom_cursor_handle = cursor;
        _ = sdl.SDL_SetCursor(cursor);
        if (!sdl.SDL_ShowCursor()) {
            std.debug.print("custom cursor install failed: SDL_ShowCursor: {s}\n", .{sdl.sdlError()});
            return error.SDLCustomCursorShowFailed;
        }
        std.debug.print("custom cursor install: ok\n", .{});
    }
    defer {
        if (custom_cursor_handle) |cursor| sdl.SDL_DestroyCursor(cursor);
        if (custom_cursor_surface) |surface| sdl.SDL_FreeSurface(surface);
        if (custom_cursor) std.debug.print("custom cursor clear: ok\n", .{});
    }

    var running = true;
    var frame: i32 = 0;
    var event: sdl.SDL_Event = undefined;
    var peek_events: [8]sdl.SDL_Event = undefined;

    while (running and frame < max_frames) : (frame += 1) {
        sdl.SDL_PumpEvents();
        const peep_count = sdl.SDL_PeepEvents(&peek_events, @intCast(peek_events.len), sdl.SDL_PEEKEVENT, 0, 0xffff_ffff);

        while (sdl.SDL_PollEvent(&event)) {
            if (log_events) std.debug.print("event type=0x{x}\n", .{event.type});
            if (event.type == sdl.SDL_QUIT or event.type == sdl.SDL_WINDOWEVENT_CLOSE) {
                running = false;
            }
        }

        var key_count: c_int = 0;
        _ = sdl.SDL_GetKeyboardState(&key_count);
        var mouse_x: f32 = 0;
        var mouse_y: f32 = 0;
        const mouse_buttons = sdl.SDL_GetMouseState(&mouse_x, &mouse_y);
        var global_mouse_x: f32 = 0;
        var global_mouse_y: f32 = 0;
        const global_mouse_buttons = sdl.SDL_GetGlobalMouseState(&global_mouse_x, &global_mouse_y);
        var rel_x: f32 = 0;
        var rel_y: f32 = 0;
        const rel_buttons = sdl.SDL_GetRelativeMouseState(&rel_x, &rel_y);

        if (log_events and @mod(frame, 30) == 0) {
            std.debug.print(
                "frame={d} peep={d} key_count={d} mouse={d:.1},{d:.1} buttons=0x{x} global={d:.1},{d:.1} global_buttons=0x{x} rel={d:.1},{d:.1} rel_buttons=0x{x}\n",
                .{ frame, peep_count, key_count, mouse_x, mouse_y, mouse_buttons, global_mouse_x, global_mouse_y, global_mouse_buttons, rel_x, rel_y, rel_buttons },
            );
        }

        _ = sdl.SDL_SetRenderDrawColor(renderer, 10, 18, 34, 255);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderPoint(renderer, @floatFromInt(@mod(frame, 800)), @floatFromInt(@mod(frame * 3, 480)));
        _ = sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(16);
    }
}
