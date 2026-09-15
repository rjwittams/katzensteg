const std = @import("std");

const ControlWriter = struct {
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    channel: ?*ClientChannel = null,
    err: ?anyerror = null,

    fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ControlWriter = @fieldParentPtr("interface", interface);
        for (data, 0..) |bytes, i| {
            if (i == data.len - 1 and splat == 0) break;
            if (bytes.len == 0) continue;
            return self.channel.?.writeControl(bytes) catch |err| {
                self.err = err;
                return error.WriteFailed;
            };
        }
        return 0;
    }
};

pub const SessionId = u32;

pub const StdioChannel = struct {
    control: ?std.fs.File = null,
    presentation: ?std.fs.File = null,
    control_open: bool = true,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    pending: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    output: ControlWriter = .{},
};

pub const SocketChannel = struct {
    file: ?std.fs.File,
    control_open: bool = true,
    presentation_open: bool = true,
    allocator: std.mem.Allocator = std.heap.page_allocator,
    pending: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    output: ControlWriter = .{},

    fn closeIfFinished(self: *SocketChannel) void {
        if (self.control_open or self.presentation_open or self.pending.items.len != 0) return;
        if (self.file) |file| file.close();
        self.file = null;
    }
};

// Owns its descriptors. Files returned by the accessors are borrowed: callers
// must close directions through this channel, never through the borrowed File.
// A socket has one owner even though both protocol directions use the same FD.
// The owning host event loop serializes writes, flushes and teardown. Channel
// descriptors and pending bytes must not be accessed concurrently.
pub const ClientChannel = union(enum) {
    stdio: StdioChannel,
    socket: SocketChannel,

    pub fn controlFile(self: ClientChannel) ?std.fs.File {
        return switch (self) {
            .stdio => |pipes| if (pipes.control_open) pipes.control else null,
            .socket => |socket| if (socket.control_open) socket.file else null,
        };
    }

    pub fn presentationFile(self: ClientChannel) ?std.fs.File {
        return switch (self) {
            .stdio => |pipes| pipes.presentation,
            .socket => |socket| if (socket.presentation_open) socket.file else null,
        };
    }

    // Borrowed until the channel moves or is destroyed. The interface has no
    // buffer: writes enter the same bounded pending queue as before.
    pub fn writer(self: *ClientChannel) *std.Io.Writer {
        switch (self.*) {
            inline else => |*transport| {
                transport.output.channel = self;
                transport.output.err = null;
                return &transport.output.interface;
            },
        }
    }

    pub fn writeError(self: *const ClientChannel) ?anyerror {
        return switch (self.*) {
            inline else => |transport| transport.output.err,
        };
    }

    fn writeControl(self: *ClientChannel, bytes: []const u8) !usize {
        _ = self.controlFile() orelse return error.ControlClosed;
        switch (self.*) {
            inline else => |*transport| {
                if (transport.sent != 0) {
                    const remaining = transport.pending.items[transport.sent..];
                    std.mem.copyForwards(u8, transport.pending.items[0..remaining.len], remaining);
                    transport.pending.shrinkRetainingCapacity(remaining.len);
                    transport.sent = 0;
                }
                if (transport.pending.items.len + bytes.len > 512 * 1024) return error.ControlBackpressure;
                try transport.pending.appendSlice(transport.allocator, bytes);
            },
        }
        try self.flushControl();
        return bytes.len;
    }

    pub fn flushControl(self: *ClientChannel) !void {
        switch (self.*) {
            .stdio => |*pipes| {
                const file = pipes.control orelse return;
                while (pipes.sent < pipes.pending.items.len) {
                    const n = file.write(pipes.pending.items[pipes.sent..]) catch |err| switch (err) {
                        error.WouldBlock => return,
                        else => {
                            file.close();
                            pipes.control = null;
                            pipes.control_open = false;
                            pipes.pending.clearRetainingCapacity();
                            pipes.sent = 0;
                            return err;
                        },
                    };
                    pipes.sent += n;
                }
                pipes.pending.clearRetainingCapacity();
                pipes.sent = 0;
                if (!pipes.control_open) {
                    file.close();
                    pipes.control = null;
                }
            },
            .socket => |*socket| {
                const file = socket.file orelse return;
                while (socket.sent < socket.pending.items.len) {
                    const n = file.write(socket.pending.items[socket.sent..]) catch |err| switch (err) {
                        error.WouldBlock => return,
                        else => {
                            socket.pending.clearRetainingCapacity();
                            socket.sent = 0;
                            socket.control_open = false;
                            std.posix.shutdown(file.handle, .send) catch {};
                            socket.closeIfFinished();
                            return err;
                        },
                    };
                    socket.sent += n;
                }
                socket.pending.clearRetainingCapacity();
                socket.sent = 0;
                if (!socket.control_open) std.posix.shutdown(file.handle, .send) catch {};
                socket.closeIfFinished();
            },
        }
    }

    pub fn closeControl(self: *ClientChannel) void {
        switch (self.*) {
            .stdio => |*pipes| {
                pipes.control_open = false;
                self.flushControl() catch {};
            },
            .socket => |*socket| {
                socket.control_open = false;
                self.flushControl() catch {};
            },
        }
    }

    pub fn closePresentation(self: *ClientChannel) void {
        switch (self.*) {
            .stdio => |*pipes| {
                if (pipes.presentation) |file| file.close();
                pipes.presentation = null;
            },
            .socket => |*socket| {
                if (socket.presentation_open) {
                    if (socket.file) |file| std.posix.shutdown(file.handle, .recv) catch {};
                    socket.presentation_open = false;
                }
                socket.closeIfFinished();
            },
        }
    }

    pub fn deinit(self: *ClientChannel) void {
        switch (self.*) {
            .stdio => |*pipes| {
                if (pipes.control) |file| file.close();
                if (pipes.presentation) |file| file.close();
                pipes.control = null;
                pipes.presentation = null;
                pipes.control_open = false;
                pipes.pending.deinit(pipes.allocator);
                pipes.pending = .empty;
                pipes.sent = 0;
            },
            .socket => |*socket| {
                if (socket.file) |file| file.close();
                socket.file = null;
                socket.control_open = false;
                socket.presentation_open = false;
                socket.pending.deinit(socket.allocator);
                socket.pending = .empty;
                socket.sent = 0;
            },
        }
    }
};

test "stdio control close preserves final presentation bytes" {
    const control = try std.posix.pipe();
    defer std.posix.close(control[0]);
    const presentation = try std.posix.pipe();
    defer std.posix.close(presentation[1]);
    var channel = ClientChannel{ .stdio = .{
        .control = .{ .handle = control[1] },
        .presentation = .{ .handle = presentation[0] },
    } };
    defer channel.deinit();

    channel.closeControl();
    channel.closeControl();
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(control[0], &buf));
    try std.testing.expect(channel.controlFile() == null);
    _ = try std.posix.write(presentation[1], "final batch");
    const n = try channel.presentationFile().?.read(&buf);
    try std.testing.expectEqualStrings("final batch", buf[0..n]);
}

test "socket control half close preserves final batches and closes once" {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer std.posix.close(fds[1]);
    var channel = ClientChannel{ .socket = .{ .file = .{ .handle = fds[0] } } };
    defer channel.deinit();

    channel.closeControl();
    channel.closeControl();
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(fds[1], &buf));
    _ = try std.posix.write(fds[1], "final batch");
    try std.posix.shutdown(fds[1], .send);
    const n = try channel.presentationFile().?.read(&buf);
    try std.testing.expectEqualStrings("final batch", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try channel.presentationFile().?.read(&buf));
    channel.closePresentation();
    try std.testing.expect(channel.socket.file == null);
    // Repeated cleanup must not close a descriptor subsequently allocated by
    // the process (or attempt a second close of the original descriptor).
    channel.deinit();
    try std.testing.expect(channel.presentationFile() == null);
}

test "socket presentation EOF leaves control available until retirement" {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer std.posix.close(fds[1]);
    var channel = ClientChannel{ .socket = .{ .file = .{ .handle = fds[0] } } };
    defer channel.deinit();

    try std.posix.shutdown(fds[1], .send);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try channel.presentationFile().?.read(&buf));
    channel.closePresentation();
    try std.testing.expect(channel.presentationFile() == null);
    try channel.controlFile().?.writeAll("shutdown");
    const n = try std.posix.read(fds[1], &buf);
    try std.testing.expectEqualStrings("shutdown", buf[0..n]);
    channel.closeControl();
    try std.testing.expect(channel.socket.file == null);
}

test "socket control backpressure preserves bytes through graceful half close" {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    defer std.posix.close(fds[1]);
    const small_buffer: c_int = 1024;
    try std.posix.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&small_buffer));
    for (fds) |fd| {
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        var typed: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        typed.NONBLOCK = true;
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed)));
    }
    var channel = ClientChannel{ .socket = .{ .file = .{ .handle = fds[0] }, .allocator = std.testing.allocator } };
    defer channel.deinit();
    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i);
    try channel.writer().writeAll(payload);
    try std.testing.expect(channel.socket.pending.items.len > channel.socket.sent);
    // Rejected output must not append a partial message or discard earlier
    // pending bytes; those still drain intact after the caller closes control.
    const excessive = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(excessive);
    @memset(excessive, 0);
    try std.testing.expectError(error.WriteFailed, channel.writer().writeAll(excessive));
    try std.testing.expectEqual(error.ControlBackpressure, channel.writeError().?);
    channel.closeControl();
    try std.testing.expect(channel.controlFile() == null);
    var received = std.ArrayList(u8).empty;
    defer received.deinit(std.testing.allocator);
    var eof = false;
    for (0..10000) |_| {
        try channel.flushControl();
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fds[1], &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) {
            eof = true;
            break;
        }
        try received.appendSlice(std.testing.allocator, buf[0..n]);
    }
    try std.testing.expect(eof);
    try std.testing.expectEqualSlices(u8, payload, received.items);
    try std.testing.expect(channel.presentationFile() != null);
}

test "stdio backpressure preserves bytes through graceful control close" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    for (fds) |fd| {
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        var typed: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        typed.NONBLOCK = true;
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed)));
    }
    var channel = ClientChannel{ .stdio = .{ .control = .{ .handle = fds[1] }, .allocator = std.testing.allocator } };
    defer channel.deinit();
    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i);
    try channel.writer().writeAll(payload);
    try std.testing.expect(channel.stdio.pending.items.len > channel.stdio.sent);
    // Rejected output must not append a partial message or discard earlier
    // pending bytes; those still drain intact after the caller closes control.
    const excessive = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(excessive);
    @memset(excessive, 0);
    try std.testing.expectError(error.WriteFailed, channel.writer().writeAll(excessive));
    try std.testing.expectEqual(error.ControlBackpressure, channel.writeError().?);
    channel.closeControl();
    try std.testing.expect(channel.controlFile() == null);
    var received = std.ArrayList(u8).empty;
    defer received.deinit(std.testing.allocator);
    var eof = false;
    for (0..10000) |_| {
        try channel.flushControl();
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) {
            eof = true;
            break;
        }
        try received.appendSlice(std.testing.allocator, buf[0..n]);
    }
    try std.testing.expect(eof);
    try std.testing.expectEqualSlices(u8, payload, received.items);
    try std.testing.expect(channel.stdio.control == null);
}

test "native control writer handles vectors, repetitions and closed channels" {
    const fds = try std.posix.pipe();
    const reader = std.fs.File{ .handle = fds[0] };
    defer reader.close();
    var channel = ClientChannel{ .stdio = .{ .control = .{ .handle = fds[1] }, .allocator = std.testing.allocator } };
    defer channel.deinit();
    const output = channel.writer();
    var pieces: [3][]const u8 = .{ "head:", "", "ab" };
    try output.writeSplatAll(&pieces, 3);
    try output.splatByteAll('!', 2);
    var no_tail: [2][]const u8 = .{ "end", "ignored" };
    try output.writeSplatAll(&no_tail, 0);
    channel.closeControl();
    const bytes = try reader.readToEndAlloc(std.testing.allocator, 128);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("head:ababab!!end", bytes);
    try std.testing.expectError(error.WriteFailed, channel.writer().writeAll("closed"));
    try std.testing.expectEqual(error.ControlClosed, channel.writeError().?);
}
