//! The fixed-capacity byte queue an adapter owns for a queue-mode device (an
//! SDL2 app that opens with a NULL callback and feeds `SDL_QueueAudio`).
//! One producer (app threads, serialized by the adapter) and one consumer
//! (the device's audio thread). Every operation is lock-free and never
//! allocates; the buffer is allocated once, at open.

const std = @import("std");

pub const ByteQueue = struct {
    buffer: []u8,
    /// Bytes ever consumed. Written by the consumer.
    head: std.atomic.Value(u64) = .init(0),
    /// Bytes ever queued. Written by the producer.
    tail: std.atomic.Value(u64) = .init(0),
    /// Everything before this was cleared; the consumer skips up to it.
    clear_to: std.atomic.Value(u64) = .init(0),

    fn readPosition(self: *const ByteQueue) u64 {
        return @max(self.head.load(.acquire), self.clear_to.load(.acquire));
    }

    /// The two buffer slices holding `len` bytes from `position`.
    fn ring(self: *ByteQueue, position: u64, len: usize) [2][]u8 {
        const offset: usize = @intCast(position % self.buffer.len);
        const first = @min(len, self.buffer.len - offset);
        return .{ self.buffer[offset..][0..first], self.buffer[0 .. len - first] };
    }

    /// Bytes queued and not yet played or cleared. Either thread.
    pub fn queued(self: *const ByteQueue) u64 {
        return self.tail.load(.acquire) -| self.readPosition();
    }

    /// Producer. Queues nothing and returns false when `data` does not fit.
    pub fn push(self: *ByteQueue, data: []const u8) bool {
        const tail = self.tail.load(.monotonic);
        // Cleared bytes the consumer has not skipped yet still count as used.
        if (data.len > self.buffer.len - (tail - self.head.load(.acquire))) return false;
        const parts = self.ring(tail, data.len);
        @memcpy(parts[0], data[0..parts[0].len]);
        @memcpy(parts[1], data[parts[0].len..]);
        self.tail.store(tail + data.len, .release);
        return true;
    }

    /// Producer. Drops everything queued so far.
    pub fn clear(self: *ByteQueue) void {
        self.clear_to.store(self.tail.load(.monotonic), .release);
    }

    /// Consumer. Moves up to `out.len` bytes into `out`; returns the count.
    pub fn pop(self: *ByteQueue, out: []u8) usize {
        const start = self.readPosition();
        const n: usize = @intCast(@min(self.tail.load(.acquire) -| start, out.len));
        const parts = self.ring(start, n);
        @memcpy(out[0..parts[0].len], parts[0]);
        @memcpy(out[parts[0].len..n], parts[1]);
        self.head.store(start + n, .release);
        return n;
    }
};

test "bytes come out in order across the wrap, overflow is refused and clear empties" {
    var storage: [8]u8 = undefined;
    var queue: ByteQueue = .{ .buffer = &storage };
    var out: [8]u8 = undefined;
    try std.testing.expect(queue.push(&.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectEqual(@as(usize, 4), queue.pop(out[0..4]));
    try std.testing.expect(!queue.push(&.{ 7, 8, 9, 10, 11, 12, 13 }));
    try std.testing.expect(queue.push(&.{ 7, 8, 9, 10, 11 }));
    try std.testing.expectEqual(@as(u64, 7), queue.queued());
    try std.testing.expectEqual(@as(usize, 7), queue.pop(&out));
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8, 9, 10, 11 }, out[0..7]);

    try std.testing.expect(queue.push(&.{ 1, 2, 3 }));
    queue.clear();
    try std.testing.expectEqual(@as(u64, 0), queue.queued());
    try std.testing.expect(queue.push(&.{ 9, 8 }));
    try std.testing.expectEqual(@as(usize, 2), queue.pop(&out));
    try std.testing.expectEqualSlices(u8, &.{ 9, 8 }, out[0..2]);
}
