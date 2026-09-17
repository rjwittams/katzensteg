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
    path: []const u8,
    request: js.bootstrap.Request,
    connection: ?js.media.Connection = null,
    client: ?js.input.Client = null,
    refusal: ?anyerror = null,
    setup_done: std.atomic.Value(bool) = .init(false),
    attached: bool = false, // worker-owned; distinguishes setup failure from source exit
    mutex: os.Mutex = .{},
    stopped: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    pixels: std.ArrayList(u8) = .empty,
    image: ?js.media.Image = null,

    fn run(self: *Shared) void {
        self.receive() catch |err| {
            if (err != error.Cancelled and !(err == error.Closed and self.attached)) self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn receive(self: *Shared) !void {
        // Bootstrap and admission are bounded but synchronous. The main loop
        // remains responsive to host control throughout setup.
        var fd = try js.endpoint.connect(self.path);
        defer if (fd >= 0) os.posix.close(fd);
        const connected = try js.bootstrap.connect(&fd, self.request);
        self.client = connected.client;
        self.refusal = connected.refusal;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopped.load(.acquire)) return;
            self.connection = try js.media.Connection.init(&fd);
        }
        self.setup_done.store(true, .release);
        try self.connection.?.attach();
        self.attached = true;
        var copy: std.ArrayList(u8) = .empty;
        defer copy.deinit(self.allocator);
        while (!self.stopped.load(.acquire)) {
            var frame = (self.connection.?.next(std.time.ns_per_s) catch |err| switch (err) {
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

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len < 2 or args.len > 3) return error.ExpectedSourceSocket;
    const request: js.bootstrap.Request = if (args.len == 2) .optional else if (std.mem.eql(u8, args[2], "--observe")) .observe else if (std.mem.eql(u8, args[2], "--require-input")) .required else return error.InvalidInputMode;
    var shared = Shared{ .allocator = init.gpa, .path = args[1], .request = request };
    defer shared.mutex.deinit();
    defer shared.pixels.deinit(init.gpa);
    const worker = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    defer {
        shared.stopped.store(true, .release);
        shared.mutex.lock();
        if (shared.connection) |*connection| connection.cancel();
        shared.mutex.unlock();
        worker.join();
        if (shared.connection) |*connection| connection.deinit();
        // Covers early host exit, failed media attachment, and failed controller
        // adoption. No admitted client is silently destroyed during setup.
        if (shared.client) |*client| {
            const clean = client.closeAndWait(2 * std.time.ns_per_s) catch false;
            if (!clean) std.log.warn("Jackstay setup input cleanup unconfirmed", .{});
            client.deinit();
        }
    }
    var source_runtime = runtime.Runtime.initMediaSource();
    const rt = &source_runtime;
    defer rt.deinit();
    if (!rt.active) return error.PresentationUnavailable;
    var controller: ?Controller = null;
    defer if (controller) |*control| {
        if (!control.closed) control.clean = control.client.closeAndWait(2 * std.time.ns_per_s) catch false;
        if (!control.clean) std.log.warn("Jackstay input cleanup unconfirmed at presenter exit", .{});
        control.deinit();
    };
    var input_adopted = false;
    var displayed: std.ArrayList(u8) = .empty;
    defer displayed.deinit(init.gpa);
    while (!rt.host_closed) {
        if (!input_adopted and shared.setup_done.load(.acquire)) {
            input_adopted = true;
            if (shared.client) |client| {
                controller = try Controller.init(client);
                shared.client = null;
                try rt.enableSourceInput();
                std.log.info("Jackstay source input connected: {s}", .{shared.path});
            } else if (shared.refusal) |reason| {
                std.log.info("Jackstay source is observation-only: {any}", .{reason});
            }
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
