const std = @import("std");
pub const ns_per_s = std.time.ns_per_s;
pub const ns_per_ms = std.time.ns_per_ms;
pub const ns_per_us = std.time.ns_per_us;
const is_windows = @import("builtin").os.tag == .windows;
const win = struct {
    extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;
    extern "kernel32" fn GetSystemTimePreciseAsFileTime(out: *u64) callconv(.winapi) void;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
};
// The performance-counter frequency is fixed at boot; query it once.
var qpc_frequency = std.atomic.Value(i64).init(0);
fn windowsMonotonic() i128 {
    var freq = qpc_frequency.load(.monotonic);
    if (freq == 0) {
        _ = win.QueryPerformanceFrequency(&freq);
        qpc_frequency.store(freq, .monotonic);
    }
    var counter: i64 = 0;
    _ = win.QueryPerformanceCounter(&counter);
    return @divFloor(@as(i128, counter) * ns_per_s, freq);
}
fn windowsRealtime() i128 {
    var ft: u64 = 0;
    win.GetSystemTimePreciseAsFileTime(&ft);
    // FILETIME counts 100 ns ticks since 1601-01-01.
    return (@as(i128, ft) - 116444736000000000) * 100;
}
fn timestamp(clock: std.c.clockid_t) error{ClockUnavailable}!i128 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock, &value) != 0) return error.ClockUnavailable;
    return @as(i128, value.sec) * ns_per_s + value.nsec;
}
pub fn nanoTimestamp() i128 {
    if (is_windows) return windowsRealtime();
    return timestamp(std.c.CLOCK.REALTIME) catch unreachable;
}
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), ns_per_ms));
}
pub fn sleep(ns: u64) void {
    // Sleep takes whole milliseconds; round up so it sleeps at least `ns`, as
    // nanosleep does.
    if (is_windows) return win.Sleep(@intCast(@min((ns + ns_per_ms - 1) / ns_per_ms, std.math.maxInt(u32) - 1)));
    var remaining: std.c.timespec = .{ .sec = @intCast(ns / ns_per_s), .nsec = @intCast(ns % ns_per_s) };
    while (std.c.nanosleep(&remaining, &remaining) != 0) {
        if (std.posix.errno(-1) != .INTR) return;
    }
}
pub const Instant = struct {
    ns: i128,
    pub fn now() !Instant {
        if (is_windows) return .{ .ns = windowsMonotonic() };
        return .{ .ns = try timestamp(std.c.CLOCK.MONOTONIC) };
    }
    pub fn since(self: Instant, earlier: Instant) u64 {
        return @intCast(@max(0, self.ns - earlier.ns));
    }
};
pub const Timer = struct {
    start_time: Instant,
    pub fn start() !Timer {
        return .{ .start_time = try .now() };
    }
    pub fn read(self: *Timer) u64 {
        return (Instant.now() catch unreachable).since(self.start_time);
    }
    pub fn reset(self: *Timer) void {
        self.start_time = Instant.now() catch unreachable;
    }
    pub fn lap(self: *Timer) u64 {
        const ns = self.read();
        self.reset();
        return ns;
    }
};
