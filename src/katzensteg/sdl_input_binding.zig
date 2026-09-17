//! Resolve native keys against the app's live SDL keymap. This is the one
//! place SDL is consulted for a binding; every source and both Jackstay ends
//! speak the native vocabulary, and SDL numbers never travel over a connection.
const std = @import("std");
const input = @import("input.zig");
const native_key = @import("native_key.zig");
const sdl = @import("katzensteg_sdl");
const is_sdl3 = @hasDecl(sdl, "SDL_PropertiesID");
const real_sdl = if (is_sdl3) @import("real_sdl3.zig") else @import("real_sdl.zig");

pub fn bind(key: native_key.Key) !input.KeyEvent {
    var event = try input.bindStatic(key);
    switch (key.kind) {
        .physical => {
            event.keycode = if (is_sdl3) real_sdl.SDL_GetKeyFromScancode(event.scancode, event.mods, true) else real_sdl.SDL_GetKeyFromScancode(event.scancode);
        },
        .logical => {
            var implicit_mods: u16 = 0;
            const scan = if (is_sdl3) real_sdl.SDL_GetScancodeFromKey(event.keycode, &implicit_mods) else real_sdl.SDL_GetScancodeFromKey(event.keycode);
            // A logical character with no target binding is not a physical key or paste.
            if (scan == 0) return error.Unsupported;
            event.scancode = scan;
        },
    }
    return event;
}
