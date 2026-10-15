//! Owned CPU media handles. No grants, mappings or frame pointers escape here.
const std = @import("std");
pub const c = @cImport({
    @cInclude("jackstay_handshake.h");
});

pub const Format = enum { rgba8, bgra8 };
pub const Image = struct {
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    pixels: []const u8,
    /// Host time, the offered clock; 0 asks Jackstay to stamp it at publish.
    timestamp_ns: u64 = 0,
    sequence: u64 = 0,
};

pub fn checkAbi() !void {
    if (c.FT_ABI_VERSION != 17 or c.ft_abi_version() != 17) return error.JackstayAbiMismatch;
}

/// An unconsumed Local Endpoint connection; null once a setup call consumed it.
pub const Local = ?*c.ft_local_connection;

/// Wraps a connected stream whose peer the caller verified. Consumes fd after
/// basic checks.
pub fn adopt(fd: *i32) !Local {
    var local: Local = null;
    try check(c.ft_local_connection_adopt(fd, &local));
    return local;
}

fn check(status: c.ft_status) !void {
    switch (status) {
        c.FT_STATUS_OK => {},
        c.FT_STATUS_CLOSED => return error.Closed,
        c.FT_STATUS_CANCELLED => return error.Cancelled,
        c.FT_STATUS_TIMEOUT => return error.Timeout,
        c.FT_STATUS_CAPACITY => return error.Capacity,
        else => return error.JackstayFailure,
    }
}

pub const Frame = struct {
    handle: ?*c.ft_acquired_frame,

    pub fn release(self: *Frame) void {
        // Only immediate CPU use is exposed by this wrapper.
        std.debug.assert(c.ft_acquired_frame_release(&self.handle) == c.FT_STATUS_OK);
    }

    pub fn image(self: *const Frame) !Image {
        var desc: c.ft_acquired_frame_descriptor = undefined;
        try check(c.ft_acquired_frame_describe(self.handle, &desc));
        var bytes: [*c]const u8 = null;
        var len: usize = 0;
        try check(c.ft_acquired_frame_bytes(self.handle, &bytes, &len));
        const format: Format = switch (desc.pixel_format) {
            c.FT_PIXEL_FORMAT_RGBA8_UNORM => .rgba8,
            c.FT_PIXEL_FORMAT_BGRA8_UNORM => .bgra8,
            else => return error.UnsupportedFormat,
        };
        if (bytes == null or desc.sync_kind != c.FT_FRAME_SYNC_CPU_COPY_COMPLETE) return error.UnsupportedFrame;
        const row = try std.math.mul(usize, desc.width, 4);
        const size = try std.math.mul(usize, desc.stride, desc.height);
        if (desc.width == 0 or desc.height == 0 or desc.stride < row or size > len) return error.InvalidFrame;
        return .{ .width = desc.width, .height = desc.height, .stride = desc.stride, .format = format, .pixels = bytes[0..size], .timestamp_ns = desc.timestamp_ns, .sequence = desc.sequence };
    }
};

pub const Connection = struct {
    handle: ?*c.ft_cpu_acquisition_connection = null,
    cancellation: ?*c.ft_acquisition_cancellation = null,
    consumer: ?*c.ft_acquisition_consumer = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    cursor: u64 = 0,
    requested_epoch: ?u64 = null,

    // Consumes the connection after basic validation, including on failure.
    pub fn init(local: *Local) !Connection {
        try checkAbi();
        var self = Connection{};
        errdefer self.deinit();
        try check(c.ft_acquisition_cancellation_create(&self.cancellation));
        try check(c.ft_acquisition_cpu_connection_create_local(local, &self.handle));
        return self;
    }

    pub fn attach(self: *Connection) !void {
        try self.attachHolding(1);
    }

    pub fn attachHolding(self: *Connection, holding: u32) !void {
        try check(c.ft_acquisition_cpu_attach(self.handle, holding, &self.consumer));
    }

    // May overlap setup and acquisition waits. Closing setup can wake a frame
    // wait as Closed before the cancellation wake arrives. Both end acquisition.
    // Destruction follows worker join.
    pub fn cancel(self: *Connection) void {
        self.cancelled.store(true, .release);
        c.ft_acquisition_cpu_connection_cancel(self.handle);
        _ = c.ft_acquisition_cancellation_cancel(self.cancellation);
    }

    pub fn deinit(self: *Connection) void {
        c.ft_acquisition_consumer_destroy(&self.consumer);
        c.ft_acquisition_cpu_connection_destroy(&self.handle);
        c.ft_acquisition_cancellation_destroy(&self.cancellation);
    }

    // Detects producer disconnect only; EOF is not lease retirement.
    fn checkConnected(self: *Connection) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        try check(c.ft_acquisition_cpu_connection_alive(self.handle));
    }

    pub fn next(self: *Connection, timeout_ns: u64) !?Frame {
        try self.checkConnected();
        var observed: c.ft_acquisition_events = undefined;
        try check(c.ft_acquisition_snapshot(self.consumer, &observed));
        var frame = Frame{ .handle = null };
        var range: c.ft_acquisition_range = undefined;
        const result = c.ft_acquisition_acquire(self.consumer, c.FT_ACQUIRE_LATEST, self.cursor, &frame.handle, &range);
        var interest: u32 = c.FT_WAIT_DATA;
        switch (result) {
            c.FT_STATUS_OK => {
                var desc: c.ft_acquired_frame_descriptor = undefined;
                errdefer frame.release();
                try check(c.ft_acquired_frame_describe(frame.handle, &desc));
                self.cursor = desc.cursor;
                return frame;
            },
            c.FT_STATUS_EMPTY, c.FT_STATUS_MISS => {},
            c.FT_STATUS_HOLDING_LIMIT => interest = c.FT_WAIT_CAPACITY,
            c.FT_STATUS_RECONFIGURATION => {
                interest = c.FT_WAIT_ALL;
                if (self.requested_epoch == null or self.requested_epoch.? != observed.reconfiguration_epoch) {
                    self.requested_epoch = observed.reconfiguration_epoch;
                    // Acquired frames retain their own mappings. Dropping the
                    // unleased configuration lets a capacity-paused resize advance.
                    try check(c.ft_acquisition_relinquish_configuration(self.consumer));
                    const installed = c.ft_acquisition_cpu_install_configuration(self.handle, self.consumer);
                    if (installed == c.FT_STATUS_OK) return null;
                    if (installed != c.FT_STATUS_EMPTY and installed != c.FT_STATUS_STALE) try check(installed);
                }
            },
            else => try check(result),
        }
        var updated: c.ft_acquisition_events = undefined;
        const waited = c.ft_acquisition_wait(self.consumer, &observed, interest, self.cancellation, timeout_ns, &updated);
        if (waited == c.FT_STATUS_TIMEOUT) try self.checkConnected();
        try check(waited);
        return null;
    }
};

pub const Producer = struct {
    handle: ?*c.ft_cpu_producer = null,
    capacity: usize,
    pending_capacity: ?usize = null,
    pub const Options = struct { memory_budget: u64 = 256 * 1024 * 1024 };

    pub fn init(capacity: usize) !Producer {
        return initWithOptions(capacity, .{});
    }

    pub fn initWithOptions(capacity: usize, options: Options) !Producer {
        try checkAbi();
        var self = Producer{ .capacity = capacity };
        const config = c.ft_cpu_producer_config{
            .resource_capacity = 4,
            .retained_history = 1,
            .producer_reserve = 1,
            .max_incarnations = 8,
            .payload_capacity = capacity,
            .memory_budget = options.memory_budget,
            .drain_timeout_ns = 2 * std.time.ns_per_s,
        };
        try check(c.ft_cpu_producer_create(&config, &self.handle));
        return self;
    }

    pub fn publish(self: *Producer, image: Image) !bool {
        if (self.pending_capacity != null) return false;
        if (image.pixels.len > self.capacity) {
            var replacement: c.ft_cpu_reconfiguration = undefined;
            const result = c.ft_cpu_producer_reconfigure(self.handle, image.pixels.len, &replacement);
            if (result == c.FT_STATUS_PAUSED_CAPACITY) {
                self.pending_capacity = image.pixels.len;
                return false;
            }
            try check(result);
            self.capacity = image.pixels.len;
        }
        var desc: c.ft_acquired_frame_descriptor = std.mem.zeroes(c.ft_acquired_frame_descriptor);
        desc.width = image.width;
        desc.height = image.height;
        desc.stride = image.stride;
        desc.pixel_format = if (image.format == .rgba8) c.FT_PIXEL_FORMAT_RGBA8_UNORM else c.FT_PIXEL_FORMAT_BGRA8_UNORM;
        desc.timestamp_ns = image.timestamp_ns;
        desc.sequence = image.sequence;
        var cursor: u64 = 0;
        const result = c.ft_cpu_producer_publish(self.handle, &desc, image.pixels.ptr, image.pixels.len, &cursor);
        if (result == c.FT_STATUS_DROPPED or result == c.FT_STATUS_PAUSED_CAPACITY) return false;
        try check(result);
        return true;
    }

    pub fn maintenance(self: *Producer) !void {
        try check(c.ft_cpu_producer_poll_cleanup(self.handle));
        var replacement: c.ft_cpu_reconfiguration = undefined;
        const result = c.ft_cpu_producer_advance(self.handle, &replacement);
        if (result == c.FT_STATUS_PAUSED_CAPACITY) return;
        try check(result);
        if (self.pending_capacity) |capacity| {
            self.capacity = capacity;
            self.pending_capacity = null;
        }
    }

    pub fn serve(self: *Producer, local: *Local) !Server {
        var server = Server{};
        try check(c.ft_cpu_producer_serve_local(self.handle, local, &server.handle));
        return server;
    }

    // false retains ownership. Never discard the handle or force reclamation.
    pub fn close(self: *Producer) !bool {
        const result = c.ft_cpu_producer_destroy(&self.handle);
        if (result == c.FT_STATUS_DRAINING) return false;
        try check(result);
        return true;
    }
};

pub const Server = struct {
    handle: ?*c.ft_cpu_setup_server = null,
    pub fn finished(self: *Server) bool {
        return c.ft_cpu_setup_server_poll(self.handle) != c.FT_STATUS_DRAINING;
    }
    pub fn close(self: *Server) void {
        c.ft_cpu_setup_server_cancel(self.handle);
        _ = c.ft_cpu_setup_server_destroy(&self.handle);
    }
};
