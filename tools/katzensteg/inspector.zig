const std = @import("std");
const Logger = @import("log.zig").Logger;

pub const FrameRecord = struct {
    id: u64 = 0,
    segment_id: u64 = 0,
    ts_ns: i128,
    present_ns: i128,
    queue_depth: usize,
    skipped_presents: u64,
    render_strategy: []const u8,
    strategy_short: []const u8,
    copies: u32,
    fills: u32,
    lines: u32,
    uploads: u32,
    placements: u32,
    bytes_uploaded: u64,
    fallback_texture_key: u64,
    fallback_reason: ?[]const u8,
    image_id: u32,
    placement_id: u32,
    first_event_seq: u64 = 0,
    last_event_seq: u64 = 0,
};

pub const ResourceKind = enum {
    texture,
    image,
    placement,
};

pub const ResourceRecord = struct {
    kind: ResourceKind,
    texture_key: u64,
    placement_id: u32,
    alias: [24]u8,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
    image_id: u32,
};

pub const ResourceVersionRecord = struct {
    segment_id: u64,
    frame_id: u64,
    event_seq: u64,
    kind: ResourceKind,
    texture_key: u64,
    placement_id: u32,
    alias: [24]u8,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
    image_id: u32,
};

pub const EventRecord = struct {
    segment_id: u64,
    event_seq: u64,
    frame_id: ?u64 = null,
    ts_ns: i128,
    kind: []const u8,
    thread: []const u8,
    texture_key: u64 = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    bytes_uploaded: u64 = 0,
    reason: ?[]const u8 = null,
};

pub const SegmentRecord = struct {
    id: u64,
    start_ts_ns: i128,
    end_ts_ns: ?i128 = null,
    frame_count: u64 = 0,
    event_count: u64 = 0,
    bytes_uploaded: u64 = 0,
    skipped_presents: u64 = 0,
    dropped_batches: u64 = 0,
};

pub const SessionStatus = struct {
    terminal_identity: []const u8 = "unknown",
    composite_mode: []const u8 = "unknown",
    intercept_mode: []const u8 = "unknown",
    output_profile: []const u8 = "unknown",
    present_fps: u32 = 0,
};

const max_frames = 600;
const max_segments = 64;

fn closeOwnedFd(fd: std.posix.fd_t) void {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS, .INTR, .BADF => return,
        else => return,
    }
}

const RequestTarget = struct {
    path: []const u8,
    query: []const u8,
};

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    socket_path: []u8,
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    listener_fd: ?std.posix.fd_t = null,
    server_thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    segments: std.ArrayList(SegmentRecord),
    frames: std.ArrayList(FrameRecord),
    events: std.ArrayList(EventRecord),
    resource_versions: std.ArrayList(ResourceVersionRecord),
    session: SessionStatus = .{},
    next_segment_id: u64 = 1,
    next_frame_id: u64 = 1,
    active_segment_id: ?u64 = null,
    active_event_seq: u64 = 1,
    last_recorded_frame_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, logger: *Logger, socket_path: []const u8) !Inspector {
        return .{
            .allocator = allocator,
            .logger = logger,
            .socket_path = try allocator.dupe(u8, socket_path),
            .segments = std.ArrayList(SegmentRecord).empty,
            .frames = std.ArrayList(FrameRecord).empty,
            .events = std.ArrayList(EventRecord).empty,
            .resource_versions = std.ArrayList(ResourceVersionRecord).empty,
        };
    }

    pub fn start(self: *Inspector) void {
        if (self.server_thread != null) return;
        if (std.Thread.spawn(.{}, serverMain, .{self})) |thread| {
            self.server_thread = thread;
        } else |err| {
            self.logger.writeFmt("katzensteg: failed to start inspector thread: {any}", .{err});
        }
    }

    pub fn deinit(self: *Inspector) void {
        self.shutdown.store(true, .release);
        if (std.net.connectUnixSocket(self.socket_path)) |stream| {
            closeOwnedFd(stream.handle);
        } else |_| {}
        if (self.server_thread) |thread| thread.join();
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        self.mutex.lock();
        defer self.mutex.unlock();
        self.segments.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.resource_versions.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    pub fn configureSession(self: *Inspector, session: SessionStatus) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = session;
    }

    pub fn isEnabled(self: *const Inspector) bool {
        return self.enabled.load(.monotonic);
    }

    pub fn noteFrame(self: *Inspector, frame: FrameRecord) void {
        if (!self.enabled.load(.monotonic)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const segment_id = self.ensureActiveSegmentLocked(frame.ts_ns);
        const first_event_seq = self.active_event_seq;
        _ = self.appendSyntheticFrameEventsLocked(segment_id, self.next_frame_id, frame);
        const last_event_seq = self.active_event_seq - 1;
        self.frames.append(self.allocator, .{
            .id = self.next_frame_id,
            .segment_id = segment_id,
            .ts_ns = frame.ts_ns,
            .present_ns = frame.present_ns,
            .queue_depth = frame.queue_depth,
            .skipped_presents = frame.skipped_presents,
            .render_strategy = frame.render_strategy,
            .strategy_short = frame.strategy_short,
            .copies = frame.copies,
            .fills = frame.fills,
            .lines = frame.lines,
            .uploads = frame.uploads,
            .placements = frame.placements,
            .bytes_uploaded = frame.bytes_uploaded,
            .fallback_texture_key = frame.fallback_texture_key,
            .fallback_reason = frame.fallback_reason,
            .image_id = frame.image_id,
            .placement_id = frame.placement_id,
            .first_event_seq = first_event_seq,
            .last_event_seq = last_event_seq,
        }) catch return;
        self.last_recorded_frame_id = self.next_frame_id;
        self.next_frame_id += 1;
        if (self.frames.items.len > max_frames) {
            _ = self.frames.orderedRemove(0);
        }
        if (self.segmentByIdLocked(segment_id)) |segment| {
            segment.frame_count += 1;
            segment.bytes_uploaded += frame.bytes_uploaded;
            segment.skipped_presents += frame.skipped_presents;
        }
    }

    pub fn noteResources(self: *Inspector, resources: []const ResourceRecord) void {
        if (!self.enabled.load(.monotonic)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const segment_id = self.active_segment_id orelse return;
        const frame_id = self.last_recorded_frame_id orelse return;
        for (resources) |res| {
            self.resource_versions.append(self.allocator, .{
                .segment_id = segment_id,
                .frame_id = frame_id,
                .event_seq = self.nextEventSeqLocked(),
                .kind = res.kind,
                .texture_key = res.texture_key,
                .placement_id = res.placement_id,
                .alias = res.alias,
                .w = res.w,
                .h = res.h,
                .format = res.format,
                .blend_mode = res.blend_mode,
                .update_count = res.update_count,
                .image_id = res.image_id,
            }) catch return;
        }
    }

    fn startCaptureLocked(self: *Inspector, now_ns: i128) u64 {
        self.enabled.store(true, .release);
        if (self.active_segment_id) |id| return id;
        const id = self.next_segment_id;
        self.next_segment_id += 1;
        self.segments.append(self.allocator, .{ .id = id, .start_ts_ns = now_ns }) catch return id;
        self.active_segment_id = id;
        self.active_event_seq = 1;
        if (self.segments.items.len > max_segments) {
            _ = self.segments.orderedRemove(0);
        }
        return id;
    }

    fn stopCaptureLocked(self: *Inspector, now_ns: i128) ?u64 {
        self.enabled.store(false, .release);
        const id = self.active_segment_id orelse return null;
        if (self.segmentByIdLocked(id)) |segment| segment.end_ts_ns = now_ns;
        self.active_segment_id = null;
        self.last_recorded_frame_id = null;
        return id;
    }

    fn clearLiveLocked(self: *Inspector) void {
        self.frames.clearRetainingCapacity();
        self.events.clearRetainingCapacity();
        self.resource_versions.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.active_segment_id = null;
        self.last_recorded_frame_id = null;
        self.next_segment_id = 1;
        self.next_frame_id = 1;
        self.active_event_seq = 1;
    }

    fn ensureActiveSegmentLocked(self: *Inspector, now_ns: i128) u64 {
        if (self.active_segment_id) |id| return id;
        return self.startCaptureLocked(now_ns);
    }

    fn nextEventSeqLocked(self: *Inspector) u64 {
        const seq = self.active_event_seq;
        self.active_event_seq += 1;
        if (self.active_segment_id) |id| {
            if (self.segmentByIdLocked(id)) |segment| segment.event_count += 1;
        }
        return seq;
    }

    fn appendSyntheticFrameEventsLocked(self: *Inspector, segment_id: u64, frame_id: u64, frame: FrameRecord) void {
        self.events.append(self.allocator, .{
            .segment_id = segment_id,
            .event_seq = self.nextEventSeqLocked(),
            .frame_id = frame_id,
            .ts_ns = frame.ts_ns,
            .kind = "present",
            .thread = "worker",
        }) catch return;
        if (frame.fallback_reason) |reason| {
            self.events.append(self.allocator, .{
                .segment_id = segment_id,
                .event_seq = self.nextEventSeqLocked(),
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "fallback",
                .thread = "worker",
                .texture_key = frame.fallback_texture_key,
                .reason = reason,
            }) catch return;
        }
        if (frame.uploads > 0 and frame.image_id != 0) {
            self.events.append(self.allocator, .{
                .segment_id = segment_id,
                .event_seq = self.nextEventSeqLocked(),
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "upload",
                .thread = "worker",
                .image_id = frame.image_id,
                .bytes_uploaded = frame.bytes_uploaded,
            }) catch return;
        }
        if (frame.placements > 0 and frame.image_id != 0 and frame.placement_id != 0) {
            self.events.append(self.allocator, .{
                .segment_id = segment_id,
                .event_seq = self.nextEventSeqLocked(),
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "placement",
                .thread = "worker",
                .image_id = frame.image_id,
                .placement_id = frame.placement_id,
            }) catch return;
        }
    }

    fn segmentByIdLocked(self: *Inspector, id: u64) ?*SegmentRecord {
        for (self.segments.items) |*segment| {
            if (segment.id == id) return segment;
        }
        return null;
    }

    fn frameByIdLocked(self: *Inspector, id: u64) ?FrameRecord {
        for (self.frames.items) |frame| {
            if (frame.id == id) return frame;
        }
        return null;
    }

    fn frameIndexByIdLocked(self: *Inspector, id: u64) ?usize {
        for (self.frames.items, 0..) |frame, i| {
            if (frame.id == id) return i;
        }
        return null;
    }

    fn currentLatestSegmentIdLocked(self: *Inspector) ?u64 {
        if (self.active_segment_id) |id| return id;
        if (self.segments.items.len == 0) return null;
        return self.segments.items[self.segments.items.len - 1].id;
    }

    fn latestFrameInSegmentLocked(self: *Inspector, segment_id: u64) ?FrameRecord {
        var i: usize = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.frames.items[i];
            if (frame.segment_id == segment_id) return frame;
        }
        return null;
    }

    fn resourcesAtFrameLocked(self: *Inspector, frame: FrameRecord, allocator: std.mem.Allocator) ![]ResourceVersionRecord {
        var list = std.ArrayList(ResourceVersionRecord).empty;
        defer list.deinit(allocator);
        for (self.resource_versions.items) |res| {
            if (res.segment_id == frame.segment_id and res.frame_id == frame.id) {
                try list.append(allocator, res);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    fn eventsForFrameLocked(self: *Inspector, frame: FrameRecord, allocator: std.mem.Allocator) ![]EventRecord {
        var list = std.ArrayList(EventRecord).empty;
        defer list.deinit(allocator);
        for (self.events.items) |event| {
            if (event.segment_id == frame.segment_id and event.frame_id != null and event.frame_id.? == frame.id) {
                try list.append(allocator, event);
            }
        }
        return list.toOwnedSlice(allocator);
    }

    fn serverMain(self: *Inspector) void {
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
        const addr = std.net.Address.initUnix(self.socket_path) catch |err| {
            self.logger.writeFmt("katzensteg: inspector initUnix failed: {any}", .{err});
            return;
        };
        var server = addr.listen(.{}) catch |err| {
            self.logger.writeFmt("katzensteg: inspector listen failed: {any}", .{err});
            return;
        };
        defer closeOwnedFd(server.stream.handle);
        self.listener_fd = server.stream.handle;
        self.logger.writeFmt("katzensteg: inspector listening on unix socket {s}", .{self.socket_path});

        while (!self.shutdown.load(.acquire)) {
            const conn = server.accept() catch |err| switch (err) {
                error.ConnectionAborted => continue,
                error.FileDescriptorNotASocket, error.OperationNotSupported, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.SocketNotListening, error.Unexpected, error.WouldBlock => {
                    if (self.shutdown.load(.acquire)) break;
                    continue;
                },
                else => {
                    if (self.shutdown.load(.acquire)) break;
                    self.logger.writeFmt("katzensteg: inspector accept failed: {any}", .{err});
                    continue;
                },
            };
            self.handleConnection(conn.stream.handle);
            conn.stream.close();
        }

        self.listener_fd = null;
    }

    fn handleConnection(self: *Inspector, fd: std.posix.fd_t) void {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch return;
        if (n == 0) return;
        const req = buf[0..n];
        const target = parseTarget(req) orelse RequestTarget{ .path = "/", .query = "" };

        if (std.mem.eql(u8, target.path, "/capture/start")) {
            self.mutex.lock();
            const id = self.startCaptureLocked(std.time.nanoTimestamp());
            const segments_len = self.segments.items.len;
            self.mutex.unlock();
            var body: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&body, "{{\"ok\":true,\"enabled\":true,\"active_segment_id\":{d},\"segments\":{d}}}\n", .{ id, segments_len }) catch return;
            self.writeJson(fd, json) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/capture/stop")) {
            self.mutex.lock();
            const stopped = self.stopCaptureLocked(std.time.nanoTimestamp());
            const segments_len = self.segments.items.len;
            self.mutex.unlock();
            var body: [160]u8 = undefined;
            const json = if (stopped) |id|
                std.fmt.bufPrint(&body, "{{\"ok\":true,\"enabled\":false,\"closed_segment_id\":{d},\"segments\":{d}}}\n", .{ id, segments_len }) catch "{\"ok\":true,\"enabled\":false}\n"
            else
                std.fmt.bufPrint(&body, "{{\"ok\":true,\"enabled\":false,\"closed_segment_id\":null,\"segments\":{d}}}\n", .{segments_len}) catch "{\"ok\":true,\"enabled\":false}\n";
            self.writeJson(fd, json) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/capture/clear")) {
            self.mutex.lock();
            self.clearLiveLocked();
            self.mutex.unlock();
            self.writeJson(fd, "{\"ok\":true,\"cleared\":true}\n") catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/capture/status")) {
            self.writeCaptureStatus(fd) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/segments")) {
            self.writeSegments(fd) catch {};
            return;
        }
        if (std.mem.startsWith(u8, target.path, "/segment/")) {
            self.writeSegmentById(fd, target.path[9..]) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/frames")) {
            self.writeFrames(fd, target.query) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/frame/latest")) {
            self.writeLatestFrame(fd, target.query) catch {};
            return;
        }
        if (std.mem.startsWith(u8, target.path, "/frame/")) {
            self.writeFrameById(fd, target.path[7..]) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/resources")) {
            self.writeResources(fd, target.query) catch {};
            return;
        }
        if (std.mem.startsWith(u8, target.path, "/resource/")) {
            self.writeResourceByPath(fd, target.path[10..], target.query) catch {};
            return;
        }
        if (std.mem.eql(u8, target.path, "/stats")) {
            self.writeCaptureStatus(fd) catch {};
            return;
        }
        self.writeNotFound(fd) catch {};
    }

    fn writeCaptureStatus(self: *Inspector, fd: std.posix.fd_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_segment_id;
        var body: [640]u8 = undefined;
        const json = try std.fmt.bufPrint(&body, "{{\"enabled\":{s},\"frames\":{d},\"next_frame_id\":{d},\"active_segment_id\":{s},\"segments\":{d},\"terminal_identity\":\"{s}\",\"composite_mode\":\"{s}\",\"intercept_mode\":\"{s}\",\"output_profile\":\"{s}\",\"present_fps\":{d}}}\n", .{
            if (self.enabled.load(.monotonic)) "true" else "false",
            self.frames.items.len,
            self.next_frame_id,
            if (active) |id| blk: {
                var active_buf: [24]u8 = undefined;
                break :blk try std.fmt.bufPrint(&active_buf, "{d}", .{id});
            } else "null",
            self.segments.items.len,
            self.session.terminal_identity,
            self.session.composite_mode,
            self.session.intercept_mode,
            self.session.output_profile,
            self.session.present_fps,
        });
        try self.writeJson(fd, json);
    }

    fn writeSegments(self: *Inspector, fd: std.posix.fd_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.append(self.allocator, '[');
        for (self.segments.items, 0..) |segment, i| {
            if (i != 0) try body.append(self.allocator, ',');
            try body.writer(self.allocator).print("{{\"id\":{d},\"start_ts_ns\":{d},\"end_ts_ns\":{s},\"frame_count\":{d},\"event_count\":{d},\"bytes_uploaded\":{d},\"skipped_presents\":{d},\"active\":{s}}}", .{
                segment.id,
                segment.start_ts_ns,
                if (segment.end_ts_ns) |ts| blk: {
                    var buf: [32]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&buf, "{d}", .{ts});
                } else "null",
                segment.frame_count,
                segment.event_count,
                segment.bytes_uploaded,
                segment.skipped_presents,
                if (self.active_segment_id != null and self.active_segment_id.? == segment.id) "true" else "false",
            });
        }
        try body.appendSlice(self.allocator, "]\n");
        try self.writeJson(fd, body.items);
    }

    fn writeSegmentById(self: *Inspector, fd: std.posix.fd_t, id_text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = std.fmt.parseInt(u64, id_text, 10) catch return self.writeNotFound(fd);
        const segment = self.segmentByIdLocked(id) orelse return self.writeNotFound(fd);
        var body: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&body, "{{\"id\":{d},\"start_ts_ns\":{d},\"end_ts_ns\":{s},\"frame_count\":{d},\"event_count\":{d},\"bytes_uploaded\":{d},\"skipped_presents\":{d},\"active\":{s}}}\n", .{
            segment.id,
            segment.start_ts_ns,
            if (segment.end_ts_ns) |ts| blk: {
                var buf: [32]u8 = undefined;
                break :blk try std.fmt.bufPrint(&buf, "{d}", .{ts});
            } else "null",
            segment.frame_count,
            segment.event_count,
            segment.bytes_uploaded,
            segment.skipped_presents,
            if (self.active_segment_id != null and self.active_segment_id.? == segment.id) "true" else "false",
        });
        try self.writeJson(fd, json);
    }

    fn writeFrames(self: *Inspector, fd: std.posix.fd_t, query: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const segment_id = parseQueryU64(query, "segment") orelse self.currentLatestSegmentIdLocked() orelse return self.writeJson(fd, "[]\n");
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.append(self.allocator, '[');
        var first = true;
        for (self.frames.items) |frame| {
            if (frame.segment_id != segment_id) continue;
            if (!first) try body.append(self.allocator, ',');
            first = false;
            try body.writer(self.allocator).print("{{\"id\":{d},\"segment_id\":{d},\"ts_ns\":{d},\"present_ns\":{d},\"queue_depth\":{d},\"skipped_presents\":{d},\"render_strategy\":\"{s}\",\"strategy_short\":\"{s}\",\"counts\":{{\"copies\":{d},\"fills\":{d},\"lines\":{d},\"uploads\":{d},\"placements\":{d}}},\"bytes\":{{\"uploaded\":{d}}}}}", .{ frame.id, frame.segment_id, frame.ts_ns, frame.present_ns, frame.queue_depth, frame.skipped_presents, frame.render_strategy, frame.strategy_short, frame.copies, frame.fills, frame.lines, frame.uploads, frame.placements, frame.bytes_uploaded });
        }
        try body.appendSlice(self.allocator, "]\n");
        try self.writeJson(fd, body.items);
    }

    fn writeLatestFrame(self: *Inspector, fd: std.posix.fd_t, query: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const segment_id = parseQueryU64(query, "segment") orelse self.currentLatestSegmentIdLocked() orelse return self.writeJson(fd, "null\n");
        const frame = self.latestFrameInSegmentLocked(segment_id) orelse return self.writeJson(fd, "null\n");
        try self.writeFrameJsonLocked(fd, frame);
    }

    fn writeFrameById(self: *Inspector, fd: std.posix.fd_t, id_text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = std.fmt.parseInt(u64, id_text, 10) catch return self.writeNotFound(fd);
        const frame = self.frameByIdLocked(id) orelse return self.writeNotFound(fd);
        try self.writeFrameJsonLocked(fd, frame);
    }

    fn writeResources(self: *Inspector, fd: std.posix.fd_t, query: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const frame_id = parseQueryU64(query, "frame");
        if (frame_id) |id| {
            const frame = self.frameByIdLocked(id) orelse return self.writeJson(fd, "[]\n");
            const resources = try self.resourcesAtFrameLocked(frame, self.allocator);
            defer self.allocator.free(resources);
            return self.writeResourceVersionArray(fd, resources);
        }
        const segment_id = parseQueryU64(query, "segment") orelse self.currentLatestSegmentIdLocked() orelse return self.writeJson(fd, "[]\n");
        const latest = self.latestFrameInSegmentLocked(segment_id) orelse return self.writeJson(fd, "[]\n");
        const resources = try self.resourcesAtFrameLocked(latest, self.allocator);
        defer self.allocator.free(resources);
        try self.writeResourceVersionArray(fd, resources);
    }

    fn writeResourceByPath(self: *Inspector, fd: std.posix.fd_t, rest: []const u8, query: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return self.writeNotFound(fd);
        const kind_text = rest[0..slash];
        const id_text = rest[slash + 1 ..];
        const frame_id = parseQueryU64(query, "frame") orelse return self.writeNotFound(fd);
        const frame = self.frameByIdLocked(frame_id) orelse return self.writeNotFound(fd);
        const kind = parseResourceKind(kind_text) orelse return self.writeNotFound(fd);
        const resource = self.findResourceAtFrameLocked(kind, id_text, frame) orelse return self.writeNotFound(fd);
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try self.writeResourceVersionJson(&body, resource);
        try body.append(self.allocator, '\n');
        try self.writeJson(fd, body.items);
    }

    fn findResourceAtFrameLocked(self: *Inspector, kind: ResourceKind, id_text: []const u8, frame: FrameRecord) ?ResourceVersionRecord {
        const wanted_u64 = std.fmt.parseInt(u64, if (std.mem.startsWith(u8, id_text, "0x")) id_text[2..] else id_text, 16) catch std.fmt.parseInt(u64, id_text, 10) catch return null;
        var i: usize = self.resource_versions.items.len;
        while (i > 0) {
            i -= 1;
            const res = self.resource_versions.items[i];
            if (res.segment_id != frame.segment_id) continue;
            if (res.frame_id > frame.id) continue;
            if (res.kind != kind) continue;
            switch (kind) {
                .texture => if (res.texture_key == wanted_u64) return res,
                .image => if (res.image_id == @as(u32, @intCast(wanted_u64))) return res,
                .placement => if (res.placement_id == @as(u32, @intCast(wanted_u64))) return res,
            }
        }
        return null;
    }

    fn writeResourceVersionArray(self: *Inspector, fd: std.posix.fd_t, resources: []const ResourceVersionRecord) !void {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.append(self.allocator, '[');
        for (resources, 0..) |res, i| {
            if (i != 0) try body.append(self.allocator, ',');
            try self.writeResourceVersionJson(&body, res);
        }
        try body.appendSlice(self.allocator, "]\n");
        try self.writeJson(fd, body.items);
    }

    fn writeResourceVersionJson(self: *Inspector, body: *std.ArrayList(u8), res: ResourceVersionRecord) !void {
        try body.writer(self.allocator).print("{{\"kind\":\"{s}\",\"texture_key\":\"0x{x}\",\"placement_id\":{d},\"alias\":\"{s}\",\"size\":[{d},{d}],\"format\":{d},\"blend_mode\":{d},\"update_count\":{d},\"image_id\":{d},\"frame_id\":{d},\"event_seq\":{d}}}", .{ @tagName(res.kind), res.texture_key, res.placement_id, std.mem.sliceTo(&res.alias, 0), res.w, res.h, res.format, res.blend_mode, res.update_count, res.image_id, res.frame_id, res.event_seq });
    }

    fn writeFrameJsonLocked(self: *Inspector, fd: std.posix.fd_t, frame: FrameRecord) !void {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        const events = try self.eventsForFrameLocked(frame, self.allocator);
        defer self.allocator.free(events);
        const resources = try self.resourcesAtFrameLocked(frame, self.allocator);
        defer self.allocator.free(resources);
        try body.writer(self.allocator).print("{{\"id\":{d},\"segment_id\":{d},\"ts_ns\":{d},\"present_ns\":{d},\"queue_depth\":{d},\"skipped_presents\":{d},\"render_strategy\":\"{s}\",\"strategy_short\":\"{s}\",\"counts\":{{\"copies\":{d},\"fills\":{d},\"lines\":{d},\"uploads\":{d},\"placements\":{d}}},\"bytes\":{{\"uploaded\":{d}}},\"image_id\":{d},\"placement_id\":{d},\"fallback_reasons\":[", .{ frame.id, frame.segment_id, frame.ts_ns, frame.present_ns, frame.queue_depth, frame.skipped_presents, frame.render_strategy, frame.strategy_short, frame.copies, frame.fills, frame.lines, frame.uploads, frame.placements, frame.bytes_uploaded, frame.image_id, frame.placement_id });
        if (frame.fallback_reason) |reason| {
            try body.writer(self.allocator).print("{{\"kind\":\"{s}\",\"texture_key\":\"0x{x}\"}}", .{ reason, frame.fallback_texture_key });
        }
        try body.appendSlice(self.allocator, "],\"events\":[");
        for (events, 0..) |event, i| {
            if (i != 0) try body.append(self.allocator, ',');
            try body.writer(self.allocator).print("{{\"event_seq\":{d},\"kind\":\"{s}\",\"thread\":\"{s}\",\"ts_ns\":{d},\"payload\":{{\"texture_key\":\"0x{x}\",\"image_id\":{d},\"placement_id\":{d},\"bytes\":{d}{s}}}}}", .{
                event.event_seq,
                event.kind,
                event.thread,
                event.ts_ns,
                event.texture_key,
                event.image_id,
                event.placement_id,
                event.bytes_uploaded,
                if (event.reason) |reason| blk: {
                    var reason_buf: [128]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&reason_buf, ",\"reason\":\"{s}\"", .{reason});
                } else "",
            });
        }
        try body.appendSlice(self.allocator, "],\"mappings\":[");
        var need_mapping_comma = false;
        if (frame.uploads > 0 and frame.image_id != 0) {
            try body.writer(self.allocator).print("{{\"kind\":\"upload\",\"image_id\":{d},\"bytes\":{d}}}", .{ frame.image_id, frame.bytes_uploaded });
            need_mapping_comma = true;
        }
        if (frame.placements > 0 and frame.image_id != 0 and frame.placement_id != 0) {
            if (need_mapping_comma) try body.append(self.allocator, ',');
            try body.writer(self.allocator).print("{{\"kind\":\"placement\",\"image_id\":{d},\"placement_id\":{d}}}", .{ frame.image_id, frame.placement_id });
            need_mapping_comma = true;
        }
        if (frame.fallback_reason) |reason| {
            if (need_mapping_comma) try body.append(self.allocator, ',');
            try body.writer(self.allocator).print("{{\"kind\":\"fallback\",\"texture_key\":\"0x{x}\",\"reason\":\"{s}\"}}", .{ frame.fallback_texture_key, reason });
        }
        try body.appendSlice(self.allocator, "],\"resource_refs\":[");
        for (resources, 0..) |res, i| {
            if (i != 0) try body.append(self.allocator, ',');
            try body.writer(self.allocator).print("{{\"kind\":\"{s}\",\"texture_key\":\"0x{x}\",\"image_id\":{d},\"placement_id\":{d}}}", .{ @tagName(res.kind), res.texture_key, res.image_id, res.placement_id });
        }
        try body.appendSlice(self.allocator, "]}\n");
        try self.writeJson(fd, body.items);
    }

    fn writeJson(_: *Inspector, fd: std.posix.fd_t, body: []const u8) !void {
        var header: [256]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        _ = try std.posix.write(fd, hdr);
        _ = try std.posix.write(fd, body);
    }

    fn writeNotFound(_: *Inspector, fd: std.posix.fd_t) !void {
        const body = "{\"error\":\"not_found\"}\n";
        var header: [256]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&header, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        _ = try std.posix.write(fd, hdr);
        _ = try std.posix.write(fd, body);
    }

    pub fn segmentCount(self: *Inspector) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.segments.items.len;
    }

    pub fn activeSegmentId(self: *Inspector) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.active_segment_id;
    }

    pub fn startCaptureForTest(self: *Inspector) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.startCaptureLocked(std.time.nanoTimestamp());
    }

    pub fn stopCaptureForTest(self: *Inspector) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.stopCaptureLocked(std.time.nanoTimestamp());
    }
};

pub fn makeAlias(texture_key: u64) [24]u8 {
    var buf: [24]u8 = [_]u8{0} ** 24;
    const adjectives = [_][]const u8{ "amber", "cinder", "sable", "lunar", "brisk", "moss", "ember", "azure" };
    const animals = [_][]const u8{ "otter", "lark", "lynx", "quail", "stoat", "wren", "ibis", "yak" };
    const a = adjectives[@intCast(texture_key % adjectives.len)];
    const b = animals[@intCast((texture_key / 17) % animals.len)];
    _ = std.fmt.bufPrint(&buf, "tex-{s}-{s}-{x}", .{ a, b, texture_key & 0xff }) catch {};
    return buf;
}

fn parseTarget(req: []const u8) ?RequestTarget {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return null;
    const line = req[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return null;
    const rest = line[4..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const target = rest[0..space];
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        return .{ .path = target[0..q], .query = target[q + 1 ..] };
    }
    return .{ .path = target, .query = "" };
}

fn parseQueryU64(query: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, part[0..eq], key)) continue;
        return std.fmt.parseInt(u64, part[eq + 1 ..], 10) catch null;
    }
    return null;
}

fn parseResourceKind(text: []const u8) ?ResourceKind {
    if (std.mem.eql(u8, text, "texture")) return .texture;
    if (std.mem.eql(u8, text, "image")) return .image;
    if (std.mem.eql(u8, text, "placement")) return .placement;
    return null;
}

test "closeOwnedFd tolerates already closed descriptor" {
    const fds = try std.posix.pipe();
    defer closeOwnedFd(fds[0]);
    _ = std.posix.system.close(fds[1]);
    closeOwnedFd(fds[1]);
}

test "closeOwnedFd closes open descriptor" {
    const fds = try std.posix.pipe();
    defer closeOwnedFd(fds[0]);
    closeOwnedFd(fds[1]);
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(std.posix.system.close(fds[1])));
}

test "inspector segment lifecycle is idempotent" {
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();
    var inspector = try Inspector.init(std.testing.allocator, &logger, "/tmp/katzensteg-inspector-test.sock");
    defer inspector.deinit();

    try std.testing.expectEqual(@as(usize, 0), inspector.segmentCount());
    try inspector.startCaptureForTest();
    try std.testing.expect(inspector.activeSegmentId() != null);
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.startCaptureForTest();
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.stopCaptureForTest();
    try std.testing.expectEqual(@as(?u64, null), inspector.activeSegmentId());
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());

    try inspector.stopCaptureForTest();
    try std.testing.expectEqual(@as(usize, 1), inspector.segmentCount());
}
