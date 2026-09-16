const std = @import("std");
pub const ns_per_s = std.time.ns_per_s;
pub const ns_per_ms = std.time.ns_per_ms;
pub const ns_per_us = std.time.ns_per_us;
fn timestamp(clock: std.c.clockid_t) error{ClockUnavailable}!i128 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(clock, &value) != 0) return error.ClockUnavailable;
    return @as(i128, value.sec) * ns_per_s + value.nsec;
}
pub fn nanoTimestamp() i128 {
    return timestamp(std.c.CLOCK.REALTIME) catch unreachable;
}
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), ns_per_ms));
}
pub fn sleep(ns: u64) void {
    var remaining: std.c.timespec = .{ .sec = @intCast(ns / ns_per_s), .nsec = @intCast(ns % ns_per_s) };
    while (std.c.nanosleep(&remaining, &remaining) != 0) {
        if (std.posix.errno(-1) != .INTR) return;
    }
}
pub const Instant = struct {
    ns: i128,
    pub fn now() !Instant {
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
