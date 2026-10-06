//! File logging ABI owned by the shared core library.
const log_mod = @import("log.zig");

pub export fn ks_katzensteg_log_write_line(message: [*]const u8, len: usize) callconv(.c) void {
    log_mod.writeLine(message[0..len]);
}

pub export fn ks_katzensteg_log_retain() callconv(.c) void {
    log_mod.retainLoggerFileUser();
}

pub export fn ks_katzensteg_log_release() callconv(.c) void {
    log_mod.releaseLoggerFileUser();
}
