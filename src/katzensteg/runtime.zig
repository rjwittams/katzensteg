const std = @import("std");
const builtin = @import("builtin");
const termscene = @import("termscene");
const config_mod = @import("config.zig");
const core = @import("core_types.zig");
const core_commands = @import("core_commands.zig");
const core_dispatch = @import("core_command_dispatch.zig");
const cursor_mod = @import("cursor.zig");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;
const frame_builder_mod = @import("frame_builder.zig");
const inspect_model = @import("inspect_model.zig");
const input_mod = @import("input.zig");
const gl_capture_mod = @import("gl_capture.zig");
const presentation_layout_mod = @import("presentation_layout.zig");
const present_job_mod = @import("present_job.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");
const render_batch_sink_mod = @import("render_batch_sink.zig");
const upload_path_mod = @import("upload_path.zig");
const whiskers_client_mod = @import("whiskers_client.zig");
const window_policy_mod = @import("window_policy.zig");
const WhiskersClient = whiskers_client_mod.WhiskersClient;
const InspectResource = frame_builder_mod.InspectResource;
const ResourceRecord = inspect_model.ResourceRecord;
const FrameBuilder = frame_builder_mod.FrameBuilder;
const PresentJob = present_job_mod.PresentJob;
const CompositeMode = config_mod.CompositeMode;
const InterceptMode = config_mod.InterceptMode;
const Command = core_commands.Command;
const PixelSize = frame_builder_mod.PixelSize;
const ExternalFramebufferFormat = frame_builder_mod.ExternalFramebufferFormat;
const RenderBatchSink = render_batch_sink_mod.RenderBatchSink;

const log = std.log.scoped(.runtime);

const queue_compact_threshold = 4096;
const payload_pool_max_buffers = 64;
const payload_pool_max_bytes = 64 * 1024 * 1024;

var terminal_resize_pending = std.atomic.Value(bool).init(false);
var terminal_resize_handler_installed = std.atomic.Value(bool).init(false);

fn handleTerminalResizeSignal(_: c_int) callconv(.c) void {
    terminal_resize_pending.store(true, .release);
}

fn installTerminalResizeSignalHandler() void {
    if (builtin.os.tag == .windows) return;
    if (terminal_resize_handler_installed.swap(true, .acq_rel)) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleTerminalResizeSignal },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            else => std.posix.sigemptyset(),
        },
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}

const QueuedLockCapture = struct {
    rect: ?core.CoreRect,
    pixels: ?*anyopaque,
    pitch: i32,
};

const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;

var global_mutex: std.Thread.Mutex = .{};
var global_runtime: ?Runtime = null;
var global_shutdown_started: bool = false;
var global_runtime_is_stub: bool = false;

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
    batch_writer: ?std.fs.File = null,
    batch_control: ?std.fs.File = null,
    batch_control_line: std.ArrayList(u8),
    batch_sink: ?RenderBatchSink = null,
    batch_presentation_reset_pending: bool = false,
    frame_builder: FrameBuilder,
    cursor_state: cursor_mod.State,
    bg_only: bool = false,
    stats: bool = false,
    debug_protocol_replies: bool = false,
    image_gc: bool = false,
    input_enabled: bool = false,
    input_claimed: bool = false,
    input_claim_focus: bool = false,
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
    whiskers_client: ?WhiskersClient = null,
    shutdown_worker: bool = false,
    queued_lock_captures: std.AutoHashMap(usize, QueuedLockCapture),
    sdl_window_ids: std.AutoHashMap(u32, core.CoreHandle),
    input_parser: ?input_mod.TerminalInputParser = null,
    relative_mouse_baseline: input_mod.RelativeMouseBaseline = .{},
    mouse_ownership: input_mod.MouseOwnership = .{},
    input_window_w: i32 = 640,
    input_window_h: i32 = 480,
    keyboard_state: [input_mod.sdl_num_scancodes]u8 = [_]u8{0} ** input_mod.sdl_num_scancodes,
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
        const logger = Logger.init(allocator);
        const config = config_mod.loadRuntimeConfig(allocator);
        const bg_only = std.c.getenv("KATZENSTEG_BG_ONLY") != null;
        const stats = config.stats;
        const debug_protocol_replies = config.debug_protocol_replies;
        const image_gc = config.image_gc;
        const input_enabled = config.input_enabled;
        const input_claimed = input_enabled and config.input_claimed;
        const input_claim_focus = input_claimed and config.input_claim_focus;
        const dump_composites = config.dump_composites;
        const debug_composite = config.debug_composite;
        var runtime = Runtime{
            .allocator = allocator,
            .logger = logger,
            .frame_builder = FrameBuilder.init(allocator, stats, config.composite_mode, dump_composites, debug_composite),
            .cursor_state = cursor_mod.State.init(allocator),
            .batch_control_line = .empty,
            .bg_only = bg_only,
            .stats = stats,
            .debug_protocol_replies = debug_protocol_replies,
            .image_gc = image_gc,
            .input_enabled = input_enabled,
            .input_claimed = input_claimed,
            .input_claim_focus = input_claim_focus,
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
            .sdl_window_ids = std.AutoHashMap(u32, core.CoreHandle).init(allocator),
            .present_interval_ns = if (config.present_fps > 0) @divTrunc(std.time.ns_per_s, config.present_fps) else 0,
            .producer_stats = .{ .enabled = stats, .last_report_ns = std.time.nanoTimestamp() },
            .gl_capture_mode = mapGlCaptureMode(config.gl_capture),
            .forced_output_profile = config.output_profile,
            .file_transport_enabled = config.file_transport,
            .file_transport_max_bytes = config.file_transport_max_bytes,
        };
        if (std.c.getenv("KATZENSTEG_WHISKERS_SOCKET")) |path_z| {
            var free_producer_hello = true;
            const producer_hello = runtime.buildWhiskersHello() catch |err| blk: {
                log.warn("whiskers hello build failed: {any}", .{err});
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
            log.info("whiskers socket configured: {s}", .{std.mem.span(path_z)});
            defer if (free_producer_hello) runtime.freeWhiskersHello(producer_hello);
            runtime.whiskers_client = WhiskersClient.init(allocator, std.mem.span(path_z), producer_hello) catch |err| blk: {
                log.warn("whiskers client init failed: {any}", .{err});
                break :blk null;
            };
            if (runtime.whiskers_client) |*client| {
                if (std.c.getenv("KATZENSTEG_WHISKERS_FORCE_CAPTURE") != null) {
                    client.capture_enabled.store(true, .release);
                    log.info("whiskers force capture enabled", .{});
                }
                log.info("whiskers push registered producer={s} display={s}", .{ client.producer_id, client.display_name });
            }
        }
        const presentation_options = presentationOptionsFromConfig(config);
        if (presentation_options.batch_enabled) {
            runtime.initBatchPresentation(presentation_options) catch |err| {
                log.warn("batch presentation init failed: {any}", .{err});
                return runtime;
            };
            runtime.active = true;
            runtime.output_profile_name = "jsonl_fd";
            runtime.file_transport_enabled = false;
            log.info("runtime initialized in JSONL fd presentation mode", .{});
            return runtime;
        }

        runtime.tty = DirectTty.init() catch |err| {
            log.warn("direct tty init failed: {any}", .{err});
            return runtime;
        };
        installTerminalResizeSignalHandler();
        runtime.engine = ts_scene.SceneEngine.init(allocator);

        const backend_options = selectBackendOptions(allocator, &runtime) catch |err| blk: {
            log.warn("upload transport selection failed; falling back to direct APC: {any}", .{err});
            break :blk ts_kitty.Options{};
        };
        var actual_upload_medium = backend_options.upload_medium;
        runtime.backend = ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, backend_options) catch |err| blk: {
            log.warn("backend init failed: {any}", .{err});
            log.info("retrying backend init with direct APC fallback", .{});
            actual_upload_medium = .direct;
            break :blk ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, .{
                .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail,
            }) catch |fallback_err| {
                log.warn("direct APC fallback backend init failed: {any}", .{fallback_err});
                return runtime;
            };
        };
        runtime.active = true;
        runtime.output_profile_name = switch (actual_upload_medium) {
            .direct => "direct_apc",
            .file_whole => "file_whole",
            .file_offset => "file_offset_ring",
        };
        log.info("runtime initialized in direct tty mode", .{});
        switch (actual_upload_medium) {
            .direct => log.info("upload transport profile = direct_apc", .{}),
            .file_whole => {
                log.info("upload transport profile = file_whole path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
            },
            .file_offset => {
                log.info("upload transport profile = file_offset_ring path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
            },
        }
        if (backend_options.upload_file_path) |path| allocator.free(path);
        if (runtime.bg_only) log.info("background-only debug mode enabled", .{});
        if (runtime.stats) log.info("periodic stats enabled", .{});
        if (runtime.debug_protocol_replies) log.info("kitty protocol reply logging enabled (q=0)", .{});
        log.info("composite mode = {s}", .{@tagName(config.composite_mode)});
        log.info("intercept mode = {s}", .{@tagName(config.intercept_mode)});
        if (runtime.whiskers_client) |*client| {
            client.updateRuntimeInfo(
                runtime.terminal_identity,
                @tagName(config.composite_mode),
                @tagName(config.intercept_mode),
                runtime.output_profile_name,
                config.present_fps,
            );
        }
        if (config.present_fps > 0) log.info("present fps cap = {d}", .{config.present_fps});
        if (runtime.image_gc) log.info("old image GC enabled", .{});
        if (runtime.input_enabled) {
            runtime.input_parser = input_mod.TerminalInputParser.init(allocator);
            runtime.updateInputTarget();
            runtime.tty.?.enableInputCapture() catch |err| {
                log.warn("terminal input capture enable failed: {any}", .{err});
                if (runtime.input_parser) |*parser| parser.deinit();
                runtime.input_parser = null;
                runtime.input_enabled = false;
            };
            if (runtime.input_enabled) log.info("terminal input capture enabled", .{});
        }
        if (runtime.dump_composites) log.info("composite framebuffer dump enabled", .{});
        if (runtime.debug_composite) log.info("composite debug logging enabled", .{});
        return runtime;
    }

    fn initShutdownStub() Runtime {
        const allocator = std.heap.c_allocator;
        return .{
            .allocator = allocator,
            .logger = Logger.init(allocator),
            .frame_builder = FrameBuilder.init(allocator, false, .fullscreen, false, false),
            .cursor_state = cursor_mod.State.init(allocator),
            .batch_control_line = .empty,
            .input_enabled = false,
            .input_claimed = false,
            .input_claim_focus = false,
            .intercept_mode = .sync_compose,
            .window_policy = .mirror,
            .real_window_visibility = .show,
            .terminal_identity = "shutdown",
            .output_profile_name = "disabled",
            .active = false,
            .queue = std.ArrayList(Command).empty,
            .inspect_resources = std.ArrayList(InspectResource).empty,
            .inspect_resource_records = std.ArrayList(ResourceRecord).empty,
            .queued_lock_captures = std.AutoHashMap(usize, QueuedLockCapture).init(allocator),
            .sdl_window_ids = std.AutoHashMap(u32, core.CoreHandle).init(allocator),
            .producer_stats = .{},
            .gl_capture_mode = .disabled,
            .file_transport_enabled = false,
            .file_transport_max_bytes = config_mod.default_file_transport_max_bytes,
        };
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
        for (self.queue.items[self.queue_head..]) |*cmd| self.recycleCommandLocked(cmd);
        self.queue.deinit(self.allocator);
        self.payload_pool.deinit(self.allocator);
        self.gl_capture_buffers.deinit(self.allocator);
        self.inspect_resources.deinit(self.allocator);
        self.inspect_resource_records.deinit(self.allocator);
        self.queued_lock_captures.deinit();
        self.sdl_window_ids.deinit();
        if (self.batch_sink) |*sink| sink.deinit();
        self.batch_control_line.deinit(self.allocator);
        if (self.batch_control) |file| file.close();
        if (self.batch_writer) |file| file.close();
        if (self.tty) |*tty| {
            tty.disableInputCapture() catch {};
            self.pollTerminalInput();
        }
        if (self.input_parser) |*parser| parser.deinit();
        self.frame_builder.deinit();
        self.cursor_state.deinit();
        if (self.backend) |*backend| backend.deinit();
        if (self.engine) |*engine| engine.deinit();
        if (self.tty) |*tty| tty.deinit();
        self.logger.deinit();
    }

    fn initBatchPresentation(self: *Runtime, options: PresentationOptions) !void {
        const presentation_fd = options.presentation_fd orelse return error.MissingPresentationFd;
        const control_fd = options.control_fd orelse return error.MissingPresentationControlFd;
        self.batch_writer = std.fs.File{ .handle = @intCast(presentation_fd) };
        self.batch_control = std.fs.File{ .handle = @intCast(control_fd) };
        setNonblocking(self.batch_control.?.handle);
        self.batch_sink = RenderBatchSink.init(self.allocator, "main");
        // Batch mode enables the parser so hosts can forward terminal_bytes.
        // Consumers that never send input control messages observe no events.
        self.input_enabled = true;
        self.input_parser = input_mod.TerminalInputParser.init(self.allocator);
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

    pub fn refreshTerminalSizeIfNeeded(self: *Runtime) void {
        if (!terminal_resize_pending.swap(false, .acq_rel)) return;
        self.refreshTerminalSize();
    }

    fn refreshTerminalSize(self: *Runtime) void {
        if (self.tty) |*tty| {
            const old_cols = tty.cols;
            const old_rows = tty.rows;
            const old_pixel_width = tty.pixel_width;
            const old_pixel_height = tty.pixel_height;
            if (!tty.refreshSize()) return;
            log.info(
                "terminal resized {d}x{d} px={d}x{d} -> {d}x{d} px={d}x{d}",
                .{ old_cols, old_rows, old_pixel_width, old_pixel_height, tty.cols, tty.rows, tty.pixel_width, tty.pixel_height },
            );
            self.updateInputTarget();
        }
    }

    pub fn noteInputWindowSize(self: *Runtime, w: i32, h: i32) void {
        self.input_window_w = @max(1, w);
        self.input_window_h = @max(1, h);
        self.updateInputTarget();
    }

    pub fn noteSdlWindowId(self: *Runtime, window_id: u32, window: core.CoreHandle) void {
        if (window_id == 0 or window == 0) return;
        self.sdl_window_ids.put(window_id, window) catch |err| log.warn("failed to track SDL window id {d}: {any}", .{ window_id, err });
    }

    pub fn forgetSdlWindow(self: *Runtime, window: core.CoreHandle) void {
        if (window == 0) return;
        var it = self.sdl_window_ids.iterator();
        var doomed: ?u32 = null;
        while (it.next()) |entry| {
            if (entry.value_ptr.* == window) {
                doomed = entry.key_ptr.*;
                break;
            }
        }
        if (doomed) |window_id| _ = self.sdl_window_ids.remove(window_id);
    }

    pub fn coreWindowForSdlWindowId(self: *Runtime, window_id: u32) ?core.CoreHandle {
        return self.sdl_window_ids.get(window_id);
    }

    pub fn notePresentationLayout(self: *Runtime, layout: presentation_layout_mod.PresentationLayout) void {
        self.presentation_layout = layout;
        self.updateInputTarget();
    }

    pub fn pollTerminalInput(self: *Runtime) void {
        if (!self.input_enabled) return;
        self.refreshTerminalSizeIfNeeded();
        const tty = &(self.tty orelse return);
        var parser = &(self.input_parser orelse return);
        var buf: [256]u8 = undefined;
        while (true) {
            const n = std.posix.read(tty.file.handle, &buf) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => {
                        log.warn("terminal input read failed: {any}", .{err});
                        return;
                    },
                }
            };
            if (n == 0) {
                parser.flushStandaloneEscape() catch |err| {
                    log.warn("terminal input escape flush failed: {any}", .{err});
                };
                return;
            }
            parser.feed(buf[0..n]) catch |err| {
                log.warn("terminal input parse failed: {any}", .{err});
                return;
            };
            if (parser.takeMouseActivity()) self.mouse_ownership.claimTerminal();
            if (n < buf.len) return;
        }
    }

    pub fn terminalMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        self.pollBatchControl();
        if (!self.mouse_ownership.terminalOwns()) return null;
        const parser = &(self.input_parser orelse return null);
        return parser.mouseState();
    }

    pub fn terminalRelativeMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        self.pollBatchControl();
        if (!self.mouse_ownership.terminalOwns()) return null;
        const parser = &(self.input_parser orelse return null);
        return self.relative_mouse_baseline.snap(parser.mouseState());
    }

    pub fn claimRealWindowMouse(self: *Runtime) void {
        self.mouse_ownership.claimRealWindow();
    }

    pub fn terminalRenderingEnabled(self: *const Runtime) bool {
        return routeTerminalRendering(self.window_policy);
    }

    pub fn realRenderEnabled(self: *const Runtime) bool {
        return routeRealRendering(self.window_policy);
    }

    pub fn realWindowEnabled(self: *const Runtime) bool {
        return self.window_policy.realWindowEnabled();
    }

    pub fn realWindowCreateAction(self: *const Runtime) window_policy_mod.RealWindowAction {
        return self.real_window_visibility.createAction();
    }

    pub fn realWindowShowAction(self: *const Runtime) window_policy_mod.RealWindowAction {
        return self.real_window_visibility.showAction();
    }

    pub fn realWindowRestoreAction(self: *const Runtime) window_policy_mod.RealWindowAction {
        return self.real_window_visibility.restoreAction();
    }

    pub fn shouldCaptureExternalFrame(self: *Runtime) bool {
        if (self.active and self.batch_sink != null and self.batch_writer != null) {
            self.pollBatchControl();
            if (!self.batch_sink.?.isAttached()) return false;
            if (!self.terminalRenderingEnabled()) {
                self.notePresentationLayout(.{});
                return false;
            }
            return self.shouldPresent();
        }
        if (!(self.active and self.tty != null and self.engine != null and self.backend != null)) return false;
        if (!self.terminalRenderingEnabled()) {
            self.notePresentationLayout(.{});
            return false;
        }
        return self.shouldPresent();
    }

    pub fn presentExternalFramebuffer(self: *Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
        if (self.active and self.batch_sink != null and self.batch_writer != null) {
            const start_ns = std.time.nanoTimestamp();
            self.queuePendingBatchPresentationReset();
            self.frame_builder.renderExternalFramebufferBatch(&self.logger, &self.batch_sink.?, width, height, format, pixels, self.batch_writer.?.deprecatedWriter());
            var virtual_tty = self.batchVirtualTty();
            const layout = self.frame_builder.presentationLayoutForExternalFramebuffer(&virtual_tty);
            self.updateBatchInputTargetFromLayout(&self.batch_sink.?, layout);
            const duration = std.time.nanoTimestamp() - start_ns;
            self.notePresentDuration(duration);
            return;
        }
        if (!(self.active and self.tty != null and self.engine != null and self.backend != null)) return;
        const start_ns = std.time.nanoTimestamp();
        self.refreshTerminalSizeIfNeeded();
        self.frame_builder.presentExternalFramebuffer(&self.logger, &self.tty.?, &self.engine.?, &self.backend.?, width, height, format, pixels, self.cursor_state.snapshot(), self.debug_protocol_replies, self.image_gc);
        self.notePresentationLayout(self.frame_builder.presentationLayoutForExternalFramebuffer(&self.tty.?));
        const duration = std.time.nanoTimestamp() - start_ns;
        self.notePresentDuration(duration);
    }

    pub fn createRenderer(self: *Runtime, window: core.CoreHandle, renderer: core.CoreHandle) void {
        if (self.batch_sink != null and self.batch_writer != null) {
            self.frame_builder.flushBatchDeletesForRenderer(&self.logger, &self.batch_sink.?, renderer, self.batch_writer.?.deprecatedWriter());
        }
        self.frame_builder.onCreateRenderer(window, renderer);
    }

    pub fn destroyRenderer(self: *Runtime, renderer: core.CoreHandle) void {
        if (self.batch_sink != null and self.batch_writer != null) {
            self.frame_builder.flushBatchDeletesForRenderer(&self.logger, &self.batch_sink.?, renderer, self.batch_writer.?.deprecatedWriter());
        }
        self.frame_builder.onDestroyRenderer(renderer);
    }

    pub fn renderBatchPresent(self: *Runtime, renderer: core.CoreHandle) void {
        if (!(self.active and self.batch_sink != null and self.batch_writer != null)) return;
        self.pollBatchControl();
        self.waitForInitialBatchAttach();
        if (!self.shouldPresent()) return;
        if (!self.terminalRenderingEnabled()) {
            self.notePresentationLayout(.{});
            return;
        }
        if (!self.batch_sink.?.isAttached()) return;

        const start_ns = std.time.nanoTimestamp();
        var virtual_tty = self.batchVirtualTty();
        var job = self.frame_builder.buildPresentJob(&self.logger, &virtual_tty, renderer, self.bg_only, self.cursor_state.snapshot()) catch |err| {
            self.logger.writeFmtScoped(.info, .runtime, "batch buildPresentJob failed: {any}", .{err});
            return;
        };
        defer job.deinit(self.allocator);
        self.queuePendingBatchPresentationReset();
        self.frame_builder.renderPresentJobBatch(&self.logger, &self.batch_sink.?, renderer, &job, self.batch_writer.?.deprecatedWriter());
        const layout = self.frame_builder.presentationLayoutForRenderer(&virtual_tty, renderer);
        self.updateBatchInputTargetFromLayout(&self.batch_sink.?, layout);
        self.writeBatchPresentationStatus(renderer, &job);
        const duration = std.time.nanoTimestamp() - start_ns;
        self.notePresentDuration(duration);
    }

    fn writeBatchPresentationStatus(self: *Runtime, renderer: core.CoreHandle, job: *const PresentJob) void {
        const sink = &(self.batch_sink orelse return);
        const writer = self.batch_writer orelse return;
        const status = self.frame_builder.batchPresentationStatusForRenderer(sink, renderer, job) orelse return;
        render_batch_protocol.writePresentationStatusJsonl(writer.deprecatedWriter(), status) catch |err| {
            self.logger.writeFmtScoped(.info, .runtime, "batch presentation status write failed: {any}", .{err});
        };
    }

    fn waitForInitialBatchAttach(self: *Runtime) void {
        if (self.batch_sink == null or self.batch_sink.?.isAttached()) return;
        const deadline = std.time.nanoTimestamp() + 100 * std.time.ns_per_ms;
        while (std.time.nanoTimestamp() < deadline) {
            std.Thread.sleep(std.time.ns_per_ms);
            self.pollBatchControl();
            if (self.batch_sink == null or self.batch_sink.?.isAttached()) return;
        }
    }

    pub fn externalFramebufferUploadSize(self: *Runtime, source_w: i32, source_h: i32) PixelSize {
        if (self.batch_sink) |*sink| {
            const tty = sink.presentationTty();
            return self.frame_builder.externalFramebufferUploadSize(&tty, source_w, source_h);
        }
        const tty = &(self.tty orelse return .{ .w = source_w, .h = source_h });
        return self.frame_builder.externalFramebufferUploadSize(tty, source_w, source_h);
    }

    pub fn ensureGlCaptureBuffers(self: *Runtime, len: usize) ?*gl_capture_mod.Buffers {
        self.gl_capture_buffers.ensure(self.allocator, len) catch |err| {
            log.warn("GL capture buffer allocation failed: {any}", .{err});
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

    pub fn pollBatchControl(self: *Runtime) void {
        const file = &(self.batch_control orelse return);
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    log.warn("batch control read failed: {any}", .{err});
                    return;
                },
            };
            if (n == 0) return;
            for (buf[0..n]) |byte| {
                if (byte == '\n') {
                    self.processBatchControlLine(self.batch_control_line.items);
                    self.batch_control_line.clearRetainingCapacity();
                } else if (byte != '\r') {
                    self.batch_control_line.append(self.allocator, byte) catch {
                        self.batch_control_line.clearRetainingCapacity();
                        return;
                    };
                }
            }
            if (n < buf.len) return;
        }
    }

    fn processBatchControlLine(self: *Runtime, line: []const u8) void {
        var control = render_batch_protocol.parseControlMessage(self.allocator, line) catch return;
        defer render_batch_protocol.deinitControlMessage(self.allocator, &control);
        const sink = &(self.batch_sink orelse return);
        switch (control) {
            .attach => |attach| {
                log.info(
                    "batch attach window={s} rect=({d},{d} {d}x{d}) aspect={s} z_base={d} image_ids={d}..{d} placement_ids={d}..{d} upload={s}",
                    .{
                        attach.window_id,
                        attach.rect_cells.row,
                        attach.rect_cells.col,
                        attach.rect_cells.cols,
                        attach.rect_cells.rows,
                        @tagName(attach.aspect),
                        attach.z_base,
                        attach.image_ids.start,
                        attach.image_ids.end,
                        attach.placement_ids.start,
                        attach.placement_ids.end,
                        @tagName(attach.upload.profile),
                    },
                );
                sink.attachWithPresentation(attach.rect_cells, attach.aspect, attach.z_base);
                sink.setTerminalGeometry(attach.terminal);
                sink.setUploadPolicy(attach.upload) catch |err| {
                    log.warn("batch upload policy failed: {any}", .{err});
                    return;
                };
                self.frame_builder.setImageIdRange(attach.image_ids);
                self.frame_builder.setCompositePlacementIdRange(attach.placement_ids);
                const applied = sink.presentationRect();
                self.updateBatchInputTarget(sink);
                log.info(
                    "batch attach applied rect=({d},{d} {d}x{d}) aspect={s}",
                    .{ applied.row, applied.col, applied.cols, applied.rows, @tagName(sink.presentationAspect()) },
                );
            },
            .viewport => |viewport| {
                if (!sink.isAttached()) {
                    log.warn(
                        "batch viewport ignored while detached window={s} rect=({d},{d} {d}x{d}) aspect={s}",
                        .{ viewport.window_id, viewport.rect_cells.row, viewport.rect_cells.col, viewport.rect_cells.cols, viewport.rect_cells.rows, @tagName(viewport.aspect) },
                    );
                    return;
                }
                const previous = sink.presentationRect();
                const previous_aspect = sink.presentationAspect();
                const previous_z_base = sink.presentationZBase();
                const previous_terminal = sink.terminalGeometry();
                log.info(
                    "batch viewport window={s} from=({d},{d} {d}x{d})/{s}/z={d} to=({d},{d} {d}x{d})/{s}/z={d}",
                    .{
                        viewport.window_id,
                        previous.row,
                        previous.col,
                        previous.cols,
                        previous.rows,
                        @tagName(previous_aspect),
                        previous_z_base,
                        viewport.rect_cells.row,
                        viewport.rect_cells.col,
                        viewport.rect_cells.cols,
                        viewport.rect_cells.rows,
                        @tagName(viewport.aspect),
                        viewport.z_base,
                    },
                );
                const terminal_changed = if (viewport.terminal) |terminal| previous_terminal == null or !std.meta.eql(previous_terminal.?, terminal) else false;
                const presentation_changed = !std.meta.eql(previous, viewport.rect_cells) or previous_aspect != viewport.aspect or previous_z_base != viewport.z_base or terminal_changed;
                if (presentation_changed) self.batch_presentation_reset_pending = true;
                sink.viewportWithPresentation(viewport.rect_cells, viewport.aspect, viewport.z_base);
                if (viewport.terminal != null) sink.setTerminalGeometry(viewport.terminal);
                if (presentation_changed) {
                    if (self.batch_writer) |writer| {
                        if (self.frame_builder.flushBatchPresentationReproject(&self.logger, sink, writer.deprecatedWriter())) {
                            self.batch_presentation_reset_pending = false;
                        }
                    }
                }
                const applied = sink.presentationRect();
                self.updateBatchInputTarget(sink);
                log.info(
                    "batch viewport applied rect=({d},{d} {d}x{d}) aspect={s}",
                    .{ applied.row, applied.col, applied.cols, applied.rows, @tagName(sink.presentationAspect()) },
                );
            },
            .input => |input| {
                if (!self.input_enabled) return;
                var parser = &(self.input_parser orelse return);
                parser.feed(input.bytes) catch |err| {
                    log.warn("batch input parse failed: {any}", .{err});
                    return;
                };
                if (parser.takeMouseActivity()) self.mouse_ownership.claimTerminal();
            },
            .detach => {
                self.detachBatchWindow(sink, "main");
            },
            .shutdown => {
                self.detachBatchWindow(sink, "main");
            },
        }
    }

    fn detachBatchWindow(self: *Runtime, sink: *RenderBatchSink, window_id: []const u8) void {
        const previous = sink.presentationRect();
        log.info(
            "batch detach window={s} rect=({d},{d} {d}x{d}) aspect={s}",
            .{ window_id, previous.row, previous.col, previous.cols, previous.rows, @tagName(sink.presentationAspect()) },
        );
        if (self.batch_writer) |writer| {
            const file_writer = writer.deprecatedWriter();
            self.frame_builder.flushBatchDeletesForPresentationReset(&self.logger, sink, file_writer);
            render_batch_protocol.writeDetachedJsonl(file_writer, window_id) catch |err| {
                log.warn("batch detached ack failed: {any}", .{err});
            };
        }
        sink.detach();
    }

    fn batchVirtualTty(self: *Runtime) DirectTty {
        if (self.batch_sink) |*sink| return sink.presentationTty();
        var tty: DirectTty = undefined;
        tty.cols = 1;
        tty.rows = 1;
        tty.pixel_width = 10;
        tty.pixel_height = 20;
        return tty;
    }

    fn queuePendingBatchPresentationReset(self: *Runtime) void {
        if (!self.batch_presentation_reset_pending) return;
        const sink = &(self.batch_sink orelse return);
        self.frame_builder.queueBatchDeletesForPresentationReset(&self.logger, sink);
        self.batch_presentation_reset_pending = false;
    }

    fn updateBatchInputTarget(self: *Runtime, sink: *const RenderBatchSink) void {
        var layout = presentation_layout_mod.PresentationLayout{};
        const rect = sink.presentationRect();
        layout.setSingleSdlRegion(.{
            .kind = .sdl_window,
            .tty_rect = .{ .col = 1, .row = 1, .w = rect.cols, .h = rect.rows },
            .sdl_rect = .{ .x = 0, .y = 0, .w = self.input_window_w, .h = self.input_window_h },
            .z = 0,
        });
        self.updateBatchInputTargetFromLayout(sink, layout);
    }

    fn updateBatchInputTargetFromLayout(self: *Runtime, sink: *const RenderBatchSink, relative_layout: presentation_layout_mod.PresentationLayout) void {
        var parser = &(self.input_parser orelse return);
        const rect = sink.presentationRect();
        var layout = presentation_layout_mod.PresentationLayout{};
        for (relative_layout.regions[0..relative_layout.len]) |region| {
            var translated = region;
            translated.tty_rect.col += rect.col - 1;
            translated.tty_rect.row += rect.row - 1;
            layout.addRegion(translated);
        }
        if (layout.len == 0) {
            layout.setSingleSdlRegion(.{
                .kind = .sdl_window,
                .tty_rect = .{ .col = rect.col, .row = rect.row, .w = rect.cols, .h = rect.rows },
                .sdl_rect = .{ .x = 0, .y = 0, .w = self.input_window_w, .h = self.input_window_h },
                .z = 0,
            });
        }
        parser.setTarget(.{
            .cols = @max(1, rect.col + rect.cols - 1),
            .rows = @max(1, rect.row + rect.rows - 1),
            .w = self.input_window_w,
            .h = self.input_window_h,
            .layout = layout,
        });
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
        log.info(
            "producer generic={d}({d:.1}us avg/{d:.1}us max) update={d}({d:.1}us/{d:.1}us) unlock={d}({d:.1}us/{d:.1}us) ctfs={d}({d:.1}us/{d:.1}us) present={d}({d:.1}us/{d:.1}us)",
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
                log.info("skipped presents={d}", .{self.skipped_presents});
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

    pub fn rememberQueuedLock(self: *Runtime, texture: core.CoreHandle, rect: ?core.CoreRect, pixels: ?*anyopaque, pitch: i32) void {
        if (texture == 0) return;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.queued_lock_captures.put(texture, .{ .rect = rect, .pixels = pixels, .pitch = pitch }) catch |err| {
            log.warn("failed to remember queued lock capture: {any}", .{err});
        };
    }

    pub fn takeQueuedLock(self: *Runtime, texture: core.CoreHandle) ?QueuedLockCapture {
        if (texture == 0) return null;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.queued_lock_captures.fetchRemove(texture)) |entry| return entry.value;
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
            log.warn("failed to enqueue command: {any}", .{err});
            self.recycleCommandLocked(&owned);
            return;
        };
        if (isPresentCommand(owned)) self.pending_presents += 1;
        self.maybeCompactQueue();
        self.queue_cond.signal();
    }

    pub fn dispatchCursorPosition(self: *Runtime, position: ?core.CorePoint) void {
        const cmd = Command{ .set_cursor_position = .{ .position = position } };
        switch (self.intercept_mode) {
            .sync_compose => core_dispatch.handleCommand(self, cmd),
            .queued_replay => self.enqueueCommand(cmd),
        }
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
            .create_color_cursor => |*c| {
                if (c.rgba) |buf| self.payload_pool.release(self.allocator, buf);
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
        if (dropped_any) log.info("dropped stale queued frame-local commands before latest present", .{});
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

test "external framebuffer present is a frame-local present command" {
    const cmd = Command{ .external_framebuffer_present = .{ .width = 2, .height = 1, .format = .rgba8, .pixels = null } };
    try std.testing.expect(isFrameLocalCommand(cmd));
    try std.testing.expect(isPresentCommand(cmd));
}

test "sync dispatch recycles cloned external framebuffer payload" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    var pixels = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const copied = try runtime.acquirePayloadBuffer(pixels.len);
    @memcpy(copied, &pixels);
    var cmd = Command{ .external_framebuffer_present = .{
        .width = 1,
        .height = 2,
        .format = .rgba8,
        .pixels = copied,
    } };
    runtime.recycleCommand(&cmd);

    try std.testing.expectEqual(@as(usize, 1), runtime.payload_pool.buffers.items.len);
    try std.testing.expectEqual(@as(usize, pixels.len), runtime.payload_pool.bytes);
}

test "queued batch texture update reaches frame builder without terminal backend" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.active = true;
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");

    const texture: core.CoreHandle = 0x1234;
    core_dispatch.handleCommand(&runtime, .{ .create_texture = .{
        .texture = texture,
        .format = core.pixelFormat(.rgba8, .{ .sdl2 = 376840196 }),
        .w = 1,
        .h = 1,
    } });

    var pixel = [_]u8{ 17, 34, 51, 255 };
    core_dispatch.handleCommand(&runtime, .{ .update_texture = .{
        .texture = texture,
        .rect = null,
        .pixels = pixel[0..],
        .pitch = 4,
    } });

    const resources = try runtime.frame_builder.snapshotResources(std.testing.allocator);
    defer std.testing.allocator.free(resources);

    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqual(@as(u64, 1), resources[0].update_count);
}

test "queued batch texture unlock reaches frame builder without terminal backend" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.active = true;
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");

    const texture: core.CoreHandle = 0x5678;
    core_dispatch.handleCommand(&runtime, .{ .create_texture = .{
        .texture = texture,
        .format = core.pixelFormat(.rgba8, .{ .sdl2 = 376840196 }),
        .w = 1,
        .h = 1,
    } });

    var pixel = [_]u8{ 68, 85, 102, 255 };
    core_dispatch.handleCommand(&runtime, .{ .lock_texture = .{
        .texture = texture,
        .rect = null,
        .pixels = @ptrCast(&pixel),
        .pitch = 4,
    } });
    core_dispatch.handleCommand(&runtime, .{ .unlock_texture = .{ .texture = texture } });

    const resources = try runtime.frame_builder.snapshotResources(std.testing.allocator);
    defer std.testing.allocator.free(resources);

    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqual(@as(u64, 1), resources[0].update_count);
}

test "batch input terminal bytes map through attached rect" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);
    runtime.input_window_w = 320;
    runtime.input_window_h = 240;

    runtime.processBatchControlLine("{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":6,\"col\":11,\"rows\":30,\"cols\":80},\"aspect\":\"fit\",\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}");
    runtime.processBatchControlLine("{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":\"\\u001b[<35;11;6M\"}");

    try std.testing.expectEqual(@as(usize, 1), runtime.input_parser.?.target.layout.len);
    try std.testing.expectEqual(presentation_layout_mod.CellRect{ .col = 11, .row = 6, .w = 80, .h = 30 }, runtime.input_parser.?.target.layout.regions[0].tty_rect);
    try std.testing.expectEqual(@as(usize, 1), runtime.input_parser.?.pendingCount());
}

test "batch viewport marks presentation reset pending without immediate flush" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);

    runtime.processBatchControlLine("{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":6,\"col\":11,\"rows\":30,\"cols\":80},\"aspect\":\"fit\",\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}");
    runtime.processBatchControlLine("{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":7,\"col\":12,\"rows\":28,\"cols\":76},\"aspect\":\"fit\"}");

    try std.testing.expect(runtime.batch_presentation_reset_pending);
    try std.testing.expect(runtime.batch_sink.?.hasPendingBytes() == false);
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 7, .col = 12, .rows = 28, .cols = 76 }, runtime.batch_sink.?.presentationRect());
}

test "batch viewport immediately reprojects retained presentation when writer is available" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    runtime.batch_writer = .{ .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 40, .cols = 100 });

    const window: core.CoreHandle = 0x6666;
    const renderer: core.CoreHandle = 0x7777;
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.frame_builder.onCreateRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    var job = try runtime.frame_builder.buildPresentJob(&runtime.logger, &tty, renderer, false, null);
    defer job.deinit(runtime.allocator);
    var first_out = std.ArrayList(u8).empty;
    defer first_out.deinit(std.testing.allocator);
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, first_out.writer(std.testing.allocator));

    setNonblocking(pipe[0]);
    runtime.processBatchControlLine("{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":5,\"col\":11,\"rows\":20,\"cols\":40},\"aspect\":\"fit\"}");

    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"placements\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "c=40,r=15") != null);
    try std.testing.expect(!runtime.batch_presentation_reset_pending);
}

test "batch present reports source pixels and effective fitted rect" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 20, .cols = 40 });

    const window: core.CoreHandle = 0x6680;
    const renderer: core.CoreHandle = 0x7780;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.createRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    setNonblocking(pipe[0]);
    runtime.renderBatchPresent(renderer);

    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"frame_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"presentation_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"ready_to_show\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"source_px\":{\"w\":640,\"h\":480}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"effective_rect_cells\":{\"row\":7,\"col\":11,\"rows\":15,\"cols\":40}") != null);
}

test "batch present uses host terminal pixels for effective fitted rect" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.processBatchControlLine("{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":5,\"col\":11,\"rows\":20,\"cols\":40},\"aspect\":\"fit\",\"terminal_cells\":{\"rows\":40,\"cols\":160},\"terminal_px\":{\"w\":1280,\"h\":800},\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}");

    const window: core.CoreHandle = 0x6681;
    const renderer: core.CoreHandle = 0x7781;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.createRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    setNonblocking(pipe[0]);
    runtime.renderBatchPresent(renderer);

    var buf: [8192]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"effective_rect_cells\":{\"row\":9,\"col\":11,\"rows\":12,\"cols\":40}") != null);
}

test "batch renderer destroy emits retained placement deletes before forgetting state" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    runtime.batch_writer = .{ .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 40, .cols = 100 });

    const window: core.CoreHandle = 0x6666;
    const renderer: core.CoreHandle = 0x7777;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.frame_builder.onCreateRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    var job = try runtime.frame_builder.buildPresentJob(&runtime.logger, &tty, renderer, false, null);
    defer job.deinit(runtime.allocator);
    var first_out = std.ArrayList(u8).empty;
    defer first_out.deinit(std.testing.allocator);
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, first_out.writer(std.testing.allocator));

    setNonblocking(pipe[0]);
    runtime.destroyRenderer(renderer);

    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "p=200000") != null);
}

test "batch renderer replacement emits retained placement deletes before overwriting state" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    runtime.batch_writer = .{ .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 40, .cols = 100 });

    const window: core.CoreHandle = 0x6667;
    const renderer: core.CoreHandle = 0x7778;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.createRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    var tty: DirectTty = undefined;
    tty.cols = 100;
    tty.rows = 40;
    tty.pixel_width = 1000;
    tty.pixel_height = 800;

    var job = try runtime.frame_builder.buildPresentJob(&runtime.logger, &tty, renderer, false, null);
    defer job.deinit(runtime.allocator);
    var first_out = std.ArrayList(u8).empty;
    defer first_out.deinit(std.testing.allocator);
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, first_out.writer(std.testing.allocator));

    setNonblocking(pipe[0]);
    runtime.createRenderer(window, renderer);

    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "p=200000") != null);
}

test "batch input poll drains control pipe before SDL event reads" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try std.posix.pipe();
    runtime.batch_control = .{ .handle = pipe[0] };
    setNonblocking(runtime.batch_control.?.handle);
    const control_writer = std.fs.File{ .handle = pipe[1] };
    defer control_writer.close();

    runtime.batch_sink = RenderBatchSink.init(runtime.allocator, "main");
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);
    runtime.input_window_w = 320;
    runtime.input_window_h = 240;

    try control_writer.writeAll(
        "{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":6,\"col\":11,\"rows\":30,\"cols\":80},\"aspect\":\"fit\",\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}\n" ++
            "{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":\"\\u001b[<35;11;6M\"}\n",
    );

    runtime.pollBatchControl();
    try std.testing.expectEqual(@as(usize, 1), runtime.input_parser.?.pendingCount());
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
    log.info("queued replay worker started", .{});
    while (true) {
        runtime.queue_mutex.lock();
        while (!runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_cond.wait(&runtime.queue_mutex);
        }
        if (runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_mutex.unlock();
            log.info("queued replay worker exiting", .{});
            return;
        }
        var cmd = runtime.queue.items[runtime.queue_head];
        runtime.queue_head += 1;
        if (isPresentCommand(cmd) and runtime.pending_presents > 0) runtime.pending_presents -= 1;
        runtime.maybeCompactQueue();
        runtime.queue_mutex.unlock();
        core_dispatch.handleCommand(runtime, cmd);
        runtime.recycleCommand(&cmd);
    }
}

pub fn get() *Runtime {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime == null) {
        if (global_shutdown_started) {
            global_runtime = Runtime.initShutdownStub();
            global_runtime_is_stub = true;
            return &global_runtime.?;
        }
        global_runtime = Runtime.init();
        global_runtime_is_stub = false;
        if (global_runtime) |*runtime| {
            if (runtime.whiskers_client) |*client| {
                if (std.c.getenv("KATZENSTEG_WHISKERS_FORCE_CAPTURE") == null) {
                    client.start();
                }
            }
            if (runtime.intercept_mode == .queued_replay) {
                if (std.Thread.spawn(.{}, workerMain, .{runtime})) |thread| {
                    runtime.worker_thread = thread;
                } else |err| {
                    log.warn("failed to start queued replay worker: {any}", .{err});
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

const PresentationOptions = struct {
    batch_enabled: bool,
    open_direct_tty: bool,
    presentation_fd: ?i32,
    control_fd: ?i32,
};

fn presentationOptionsFromConfig(config: config_mod.RuntimeConfig) PresentationOptions {
    return switch (config.presentation_sink) {
        .tty => .{
            .batch_enabled = false,
            .open_direct_tty = true,
            .presentation_fd = null,
            .control_fd = null,
        },
        .jsonl_fd => .{
            .batch_enabled = true,
            .open_direct_tty = false,
            .presentation_fd = config.presentation_fd,
            .control_fd = config.presentation_control_fd,
        },
    };
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, flags | (1 << @bitOffsetOf(std.posix.O, "NONBLOCK"))) catch {};
}

pub fn shutdownGlobal() callconv(.c) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_shutdown_started = true;
    if (global_runtime_is_stub) return;
    if (global_runtime) |*runtime| {
        runtime.active = false;
        runtime.deinit();
        global_runtime = Runtime.initShutdownStub();
        global_runtime_is_stub = true;
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
    log.info(
        "terminal={s} graphics={s} file_whole={s}/{s} file_offset={s}/{s}",
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
        log.info("forced output profile = {s}", .{@tagName(profile)});
    }
    return switch (chosen) {
        .direct_apc => blk: {
            allocator.free(upload_path);
            log.info("file upload transport unavailable or avoided; falling back to inline APC", .{});
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
    return upload_path_mod.makeUploadPath(allocator);
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

test "batch presentation forces fd sink without direct tty" {
    const options = presentationOptionsFromConfig(.{
        .presentation_sink = .jsonl_fd,
        .presentation_fd = 3,
        .presentation_control_fd = 4,
    });
    try std.testing.expect(options.batch_enabled);
    try std.testing.expect(!options.open_direct_tty);
    try std.testing.expectEqual(@as(i32, 3), options.presentation_fd.?);
    try std.testing.expectEqual(@as(i32, 4), options.control_fd.?);
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
