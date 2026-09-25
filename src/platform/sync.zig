//! Blocking OS-thread synchronization. These objects do not install signal
//! handlers or create an I/O scheduler inside the interposed application.
const std = @import("std");
const builtin = @import("builtin");
pub const Mutex = if (builtin.os.tag == .windows) WinMutex else PosixMutex;
pub const Condition = if (builtin.os.tag == .windows) WinCondition else PosixCondition;
const windows = std.os.windows;
const k32 = struct {
    extern "kernel32" fn AcquireSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn SleepConditionVariableSRW(cv: *windows.CONDITION_VARIABLE, lock: *windows.SRWLOCK, ms: u32, flags: u32) callconv(.winapi) i32;
    extern "kernel32" fn WakeConditionVariable(cv: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
    extern "kernel32" fn WakeAllConditionVariable(cv: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
};
const WinMutex = struct {
    native: windows.SRWLOCK = .{},
    pub fn deinit(_: *WinMutex) void {}
    pub fn lock(self: *WinMutex) void {
        k32.AcquireSRWLockExclusive(&self.native);
    }
    pub fn unlock(self: *WinMutex) void {
        k32.ReleaseSRWLockExclusive(&self.native);
    }
};
const WinCondition = struct {
    native: windows.CONDITION_VARIABLE = .{},
    pub fn deinit(_: *WinCondition) void {}
    pub fn wait(self: *WinCondition, mutex: *WinMutex) void {
        _ = k32.SleepConditionVariableSRW(&self.native, &mutex.native, std.math.maxInt(u32), 0);
    }
    pub fn timedWait(self: *WinCondition, mutex: *WinMutex, ns: u64) error{Timeout}!void {
        const ms: u32 = @intCast(@min((ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(u32) - 1));
        if (k32.SleepConditionVariableSRW(&self.native, &mutex.native, ms, 0) == 0) return error.Timeout;
    }
    pub fn signal(self: *WinCondition) void {
        k32.WakeConditionVariable(&self.native);
    }
    pub fn broadcast(self: *WinCondition) void {
        k32.WakeAllConditionVariable(&self.native);
    }
};
const PosixMutex = struct {
    native: std.c.pthread_mutex_t = .{},
    pub fn deinit(self: *PosixMutex) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.native) == .SUCCESS);
    }
    pub fn lock(self: *PosixMutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.native) == .SUCCESS);
    }
    pub fn unlock(self: *PosixMutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.native) == .SUCCESS);
    }
};
const PosixCondition = struct {
    native: std.c.pthread_cond_t = .{},
    pub fn deinit(self: *PosixCondition) void {
        std.debug.assert(std.c.pthread_cond_destroy(&self.native) == .SUCCESS);
    }
    pub fn wait(self: *PosixCondition, mutex: *PosixMutex) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.native, &mutex.native) == .SUCCESS);
    }
    pub fn timedWait(self: *PosixCondition, mutex: *PosixMutex, ns: u64) error{Timeout}!void {
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
    pub fn signal(self: *PosixCondition) void {
        std.debug.assert(std.c.pthread_cond_signal(&self.native) == .SUCCESS);
    }
    pub fn broadcast(self: *PosixCondition) void {
        std.debug.assert(std.c.pthread_cond_broadcast(&self.native) == .SUCCESS);
    }
};

/// Stack size for `runOnLargeStack`, the same as Zig's default for
/// executables and the threads it spawns.
pub const large_stack_size: usize = 16 * 1024 * 1024;

/// Runs `func(args...)` on a stack of at least `large_stack_size` bytes and
/// returns when it has finished.
///
/// Katzensteg runs on the application's own threads. Windows applications
/// built with MSVC reserve 1 MiB for their main thread by default, which
/// Katzensteg's initialization can exceed in Debug builds, so on Windows
/// `func` runs on a helper thread that the caller joins. POSIX main threads
/// reserve several MiB and `func` runs inline. If the helper thread cannot be
/// started, `func` runs inline too.
pub fn runOnLargeStack(comptime func: anytype, args: anytype) void {
    if (builtin.os.tag == .windows) {
        if (std.Thread.spawn(.{ .stack_size = large_stack_size }, func, args)) |thread| {
            thread.join();
            return;
        } else |_| {}
    }
    @call(.auto, func, args);
}
