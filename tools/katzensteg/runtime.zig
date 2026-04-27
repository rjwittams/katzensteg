const std = @import("std");
const termscene = @import("termscene");
const config_mod = @import("config.zig");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;
const frame_builder_mod = @import("frame_builder.zig");
const intercept_sink = @import("intercept_sink.zig");
const inspect_model = @import("inspect_model.zig");
const inspector_mod = @import("inspector.zig");
const input_mod = @import("input.zig");
const gl_capture_mod = @import("gl_capture.zig");
const presentation_layout_mod = @import("presentation_layout.zig");
const whiskers_client_mod = @import("whiskers_client.zig");
const window_policy_mod = @import("window_policy.zig");
const sdl = @import("katzensteg_sdl");
const Inspector = inspector_mod.Inspector;
const WhiskersClient = whiskers_client_mod.WhiskersClient;
const InspectResource = frame_builder_mod.InspectResource;
const ResourceRecord = inspect_model.ResourceRecord;
const FrameBuilder = frame_builder_mod.FrameBuilder;
const CompositeMode = config_mod.CompositeMode;
const InterceptMode = config_mod.InterceptMode;
const Command = intercept_sink.Command;
const PixelSize = frame_builder_mod.PixelSize;
const ExternalFramebufferFormat = frame_builder_mod.ExternalFramebufferFormat;

const queue_compact_threshold = 4096;
const payload_pool_max_buffers = 64;
const payload_pool_max_bytes = 64 * 1024 * 1024;

const QueuedLockCapture = struct {
    rect: ?@import("katzensteg_sdl").SDL_Rect,
    pixels: ?*anyopaque,
    pitch: i32,
};

const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;

var global_mutex: std.Thread.Mutex = .{};
var global_runtime: ?Runtime = null;

pub const ProducerStatKind = enum {
    generic,
    update_texture,
    unlock_texture,
    create_texture_from_surface,
    render_present,
};

const ProducerBucket = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
};

const ProducerStats = struct {
    enabled: bool = false,
    last_report_ns: i128 = 0,
    generic: ProducerBucket = .{},
    update_texture: ProducerBucket = .{},
    unlock_texture: ProducerBucket = .{},
    create_texture_from_surface: ProducerBucket = .{},
    render_present: ProducerBucket = .{},
};

const PayloadBufferPool = struct {
    buffers: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,

    fn acquire(self: *PayloadBufferPool, allocator: std.mem.Allocator, len: usize) ![]u8 {
        var idx: usize = self.buffers.items.len;
        while (idx > 0) {
            idx -= 1;
            const buf = self.buffers.items[idx];
            if (buf.len != len) continue;
            _ = self.buffers.swapRemove(idx);
            self.bytes -= buf.len;
            return buf;
        }
        return allocator.alloc(u8, len);
    }

    fn release(self: *PayloadBufferPool, allocator: std.mem.Allocator, buf: []u8) void {
        if (buf.len == 0) {
            allocator.free(buf);
            return;
        }
        if (self.buffers.items.len >= payload_pool_max_buffers or self.bytes + buf.len > payload_pool_max_bytes) {
            allocator.free(buf);
            return;
        }
        self.buffers.append(allocator, buf) catch {
            allocator.free(buf);
            return;
        };
        self.bytes += buf.len;
    }

    fn deinit(self: *PayloadBufferPool, allocator: std.mem.Allocator) void {
        for (self.buffers.items) |buf| allocator.free(buf);
        self.buffers.deinit(allocator);
        self.* = .{};
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    logger: Logger,
    tty: ?DirectTty = null,
    engine: ?ts_scene.SceneEngine = null,
    backend: ?ts_kitty.Backend = null,
    frame_builder: FrameBuilder,
    bg_only: bool = false,
    stats: bool = false,
    debug_protocol_replies: bool = false,
    image_gc: bool = false,
    input_enabled: bool = false,
    input_claimed: bool = false,
    dump_composites: bool = false,
    debug_composite: bool = false,
    intercept_mode: InterceptMode = .sync_compose,
    window_policy: window_policy_mod.WindowPresentationPolicy = .mirror,
    real_window_visibility: window_policy_mod.RealWindowVisibility = .show,
    terminal_identity: []const u8 = "unknown",
    output_profile_name: []const u8 = "unknown",
    logged_queued_replay_stub: bool = false,
    active: bool = false,
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    queue: std.ArrayList(Command),
    payload_pool: PayloadBufferPool = .{},
    inspect_resources: std.ArrayList(InspectResource),
    inspect_resource_records: std.ArrayList(ResourceRecord),
    queue_head: usize = 0,
    pending_presents: usize = 0,
    worker_thread: ?std.Thread = null,
    inspector: ?Inspector = null,
    whiskers_client: ?WhiskersClient = null,
    shutdown_worker: bool = false,
    queued_lock_captures: std.AutoHashMap(usize, QueuedLockCapture),
    input_parser: ?input_mod.TerminalInputParser = null,
    relative_mouse_baseline: input_mod.RelativeMouseBaseline = .{},
    mouse_ownership: input_mod.MouseOwnership = .{},
    input_window_w: i32 = 640,
    input_window_h: i32 = 480,
    keyboard_state: [sdl.SDL_NUM_SCANCODES]u8 = [_]u8{0} ** sdl.SDL_NUM_SCANCODES,
    presentation_layout: presentation_layout_mod.PresentationLayout = .{},
    present_interval_ns: i128 = 0,
    adaptive_present_target_ns: i128 = std.time.ns_per_s / 60,
    next_present_ns: i128 = 0,
    skipped_presents: u64 = 0,
    producer_stats: ProducerStats,
    gl_capture_buffers: gl_capture_mod.Buffers = .{},
    gl_capture_pbo: gl_capture_mod.PboState = .{},
    gl_capture_downscale: gl_capture_mod.DownscaleState = .{},
    gl_capture_mode: gl_capture_mod.CaptureMode = .disabled,
    forced_output_profile: ?config_mod.OutputProfile = null,
    file_transport_enabled: bool = true,
    file_transport_max_bytes: u64 = config_mod.default_file_transport_max_bytes,

    fn init() Runtime {
        const allocator = std.heap.c_allocator;
        var logger = Logger.init(allocator);
        const config = config_mod.loadRuntimeConfig(allocator, &logger);
        const bg_only = std.c.getenv("KATZENSTEG_BG_ONLY") != null;
        const stats = config.stats;
        const debug_protocol_replies = config.debug_protocol_replies;
        const image_gc = config.image_gc;
        const input_enabled = config.input_enabled;
        const input_claimed = input_enabled and config.input_claimed;
        const dump_composites = config.dump_composites;
        const debug_composite = config.debug_composite;
        var runtime = Runtime{
            .allocator = allocator,
            .logger = logger,
            .frame_builder = FrameBuilder.init(allocator, stats, config.composite_mode, dump_composites, debug_composite),
            .bg_only = bg_only,
            .stats = stats,
            .debug_protocol_replies = debug_protocol_replies,
            .image_gc = image_gc,
            .input_enabled = input_enabled,
            .input_claimed = input_claimed,
            .dump_composites = dump_composites,
            .debug_composite = debug_composite,
            .intercept_mode = config.intercept_mode,
            .window_policy = config.window_policy,
            .real_window_visibility = config.real_window_visibility,
            .queue = std.ArrayList(Command).empty,
            .inspect_resources = std.ArrayList(InspectResource).empty,
            .inspect_resource_records = std.ArrayList(ResourceRecord).empty,
            .queue_head = 0,
            .pending_presents = 0,
            .queued_lock_captures = std.AutoHashMap(usize, QueuedLockCapture).init(allocator),
            .present_interval_ns = if (config.present_fps > 0) @divTrunc(std.time.ns_per_s, config.present_fps) else 0,
            .producer_stats = .{ .enabled = stats, .last_report_ns = std.time.nanoTimestamp() },
            .gl_capture_mode = mapGlCaptureMode(config.gl_capture),
            .forced_output_profile = config.output_profile,
            .file_transport_enabled = config.file_transport,
            .file_transport_max_bytes = config.file_transport_max_bytes,
        };
        if (std.c.getenv("KATZENSTEG_INSPECT_SOCKET")) |path_z| {
            runtime.inspector = Inspector.init(allocator, &runtime.logger, std.mem.span(path_z)) catch |err| blk: {
                runtime.logger.writeFmt("katzensteg: inspector init failed: {any}", .{err});
                break :blk null;
            };
        }
        if (std.c.getenv("KATZENSTEG_WHISKERS_SOCKET")) |path_z| {
            var free_producer_hello = true;
            const producer_hello = runtime.buildWhiskersHello() catch |err| blk: {
                runtime.logger.writeFmt("katzensteg: whiskers hello build failed: {any}", .{err});
                free_producer_hello = false;
                break :blk whiskers_client_mod.ProducerHello{
                    .producer_kind = "katzensteg",
                    .producer_name_hint = null,
                    .program = null,
                    .cmdline = &.{},
                    .cwd = null,
                    .terminal = runtime.terminal_identity,
                };
            };
            runtime.logger.writeFmt("katzensteg: whiskers socket configured: {s}", .{std.mem.span(path_z)});
            defer if (free_producer_hello) runtime.freeWhiskersHello(producer_hello);
            runtime.whiskers_client = WhiskersClient.init(allocator, &runtime.logger, std.mem.span(path_z), producer_hello) catch |err| blk: {
                runtime.logger.writeFmt("katzensteg: whiskers client init failed: {any}", .{err});
                break :blk null;
            };
            if (runtime.whiskers_client) |*client| {
                if (std.c.getenv("KATZENSTEG_WHISKERS_FORCE_CAPTURE") != null) {
                    client.capture_enabled.store(true, .release);
                    runtime.logger.write("katzensteg: whiskers force capture enabled");
                } else {
                    client.start();
                }
                runtime.logger.writeFmt("katzensteg: whiskers push registered producer={s} display={s}", .{ client.producer_id, client.display_name });
            }
        }
        runtime.tty = DirectTty.init() catch |err| {
            runtime.logger.writeFmt("katzensteg: direct tty init failed: {any}", .{err});
            return runtime;
        };
        runtime.engine = ts_scene.SceneEngine.init(allocator);

        const backend_options = selectBackendOptions(allocator, &runtime) catch |err| blk: {
            runtime.logger.writeFmt("katzensteg: upload transport selection failed; falling back to direct APC: {any}", .{err});
            break :blk ts_kitty.Options{};
        };
        var actual_upload_medium = backend_options.upload_medium;
        runtime.backend = ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, backend_options) catch |err| blk: {
            runtime.logger.writeFmt("katzensteg: backend init failed: {any}", .{err});
            runtime.logger.write("katzensteg: retrying backend init with direct APC fallback");
            actual_upload_medium = .direct;
            break :blk ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, .{
                .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail,
            }) catch |fallback_err| {
                runtime.logger.writeFmt("katzensteg: direct APC fallback backend init failed: {any}", .{fallback_err});
                return runtime;
            };
        };
        runtime.active = true;
        runtime.output_profile_name = switch (actual_upload_medium) {
            .direct => "direct_apc",
            .file_whole => "file_whole",
            .file_offset => "file_offset_ring",
        };
        runtime.logger.write("katzensteg: runtime initialized in direct tty mode");
        switch (actual_upload_medium) {
            .direct => runtime.logger.write("katzensteg: upload transport profile = direct_apc"),
            .file_whole => {
                runtime.logger.writeFmt("katzensteg: upload transport profile = file_whole path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
            },
            .file_offset => {
                runtime.logger.writeFmt("katzensteg: upload transport profile = file_offset_ring path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
            },
        }
        if (backend_options.upload_file_path) |path| allocator.free(path);
        if (runtime.bg_only) runtime.logger.write("katzensteg: background-only debug mode enabled");
        if (runtime.stats) runtime.logger.write("katzensteg: periodic stats enabled");
        if (runtime.debug_protocol_replies) runtime.logger.write("katzensteg: kitty protocol reply logging enabled (q=0)");
        runtime.logger.writeFmt("katzensteg: composite mode = {s}", .{@tagName(config.composite_mode)});
        runtime.logger.writeFmt("katzensteg: intercept mode = {s}", .{@tagName(config.intercept_mode)});
        if (runtime.inspector) |*inspector| inspector.configureSession(.{
            .terminal_identity = runtime.terminal_identity,
            .composite_mode = @tagName(config.composite_mode),
            .intercept_mode = @tagName(config.intercept_mode),
            .output_profile = runtime.output_profile_name,
            .present_fps = config.present_fps,
        });
        if (config.present_fps > 0) runtime.logger.writeFmt("katzensteg: present fps cap = {d}", .{config.present_fps});
        if (runtime.image_gc) runtime.logger.write("katzensteg: old image GC enabled");
        if (runtime.input_enabled) {
            runtime.input_parser = input_mod.TerminalInputParser.init(allocator);
            runtime.updateInputTarget();
            runtime.tty.?.enableInputCapture() catch |err| {
                runtime.logger.writeFmt("katzensteg: terminal input capture enable failed: {any}", .{err});
                if (runtime.input_parser) |*parser| parser.deinit();
                runtime.input_parser = null;
                runtime.input_enabled = false;
            };
            if (runtime.input_enabled) runtime.logger.write("katzensteg: terminal input capture enabled");
        }
        if (runtime.dump_composites) runtime.logger.write("katzensteg: composite framebuffer dump enabled");
        if (runtime.debug_composite) runtime.logger.write("katzensteg: composite debug logging enabled");
        return runtime;
    }

    fn buildWhiskersHello(self: *Runtime) !whiskers_client_mod.ProducerHello {
        const argv = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, argv);
        const cmdline = try self.allocator.alloc([]const u8, argv.len);
        for (argv, 0..) |arg, i| cmdline[i] = try self.allocator.dupe(u8, arg);
        errdefer {
            for (cmdline) |arg| self.allocator.free(arg);
            self.allocator.free(cmdline);
        }
        const program_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "producer";
        const program = if (argv.len > 0) try self.allocator.dupe(u8, program_name) else null;
        errdefer if (program) |p| self.allocator.free(p);
        const producer_name_hint = try std.fmt.allocPrint(self.allocator, "katzensteg: {s}", .{program_name});
        errdefer self.allocator.free(producer_name_hint);
        const cwd = std.process.getCwdAlloc(self.allocator) catch null;
        return .{
            .producer_kind = "katzensteg",
            .producer_name_hint = producer_name_hint,
            .program = program,
            .cmdline = cmdline,
            .cwd = cwd,
            .terminal = self.terminal_identity,
        };
    }

    fn freeWhiskersHello(self: *Runtime, hello: whiskers_client_mod.ProducerHello) void {
        if (hello.producer_name_hint) |s| self.allocator.free(s);
        if (hello.program) |s| self.allocator.free(s);
        if (hello.cwd) |s| self.allocator.free(s);
        for (hello.cmdline) |arg| self.allocator.free(arg);
        self.allocator.free(hello.cmdline);
    }

    fn deinit(self: *Runtime) void {
        self.queue_mutex.lock();
        self.shutdown_worker = true;
        self.queue_cond.signal();
        self.queue_mutex.unlock();
        if (self.worker_thread) |thread| thread.join();
        if (self.whiskers_client) |*client| client.deinit();
        if (self.inspector) |*inspector| inspector.deinit();
        for (self.queue.items[self.queue_head..]) |*cmd| self.recycleCommandLocked(cmd);
        self.queue.deinit(self.allocator);
        self.payload_pool.deinit(self.allocator);
        self.gl_capture_buffers.deinit(self.allocator);
        self.inspect_resources.deinit(self.allocator);
        self.inspect_resource_records.deinit(self.allocator);
        self.queued_lock_captures.deinit();
        if (self.tty) |*tty| {
            tty.disableInputCapture() catch {};
            self.pollTerminalInput();
        }
        if (self.input_parser) |*parser| parser.deinit();
        self.frame_builder.deinit();
        if (self.backend) |*backend| backend.deinit();
        if (self.engine) |*engine| engine.deinit();
        if (self.tty) |*tty| tty.deinit();
        self.logger.deinit();
    }

    pub fn noteProducerTime(self: *Runtime, kind: ProducerStatKind, duration_ns: u64) void {
        if (!self.producer_stats.enabled) return;
        const bucket = switch (kind) {
            .generic => &self.producer_stats.generic,
            .update_texture => &self.producer_stats.update_texture,
            .unlock_texture => &self.producer_stats.unlock_texture,
            .create_texture_from_surface => &self.producer_stats.create_texture_from_surface,
            .render_present => &self.producer_stats.render_present,
        };
        bucket.calls += 1;
        bucket.total_ns += duration_ns;
        bucket.max_ns = @max(bucket.max_ns, duration_ns);
        self.maybeReportProducerStats();
    }

    pub fn noteInputWindowSize(self: *Runtime, w: i32, h: i32) void {
        self.input_window_w = @max(1, w);
        self.input_window_h = @max(1, h);
        self.updateInputTarget();
    }

    pub fn notePresentationLayout(self: *Runtime, layout: presentation_layout_mod.PresentationLayout) void {
        self.presentation_layout = layout;
        self.updateInputTarget();
    }

    pub fn pollTerminalInput(self: *Runtime) void {
        if (!self.input_enabled) return;
        const tty = &(self.tty orelse return);
        var parser = &(self.input_parser orelse return);
        var buf: [256]u8 = undefined;
        while (true) {
            const n = std.posix.read(tty.file.handle, &buf) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => {
                        self.logger.writeFmt("katzensteg: terminal input read failed: {any}", .{err});
                        return;
                    },
                }
            };
            if (n == 0) {
                parser.flushStandaloneEscape() catch |err| {
                    self.logger.writeFmt("katzensteg: terminal input escape flush failed: {any}", .{err});
                };
                return;
            }
            parser.feed(buf[0..n]) catch |err| {
                self.logger.writeFmt("katzensteg: terminal input parse failed: {any}", .{err});
                return;
            };
            if (parser.takeMouseActivity()) self.mouse_ownership.claimTerminal();
            if (n < buf.len) return;
        }
    }

    pub fn popSdlInputEvent(self: *Runtime, event: ?*sdl.SDL_Event) bool {
        if (!self.input_enabled) return false;
        var parser = &(self.input_parser orelse return false);
        const input_event = parser.pop() orelse return false;
        if (inputEventIsMouse(input_event)) self.mouse_ownership.claimTerminal();
        const out = event orelse return true;
        fillSdlEvent(out, input_event);
        return true;
    }

    pub fn popSdlInputEventInRange(self: *Runtime, event: ?*sdl.SDL_Event, min_type: u32, max_type: u32) bool {
        if (!self.input_enabled) return false;
        var parser = &(self.input_parser orelse return false);
        const input_event = parser.popSdlRange(min_type, max_type) orelse return false;
        if (inputEventIsMouse(input_event)) self.mouse_ownership.claimTerminal();
        const out = event orelse return true;
        fillSdlEvent(out, input_event);
        return true;
    }

    pub fn terminalMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        if (!self.mouse_ownership.terminalOwns()) return null;
        const parser = &(self.input_parser orelse return null);
        return parser.mouseState();
    }

    pub fn terminalRelativeMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        if (!self.mouse_ownership.terminalOwns()) return null;
        const parser = &(self.input_parser orelse return null);
        return self.relative_mouse_baseline.snap(parser.mouseState());
    }

    pub fn noteRealSdlEvent(self: *Runtime, event: *const sdl.SDL_Event) void {
        if (eventIsMouse(event.*)) self.mouse_ownership.claimRealWindow();
    }

    pub fn claimRealWindowMouse(self: *Runtime) void {
        self.mouse_ownership.claimRealWindow();
    }

    pub fn mergedKeyboardState(self: *Runtime, real_state: ?[*]const u8, real_count: c_int, numkeys: ?*c_int) ?[*]const u8 {
        if (!self.input_enabled) return real_state;
        var parser = &(self.input_parser orelse return real_state);
        @memset(&self.keyboard_state, 0);
        if (real_state) |keys| {
            const n: usize = @min(self.keyboard_state.len, @as(usize, @intCast(@max(0, real_count))));
            @memcpy(self.keyboard_state[0..n], keys[0..n]);
        }
        var terminal_state = [_]u8{0} ** sdl.SDL_NUM_SCANCODES;
        parser.copyKeyboardState(&terminal_state, std.time.nanoTimestamp());
        for (&self.keyboard_state, terminal_state) |*dst, src| dst.* |= src;
        if (numkeys) |out| out.* = @intCast(self.keyboard_state.len);
        return &self.keyboard_state;
    }

    pub fn claimedWindowFlags(self: *const Runtime, flags: u32) u32 {
        return applyClaimedInputWindowFlags(self.input_claimed, flags);
    }

    pub fn shouldSuppressSdlEvent(self: *const Runtime, event: *const sdl.SDL_Event) bool {
        if (!self.input_claimed) return false;
        if (event.type != sdl.SDL_WINDOWEVENT) return false;
        return shouldSuppressClaimedWindowEvent(true, event.type, event.window.event);
    }

    pub fn terminalRenderingEnabled(self: *const Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool {
        _ = window;
        _ = renderer;
        return routeTerminalRendering(self.window_policy);
    }

    pub fn realRenderEnabled(self: *const Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool {
        _ = window;
        _ = renderer;
        return routeRealRendering(self.window_policy);
    }

    pub fn realWindowEnabled(self: *const Runtime, window: ?*sdl.SDL_Window) bool {
        _ = window;
        return self.window_policy.realWindowEnabled();
    }

    pub fn realWindowCreateAction(self: *const Runtime, window: ?*sdl.SDL_Window) window_policy_mod.RealWindowAction {
        _ = window;
        return self.real_window_visibility.createAction();
    }

    pub fn realWindowShowAction(self: *const Runtime, window: ?*sdl.SDL_Window) window_policy_mod.RealWindowAction {
        _ = window;
        return self.real_window_visibility.showAction();
    }

    pub fn realWindowRestoreAction(self: *const Runtime, window: ?*sdl.SDL_Window) window_policy_mod.RealWindowAction {
        _ = window;
        return self.real_window_visibility.restoreAction();
    }

    pub fn shouldCaptureExternalFrame(self: *Runtime, window: ?*sdl.SDL_Window) bool {
        if (!(self.active and self.tty != null and self.engine != null and self.backend != null)) return false;
        if (!self.terminalRenderingEnabled(window, null)) {
            self.notePresentationLayout(.{});
            return false;
        }
        return self.shouldPresent();
    }

    pub fn presentExternalFramebuffer(self: *Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
        if (!(self.active and self.tty != null and self.engine != null and self.backend != null)) return;
        const start_ns = std.time.nanoTimestamp();
        self.frame_builder.presentExternalFramebuffer(&self.logger, &self.tty.?, &self.engine.?, &self.backend.?, width, height, format, pixels, self.debug_protocol_replies, self.image_gc);
        self.notePresentationLayout(self.frame_builder.presentationLayoutForExternalFramebuffer(&self.tty.?));
        const duration = std.time.nanoTimestamp() - start_ns;
        self.notePresentDuration(duration);
    }

    pub fn externalFramebufferUploadSize(self: *Runtime, source_w: i32, source_h: i32) PixelSize {
        const tty = &(self.tty orelse return .{ .w = source_w, .h = source_h });
        return self.frame_builder.externalFramebufferUploadSize(tty, source_w, source_h);
    }

    pub fn ensureGlCaptureBuffers(self: *Runtime, len: usize) ?*gl_capture_mod.Buffers {
        self.gl_capture_buffers.ensure(self.allocator, len) catch |err| {
            self.logger.writeFmt("katzensteg: GL capture buffer allocation failed: {any}", .{err});
            return null;
        };
        return &self.gl_capture_buffers;
    }

    pub fn glCaptureMode(self: *const Runtime) gl_capture_mod.CaptureMode {
        return self.gl_capture_mode;
    }

    fn updateInputTarget(self: *Runtime) void {
        var parser = &(self.input_parser orelse return);
        const tty = self.tty orelse return;
        parser.setTarget(buildInputTarget(&tty, self.input_window_w, self.input_window_h, self.presentation_layout));
    }

    fn maybeReportProducerStats(self: *Runtime) void {
        if (!self.producer_stats.enabled) return;
        const now = std.time.nanoTimestamp();
        if (now - self.producer_stats.last_report_ns < std.time.ns_per_s) return;
        const g = self.producer_stats.generic;
        const u = self.producer_stats.update_texture;
        const unl = self.producer_stats.unlock_texture;
        const c = self.producer_stats.create_texture_from_surface;
        const p = self.producer_stats.render_present;
        self.logger.writeFmt(
            "katzensteg: producer generic={d}({d:.1}us avg/{d:.1}us max) update={d}({d:.1}us/{d:.1}us) unlock={d}({d:.1}us/{d:.1}us) ctfs={d}({d:.1}us/{d:.1}us) present={d}({d:.1}us/{d:.1}us)",
            .{
                g.calls,   avgMicros(g),   maxMicros(g),
                u.calls,   avgMicros(u),   maxMicros(u),
                unl.calls, avgMicros(unl), maxMicros(unl),
                c.calls,   avgMicros(c),   maxMicros(c),
                p.calls,   avgMicros(p),   maxMicros(p),
            },
        );
        self.producer_stats.generic = .{};
        self.producer_stats.update_texture = .{};
        self.producer_stats.unlock_texture = .{};
        self.producer_stats.create_texture_from_surface = .{};
        self.producer_stats.render_present = .{};
        self.producer_stats.last_report_ns = now;
    }

    pub fn shouldPresent(self: *Runtime) bool {
        const now = std.time.nanoTimestamp();
        if (now < self.next_present_ns) {
            self.skipped_presents += 1;
            if ((self.skipped_presents % 120) == 1) {
                self.logger.writeFmt("katzensteg: skipped presents={d}", .{self.skipped_presents});
            }
            return false;
        }
        if (self.present_interval_ns > 0) self.next_present_ns = now + self.present_interval_ns;
        return true;
    }

    pub fn notePresentDuration(self: *Runtime, duration_ns: i128) void {
        if (self.present_interval_ns > 0) return;
        if (duration_ns <= self.adaptive_present_target_ns) return;
        const extra = duration_ns - self.adaptive_present_target_ns;
        self.next_present_ns = std.time.nanoTimestamp() + extra;
    }

    pub fn rememberQueuedLock(self: *Runtime, texture: ?*@import("katzensteg_sdl").SDL_Texture, rect: ?*const @import("katzensteg_sdl").SDL_Rect, pixels: ?*anyopaque, pitch: i32) void {
        const key = if (texture) |t| @intFromPtr(t) else return;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.queued_lock_captures.put(key, .{ .rect = if (rect) |r| r.* else null, .pixels = pixels, .pitch = pitch }) catch |err| {
            self.logger.writeFmt("katzensteg: failed to remember queued lock capture: {any}", .{err});
        };
    }

    pub fn takeQueuedLock(self: *Runtime, texture: ?*@import("katzensteg_sdl").SDL_Texture) ?QueuedLockCapture {
        const key = if (texture) |t| @intFromPtr(t) else return null;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queued_lock_captures.fetchRemove(key)) |entry| return entry.value;
        return null;
    }

    pub fn currentQueueDepth(self: *Runtime) usize {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.queue.items.len - self.queue_head;
    }

    pub fn enqueueCommand(self: *Runtime, cmd: Command) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        var owned = cmd;
        if (isPresentCommand(owned) and self.pending_presents > 0) {
            self.dropQueuedFrameLocalsBeforeLatestPresent();
        }
        self.queue.append(self.allocator, owned) catch |err| {
            self.logger.writeFmt("katzensteg: failed to enqueue command: {any}", .{err});
            self.recycleCommandLocked(&owned);
            return;
        };
        if (isPresentCommand(owned)) self.pending_presents += 1;
        self.maybeCompactQueue();
        self.queue_cond.signal();
    }

    pub fn acquirePayloadBuffer(self: *Runtime, len: usize) ![]u8 {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.payload_pool.acquire(self.allocator, len);
    }

    pub fn recycleCommand(self: *Runtime, cmd: *Command) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.recycleCommandLocked(cmd);
    }

    fn recycleCommandLocked(self: *Runtime, cmd: *Command) void {
        switch (cmd.*) {
            .update_texture => |*c| {
                if (c.pixels) |buf| self.payload_pool.release(self.allocator, buf);
            },
            .update_yuv_texture => |*c| {
                if (c.yplane) |buf| self.payload_pool.release(self.allocator, buf);
                if (c.uplane) |buf| self.payload_pool.release(self.allocator, buf);
                if (c.vplane) |buf| self.payload_pool.release(self.allocator, buf);
            },
            .update_nv_texture => |*c| {
                if (c.yplane) |buf| self.payload_pool.release(self.allocator, buf);
                if (c.uvplane) |buf| self.payload_pool.release(self.allocator, buf);
            },
            .external_framebuffer_present => |*c| {
                if (c.pixels) |buf| self.payload_pool.release(self.allocator, buf);
            },
            else => {},
        }
        cmd.* = undefined;
    }

    fn maybeCompactQueue(self: *Runtime) void {
        if (self.queue_head == 0) return;
        if (self.queue_head < queue_compact_threshold and self.queue_head * 2 < self.queue.items.len) return;
        std.mem.copyForwards(Command, self.queue.items[0 .. self.queue.items.len - self.queue_head], self.queue.items[self.queue_head..]);
        self.queue.items.len -= self.queue_head;
        self.queue_head = 0;
    }

    fn dropQueuedFrameLocalsBeforeLatestPresent(self: *Runtime) void {
        var last_present_idx: ?usize = null;
        for (self.queue.items[self.queue_head..], self.queue_head..) |cmd, idx| {
            if (isPresentCommand(cmd)) last_present_idx = idx;
        }
        const cutoff = last_present_idx orelse return;
        var write_idx = self.queue_head;
        var dropped_any = false;
        var idx = self.queue_head;
        while (idx <= cutoff) : (idx += 1) {
            const cmd = self.queue.items[idx];
            if (isFrameLocalCommand(cmd)) {
                var doomed = cmd;
                self.recycleCommandLocked(&doomed);
                dropped_any = true;
                continue;
            }
            if (write_idx != idx) self.queue.items[write_idx] = cmd;
            write_idx += 1;
        }
        idx = cutoff + 1;
        while (idx < self.queue.items.len) : (idx += 1) {
            if (write_idx != idx) self.queue.items[write_idx] = self.queue.items[idx];
            write_idx += 1;
        }
        self.queue.items.len = write_idx;
        self.pending_presents = 0;
        for (self.queue.items[self.queue_head..]) |queued| {
            if (isPresentCommand(queued)) self.pending_presents += 1;
        }
        if (dropped_any) self.logger.write("katzensteg: dropped stale queued frame-local commands before latest present");
    }
};

fn isPresentCommand(cmd: Command) bool {
    return switch (cmd) {
        .render_present,
        .external_framebuffer_present,
        => true,
        else => false,
    };
}

fn isFrameLocalCommand(cmd: Command) bool {
    return switch (cmd) {
        .set_render_draw_color,
        .render_clear,
        .render_copy,
        .render_copy_ex,
        .render_fill_rect,
        .render_draw_point,
        .render_draw_line,
        .render_set_viewport,
        .render_set_clip_rect,
        .render_present,
        .external_framebuffer_present,
        => true,
        else => false,
    };
}

fn inputEventIsMouse(event: input_mod.InputEvent) bool {
    return switch (event) {
        .mouse_motion,
        .mouse_button,
        .mouse_wheel,
        => true,
        else => false,
    };
}

fn eventIsMouse(event: sdl.SDL_Event) bool {
    return switch (event.type) {
        sdl.SDL_MOUSEMOTION,
        sdl.SDL_MOUSEBUTTONDOWN,
        sdl.SDL_MOUSEBUTTONUP,
        sdl.SDL_MOUSEWHEEL,
        => true,
        else => false,
    };
}

test "external framebuffer present is a frame-local present command" {
    const cmd = Command{ .external_framebuffer_present = .{ .width = 2, .height = 1, .format = .rgba8, .pixels = null } };
    try std.testing.expect(isFrameLocalCommand(cmd));
    try std.testing.expect(isPresentCommand(cmd));
}

test "SDL mouse events are recognized for ownership handoff" {
    var event: sdl.SDL_Event = undefined;
    event.type = sdl.SDL_MOUSEMOTION;
    try std.testing.expect(eventIsMouse(event));
    event.type = sdl.SDL_KEYDOWN;
    try std.testing.expect(!eventIsMouse(event));
}

fn fillSdlEvent(event: *sdl.SDL_Event, input_event: input_mod.InputEvent) void {
    @memset(&event.padding, 0);
    const now = sdl.SDL_GetTicks();
    switch (input_event) {
        .key_down => |key| event.key = .{
            .type = sdl.SDL_KEYDOWN,
            .timestamp = now,
            .windowID = 0,
            .state = sdl.SDL_PRESSED,
            .repeat = 0,
            .keysym = .{ .scancode = key.scancode, .sym = key.keycode, .mod = key.mods, .unused = 0 },
        },
        .key_up => |key| event.key = .{
            .type = sdl.SDL_KEYUP,
            .timestamp = now,
            .windowID = 0,
            .state = sdl.SDL_RELEASED,
            .repeat = 0,
            .keysym = .{ .scancode = key.scancode, .sym = key.keycode, .mod = key.mods, .unused = 0 },
        },
        .text => |text| {
            event.text = .{ .type = sdl.SDL_TEXTINPUT, .timestamp = now, .windowID = 0, .text = text.buf };
        },
        .mouse_motion => |motion| event.motion = .{
            .type = sdl.SDL_MOUSEMOTION,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .state = motion.buttons,
            .x = motion.x,
            .y = motion.y,
            .xrel = motion.xrel,
            .yrel = motion.yrel,
        },
        .mouse_button => |button| event.button = .{
            .type = if (button.pressed) sdl.SDL_MOUSEBUTTONDOWN else sdl.SDL_MOUSEBUTTONUP,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .button = button.button,
            .state = if (button.pressed) sdl.SDL_PRESSED else sdl.SDL_RELEASED,
            .clicks = button.clicks,
            .x = button.x,
            .y = button.y,
        },
        .mouse_wheel => |wheel| event.wheel = .{
            .type = sdl.SDL_MOUSEWHEEL,
            .timestamp = now,
            .windowID = 0,
            .which = 0,
            .x = wheel.x,
            .y = wheel.y,
            .direction = sdl.SDL_MOUSEWHEEL_NORMAL,
            .preciseX = @floatFromInt(wheel.x),
            .preciseY = @floatFromInt(wheel.y),
            .mouseX = wheel.mouse_x,
            .mouseY = wheel.mouse_y,
        },
    }
}

fn buildInputTarget(tty: *const DirectTty, w: i32, h: i32, layout: presentation_layout_mod.PresentationLayout) input_mod.Target {
    return .{
        .cols = tty.cols,
        .rows = tty.rows,
        .w = w,
        .h = h,
        .layout = layout,
    };
}

fn workerMain(runtime: *Runtime) void {
    runtime.logger.write("katzensteg: queued replay worker started");
    while (true) {
        runtime.queue_mutex.lock();
        while (!runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_cond.wait(&runtime.queue_mutex);
        }
        if (runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_mutex.unlock();
            runtime.logger.write("katzensteg: queued replay worker exiting");
            return;
        }
        var cmd = runtime.queue.items[runtime.queue_head];
        runtime.queue_head += 1;
        if (isPresentCommand(cmd) and runtime.pending_presents > 0) runtime.pending_presents -= 1;
        runtime.maybeCompactQueue();
        runtime.queue_mutex.unlock();
        intercept_sink.handleCommand(runtime, cmd);
        runtime.recycleCommand(&cmd);
    }
}

pub fn get() *Runtime {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime == null) {
        global_runtime = Runtime.init();
        if (global_runtime) |*runtime| {
            if (runtime.inspector) |*inspector| {
                inspector.logger = &runtime.logger;
                inspector.start();
            }
            if (runtime.intercept_mode == .queued_replay) {
                if (std.Thread.spawn(.{}, workerMain, .{runtime})) |thread| {
                    runtime.worker_thread = thread;
                } else |err| {
                    runtime.logger.writeFmt("katzensteg: failed to start queued replay worker: {any}", .{err});
                    runtime.active = false;
                }
            }
        }
    }
    return &global_runtime.?;
}

fn avgMicros(bucket: ProducerBucket) f64 {
    if (bucket.calls == 0) return 0;
    return @as(f64, @floatFromInt(bucket.total_ns)) / @as(f64, @floatFromInt(bucket.calls)) / 1000.0;
}

fn maxMicros(bucket: ProducerBucket) f64 {
    return @as(f64, @floatFromInt(bucket.max_ns)) / 1000.0;
}

fn routeTerminalRendering(policy: window_policy_mod.WindowPresentationPolicy) bool {
    return policy.terminalEnabled();
}

fn routeRealRendering(policy: window_policy_mod.WindowPresentationPolicy) bool {
    return policy.realRenderEnabled();
}

pub fn shutdownGlobal() callconv(.c) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime) |*runtime| {
        runtime.deinit();
        global_runtime = null;
    }
}

fn selectBackendOptions(allocator: std.mem.Allocator, runtime: *Runtime) !ts_kitty.Options {
    const tty = runtime.tty.?.file;
    const forced_profile = mapOutputProfile(runtime.forced_output_profile);
    if (!runtime.file_transport_enabled) return .{ .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail };

    const high_water = runtime.file_transport_max_bytes;
    const upload_path = try makeUploadPath(allocator);
    errdefer allocator.free(upload_path);

    const probe_file = try std.fs.createFileAbsolute(upload_path, .{ .read = true, .truncate = true });
    defer probe_file.close();
    const probe_pixel = [_]u8{ 0, 0, 0, 255 };
    try probe_file.writeAll(&probe_pixel);

    const caps = try ts_kitty.capabilities.probe(allocator, tty, upload_path);
    runtime.terminal_identity = @tagName(caps.terminal);
    runtime.logger.writeFmt(
        "katzensteg: terminal={s} graphics={s} file_whole={s}/{s} file_offset={s}/{s}",
        .{
            @tagName(caps.terminal),
            @tagName(caps.graphics_basic.probe),
            @tagName(caps.file_regular_whole_rgba.probe),
            @tagName(caps.file_regular_whole_rgba.compat),
            @tagName(caps.file_regular_offset_rgba.probe),
            @tagName(caps.file_regular_offset_rgba.compat),
        },
    );

    const chosen = forced_profile orelse ts_kitty.profile.choose(caps);
    if (forced_profile) |profile| {
        runtime.logger.writeFmt("katzensteg: forced output profile = {s}", .{@tagName(profile)});
    }
    return switch (chosen) {
        .direct_apc => blk: {
            allocator.free(upload_path);
            runtime.logger.write("katzensteg: file upload transport unavailable or avoided; falling back to inline APC");
            break :blk .{ .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail };
        },
        .file_whole => .{
            .upload_medium = .file_whole,
            .upload_file_path = upload_path,
            .upload_file_high_water = high_water,
            .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail,
        },
        .file_offset_ring => .{
            .upload_medium = .file_offset,
            .upload_file_path = upload_path,
            .upload_file_high_water = high_water,
            .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail,
        },
    };
}

fn makeUploadPath(allocator: std.mem.Allocator) ![]u8 {
    const tmpdir = if (std.c.getenv("TMPDIR")) |value| std.mem.span(value) else "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/tty-graphics-protocol-katzensteg-{d}.rgba", .{ tmpdir, std.c.getpid() });
}

fn mapOutputProfile(profile: ?config_mod.OutputProfile) ?ts_kitty.OutputProfile {
    return switch (profile orelse return null) {
        .direct_apc => .direct_apc,
        .file_whole => .file_whole,
        .file_offset_ring => .file_offset_ring,
    };
}

fn mapGlCaptureMode(mode: config_mod.GlCaptureMode) gl_capture_mod.CaptureMode {
    return switch (mode) {
        .disabled => .disabled,
        .sync => .sync,
        .pbo => .pbo,
    };
}

fn applyClaimedInputWindowFlags(claimed: bool, flags: u32) u32 {
    if (!claimed) return flags;
    return flags | sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS;
}

fn shouldSuppressClaimedWindowEvent(claimed: bool, event_type: u32, window_event: u8) bool {
    if (!claimed or event_type != sdl.SDL_WINDOWEVENT) return false;
    return switch (window_event) {
        sdl.SDL_WINDOWEVENT_FOCUS_LOST,
        sdl.SDL_WINDOWEVENT_LEAVE,
        => true,
        else => false,
    };
}

test "payload buffer pool reuses exact-sized buffers" {
    var pool = PayloadBufferPool{};
    defer pool.deinit(std.testing.allocator);

    const first = try pool.acquire(std.testing.allocator, 32);
    const first_ptr = first.ptr;
    pool.release(std.testing.allocator, first);

    const second = try pool.acquire(std.testing.allocator, 32);
    try std.testing.expectEqual(first_ptr, second.ptr);
    pool.release(std.testing.allocator, second);

    const third = try pool.acquire(std.testing.allocator, 16);
    try std.testing.expect(third.ptr != first_ptr);
    pool.release(std.testing.allocator, third);
}

test "runtime maps configured GL capture mode to preload capture mode" {
    try std.testing.expectEqual(gl_capture_mod.CaptureMode.disabled, mapGlCaptureMode(.disabled));
    try std.testing.expectEqual(gl_capture_mod.CaptureMode.sync, mapGlCaptureMode(.sync));
    try std.testing.expectEqual(gl_capture_mod.CaptureMode.pbo, mapGlCaptureMode(.pbo));
}

test "window policy controls terminal and real render routes" {
    try std.testing.expect(routeTerminalRendering(.mirror));
    try std.testing.expect(routeRealRendering(.mirror));
    try std.testing.expect(routeTerminalRendering(.terminal_only));
    try std.testing.expect(!routeRealRendering(.terminal_only));
    try std.testing.expect(!routeTerminalRendering(.real_only));
    try std.testing.expect(routeRealRendering(.real_only));
}

test "runtime input target includes latest presentation layout" {
    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    var layout = presentation_layout_mod.PresentationLayout{};
    layout.setSingleSdlRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    });

    const target = buildInputTarget(&tty, 320, 240, layout);

    try std.testing.expectEqual(@as(i32, 100), target.cols);
    try std.testing.expectEqual(@as(i32, 40), target.rows);
    try std.testing.expectEqual(@as(i32, 320), target.w);
    try std.testing.expectEqual(@as(i32, 240), target.h);
    try std.testing.expectEqual(presentation_layout_mod.Point{ .x = 0, .y = 0 }, target.layout.mapCellToSdl(11, 6).?);
}

test "claimed input keeps SDL window focused locally" {
    try std.testing.expectEqual(
        @as(u32, sdl.SDL_WINDOW_INPUT_FOCUS | sdl.SDL_WINDOW_MOUSE_FOCUS),
        applyClaimedInputWindowFlags(true, 0),
    );
    try std.testing.expectEqual(@as(u32, 0), applyClaimedInputWindowFlags(false, 0));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
    try std.testing.expect(shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_LEAVE));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(true, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_GAINED));
    try std.testing.expect(!shouldSuppressClaimedWindowEvent(false, sdl.SDL_WINDOWEVENT, sdl.SDL_WINDOWEVENT_FOCUS_LOST));
}
