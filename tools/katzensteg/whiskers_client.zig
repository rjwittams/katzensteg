const std = @import("std");
const Logger = @import("log.zig").Logger;
const inspect_model = @import("inspect_model.zig");

pub const ProducerHello = struct {
    producer_kind: []const u8,
    producer_name_hint: ?[]const u8,
    program: ?[]const u8,
    cmdline: []const []const u8,
    cwd: ?[]const u8,
    terminal: ?[]const u8,
};

const ProducerHelloResponse = struct {
    producer_id: []const u8,
    bearer_token: []const u8,
    display_name: []const u8,
    capture_enabled: bool,
};

const ProducerSelfResponse = struct {
    producer_id: []const u8,
    display_name: []const u8,
    producer_kind: []const u8,
    program: ?[]const u8,
    cmdline: []const []const u8,
    cwd: ?[]const u8,
    terminal: ?[]const u8,
    capture_enabled: bool,
};

const SegmentStartRequest = struct { segment_id: []const u8 };
const SegmentStopRequest = struct { segment_id: []const u8 };
const RuntimeInfoUpdateRequest = struct {
    terminal_identity: ?[]const u8,
    composite_mode: ?[]const u8,
    intercept_mode: ?[]const u8,
    output_profile: ?[]const u8,
    present_fps: ?u32,
};
const FrameIngestRecord = struct {
    frame_id: []const u8,
    ts_ns: i128,
    present_ns: i128,
    queue_depth: u64,
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
};
const FrameBatchRequest = struct { segment_id: []const u8, frames: []const FrameIngestRecord };
const EventIngestRecord = struct {
    frame_id: []const u8,
    ts_ns: i128,
    kind: []const u8,
    thread: []const u8,
    texture_key: u64,
    image_id: u32,
    placement_id: u32,
    bytes_uploaded: u64,
    reason: ?[]const u8,
};
const EventBatchRequest = struct { segment_id: []const u8, events: []const EventIngestRecord };
const ResourceIngestRecord = struct {
    frame_id: []const u8,
    kind: []const u8,
    texture_key: u64,
    placement_id: u32,
    alias: []const u8,
    w: i32,
    h: i32,
    format: u32,
    blend_mode: i32,
    update_count: u64,
    image_id: u32,
};
const ResourceBatchRequest = struct { segment_id: []const u8, resources: []const ResourceIngestRecord };

const ParseProgress = enum {
    progress,
    need_more,
    done,
};

pub const WhiskersClient = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    socket_path: []u8,
    producer_id: []u8,
    bearer_token: []u8,
    display_name: []u8,
    capture_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    control_thread: ?std.Thread = null,
    control_fd: ?std.posix.fd_t = null,
    wake_read_fd: std.posix.fd_t = -1,
    wake_write_fd: std.posix.fd_t = -1,
    mutex: std.Thread.Mutex = .{},
    current_segment_id: ?[]u8 = null,
    next_segment_seq: u64 = 1,
    runtime_info_sent: bool = false,
    last_capture_poll_ns: i128 = 0,
    next_frame_seq: u64 = 1,
    next_resource_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, logger: *Logger, socket_path: []const u8, hello: ProducerHello) !WhiskersClient {
        const response_body = try postJsonForBody(allocator, socket_path, null, "/v0/producers/connect", hello);
        defer allocator.free(response_body);
        const parsed = try std.json.parseFromSlice(ProducerHelloResponse, allocator, response_body, .{});
        defer parsed.deinit();

        const wake = try createWakeSocketPair();
        errdefer {
            std.posix.close(wake[0]);
            std.posix.close(wake[1]);
        }

        return .{
            .allocator = allocator,
            .logger = logger,
            .socket_path = try allocator.dupe(u8, socket_path),
            .producer_id = try allocator.dupe(u8, parsed.value.producer_id),
            .bearer_token = try allocator.dupe(u8, parsed.value.bearer_token),
            .display_name = try allocator.dupe(u8, parsed.value.display_name),
            .capture_enabled = std.atomic.Value(bool).init(parsed.value.capture_enabled),
            .wake_read_fd = wake[0],
            .wake_write_fd = wake[1],
        };
    }

    pub fn start(self: *WhiskersClient) void {
        if (self.control_thread != null) return;
        self.control_thread = std.Thread.spawn(.{}, controlMain, .{self}) catch |err| {
            self.logger.writeFmt("katzensteg: failed to start whiskers control thread: {any}", .{err});
            return;
        };
    }

    pub fn deinit(self: *WhiskersClient) void {
        self.shutdown.store(true, .release);
        if (self.wake_write_fd >= 0) {
            _ = std.posix.write(self.wake_write_fd, &[1]u8{1}) catch {};
        }
        self.mutex.lock();
        if (self.control_fd) |fd| {
            std.posix.shutdown(fd, .both) catch {};
        }
        self.mutex.unlock();
        if (self.control_thread) |thread| thread.join();
        self.mutex.lock();
        const segment_id_owned = self.current_segment_id;
        self.current_segment_id = null;
        self.mutex.unlock();
        if (segment_id_owned) |segment_id| {
            self.logger.writeFmt("katzensteg: whiskers leaving active segment open during shutdown producer={s}", .{self.producer_id});
            self.allocator.free(segment_id);
        }
        if (self.wake_read_fd >= 0) {
            std.posix.close(self.wake_read_fd);
            self.wake_read_fd = -1;
        }
        if (self.wake_write_fd >= 0) {
            std.posix.close(self.wake_write_fd);
            self.wake_write_fd = -1;
        }
        self.allocator.free(self.socket_path);
        self.allocator.free(self.producer_id);
        self.allocator.free(self.bearer_token);
        self.allocator.free(self.display_name);
    }

    pub fn isCaptureEnabled(self: *const WhiskersClient) bool {
        return self.capture_enabled.load(.monotonic);
    }

    pub fn updateRuntimeInfo(self: *WhiskersClient, terminal_identity: []const u8, composite_mode: []const u8, intercept_mode: []const u8, output_profile: []const u8, present_fps: u32) void {
        postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/runtime/info", RuntimeInfoUpdateRequest{
            .terminal_identity = terminal_identity,
            .composite_mode = composite_mode,
            .intercept_mode = intercept_mode,
            .output_profile = output_profile,
            .present_fps = present_fps,
        }) catch |err| {
            self.logger.writeFmt("katzensteg: whiskers runtime info update failed: {any}", .{err});
            return;
        };
        self.runtime_info_sent = true;
    }

    pub fn notePresent(self: *WhiskersClient, frame: inspect_model.FrameRecord, resources: []const inspect_model.ResourceRecord) void {
        self.pollCaptureState() catch |err| {
            self.logger.writeFmt("katzensteg: whiskers capture poll failed: {any}", .{err});
        };
        if (!self.isCaptureEnabled()) return;

        var maybe_start_segment_id: ?[]u8 = null;
        var frame_id: []u8 = undefined;
        var frame_records = std.ArrayList(FrameIngestRecord).empty;
        var event_records = std.ArrayList(EventIngestRecord).empty;
        var resource_records = std.ArrayList(ResourceIngestRecord).empty;
        defer {
            frame_records.deinit(self.allocator);
            event_records.deinit(self.allocator);
            resource_records.deinit(self.allocator);
            self.allocator.free(frame_id);
            if (maybe_start_segment_id) |id| self.allocator.free(id);
        }

        self.mutex.lock();
        if (!self.capture_enabled.load(.monotonic)) {
            self.mutex.unlock();
            return;
        }

        if (self.current_segment_id == null) {
            const new_segment_id = std.fmt.allocPrint(self.allocator, "seg-{d}", .{self.next_segment_seq}) catch {
                self.mutex.unlock();
                return;
            };
            self.next_segment_seq += 1;
            self.current_segment_id = new_segment_id;
            maybe_start_segment_id = self.allocator.dupe(u8, new_segment_id) catch {
                self.mutex.unlock();
                return;
            };
        }
        const segment_id = self.current_segment_id.?;
        frame_id = std.fmt.allocPrint(self.allocator, "frame-{d}", .{self.next_frame_seq}) catch {
            self.mutex.unlock();
            return;
        };
        self.next_frame_seq += 1;
        self.mutex.unlock();

        frame_records.append(self.allocator, .{
            .frame_id = frame_id,
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
        }) catch return;

        event_records.append(self.allocator, .{
            .frame_id = frame_id,
            .ts_ns = frame.ts_ns,
            .kind = "present",
            .thread = "producer",
            .texture_key = 0,
            .image_id = frame.image_id,
            .placement_id = frame.placement_id,
            .bytes_uploaded = frame.bytes_uploaded,
            .reason = null,
        }) catch return;
        if (frame.fallback_reason) |reason| {
            event_records.append(self.allocator, .{
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "fallback",
                .thread = "producer",
                .texture_key = frame.fallback_texture_key,
                .image_id = frame.image_id,
                .placement_id = frame.placement_id,
                .bytes_uploaded = 0,
                .reason = reason,
            }) catch return;
        }
        if (frame.image_id != 0) {
            event_records.append(self.allocator, .{
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "upload",
                .thread = "producer",
                .texture_key = 0,
                .image_id = frame.image_id,
                .placement_id = 0,
                .bytes_uploaded = frame.bytes_uploaded,
                .reason = null,
            }) catch return;
        }
        if (frame.image_id != 0 and frame.placement_id != 0) {
            event_records.append(self.allocator, .{
                .frame_id = frame_id,
                .ts_ns = frame.ts_ns,
                .kind = "placement",
                .thread = "producer",
                .texture_key = 0,
                .image_id = frame.image_id,
                .placement_id = frame.placement_id,
                .bytes_uploaded = 0,
                .reason = null,
            }) catch return;
        }

        for (resources) |res| {
            const alias = std.mem.sliceTo(&res.alias, 0);
            resource_records.append(self.allocator, .{
                .frame_id = frame_id,
                .kind = @tagName(res.kind),
                .texture_key = res.texture_key,
                .placement_id = res.placement_id,
                .alias = alias,
                .w = res.w,
                .h = res.h,
                .format = res.format,
                .blend_mode = res.blend_mode,
                .update_count = res.update_count,
                .image_id = res.image_id,
            }) catch return;
        }

        if (maybe_start_segment_id) |sid| {
            postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/segments/start", SegmentStartRequest{ .segment_id = sid }) catch |err| {
                self.logger.writeFmt("katzensteg: whiskers segment start failed: {any}", .{err});
            };
        }
        postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/frames/batch", FrameBatchRequest{ .segment_id = segment_id, .frames = frame_records.items }) catch |err| {
            self.logger.writeFmt("katzensteg: whiskers frame batch failed: {any}", .{err});
        };
        if (event_records.items.len > 0) {
            postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/events/batch", EventBatchRequest{ .segment_id = segment_id, .events = event_records.items }) catch |err| {
                self.logger.writeFmt("katzensteg: whiskers event batch failed: {any}", .{err});
            };
        }
        if (resource_records.items.len > 0) {
            postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/resources/batch", ResourceBatchRequest{ .segment_id = segment_id, .resources = resource_records.items }) catch |err| {
                self.logger.writeFmt("katzensteg: whiskers resource batch failed: {any}", .{err});
            };
        }
    }

    fn stopActiveSegmentNow(self: *WhiskersClient) !void {
        var segment_id_owned: ?[]u8 = null;
        self.mutex.lock();
        if (self.current_segment_id) |segment_id| {
            segment_id_owned = segment_id;
            self.current_segment_id = null;
        }
        self.mutex.unlock();
        if (segment_id_owned) |segment_id| {
            defer self.allocator.free(segment_id);
            try postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/segments/stop", SegmentStopRequest{ .segment_id = segment_id });
        }
    }

    fn pollCaptureState(self: *WhiskersClient) !void {
        const now = std.time.nanoTimestamp();
        if (now - self.last_capture_poll_ns < std.time.ns_per_s) return;
        self.last_capture_poll_ns = now;
        const body = try requestForBody(self.allocator, self.socket_path, "GET", "/v0/producers/self", self.bearer_token, "");
        defer self.allocator.free(body);
        const parsed = try std.json.parseFromSlice(ProducerSelfResponse, self.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const desired = parsed.value.capture_enabled;
        const current = self.capture_enabled.load(.monotonic);
        if (desired != current) {
            self.capture_enabled.store(desired, .release);
            if (!desired) {
                self.stopActiveSegmentNow() catch |err| {
                    self.logger.writeFmt("katzensteg: whiskers segment stop on poll failed: {any}", .{err});
                };
            }
            self.logger.writeFmt("katzensteg: whiskers capture poll state -> {}", .{desired});
        }
    }

    fn applyControlEvent(self: *WhiskersClient, event_name: []const u8) void {
        if (std.mem.eql(u8, event_name, "capture_start")) {
            self.capture_enabled.store(true, .release);
            self.logger.writeFmt("katzensteg: whiskers control capture_start producer={s}", .{self.producer_id});
        } else if (std.mem.eql(u8, event_name, "capture_stop")) {
            self.capture_enabled.store(false, .release);
            self.stopActiveSegmentNow() catch |err| {
                self.logger.writeFmt("katzensteg: whiskers segment stop on capture_stop failed: {any}", .{err});
            };
            self.logger.writeFmt("katzensteg: whiskers control capture_stop producer={s}", .{self.producer_id});
        }
    }

    fn controlMain(self: *WhiskersClient) void {
        while (!self.shutdown.load(.acquire)) {
            self.controlLoopOnce() catch |err| {
                if (self.shutdown.load(.acquire)) break;
                switch (err) {
                    error.EndOfStream, error.ConnectionResetByPeer, error.BrokenPipe => continue,
                    else => {
                        self.logger.writeFmt("katzensteg: whiskers control loop error: {any}", .{err});
                        std.Thread.sleep(250 * std.time.ns_per_ms);
                    },
                }
            };
        }
    }

    fn controlLoopOnce(self: *WhiskersClient) !void {
        var stream = try std.net.connectUnixSocket(self.socket_path);
        defer {
            self.mutex.lock();
            if (self.control_fd != null and self.control_fd.? == stream.handle) self.control_fd = null;
            self.mutex.unlock();
            stream.close();
        }
        self.mutex.lock();
        self.control_fd = stream.handle;
        self.mutex.unlock();

        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.writer(self.allocator).print(
            "GET /v0/producers/control HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n",
            .{self.bearer_token},
        );
        _ = try stream.write(req_buf.items);

        var recv_buf = std.ArrayList(u8).empty;
        defer recv_buf.deinit(self.allocator);
        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(self.allocator);
        var parse_offset: usize = 0;
        var headers_done = false;
        var chunk_remaining: ?usize = null;
        var expect_chunk_trailer = false;

        while (!self.shutdown.load(.acquire)) {
            while (true) {
                switch (try self.processControlBytes(&recv_buf, &line_buf, &parse_offset, &headers_done, &chunk_remaining, &expect_chunk_trailer)) {
                    .progress => continue,
                    .done => return,
                    .need_more => break,
                }
            }

            var poll_fds = [_]std.posix.pollfd{
                .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_read_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&poll_fds, -1);
            if ((poll_fds[1].revents & std.posix.POLL.IN) != 0) {
                self.drainWakeFd();
                return;
            }
            if ((poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                return error.EndOfStream;
            }
            if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) continue;

            var buf: [4096]u8 = undefined;
            const n = try std.posix.read(stream.handle, &buf);
            if (n == 0) return error.EndOfStream;
            try recv_buf.appendSlice(self.allocator, buf[0..n]);
        }
    }

    fn drainWakeFd(self: *WhiskersClient) void {
        var buf: [64]u8 = undefined;
        _ = std.posix.read(self.wake_read_fd, &buf) catch {};
    }

    fn processControlBytes(
        self: *WhiskersClient,
        recv_buf: *std.ArrayList(u8),
        line_buf: *std.ArrayList(u8),
        parse_offset: *usize,
        headers_done: *bool,
        chunk_remaining: *?usize,
        expect_chunk_trailer: *bool,
    ) !ParseProgress {
        if (!headers_done.*) {
            const pending = recv_buf.items[parse_offset.*..];
            const rel_end = std.mem.indexOf(u8, pending, "\r\n\r\n") orelse return .need_more;
            const header = pending[0..rel_end];
            const status = parseStatusCode(header) orelse return error.BadHttpResponse;
            if (status != 200) return error.BadHttpStatus;
            parse_offset.* += rel_end + 4;
            headers_done.* = true;
            try maybeCompactBuffer(recv_buf, self.allocator, parse_offset);
            return .progress;
        }

        if (expect_chunk_trailer.*) {
            const pending = recv_buf.items[parse_offset.*..];
            if (pending.len < 2) return .need_more;
            parse_offset.* += 2;
            expect_chunk_trailer.* = false;
            chunk_remaining.* = null;
            try maybeCompactBuffer(recv_buf, self.allocator, parse_offset);
            return .progress;
        }

        if (chunk_remaining.* == null) {
            const pending = recv_buf.items[parse_offset.*..];
            const rel_nl = findNewline(pending) orelse return .need_more;
            const chunk_header = std.mem.trim(u8, pending[0..rel_nl], "\r ");
            parse_offset.* += rel_nl + 1;
            if (chunk_header.len == 0) {
                try maybeCompactBuffer(recv_buf, self.allocator, parse_offset);
                return .progress;
            }
            const size = std.fmt.parseInt(usize, chunk_header, 16) catch return error.BadChunkHeader;
            if (size == 0) return .done;
            chunk_remaining.* = size;
            try maybeCompactBuffer(recv_buf, self.allocator, parse_offset);
            return .progress;
        }

        const remaining = chunk_remaining.*.?;
        const pending = recv_buf.items[parse_offset.*..];
        if (pending.len == 0) return .need_more;
        const take = @min(remaining, pending.len);
        try processSseData(line_buf, self.allocator, pending[0..take], self);
        parse_offset.* += take;
        chunk_remaining.* = remaining - take;
        if (chunk_remaining.*.? == 0) expect_chunk_trailer.* = true;
        try maybeCompactBuffer(recv_buf, self.allocator, parse_offset);
        return .progress;
    }
};

fn createWakeSocketPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

fn postJsonIgnoreBody(allocator: std.mem.Allocator, socket_path: []const u8, bearer_token: ?[]const u8, path: []const u8, payload: anytype) !void {
    const body = try postJsonForBody(allocator, socket_path, bearer_token, path, payload);
    allocator.free(body);
}

fn postJsonForBody(allocator: std.mem.Allocator, socket_path: []const u8, bearer_token: ?[]const u8, path: []const u8, payload: anytype) ![]u8 {
    const json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
    defer allocator.free(json);
    return requestForBody(allocator, socket_path, "POST", path, bearer_token, json);
}

fn requestForBody(allocator: std.mem.Allocator, socket_path: []const u8, method: []const u8, path: []const u8, bearer_token: ?[]const u8, body: []const u8) ![]u8 {
    var stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    var req = std.ArrayList(u8).empty;
    defer req.deinit(allocator);
    try req.writer(allocator).print("{s} {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n", .{ method, path, body.len });
    if (bearer_token) |token| try req.writer(allocator).print("Authorization: Bearer {s}\r\n", .{token});
    try req.appendSlice(allocator, "Connection: close\r\n\r\n");
    try req.appendSlice(allocator, body);
    _ = try stream.write(req.items);

    const file = std.fs.File{ .handle = stream.handle };
    const response = try file.deprecatedReader().readAllAlloc(allocator, 1 << 20);
    errdefer allocator.free(response);
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.BadHttpResponse;
    const header = response[0..header_end];
    const status = parseStatusCode(header) orelse return error.BadHttpResponse;
    if (status != 200) {
        return error.BadHttpStatus;
    }
    const body_slice = response[header_end + 4 ..];
    return try allocator.dupe(u8, body_slice);
}

fn parseStatusCode(header: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, header, "\r\n") orelse header.len;
    const line = header[0..line_end];
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next() orelse return null;
    const code_text = it.next() orelse return null;
    return std.fmt.parseInt(u16, code_text, 10) catch null;
}

fn maybeCompactBuffer(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, parse_offset: *usize) !void {
    if (parse_offset.* == 0) return;
    if (parse_offset.* < 4096 and parse_offset.* < buf.items.len / 2) return;
    const remaining = buf.items[parse_offset.*..];
    std.mem.copyForwards(u8, buf.items[0..remaining.len], remaining);
    buf.items.len = remaining.len;
    parse_offset.* = 0;
    _ = allocator;
}

fn processSseData(line_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8, client: *WhiskersClient) !void {
    for (data) |byte| {
        if (byte == '\n') {
            const trimmed = std.mem.trimRight(u8, line_buf.items, "\r");
            if (trimmed.len != 0 and std.mem.startsWith(u8, trimmed, "event:")) {
                const event_name = std.mem.trim(u8, trimmed[6..], " ");
                client.applyControlEvent(event_name);
            }
            line_buf.clearRetainingCapacity();
        } else {
            try line_buf.append(allocator, byte);
        }
    }
}

fn findNewline(bytes: []const u8) ?usize {
    return std.mem.indexOfScalar(u8, bytes, '\n');
}
