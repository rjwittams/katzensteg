//! Named shared-memory objects for Kitty `t=s` uploads. POSIX uses
//! `shm_open`; the reader signals consumption by unlinking the name.
//! Windows has no equivalent "name disappears" signal (named file mappings
//! live while any handle is open), so it reports `Unsupported` until an
//! explicit acknowledgement protocol exists; callers fall back to other media.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag != .windows;

pub const CreateError = error{
    Unsupported,
    NameExists,
    SharedMemoryOpenFailed,
    SharedMemoryResizeFailed,
    SharedMemoryMapFailed,
};

/// Identifier folded into object names so concurrent producers do not collide.
pub fn processId() u32 {
    if (!supported) return 0;
    return @intCast(std.c.getpid());
}

/// Creates `name` exclusively and fills it with `bytes`.
pub fn create(name: [:0]const u8, bytes: []const u8) CreateError!void {
    if (!supported) return error.Unsupported;
    const flags: std.c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true };
    const fd = std.c.shm_open(name, @bitCast(flags), @as(c_uint, 0o600));
    if (fd < 0) {
        if (std.c.errno(fd) == .EXIST) return error.NameExists;
        return error.SharedMemoryOpenFailed;
    }
    defer _ = std.c.close(fd);
    errdefer unlink(name);
    if (std.c.ftruncate(fd, @intCast(bytes.len)) != 0) return error.SharedMemoryResizeFailed;
    const mapping = std.c.mmap(null, bytes.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (mapping == std.c.MAP_FAILED) return error.SharedMemoryMapFailed;
    defer _ = std.c.munmap(@alignCast(mapping), bytes.len);
    @memcpy(@as([*]u8, @ptrCast(mapping))[0..bytes.len], bytes);
}

pub fn unlink(name: [:0]const u8) void {
    if (!supported) return;
    _ = std.c.shm_unlink(name);
}

/// True only when the name is known to be gone. Other open failures (e.g.
/// descriptor exhaustion) are not proof of consumption.
pub fn removed(name: [:0]const u8) bool {
    // Nothing is ever created where unsupported, so no object is outstanding.
    if (!supported) return true;
    const flags: std.c.O = .{ .ACCMODE = .RDONLY };
    const fd = std.c.shm_open(name, @bitCast(flags), @as(c_uint, 0));
    if (fd >= 0) {
        _ = std.c.close(fd);
        return false;
    }
    return std.c.errno(fd) == .NOENT;
}
