//! Shared core library root. Only this library owns the runtime log ABI.
const core_exports = @import("core_exports.zig");

pub const std_options = core_exports.std_options;

comptime {
    _ = core_exports;
    _ = @import("log_exports.zig");
}
