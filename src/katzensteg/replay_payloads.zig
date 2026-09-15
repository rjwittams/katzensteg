//! Owns copied command payloads from producer allocation through worker retirement.
//! Reserve all planes of one command together: waiting between planes could deadlock.
const std = @import("std");

pub const Payloads = struct {
    mutex: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    closed: bool = false,
    waiters: usize = 0,
    live_bytes: usize = 0,
    limit: usize = 64 * 1024 * 1024,
    buffers: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,

    pub fn acquire(self: *Payloads, allocator: std.mem.Allocator, len: usize) ![]u8 {
        return (try self.acquireMany(allocator, 1, .{len}))[0].?;
    }

    pub fn acquireMany(self: *Payloads, allocator: std.mem.Allocator, comptime n: usize, lengths: [n]?usize) ![n]?[]u8 {
        var total: usize = 0;
        for (lengths) |len| total = try std.math.add(usize, total, len orelse 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        // A command larger than the budget may run alone, so valid large textures
        // still make progress. Queued, in-flight, and producer-owned bytes all count.
        while (!self.closed and total != 0 and self.live_bytes != 0 and
            (total > self.limit or self.live_bytes > self.limit - total))
        {
            self.waiters += 1;
            self.changed.broadcast();
            self.changed.wait(&self.mutex);
            self.waiters -= 1;
            self.changed.broadcast();
        }
        if (self.closed) return error.Shutdown;
        var result: [n]?[]u8 = @splat(null);
        errdefer for (result) |buf| {
            if (buf) |b| allocator.free(b);
        };
        for (lengths, 0..) |len, i| {
            if (len) |size| result[i] = try self.takeBuffer(allocator, size);
        }
        self.live_bytes += total;
        return result;
    }

    pub fn copyMany(self: *Payloads, allocator: std.mem.Allocator, comptime n: usize, sources: [n]?[]const u8) ![n]?[]u8 {
        var lengths: [n]?usize = undefined;
        for (sources, 0..) |src, i| lengths[i] = if (src) |s| s.len else null;
        const copies = try self.acquireMany(allocator, n, lengths);
        for (sources, copies) |src, dst| {
            if (src) |s| @memcpy(dst.?, s);
        }
        return copies;
    }

    fn takeBuffer(self: *Payloads, allocator: std.mem.Allocator, len: usize) ![]u8 {
        var idx = self.buffers.items.len;
        while (idx > 0) {
            idx -= 1;
            const buf = self.buffers.items[idx];
            if (buf.len != len) continue;
            _ = self.buffers.swapRemove(idx);
            self.bytes -= buf.len;
            return buf;
        }
        return allocator.alloc(u8, len);
    }

    pub fn release(self: *Payloads, allocator: std.mem.Allocator, buf: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.live_bytes -= buf.len;
        self.changed.broadcast();
        // The idle cache has a separate bound; it never counts as pending work.
        if (self.closed or buf.len == 0 or self.buffers.items.len >= 64 or
            buf.len > self.limit or self.bytes > self.limit - buf.len)
        {
            allocator.free(buf);
            return;
        }
        self.buffers.append(allocator, buf) catch {
            allocator.free(buf);
            return;
        };
        self.bytes += buf.len;
    }

    pub fn close(self: *Payloads) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.changed.broadcast();
        while (self.waiters != 0) self.changed.wait(&self.mutex);
    }

    // The caller must quiesce producers and release every live payload first;
    // close() wakes admission waiters but does not retire their owned buffers.
    pub fn deinit(self: *Payloads, allocator: std.mem.Allocator) void {
        self.close();
        std.debug.assert(self.live_bytes == 0);
        for (self.buffers.items) |buf| allocator.free(buf);
        self.buffers.deinit(allocator);
    }
};

test "payload budget blocks a producer until in-flight data is retired" {
    var pool = Payloads{ .limit = 8 };
    defer pool.deinit(std.testing.allocator);
    const held = try pool.acquire(std.testing.allocator, 8);
    const Producer = struct {
        fn run(p: *Payloads) void {
            const buf = p.acquire(std.testing.allocator, 8) catch unreachable;
            p.release(std.testing.allocator, buf);
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&pool});
    defer thread.join();
    pool.mutex.lock();
    while (pool.waiters == 0) pool.changed.wait(&pool.mutex);
    const live = pool.live_bytes;
    pool.mutex.unlock();
    pool.release(std.testing.allocator, held);
    try std.testing.expectEqual(@as(usize, 8), live);
}

test "shutdown wakes blocked producers without allocating" {
    var pool = Payloads{ .limit = 8 };
    defer pool.deinit(std.testing.allocator);
    const held = try pool.acquire(std.testing.allocator, 8);
    defer pool.release(std.testing.allocator, held);
    const Producer = struct {
        fn run(p: *Payloads) void {
            std.testing.expectError(error.Shutdown, p.acquire(std.testing.allocator, 1)) catch unreachable;
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&pool});
    defer thread.join();
    pool.mutex.lock();
    while (pool.waiters == 0) pool.changed.wait(&pool.mutex);
    pool.mutex.unlock();
    pool.close();
}

test "oversized multiplane payload is admitted atomically and copied" {
    var pool = Payloads{ .limit = 4 };
    defer pool.deinit(std.testing.allocator);
    const copies = try pool.copyMany(std.testing.allocator, 3, .{ "yyyy", "uu", "vv" });
    defer for (copies) |buf| pool.release(std.testing.allocator, buf.?);
    try std.testing.expectEqual(@as(usize, 8), pool.live_bytes);
    try std.testing.expectEqualStrings("yyyy", copies[0].?);
    try std.testing.expectEqualStrings("uu", copies[1].?);
    try std.testing.expectEqualStrings("vv", copies[2].?);
}

test "failed multiplane allocation releases every acquired buffer and reservation" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var pool = Payloads{ .limit = 8 };
            defer pool.deinit(allocator);
            const copies = try pool.copyMany(allocator, 3, .{ "yyyy", "u", "v" });
            pool.close(); // Exercise acquisition failures, not optional idle-cache growth.
            for (copies) |buf| pool.release(allocator, buf.?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
