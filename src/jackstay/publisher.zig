const std = @import("std");
const os = @import("platform");
const media = @import("media.zig");
const endpoint = @import("endpoint.zig");
const bootstrap = @import("bootstrap.zig");

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    producer: media.Producer,
    listener: endpoint.Listener,
    mutex: os.Mutex = .{},
    failure: ?anyerror = null,
    stopped: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    authority: ?bootstrap.Authority,
    setups: [8]Setup = @splat(.{}),

    const Setup = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        server: ?media.Server = null,
        fd: i32 = -1,

        fn run(self: *Setup, publisher: *Publisher) void {
            defer self.done.store(true, .release);
            defer if (self.fd >= 0) os.posix.close(self.fd);
            var input_server = bootstrap.accept(&self.fd, if (publisher.authority) |a| a.target else null) catch return;
            if (input_server) |*server| {
                // Input owns a separate lifetime, including when media setup
                // fails. Executor teardown stops it and settles target cleanup.
                publisher.authority.?.servers.adopt(server.*) catch {
                    server.deinit();
                    return;
                };
            }
            if (publisher.stopped.load(.acquire)) return;
            publisher.mutex.lock();
            defer publisher.mutex.unlock();
            self.server = publisher.producer.serve(&self.fd) catch null;
        }

        fn retire(self: *Setup) void {
            if (self.thread) |thread| thread.join();
            if (self.server) |*server| server.close();
            self.* = .{};
        }
    };

    pub fn create(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: media.Producer.Options, authority: ?bootstrap.Authority) !*Publisher {
        const self = try allocator.create(Publisher);
        errdefer allocator.destroy(self);
        var producer = try media.Producer.initWithOptions(4, options);
        errdefer {
            _ = producer.close() catch {};
        }
        var listener = try endpoint.Listener.init(io, allocator, path);
        errdefer listener.deinit();
        self.* = .{ .allocator = allocator, .producer = producer, .listener = listener, .authority = authority };
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
            for (&self.setups) |*setup| {
                if (setup.thread != null and setup.done.load(.acquire)) {
                    if (setup.server == null or setup.server.?.finished()) setup.retire();
                }
            }
            if (self.listener.accept() catch null) |accepted| {
                var fd = accepted;
                defer if (fd >= 0) os.posix.close(fd);
                for (&self.setups) |*setup| {
                    if (setup.thread == null) {
                        setup.fd = fd;
                        setup.thread = std.Thread.spawn(.{}, Setup.run, .{ setup, self }) catch {
                            setup.fd = -1;
                            break;
                        };
                        fd = -1;
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
        // Bounded bootstrap calls have no cancellation handle. Join them
        // before releasing the borrowed input authority or media producer.
        for (&self.setups) |*setup| setup.retire();
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
