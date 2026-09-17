//! Optional media transport. Disabled builds never import the C header or library.
pub const enabled = @import("features").jackstay;
pub const bootstrap = if (enabled) @import("bootstrap.zig") else struct {};
pub const input = if (enabled) @import("input.zig") else struct {};
pub const media = if (enabled) @import("media.zig") else struct {};
pub const endpoint = if (enabled) @import("endpoint.zig") else struct {};
pub const Publisher = if (enabled) @import("publisher.zig").Publisher else void;

pub fn checkAvailable() !void {
    if (enabled) return media.checkAbi();
    return error.JackstayUnavailable;
}
