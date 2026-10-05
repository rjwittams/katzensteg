//! Compile-time shape for desktops built without the optional provider.
const model = @import("session_mirror.zig");
pub const Content = struct {
    mirror: model.Mirror,
    established: bool = false,
    pub fn deinit(_: *Content) void {}
    pub fn detach(_: *Content) void {}
    pub fn ended(_: *const Content) bool {
        return true;
    }
    pub fn resize(_: *Content, _: u16, _: u16) !void {}
    pub fn geometry(_: *Content, _: f32, _: f32) !void {}
    pub fn pump(_: *Content) !bool {
        return false;
    }
};
