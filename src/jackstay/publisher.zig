const std = @import("std");
const os = @import("platform");
const media = @import("media.zig");
const endpoint = @import("endpoint.zig");
const handshake = @import("handshake.zig");
const playback = @import("playback.zig");
const c = media.c;
const log = std.log.scoped(.jackstay);

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    producer: media.Producer,
    listener: endpoint.Listener,
    mutex: os.Mutex = .{},
    failure: ?anyerror = null,
    stopped: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    authority: ?handshake.Authority,
    label: [*:0]const u8,
    setups: [8]Setup = @splat(.{}),

    const Setup = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        server: ?media.Server = null,
        fd: i32 = -1,
        /// The playback track as this consumer last heard of it: nothing yet.
        notices: ?*c.ft_track_notices = null,
        announced_id: u64 = 0,
        announced_version: u64 = 0,

        fn run(self: *Setup, publisher: *Publisher) void {
            defer self.done.store(true, .release);
            defer if (self.fd >= 0) os.posix.close(self.fd);
            var accepted = handshake.accept(&self.fd, publisher.label, if (publisher.authority) |a| a.target else null) catch |err| {
                log.debug("source handshake failed: {any}", .{err});
                return;
            };
            // The run loop announces the playback track, so a stalled peer
            // never holds the track's lock through its handshake.
            self.notices = accepted.notices;
            defer accepted.close();
            if (accepted.input) |*server| {
                // Input owns a separate lifetime, including when media setup
                // fails. Executor teardown stops it and settles target cleanup.
                publisher.authority.?.servers.adopt(server.*) catch |err| {
                    log.warn("source input server adoption failed: {any}", .{err});
                    server.deinit();
                    return;
                };
            }
            if (!accepted.video or publisher.stopped.load(.acquire)) return;
            publisher.mutex.lock();
            defer publisher.mutex.unlock();
            self.server = publisher.producer.serve(&accepted.local) catch null;
        }

        /// After setup: announces track changes, then answers a late
        /// selection. A failure ends the consumer's notices.
        fn syncTrack(self: *Setup) void {
            const notices = self.notices orelse return;
            const track = &playback.track;
            const announced = blk: {
                track.mutex.lock();
                defer track.mutex.unlock();
                if (self.announced_version == track.version) break :blk true;
                if (self.announced_id != 0 and self.announced_id != track.id) {
                    if (c.ft_track_notices_remove(notices, self.announced_id) != c.FT_STATUS_OK) break :blk false;
                }
                if (track.id != 0) {
                    const offer = track.offer();
                    const status = if (self.announced_id == track.id) c.ft_track_notices_update(notices, &offer) else c.ft_track_notices_add(notices, &offer, track.playback);
                    if (status != c.FT_STATUS_OK) break :blk false;
                }
                self.announced_id = track.id;
                self.announced_version = track.version;
                break :blk true;
            };
            if (announced) switch (c.ft_track_notices_serve(notices, 0)) {
                c.FT_STATUS_OK, c.FT_STATUS_EMPTY => return,
                else => {},
            };
            c.ft_track_notices_destroy(&self.notices);
        }

        fn finished(self: *Setup) bool {
            return self.notices == null and (self.server == null or self.server.?.finished());
        }

        fn retire(self: *Setup) void {
            if (self.thread) |thread| thread.join();
            // A consumer still listening at shutdown hears the track withdrawn.
            if (self.notices != null and self.announced_id != 0) _ = c.ft_track_notices_remove(self.notices, self.announced_id);
            if (self.server) |*server| server.close();
            c.ft_track_notices_destroy(&self.notices);
            self.* = .{};
        }
    };

    /// The source label is borrowed for the publisher's lifetime.
    pub fn create(io: std.Io, allocator: std.mem.Allocator, path: []const u8, label: [*:0]const u8, options: media.Producer.Options, authority: ?handshake.Authority) !*Publisher {
        const self = try allocator.create(Publisher);
        errdefer allocator.destroy(self);
        var producer = try media.Producer.initWithOptions(4, options);
        errdefer {
            _ = producer.close() catch {};
        }
        var listener = try endpoint.Listener.init(io, allocator, path);
        errdefer listener.deinit();
        self.* = .{ .allocator = allocator, .producer = producer, .listener = listener, .authority = authority, .label = label };
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
                    setup.syncTrack();
                    if (setup.finished()) setup.retire();
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
        // Bounded handshake calls have no cancellation handle. Join them
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
