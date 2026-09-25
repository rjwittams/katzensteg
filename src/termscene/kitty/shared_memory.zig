//! One-shot Kitty upload objects. The terminal unlinks each name after mapping.
//! A pipe write is not consumption: never age out or overwrite a live object.
const std = @import("std");
const shm = @import("platform").shm;

var sequence = std.atomic.Value(u64).init(0);

pub const Object = struct {
    name_buf: [32]u8 = undefined,
    name_len: usize,
    bytes: usize,
    batch: u64 = 0,

    pub fn name(self: *const Object) [:0]const u8 {
        return self.name_buf[0..self.name_len :0];
    }

    pub fn create(bytes: []const u8) !Object {
        if (bytes.len == 0) return error.EmptySharedMemory;
        var object = Object{ .name_len = 0, .bytes = bytes.len };
        for (0..16) |_| {
            const name_z = try std.fmt.bufPrintZ(&object.name_buf, "/ks{x}-{x}", .{ shm.processId(), sequence.fetchAdd(1, .monotonic) });
            object.name_len = name_z.len;
            shm.create(name_z, bytes) catch |err| switch (err) {
                error.NameExists => continue,
                else => return err,
            };
            return object;
        }
        return error.SharedMemoryNameExhausted;
    }

    pub fn unlink(self: *const Object) void {
        shm.unlink(self.name());
    }

    pub fn consumed(self: *const Object) bool {
        return shm.removed(self.name());
    }
};

pub const Pool = struct {
    pub const max_objects = 64;
    pub const max_bytes = 64 * 1024 * 1024;
    allocator: std.mem.Allocator,
    objects: std.ArrayList(Object) = .empty,
    reserved_objects: usize = 0,
    reserved_bytes: usize = 0,
    bytes: usize = 0,

    pub fn reap(self: *Pool) void {
        var i: usize = 0;
        while (i < self.objects.items.len) {
            if (self.objects.items[i].consumed()) self.remove(i) else i += 1;
        }
    }

    pub fn create(self: *Pool, bytes: []const u8, batch: u64) !*const Object {
        self.reap();
        // Admit one oversized image alone; never overwrite an outstanding upload.
        if (self.reserved_objects != 0) {
            if (bytes.len > self.reserved_bytes) return error.InvalidUploadReservation;
        } else {
            if (self.objects.items.len >= max_objects or (self.objects.items.len != 0 and bytes.len > max_bytes -| self.bytes)) return error.UploadBackpressure;
            try self.objects.ensureTotalCapacity(self.allocator, self.objects.items.len + 1);
        }
        var object = try Object.create(bytes);
        object.batch = batch;
        self.objects.appendAssumeCapacity(object);
        if (self.reserved_objects != 0) {
            self.reserved_objects -= 1;
            self.reserved_bytes -= bytes.len;
        }
        self.bytes += bytes.len;
        return &self.objects.items[self.objects.items.len - 1];
    }

    /// Admit a whole composition before it mutates presentation state. A single
    /// oversized frame is allowed only with no outstanding uploads.
    pub fn reserveBatch(self: *Pool, count: usize, bytes: usize) !void {
        self.reap();
        if (count != 0 and self.objects.items.len != 0 and (count > max_objects -| self.objects.items.len or bytes > max_bytes -| self.bytes)) return error.UploadBackpressure;
        try self.objects.ensureTotalCapacity(self.allocator, self.objects.items.len + count);
        self.reserved_objects = count;
        self.reserved_bytes = bytes;
    }

    pub fn endReservation(self: *Pool) void {
        self.reserved_objects = 0;
        self.reserved_bytes = 0;
    }

    /// Only for batches known never to have reached the terminal.
    pub fn discard(self: *Pool, batch: u64) void {
        var i: usize = 0;
        while (i < self.objects.items.len) {
            if (self.objects.items[i].batch == batch) {
                self.objects.items[i].unlink();
                self.remove(i);
            } else i += 1;
        }
    }

    pub fn deinit(self: *Pool) void {
        for (self.objects.items) |*object| object.unlink();
        self.objects.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    fn remove(self: *Pool, i: usize) void {
        self.bytes -= self.objects.items[i].bytes;
        _ = self.objects.swapRemove(i);
    }
};

test "shared memory pixels survive terminal unlink through its mapping" {
    if (!shm.supported) return error.SkipZigTest;
    const pixels = [_]u8{ 12, 34, 56, 255 };
    const object = try Object.create(&pixels);
    defer object.unlink();
    const flags: std.c.O = .{ .ACCMODE = .RDONLY };
    const fd = std.c.shm_open(object.name(), @bitCast(flags), @as(c_uint, 0));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const mapping = std.c.mmap(null, pixels.len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    try std.testing.expect(mapping != std.c.MAP_FAILED);
    defer _ = std.c.munmap(@alignCast(mapping), pixels.len);
    object.unlink();
    try std.testing.expect(object.consumed());
    try std.testing.expectEqualSlices(u8, &pixels, @as([*]const u8, @ptrCast(mapping))[0..pixels.len]);
}

test "pool bounds outstanding uploads and reclaims only consumed or discarded batches" {
    if (!shm.supported) return error.SkipZigTest;
    var pool: Pool = .{ .allocator = std.testing.allocator };
    defer pool.deinit();
    for (0..Pool.max_objects) |i| _ = try pool.create(&.{ 0, 0, 0, 255 }, i + 1);
    const first = pool.objects.items[0];
    const last = pool.objects.items[Pool.max_objects - 1];
    try std.testing.expectError(error.UploadBackpressure, pool.create(&.{1}, 100));
    try std.testing.expect(!first.consumed());
    first.unlink(); // Terminal consumption.
    pool.reap();
    try std.testing.expectEqual(Pool.max_objects - 1, pool.objects.items.len);
    pool.discard(Pool.max_objects); // Host dropped this exact batch.
    try std.testing.expect(last.consumed());
    try std.testing.expectEqual(Pool.max_objects - 2, pool.objects.items.len);
    _ = try pool.create(&.{1}, 100);
}

test "whole-frame admission rejects pressure before allocation and permits one oversized scene" {
    if (!shm.supported) return error.SkipZigTest;
    var pool: Pool = .{ .allocator = std.testing.allocator };
    defer pool.deinit();
    const old = (try pool.create(&.{ 1, 2, 3, 255 }, 1)).*;
    try std.testing.expectError(error.UploadBackpressure, pool.reserveBatch(Pool.max_objects + 1, 4 * (Pool.max_objects + 1)));
    try std.testing.expectEqual(@as(usize, 1), pool.objects.items.len);
    try std.testing.expect(!old.consumed());
    old.unlink();
    try pool.reserveBatch(Pool.max_objects + 1, 4 * (Pool.max_objects + 1));
    for (0..Pool.max_objects + 1) |_| _ = try pool.create(&.{ 5, 6, 7, 255 }, 2);
    pool.endReservation();
    try std.testing.expectError(error.UploadBackpressure, pool.create(&.{1}, 3));
    pool.discard(2);
    try std.testing.expectEqual(@as(usize, 0), pool.objects.items.len);
    _ = try pool.create(&.{1}, 3);
}
