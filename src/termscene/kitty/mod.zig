pub const Backend = @import("backend.zig").Backend;
pub const KittyBackend = Backend;

pub const detect = @import("detect.zig");
pub const detectGraphicsSupport = detect.detectGraphicsSupport;
pub const readReplies = detect.readReplies;
