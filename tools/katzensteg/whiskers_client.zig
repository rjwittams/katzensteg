const std = @import("std");
const Logger = @import("log.zig").Logger;

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
const FrameBatchRequest = struct { frame_ids: []const []const u8 };
const ResourceBatchRequest = struct { resource_ids: []const []const u8 };

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
    mutex: std.Thread.Mutex = .{},
    current_segment_id: ?[]u8 = null,
    next_segment_seq: u64 = 1,
    last_capture_poll_ns: i128 = 0,
    next_frame_seq: u64 = 1,
    next_resource_seq: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, logger: *Logger, socket_path: []const u8, hello: ProducerHello) !WhiskersClient {
        const response_body = try postJsonForBody(allocator, socket_path, null, "/v0/producers/connect", hello);
        defer allocator.free(response_body);
        const parsed = try std.json.parseFromSlice(ProducerHelloResponse, allocator, response_body, .{});
        defer parsed.deinit();

        return .{
            .allocator = allocator,
            .logger = logger,
            .socket_path = try allocator.dupe(u8, socket_path),
            .producer_id = try allocator.dupe(u8, parsed.value.producer_id),
            .bearer_token = try allocator.dupe(u8, parsed.value.bearer_token),
            .display_name = try allocator.dupe(u8, parsed.value.display_name),
            .capture_enabled = std.atomic.Value(bool).init(parsed.value.capture_enabled),
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
        self.mutex.lock();
        if (self.control_fd) |fd| {
            self.control_fd = null;
            std.posix.close(fd);
        }
        self.mutex.unlock();
        if (self.control_thread) |thread| thread.join();
        self.stopActiveSegmentNow() catch |err| {
            self.logger.writeFmt("katzensteg: whiskers stopActiveSegmentNow failed during shutdown: {any}", .{err});
        };
        self.allocator.free(self.socket_path);
        self.allocator.free(self.producer_id);
        self.allocator.free(self.bearer_token);
        self.allocator.free(self.display_name);
    }

    pub fn isCaptureEnabled(self: *const WhiskersClient) bool {
        return self.capture_enabled.load(.monotonic);
    }

    pub fn notePresent(self: *WhiskersClient, resource_count: usize) void {
        self.pollCaptureState() catch |err| {
            self.logger.writeFmt("katzensteg: whiskers capture poll failed: {any}", .{err});
        };
        if (!self.isCaptureEnabled()) return;

        var maybe_start_segment_id: ?[]u8 = null;
        var frame_id: []u8 = undefined;
        var resource_ids = std.ArrayList([]const u8).empty;
        defer {
            for (resource_ids.items) |id| self.allocator.free(id);
            resource_ids.deinit(self.allocator);
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
        frame_id = std.fmt.allocPrint(self.allocator, "frame-{d}", .{self.next_frame_seq}) catch {
            self.mutex.unlock();
            return;
        };
        self.next_frame_seq += 1;
        var i: usize = 0;
        while (i < resource_count) : (i += 1) {
            const id = std.fmt.allocPrint(self.allocator, "res-{d}", .{self.next_resource_seq}) catch {
                self.mutex.unlock();
                return;
            };
            self.next_resource_seq += 1;
            resource_ids.append(self.allocator, id) catch {
                self.allocator.free(id);
                self.mutex.unlock();
                return;
            };
        }
        self.mutex.unlock();

        if (maybe_start_segment_id) |sid| {
            postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/segments/start", SegmentStartRequest{ .segment_id = sid }) catch |err| {
                self.logger.writeFmt("katzensteg: whiskers segment start failed: {any}", .{err});
            };
        }
        var frame_ids = [_][]const u8{frame_id};
        postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/frames/batch", FrameBatchRequest{ .frame_ids = &frame_ids }) catch |err| {
            self.logger.writeFmt("katzensteg: whiskers frame batch failed: {any}", .{err});
        };
        if (resource_ids.items.len > 0) {
            postJsonIgnoreBody(self.allocator, self.socket_path, self.bearer_token, "/v0/resources/batch", ResourceBatchRequest{ .resource_ids = resource_ids.items }) catch |err| {
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
                self.logger.writeFmt("katzensteg: whiskers control loop error: {any}", .{err});
                std.Thread.sleep(250 * std.time.ns_per_ms);
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

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(&read_buf);
        const header_bytes = try readUntilHeaderEnd(self.allocator, &reader);
        defer self.allocator.free(header_bytes);
        const status = parseStatusCode(header_bytes) orelse return error.BadHttpResponse;
        if (status != 200) return error.BadHttpStatus;

        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(self.allocator);
        while (!self.shutdown.load(.acquire)) {
            const chunk_header = try reader.interface().takeDelimiterExclusive('\n');
            const chunk_header_trimmed = std.mem.trim(u8, chunk_header, "\r ");
            if (chunk_header_trimmed.len == 0) continue;
            const chunk_size = std.fmt.parseInt(usize, chunk_header_trimmed, 16) catch return error.BadChunkHeader;
            if (chunk_size == 0) break;
            var remaining = chunk_size;
            while (remaining > 0) : (remaining -= 1) {
                const byte = try reader.interface().takeByte();
                if (byte == '\n') {
                    const trimmed = std.mem.trimRight(u8, line_buf.items, "\r");
                    if (trimmed.len != 0 and std.mem.startsWith(u8, trimmed, "event:")) {
                        const event_name = std.mem.trim(u8, trimmed[6..], " ");
                        self.applyControlEvent(event_name);
                    }
                    line_buf.clearRetainingCapacity();
                } else {
                    line_buf.append(self.allocator, byte) catch return error.OutOfMemory;
                }
            }
            _ = try reader.interface().takeByte(); // \r
            _ = try reader.interface().takeByte(); // \n
        }
    }
};

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
    if (status != 200) return error.BadHttpStatus;
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

fn readUntilHeaderEnd(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const byte = try reader.interface().takeByte();
        try buf.append(allocator, byte);
        if (std.mem.endsWith(u8, buf.items, "\r\n\r\n")) break;
        if (buf.items.len > 64 * 1024) return error.HeadersTooLarge;
    }
    return buf.toOwnedSlice(allocator);
}
