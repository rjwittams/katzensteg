//! Blocking OS-thread synchronization. These objects do not install signal
//! handlers or create an I/O scheduler inside the interposed application.
const std = @import("std");
pub const Mutex = struct {
    native: std.c.pthread_mutex_t = .{},
    pub fn deinit(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.native) == .SUCCESS);
    }
    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.native) == .SUCCESS);
    }
    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.native) == .SUCCESS);
    }
};
pub const Condition = struct {
    native: std.c.pthread_cond_t = .{},
    pub fn deinit(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_destroy(&self.native) == .SUCCESS);
    }
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.native, &mutex.native) == .SUCCESS);
    }
    pub fn timedWait(self: *Condition, mutex: *Mutex, ns: u64) error{Timeout}!void {
        var deadline: std.c.timespec = undefined;
        std.debug.assert(std.c.clock_gettime(std.c.CLOCK.REALTIME, &deadline) == 0);
        const total = @as(u128, @intCast(deadline.nsec)) + ns;
        deadline.sec += @intCast(total / std.time.ns_per_s);
        deadline.nsec = @intCast(total % std.time.ns_per_s);
        switch (std.c.pthread_cond_timedwait(&self.native, &mutex.native, &deadline)) {
            .SUCCESS => {},
            .TIMEDOUT => return error.Timeout,
            else => unreachable,
        }
    }
    pub fn signal(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_signal(&self.native) == .SUCCESS);
    }
    pub fn broadcast(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_broadcast(&self.native) == .SUCCESS);
    }
};
