//! Native media source. Acquisition owns no terminal state; presentation owns no leases.
const std = @import("std");
const os = @import("platform");
const js = @import("jackstay");
const Controller = @import("jackstay_input_controller.zig").Controller;
const runtime = @import("runtime.zig");
const log_mod = @import("log.zig");
pub const std_options: std.Options = .{ .log_level = .info, .logFn = log_mod.stdLogFn };

const Shared = struct {
    allocator: std.mem.Allocator,
    connection: js.media.Connection,
    mutex: os.Mutex = .{},
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    pixels: std.ArrayList(u8) = .empty,
    image: ?js.media.Image = null,

    fn run(self: *Shared) void {
        self.receive() catch |err| {
            if (err != error.Closed and err != error.Cancelled) self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn receive(self: *Shared) !void {
        try self.connection.attach();
        var copy: std.ArrayList(u8) = .empty;
        defer copy.deinit(self.allocator);
        while (!self.stopped.load(.acquire)) {
            var frame = (self.connection.next(std.time.ns_per_s) catch |err| switch (err) {
                error.Timeout => continue,
                else => return err,
            }) orelse continue;
            const image = blk: {
                defer frame.release();
                var image = try frame.image();
                const size = try std.math.mul(usize, @as(usize, image.width) * 4, image.height);
                if (size > 64 * 1024 * 1024 or image.width > std.math.maxInt(i32) or image.height > std.math.maxInt(i32)) return error.FrameTooLarge;
                try copy.resize(self.allocator, size);
                const row_bytes = @as(usize, image.width) * 4;
                for (0..image.height) |row| @memcpy(copy.items[row * row_bytes ..][0..row_bytes], image.pixels[row * image.stride ..][0..row_bytes]);
                image.stride = @intCast(row_bytes);
                image.pixels = copy.items;
                break :blk image;
            };
            // A slow presenter replaces pending content; it never pins a lease.
            self.mutex.lock();
            std.mem.swap(std.ArrayList(u8), &self.pixels, &copy);
            self.image = image;
            self.mutex.unlock();
        }
    }
};

// Only this worker performs the bounded synchronous input handshake. The main
// loop can keep serving host control and video while admission is in progress.
const InputConnection = struct {
    path: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    client: ?js.input.Client = null,
    failure: ?anyerror = null,
    fn run(self: *InputConnection) void {
        self.connect() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn connect(self: *InputConnection) !void {
        var fd = try js.endpoint.connect(self.path);
        defer if (fd >= 0) os.posix.close(fd);
        self.client = try js.input.Client.connect(&fd, .cooperative);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 2 and !(args.len == 4 and std.mem.eql(u8, args[2], "--input-socket"))) return error.ExpectedSourceSocket;
    var input_connection = InputConnection{ .path = if (args.len == 4) args[3] else "" };
    const input_worker = if (args.len == 4) try std.Thread.spawn(.{}, InputConnection.run, .{&input_connection}) else null;
    defer {
        if (input_worker) |thread| thread.join();
        if (input_connection.client) |*client| client.deinit();
    }
    var fd = try js.endpoint.connect(args[1]);
    defer if (fd >= 0) os.posix.close(fd);
    var shared = Shared{ .allocator = init.gpa, .connection = try js.media.Connection.init(&fd) };
    defer shared.mutex.deinit();
    defer shared.connection.deinit();
    defer shared.pixels.deinit(init.gpa);
    const worker = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    defer {
        shared.stopped.store(true, .release);
        shared.connection.cancel();
        worker.join();
    }
    var source_runtime = runtime.Runtime.initMediaSource();
    const rt = &source_runtime;
    defer rt.deinit();
    if (!rt.active) return error.PresentationUnavailable;
    var controller: ?Controller = null;
    defer if (controller) |*control| {
        control.close();
        const deadline = os.time.nanoTimestamp() + 2 * std.time.ns_per_s;
        while (!control.closed and os.time.nanoTimestamp() < deadline) {
            control.poll(&rt.input_parser.?) catch break;
            os.time.sleep(std.time.ns_per_ms);
        }
        if (!control.clean) std.log.warn("Jackstay input cleanup unconfirmed at presenter exit", .{});
        control.deinit();
    };
    var input_adopted = false;
    var displayed: std.ArrayList(u8) = .empty;
    defer displayed.deinit(init.gpa);
    while (!rt.host_closed) {
        if (!input_adopted and input_worker != null and input_connection.done.load(.acquire)) {
            input_adopted = true;
            if (input_connection.client) |client| {
                controller = try Controller.init(client);
                input_connection.client = null;
                try rt.enableSourceInput();
                std.log.info("Jackstay source input connected: {s}", .{input_connection.path});
            } else std.log.warn("Jackstay source input unavailable: {any}", .{input_connection.failure});
        }
        rt.pollBatchControl();
        rt.pollTerminalInput();
        if (controller) |*control| {
            if (!control.closed) {
                control.pump(&rt.input_parser.?) catch |err| {
                    std.log.warn("Jackstay source input stopped: {any}", .{err});
                    control.close();
                    rt.disableSourceInput();
                };
            }
            if ((control.closed or control.closing) and rt.input_supported) rt.disableSourceInput();
        }
        if (rt.shouldCaptureExternalFrame()) {
            shared.mutex.lock();
            const image = shared.image;
            if (image != null) {
                std.mem.swap(std.ArrayList(u8), &shared.pixels, &displayed);
                shared.image = null;
            }
            shared.mutex.unlock();
            if (image) |frame| {
                // Source pixels define the view mapping; input geometry remains
                // the target's independent logical extent in the controller.
                rt.noteInputWindowSize(@intCast(frame.width), @intCast(frame.height));
                rt.presentExternalFramebuffer(@intCast(frame.width), @intCast(frame.height), if (frame.format == .rgba8) .rgba8 else .bgra8, displayed.items);
            }
        }
        if (shared.done.load(.acquire)) break;
        os.time.sleep(5 * std.time.ns_per_ms);
    }
    if (shared.done.load(.acquire)) if (shared.failure) |err| return err;
}
