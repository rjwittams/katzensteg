const std = @import("std");
const os = @import("platform");
const media = @import("media.zig");
const endpoint = @import("endpoint.zig");

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    producer: media.Producer,
    listener: endpoint.Listener,
    mutex: os.Mutex = .{},
    failure: ?anyerror = null,
    stopped: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    servers: [8]?media.Server = @splat(null),

    pub fn create(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: media.Producer.Options) !*Publisher {
        const self = try allocator.create(Publisher);
        errdefer allocator.destroy(self);
        var producer = try media.Producer.initWithOptions(4, options);
        errdefer {
            _ = producer.close() catch {};
        }
        var listener = try endpoint.Listener.init(io, allocator, path);
        errdefer listener.deinit();
        self.* = .{ .allocator = allocator, .producer = producer, .listener = listener };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn publish(self: *Publisher, image: media.Image) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure) |err| return err;
        return self.producer.publish(image);
    }

    fn run(self: *Publisher) void {
        while (!self.stopped.load(.acquire)) {
            for (&self.servers) |*slot| {
                if (slot.*) |*server| {
                    if (server.finished()) {
                        server.close();
                        slot.* = null;
                    }
                }
            }
            if (self.listener.accept() catch null) |accepted| {
                var fd = accepted;
                defer if (fd >= 0) os.posix.close(fd);
                for (&self.servers) |*slot| {
                    if (slot.* == null) {
                        self.mutex.lock();
                        slot.* = self.producer.serve(&fd) catch null;
                        self.mutex.unlock();
                        break;
                    }
                }
            }
            self.mutex.lock();
            self.producer.maintenance() catch |err| {
                self.failure = err;
            };
            self.mutex.unlock();
            os.time.sleep(10 * std.time.ns_per_ms);
        }
        for (&self.servers) |*slot| {
            if (slot.*) |*server| server.close();
            slot.* = null;
        }
    }

    // Stops and joins every setup worker first. On cleanup failure the caller
    // retains this owner and may retry; no live storage is forcibly reclaimed.
    pub fn close(self: *Publisher) !void {
        if (self.thread) |thread| {
            self.stopped.store(true, .release);
            thread.join();
            self.thread = null;
            // A later close retry skips this already-completed listener teardown.
            self.listener.deinit();
        }
        const started = os.time.nanoTimestamp();
        while (!try self.producer.close()) {
            if (os.time.nanoTimestamp() - started > 3 * std.time.ns_per_s) return error.CleanupPending;
            os.time.sleep(10 * std.time.ns_per_ms);
        }
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
};
