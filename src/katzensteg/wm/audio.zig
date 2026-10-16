//! The WM's per-window audio policy. The WM resolves solo, volume and mute
//! into one effective gain per producer and sends it as
//! `{"type":"audio","gain":<0..1>}`; the producer stores it as its audio
//! model's gain (see `audio_model.Model.applyPolicyGain`). The WM is the only
//! authority: embedded producers run without a command key, so no local
//! command-mode step competes with it.

const std = @import("std");

pub const Glyph = enum { normal, muted, soloed_out };

pub const Window = struct {
    /// The producer reported a playback device open.
    open: bool = false,
    /// Seeded once from the producer's first open report, which carries its
    /// profile's starting volume (`runtime.audio.volume`) and mute.
    seeded: bool = false,
    volume: f32 = 1,
    muted: bool = false,
    /// The last gain sent; null forces a send.
    sent: ?f32 = null,

    pub fn reported(self: *Window, open: bool, volume: f32, muted: bool) void {
        if (open and !self.seeded) {
            self.volume = std.math.clamp(volume, 0, 1);
            self.muted = muted;
            self.seeded = true;
        }
        self.open = open;
        self.sent = null;
    }

    /// Steps 10% within 0 to 100%, snapping to the nearest step first.
    pub fn step(self: *Window, up: bool) void {
        const next = @round(self.volume * 10) + @as(f32, if (up) 1 else -1);
        self.volume = std.math.clamp(next, 0, 10) / 10;
    }

    pub fn percent(self: Window) u8 {
        return @intFromFloat(@round(self.volume * 100));
    }

    /// Solo silences every window but the focused one.
    pub fn glyph(self: Window, focused: bool, solo: bool) Glyph {
        if (self.muted) return .muted;
        return if (solo and !focused) .soloed_out else .normal;
    }

    pub fn gain(self: Window, focused: bool, solo: bool) f32 {
        return if (self.glyph(focused, solo) == .normal) self.volume else 0;
    }
};

test "solo, mute and volume resolve the effective gain" {
    var window = Window{};
    window.reported(true, 0.5, false);
    try std.testing.expectEqual(@as(f32, 0.5), window.gain(true, true));
    try std.testing.expectEqual(@as(f32, 0), window.gain(false, true));
    try std.testing.expectEqual(Glyph.soloed_out, window.glyph(false, true));
    try std.testing.expectEqual(@as(f32, 0.5), window.gain(false, false));
    window.muted = true;
    try std.testing.expectEqual(@as(f32, 0), window.gain(true, false));
    try std.testing.expectEqual(Glyph.muted, window.glyph(false, true));
}

test "volume steps by 10% within bounds and seeds only once" {
    var window = Window{};
    window.reported(true, 0.34, true);
    try std.testing.expect(window.muted);
    window.step(true);
    try std.testing.expectEqual(@as(u8, 40), window.percent());
    for (0..12) |_| window.step(true);
    try std.testing.expectEqual(@as(u8, 100), window.percent());
    for (0..12) |_| window.step(false);
    try std.testing.expectEqual(@as(u8, 0), window.percent());
    // A reopen reports the WM's own gain back; the window keeps its policy.
    window.reported(false, 0, false);
    window.reported(true, 0.9, false);
    try std.testing.expectEqual(@as(u8, 0), window.percent());
    try std.testing.expect(window.muted and window.open and window.sent == null);
}
