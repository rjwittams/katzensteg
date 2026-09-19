const std = @import("std");
const jackstay = @import("jackstay");
const system_io = @import("platform");
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
const blocking_trace = @import("blocking_trace.zig");
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
const worker_control_poll_interval_ns = 5 * std.time.ns_per_ms;

var terminal_resize_pending = std.atomic.Value(bool).init(false);
var terminal_resize_handler_installed = std.atomic.Value(bool).init(false);

fn handleTerminalResizeSignal(_: std.posix.SIG) callconv(.c) void {
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

var preload_io: std.Io.Threaded = .init_single_threaded;
var global_mutex: system_io.Mutex = .{};
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

const PayloadBufferPool = @import("replay_payloads.zig").Payloads;

fn presentationStatusEqual(a: render_batch_protocol.PresentationStatusView, b: render_batch_protocol.PresentationStatusView) bool {
    return std.mem.eql(u8, a.window_id, b.window_id) and
        a.input_supported == b.input_supported and
        a.ready_to_show == b.ready_to_show and
        optionalEqual(render_batch_protocol.SourcePixels, a.source_px, b.source_px) and
        optionalEqual(render_batch_protocol.PresentationRectCells, a.effective_rect_cells, b.effective_rect_cells);
}

fn optionalEqual(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

pub const Runtime = struct {
    io: std.Io,
    observation: @import("frame_observation.zig").FrameObservation = .{},
    observation_enabled: bool = false,
    placeholder_scene: @import("frame_builder.zig").PresentationSnapshot = .{},
    allocator: std.mem.Allocator,
    logger: Logger,
    tty: ?DirectTty = null,
    engine: ?ts_scene.SceneEngine = null,
    backend: ?ts_kitty.Backend = null,
    batch_writer: ?system_io.fs.File = null,
    batch_control: ?system_io.fs.File = null,
    batch_control_line: std.ArrayList(u8),
    batch_sink: ?RenderBatchSink = null,
    // Serializes batch presentation state and terminal-input projection.
    // In queued batch mode, control messages are applied from the worker path;
    // app-side SDL input calls may read snapshots but must not drain control.
    presentation_mutex: system_io.Mutex = .{},
    // Protects terminal input parser state and mouse ownership without making
    // app-side SDL input queries wait behind presentation/reproject work.
    input_mutex: system_io.Mutex = .{},
    batch_presentation_reset_pending: bool = false,
    last_batch_presentation_status: ?render_batch_protocol.PresentationStatusView = null,
    frame_builder: FrameBuilder,
    cursor_state: cursor_mod.State,
    bg_only: bool = false,
    stats: bool = false,
    debug_protocol_replies: bool = false,
    blocking_trace_settings: blocking_trace.Settings = .{},
    image_gc: bool = false,
    input_enabled: bool = false,
    input_supported: bool = true,
    host_closed: bool = false,
    publisher: ?*jackstay.Publisher = null,
    input_executor: ?*(if (jackstay.enabled) @import("jackstay_input_executor.zig").Executor else void) = null,
    publication_sequence: u64 = 0,
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
    queue_mutex: system_io.Mutex = .{},
    queue_cond: system_io.Condition = .{},
    queue: std.ArrayList(Command),
    payload_pool: PayloadBufferPool = .{},
    renderer_output_sizes: std.AutoHashMapUnmanaged(core.CoreHandle, PixelSize) = .{},
    inspect_resources: std.ArrayList(InspectResource),
    inspect_resource_records: std.ArrayList(ResourceRecord),
    queue_head: usize = 0,
    pending_presents: usize = 0,
    worker_frame_active: bool = false,
    worker_thread: ?std.Thread = null,
    whiskers_client: ?WhiskersClient = null,
    shutdown_worker: bool = false,
    queued_lock_captures: std.AutoHashMap(usize, QueuedLockCapture),
    sdl_window_ids: std.AutoHashMap(u32, core.CoreHandle),
    input_parser: ?input_mod.TerminalInputParser = null,
    command_notify_fd: ?std.posix.fd_t = null,
    command_quit_notified: bool = false,
    // Last terminal protocol replies written to the log, so each change is
    // recorded once.
    logged_keyboard_flags: u32 = 0,
    logged_mouse_units: @import("terminal_keys.zig").MouseUnits = .cell,
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
        return initWithInputSupport(true);
    }

    pub fn initMediaSource() Runtime {
        return initWithInputSupport(false);
    }

    pub fn enableSourceInput(self: *Runtime) !void {
        if (self.input_parser == null) self.input_parser = input_mod.InputModel.init(self.allocator);
        if (self.tty) |*tty| {
            try tty.enableInputCapture();
            var writer = tty.file.writerStreaming(&.{});
            try writer.interface.writeAll("\x1b[?1004h");
        }
        self.input_parser.?.queue_limit = 8192;
        self.input_supported = true;
        self.input_enabled = true;
        self.updateInputTarget();
        self.refreshSourceInputStatus();
    }

    pub fn disableSourceInput(self: *Runtime) void {
        self.input_supported = false;
        self.input_enabled = false;
        if (self.tty) |*tty| tty.disableInputCapture() catch {};
        self.refreshSourceInputStatus();
    }

    fn refreshSourceInputStatus(self: *Runtime) void {
        if (self.last_batch_presentation_status) |status| self.writeBatchPresentationStatusView(status);
    }

    fn initWithInputSupport(input_supported: bool) Runtime {
        const io = preload_io.io();
        const allocator = std.heap.c_allocator;
        const logger = Logger.init(allocator);
        var config = config_mod.loadRuntimeConfig(io, allocator);
        if (!input_supported) {
            config.input_enabled = false;
            config.intercept_mode = .sync_compose;
        }
        const bg_only = std.c.getenv("KATZENSTEG_BG_ONLY") != null;
        const stats = config.stats;
        const debug_protocol_replies = config.debug_protocol_replies;
        const image_gc = config.image_gc;
        const input_enabled = config.input_enabled;
        const input_claimed = input_enabled and config.input_claimed;
        const input_claim_focus = input_claimed and config.input_claim_focus;
        const dump_composites = config.dump_composites;
        const debug_composite = config.debug_composite;
        const trace_blocking = blocking_trace.settingsFromEnv();
        var runtime = Runtime{
            .input_supported = input_supported,
            .io = io,
            .observation_enabled = std.c.getenv("KATZENSTEG_OBSERVE") != null,
            .allocator = allocator,
            .logger = logger,
            .frame_builder = FrameBuilder.init(io, allocator, stats, config.composite_mode, dump_composites, debug_composite),
            .cursor_state = cursor_mod.State.init(allocator),
            .batch_control_line = .empty,
            .bg_only = bg_only,
            .stats = stats,
            .debug_protocol_replies = debug_protocol_replies,
            .blocking_trace_settings = trace_blocking,
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
            .producer_stats = .{ .enabled = stats, .last_report_ns = system_io.time.nanoTimestamp() },
            .gl_capture_mode = mapGlCaptureMode(config.gl_capture),
            .forced_output_profile = config.output_profile,
            .file_transport_enabled = config.file_transport,
            .file_transport_max_bytes = config.file_transport_max_bytes,
        };
        if (std.c.getenv("KATZENSTEG_PLACEMENT_INVARIANTS") != null) {
            runtime.frame_builder.enablePlacementAudit();
            log.info("placement invariant audit enabled", .{});
        }
        if (trace_blocking.enabled) {
            log.info("blocking trace enabled threshold_ms={d}", .{@divTrunc(trace_blocking.threshold_ns, std.time.ns_per_ms)});
        }
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
            runtime.whiskers_client = WhiskersClient.init(io, allocator, std.mem.span(path_z), producer_hello) catch |err| blk: {
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
        if (std.c.getenv("KATZENSTEG_PUBLISH")) |path| {
            if (jackstay.enabled) {
                runtime.input_enabled = false;
                runtime.input_claimed = false;
                runtime.input_supported = false;
                // Publication grants observation. Input is separately opted in
                // by the source owner; the same-user listener authorizes peers.
                const allow_input = if (std.c.getenv("KATZENSTEG_PUBLISH_INPUT")) |value| std.mem.eql(u8, std.mem.span(value), "1") else false;
                if (input_supported and allow_input) {
                    runtime.input_executor = @import("jackstay_input_executor.zig").Executor.create(allocator) catch |err| blk: {
                        log.err("Jackstay input executor init failed: {any}", .{err});
                        break :blk null;
                    };
                }
                runtime.publisher = jackstay.Publisher.create(io, allocator, std.mem.span(path), .{}, if (runtime.input_executor) |executor| executor.authority() else null) catch |err| {
                    if (runtime.input_executor) |executor| executor.close() catch {};
                    runtime.input_executor = null;
                    log.err("Jackstay publisher init failed: {any}", .{err});
                    return runtime;
                };
                runtime.active = true;
                if (runtime.input_executor != null) {
                    runtime.input_parser = input_mod.InputModel.init(allocator);
                    runtime.input_enabled = true;
                    runtime.mouse_ownership.claimRealWindow();
                    runtime.input_supported = true;
                    log.info("Jackstay publication allows same-user input", .{});
                }
                runtime.output_profile_name = "jackstay";
                log.info("Jackstay publication ready: {s}", .{std.mem.span(path)});
            } else log.err("Jackstay support is disabled", .{});
            return runtime;
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

        runtime.tty = DirectTty.init(io) catch |err| {
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
            .shm => "shm",
            .file_whole => "file_whole",
            .file_offset => "file_offset_ring",
        };
        log.info("runtime initialized in direct tty mode", .{});
        switch (actual_upload_medium) {
            .direct => log.info("upload transport profile = direct_apc", .{}),
            .shm => log.info("upload transport profile = shm", .{}),
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
        if (std.c.getenv("KATZENSTEG_TRACE_PLACEMENTS") != null or std.c.getenv("KATZENSTEG_PLACEMENT_INVARIANTS") != null) {
            log.info("placement trace enabled", .{});
        }
        if (runtime.input_enabled) {
            runtime.input_parser = input_mod.TerminalInputParser.init(allocator);
            if (runtime.input_claimed) runtime.input_parser.?.command_key = config.command_key;
            runtime.command_notify_fd = config.command_notify_fd;
            if (runtime.command_notify_fd) |fd| {
                _ = system_io.posix.fcntl(fd, std.posix.F.SETFD, @as(u32, std.posix.FD_CLOEXEC)) catch {};
            }
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

    pub fn initShutdownStub() Runtime {
        const io = preload_io.io();
        const allocator = std.heap.c_allocator;
        return .{
            .io = io,
            .allocator = allocator,
            .logger = Logger.init(allocator),
            .frame_builder = FrameBuilder.init(io, allocator, false, .fullscreen, false, false),
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
        const io = self.io;
        const argv = try system_io.process.argsAlloc(io, self.allocator);
        defer system_io.process.argsFree(self.allocator, argv);
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
        const cwd = system_io.process.getCwdAlloc(io, self.allocator) catch null;
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

    pub fn deinit(self: *Runtime) void {
        defer self.presentation_mutex.deinit();
        defer self.input_mutex.deinit();
        defer self.queue_mutex.deinit();
        defer self.queue_cond.deinit();
        self.payload_pool.close();
        self.queue_mutex.lock();
        self.shutdown_worker = true;
        self.queue_cond.signal();
        self.queue_mutex.unlock();
        if (self.worker_thread) |thread| thread.join();
        if (jackstay.enabled) if (self.publisher) |publisher| {
            publisher.close() catch |err| {
                // The stopped owner must remain allocated if remote leases have
                // not retired. No thread can execute unloaded KS code here.
                log.err("Jackstay cleanup incomplete, retaining storage owner: {any}", .{err});
            };
            self.publisher = null;
        };
        if (jackstay.enabled) if (self.input_executor) |executor| {
            executor.close() catch |err| {
                log.err("Jackstay input cleanup unconfirmed, retaining stopped executor: {any}", .{err});
            };
            self.input_executor = null;
        };
        if (self.whiskers_client) |*client| client.deinit();
        for (self.queue.items[self.queue_head..]) |*cmd| self.recycleCommandLocked(cmd);
        self.queue.deinit(self.allocator);
        self.renderer_output_sizes.deinit(self.allocator);
        self.payload_pool.deinit(self.allocator);
        self.gl_capture_buffers.deinit(self.allocator);
        self.inspect_resources.deinit(self.allocator);
        self.inspect_resource_records.deinit(self.allocator);
        self.queued_lock_captures.deinit();
        self.sdl_window_ids.deinit();
        if (self.batch_sink) |*sink| {
            if (self.batch_writer) |writer| {
                var output_writer = writer.writerStreaming(&.{});
                self.frame_builder.flushBatchDeletesForPresentationReset(&self.logger, sink, &output_writer.interface);
            }
            sink.deinit();
        }
        self.batch_control_line.deinit(self.allocator);
        if (self.batch_control) |file| file.close();
        if (self.batch_writer) |file| file.close();
        if (self.tty) |*tty| {
            tty.disableInputCapture() catch {};
            self.pollTerminalInput();
        }
        if (self.command_notify_fd) |fd| system_io.posix.close(fd);
        if (self.input_parser) |*parser| parser.deinit();
        self.observation.deinit(self.allocator);
        self.placeholder_scene.deinit(self.allocator);
        self.frame_builder.deinit();
        self.cursor_state.deinit();
        if (self.backend) |*backend| backend.deinit();
        if (self.engine) |*engine| engine.deinit();
        if (self.tty) |*tty| tty.deinit();
        self.logger.deinit();
    }

    fn initBatchPresentation(self: *Runtime, options: PresentationOptions) !void {
        const io = self.io;
        const presentation_fd = options.presentation_fd orelse return error.MissingPresentationFd;
        const control_fd = options.control_fd orelse return error.MissingPresentationControlFd;
        self.batch_writer = system_io.fs.File{ .io = io, .handle = @intCast(presentation_fd) };
        self.batch_control = system_io.fs.File{ .io = io, .handle = @intCast(control_fd) };
        setNonblocking(self.batch_control.?.handle);
        self.batch_sink = RenderBatchSink.init(io, self.allocator, "main");
        self.batch_sink.?.enableBlockingTrace(self.blocking_trace_settings);
        if (std.c.getenv("KATZENSTEG_TRACE_PLACEMENTS") != null or std.c.getenv("KATZENSTEG_PLACEMENT_INVARIANTS") != null) {
            self.batch_sink.?.enablePlacementTrace();
            self.logger.writeScoped(.info, .runtime, "placement trace enabled");
        }
        // Batch mode enables the parser so hosts can forward terminal_bytes.
        // Consumers that never send input control messages observe no events.
        self.input_enabled = self.input_supported;
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
        if (jackstay.enabled) if (self.input_executor) |executor| {
            self.input_mutex.lock();
            defer self.input_mutex.unlock();
            executor.setSize(self.input_window_w, self.input_window_h) catch |err| log.err("Jackstay input geometry failed: {any}", .{err});
        };
        self.updateInputTarget();
    }

    pub fn hasRemoteInput(self: *const Runtime) bool {
        return jackstay.enabled and self.input_executor != null;
    }

    pub fn remoteMouseButtons(self: *Runtime) u32 {
        if (!self.hasRemoteInput()) return 0;
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        const model = &(self.input_parser orelse return 0);
        model.observeButtons();
        return model.remote_buttons;
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

    pub fn filterNativeMouseButtons(self: *Runtime, buttons: u32) u32 {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        const model = &(self.input_parser orelse return buttons);
        if (model.command_key == null) return buttons;
        return model.nativeMouseButtons(buttons);
    }

    pub fn commandModeActive(self: *Runtime) bool {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        return if (self.input_parser) |*model| model.routing_mode == .command else false;
    }

    pub fn commandRoutingEnabled(self: *Runtime) bool {
        self.input_mutex.lock();
        defer self.input_mutex.unlock();
        return if (self.input_parser) |*model| model.command_key != null else false;
    }

    // Called with input_mutex held. Only the launcher owns process deadlines.
    fn notifyCommandQuit(self: *Runtime, model: *input_mod.InputModel) void {
        if (!model.quit_requested or self.command_quit_notified) return;
        self.command_quit_notified = true;
        if (self.command_notify_fd) |fd| {
            if (!@import("launcher/command_lifetime.zig").notify(fd)) log.warn("command quit notification failed", .{});
        }
    }

    pub fn pollTerminalInput(self: *Runtime) void {
        if (!self.input_enabled) return;
        self.refreshTerminalSizeIfNeeded();
        const tty = &(self.tty orelse return);
        var buf: [256]u8 = undefined;
        while (true) {
            const n = system_io.posix.read(tty.file.handle, &buf) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => {
                        log.warn("terminal input read failed: {any}", .{err});
                        return;
                    },
                }
            };
            if (n == 0) {
                self.lockInput("poll_terminal_input_flush");
                var parser = &(self.input_parser orelse {
                    self.input_mutex.unlock();
                    return;
                });
                parser.flushStandaloneEscape() catch |err| {
                    log.warn("terminal input escape flush failed: {any}", .{err});
                };
                self.input_mutex.unlock();
                return;
            }
            log.debug("terminal input bytes: {x}", .{buf[0..n]});
            self.lockInput("poll_terminal_input_feed");
            var parser = &(self.input_parser orelse {
                self.input_mutex.unlock();
                return;
            });
            parser.feed(buf[0..n]) catch |err| {
                log.warn("terminal input parse failed: {any}", .{err});
                self.input_mutex.unlock();
                return;
            };
            self.notifyCommandQuit(parser);
            if (parser.keyboard_protocol_flags != self.logged_keyboard_flags) {
                self.logged_keyboard_flags = parser.keyboard_protocol_flags;
                log.info("terminal keyboard protocol flags={d}", .{parser.keyboard_protocol_flags});
            }
            if (parser.mouse_units != self.logged_mouse_units) {
                self.logged_mouse_units = parser.mouse_units;
                log.info("terminal mouse units={s}", .{@tagName(parser.mouse_units)});
            }
            if (parser.takeMouseActivity()) self.mouse_ownership.claimTerminal();
            self.input_mutex.unlock();
            if (n < buf.len) return;
        }
    }

    pub fn terminalMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        self.lockInput("terminal_mouse_state");
        defer self.input_mutex.unlock();
        const parser = &(self.input_parser orelse return null);
        if (!self.mouse_ownership.terminalOwns() and parser.routing_mode != .command) return null;
        parser.observeState(.pointer);
        return parser.mouseState();
    }

    pub fn terminalRelativeMouseState(self: *Runtime) ?input_mod.MouseState {
        if (!self.input_enabled) return null;
        self.lockInput("terminal_relative_mouse_state");
        defer self.input_mutex.unlock();
        const parser = &(self.input_parser orelse return null);
        if (!self.mouse_ownership.terminalOwns() and parser.routing_mode != .command) return null;
        parser.observeState(.pointer);
        const state = parser.mouseState();
        if (parser.routing_mode == .command) {
            _ = self.relative_mouse_baseline.snap(state);
            return .{ .x = state.x, .y = state.y, .buttons = 0 };
        }
        return self.relative_mouse_baseline.snap(state);
    }

    pub fn claimRealWindowMouse(self: *Runtime) void {
        self.lockInput("claim_real_window_mouse");
        defer self.input_mutex.unlock();
        self.mouse_ownership.claimRealWindow();
    }

    pub fn terminalRenderingEnabled(self: *const Runtime) bool {
        return routeTerminalRendering(self.window_policy);
    }

    pub fn captureEnabled(self: *const Runtime) bool {
        return self.publisher != null or self.terminalRenderingEnabled();
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

    fn lockPresentation(self: *Runtime, comptime context: []const u8) void {
        self.lockTraced(&self.presentation_mutex, "presentation_mutex", context);
    }

    fn lockInput(self: *Runtime, comptime context: []const u8) void {
        self.lockTraced(&self.input_mutex, "input_mutex", context);
    }

    fn lockQueue(self: *Runtime, comptime context: []const u8) void {
        self.lockTraced(&self.queue_mutex, "queue_mutex", context);
    }

    fn lockTraced(self: *Runtime, mutex: *system_io.Mutex, comptime name: []const u8, comptime context: []const u8) void {
        if (!self.blocking_trace_settings.enabled) {
            mutex.lock();
            return;
        }
        const start_ns = system_io.time.nanoTimestamp();
        mutex.lock();
        self.traceBlockingSpan(name, context, blocking_trace.elapsedSince(start_ns));
    }

    fn traceBlockingSpan(self: *Runtime, comptime area: []const u8, comptime context: []const u8, duration_ns: i128) void {
        const settings = self.blocking_trace_settings;
        if (!blocking_trace.shouldLog(settings.enabled, duration_ns, settings.threshold_ns)) return;
        log.info("blocking trace area={s} context={s} duration_us={d}", .{
            area,
            context,
            blocking_trace.micros(duration_ns),
        });
    }

    pub fn shouldCaptureExternalFrame(self: *Runtime) bool {
        if (self.active and self.publisher != null) return self.shouldPresent();
        if (self.active and self.batch_sink != null and self.batch_writer != null) {
            self.lockPresentation("should_capture_external_frame");
            defer self.presentation_mutex.unlock();
            // Synchronous external producers have no worker to receive attach
            // and viewport messages before the first captured frame.
            if (self.intercept_mode == .sync_compose) self.pollBatchControlLocked();
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
        if (jackstay.enabled) if (self.publisher != null) {
            self.lockPresentation("publish_external_frame");
            defer self.presentation_mutex.unlock();
            const frame = self.frame_builder.externalContentFrame(&self.logger, width, height, format, pixels, self.cursor_state.snapshot()) orelse return;
            self.publishContent(frame.width, frame.height, frame.rgba);
            return;
        };
        if (self.active and self.batch_sink != null and self.batch_writer != null) {
            self.lockPresentation("present_external_framebuffer");
            defer self.presentation_mutex.unlock();
            if (!self.batch_sink.?.isAttached()) return;
            const start_ns = system_io.time.nanoTimestamp();
            self.queuePendingBatchPresentationReset();
            self.placeholder_scene.valid = false;
            var output_writer = self.batch_writer.?.writerStreaming(&.{});
            if (self.frame_builder.renderExternalFramebufferBatch(&self.logger, &self.batch_sink.?, width, height, format, pixels, &output_writer.interface)) |frame| {
                if (self.batch_sink.?.placeholder == null and self.observation_enabled) self.observation.retain(self.allocator, frame.width, frame.height, frame.rgba) catch {};
            }
            var virtual_tty = self.batchVirtualTty();
            const layout = self.frame_builder.presentationLayoutForExternalFramebuffer(&virtual_tty);
            self.updateBatchInputTargetFromLayout(&self.batch_sink.?, layout);
            self.writeExternalFramebufferBatchPresentationStatus(width, height);
            const duration = system_io.time.nanoTimestamp() - start_ns;
            self.traceBlockingSpan("batch_present", "present_external_framebuffer_locked", duration);
            self.notePresentDuration(duration);
            return;
        }
        if (!(self.active and self.tty != null and self.engine != null and self.backend != null)) return;
        const start_ns = system_io.time.nanoTimestamp();
        self.refreshTerminalSizeIfNeeded();
        self.frame_builder.presentExternalFramebuffer(&self.logger, &self.tty.?, &self.engine.?, &self.backend.?, width, height, format, pixels, self.cursor_state.snapshot(), self.debug_protocol_replies, self.image_gc);
        self.notePresentationLayout(self.frame_builder.presentationLayoutForExternalFramebuffer(&self.tty.?));
        const duration = system_io.time.nanoTimestamp() - start_ns;
        self.notePresentDuration(duration);
    }

    pub fn createRenderer(self: *Runtime, window: core.CoreHandle, renderer: core.CoreHandle) void {
        if (self.batch_sink != null and self.batch_writer != null) {
            self.lockPresentation("create_renderer");
            defer self.presentation_mutex.unlock();
            var output_writer = self.batch_writer.?.writerStreaming(&.{});
            self.frame_builder.flushBatchDeletesForRenderer(&self.logger, &self.batch_sink.?, renderer, &output_writer.interface);
            self.frame_builder.onCreateRenderer(window, renderer);
            return;
        }
        self.frame_builder.onCreateRenderer(window, renderer);
    }

    pub fn destroyRenderer(self: *Runtime, renderer: core.CoreHandle) void {
        if (self.batch_sink != null and self.batch_writer != null) {
            self.lockPresentation("destroy_renderer");
            defer self.presentation_mutex.unlock();
            var output_writer = self.batch_writer.?.writerStreaming(&.{});
            self.frame_builder.flushBatchDeletesForRenderer(&self.logger, &self.batch_sink.?, renderer, &output_writer.interface);
            self.frame_builder.onDestroyRenderer(renderer);
            return;
        }
        self.frame_builder.onDestroyRenderer(renderer);
    }

    pub fn renderBatchPresent(self: *Runtime, renderer: core.CoreHandle) void {
        if (!(self.active and self.batch_sink != null and self.batch_writer != null)) return;
        self.lockPresentation("render_batch_present");
        defer self.presentation_mutex.unlock();
        if (!(self.active and self.batch_sink != null and self.batch_writer != null)) return;
        self.pollBatchControlLocked();
        self.waitForInitialBatchAttach();
        if (!self.shouldPresent()) return;
        if (!self.terminalRenderingEnabled()) {
            self.notePresentationLayout(.{});
            return;
        }
        if (!self.batch_sink.?.isAttached()) return;

        const start_ns = system_io.time.nanoTimestamp();
        var virtual_tty = self.batchVirtualTty();
        var job = (if (self.batch_sink.?.placeholder != null)
            self.buildPlaceholderJob(renderer)
        else
            self.frame_builder.buildPresentJob(&self.logger, &virtual_tty, renderer, self.bg_only, self.cursor_state.snapshot())) catch |err| {
            self.logger.writeFmtScoped(.info, .runtime, "batch buildPresentJob failed: {any}", .{err});
            return;
        };
        defer job.deinit(self.allocator);
        if (self.batch_sink.?.placeholder == null and self.observation_enabled) {
            switch (job) {
                .framebuffer => |fb| self.observation.retain(self.allocator, fb.width, fb.height, fb.rgba) catch {},
                .scene => {
                    if (self.frame_builder.buildContentFrame(&self.logger, renderer, self.cursor_state.snapshot())) |fb| {
                        self.observation.retain(self.allocator, fb.width, fb.height, fb.rgba) catch {};
                    } else |_| self.observation.pixels.clearRetainingCapacity();
                },
            }
        }
        self.queuePendingBatchPresentationReset();
        var output_writer = self.batch_writer.?.writerStreaming(&.{});
        self.frame_builder.renderPresentJobBatch(&self.logger, &self.batch_sink.?, renderer, &job, &output_writer.interface);
        const layout = self.frame_builder.presentationLayoutForRenderer(&virtual_tty, renderer);
        self.writeBatchPresentationStatus(renderer, &job);
        self.updateBatchInputTargetFromLayout(&self.batch_sink.?, layout);
        const duration = system_io.time.nanoTimestamp() - start_ns;
        self.traceBlockingSpan("batch_present", "render_batch_present_locked", duration);
        self.notePresentDuration(duration);
    }

    pub fn renderPublishedPresent(self: *Runtime, renderer: core.CoreHandle) void {
        if (jackstay.enabled) {
            if (!self.active or self.publisher == null) return;
            self.lockPresentation("publish_renderer");
            defer self.presentation_mutex.unlock();
            defer self.frame_builder.finishContentFrame(renderer);
            if (!self.shouldPresent()) return;
            var frame = self.frame_builder.buildContentFrame(&self.logger, renderer, self.cursor_state.snapshot()) catch |err| {
                log.warn("Jackstay composition failed: {any}", .{err});
                return;
            };
            defer frame.deinit(self.allocator);
            self.publishContent(frame.width, frame.height, frame.rgba);
        }
    }

    fn publishContent(self: *Runtime, width: i32, height: i32, pixels: []const u8) void {
        if (jackstay.enabled) {
            self.publication_sequence +%= 1;
            _ = self.publisher.?.publish(.{
                .width = @intCast(width),
                .height = @intCast(height),
                .stride = @as(u32, @intCast(width)) * 4,
                .format = .rgba8,
                .pixels = pixels,
                .sequence = self.publication_sequence,
                .clock = .unix_time,
                .timestamp_ns = @intCast(@max(0, system_io.time.nanoTimestamp())),
            }) catch |err| log.warn("Jackstay publication failed: {any}", .{err});
        }
    }

    fn buildPlaceholderJob(self: *Runtime, renderer: core.CoreHandle) !PresentJob {
        try self.placeholder_scene.capture(&self.frame_builder, renderer, self.cursor_state.snapshot());
        return .{ .framebuffer = try self.placeholder_scene.presentation(self.allocator, self.batch_sink.?.placeholder.?) };
    }

    fn writeBatchPresentationStatus(self: *Runtime, renderer: core.CoreHandle, job: *const PresentJob) void {
        const sink = &(self.batch_sink orelse return);
        const status = self.frame_builder.batchPresentationStatusForRenderer(sink, renderer, job) orelse return;
        self.writeBatchPresentationStatusView(status);
    }

    fn writeExternalFramebufferBatchPresentationStatus(self: *Runtime, width: i32, height: i32) void {
        const sink = &(self.batch_sink orelse return);
        const status = self.frame_builder.batchPresentationStatusForExternalFramebuffer(sink, width, height) orelse return;
        self.writeBatchPresentationStatusView(status);
    }

    fn writeBatchPresentationStatusView(self: *Runtime, value: render_batch_protocol.PresentationStatusView) void {
        var status = value;
        status.input_supported = self.input_supported;
        if (self.last_batch_presentation_status) |previous| {
            if (presentationStatusEqual(previous, status)) return;
        }
        const writer = self.batch_writer orelse return;
        var output_writer = writer.writerStreaming(&.{});
        render_batch_protocol.writePresentationStatusJsonl(&output_writer.interface, status) catch |err| {
            self.logger.writeFmtScoped(.info, .runtime, "batch presentation status write failed: {any}", .{err});
            return;
        };
        self.last_batch_presentation_status = status;
    }

    fn waitForInitialBatchAttach(self: *Runtime) void {
        if (self.batch_sink == null or self.batch_sink.?.isAttached()) return;
        const deadline = system_io.time.nanoTimestamp() + 100 * std.time.ns_per_ms;
        while (system_io.time.nanoTimestamp() < deadline) {
            system_io.time.sleep(std.time.ns_per_ms);
            self.pollBatchControlLocked();
            if (self.batch_sink == null or self.batch_sink.?.isAttached()) return;
        }
    }

    pub fn externalFramebufferUploadSize(self: *Runtime, source_w: i32, source_h: i32) PixelSize {
        if (self.batch_sink) |*sink| {
            self.lockPresentation("external_framebuffer_upload_size");
            defer self.presentation_mutex.unlock();
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
        self.lockInput("update_input_target");
        defer self.input_mutex.unlock();
        var parser = &(self.input_parser orelse return);
        const tty = self.tty orelse return;
        parser.setTarget(buildInputTarget(&tty, self.input_window_w, self.input_window_h, self.presentation_layout));
    }

    pub fn pollBatchControl(self: *Runtime) void {
        self.lockPresentation("poll_batch_control");
        defer self.presentation_mutex.unlock();
        self.pollBatchControlLocked();
    }

    fn pollBatchControlLocked(self: *Runtime) void {
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
            if (n == 0) {
                self.host_closed = true;
                return;
            }
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
                self.placeholder_scene.valid = false;
                if (!self.advanceBatchGeneration(sink, attach.presentation_generation)) return;
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
                if (sink.isAttached()) {
                    var file_output_7 = self.batch_writer.?.writerStreaming(&.{});
                    self.frame_builder.flushBatchDeletesForPresentationReset(&self.logger, sink, &file_output_7.interface);
                }
                sink.placeholder = attach.placeholder;
                self.batch_presentation_reset_pending = false;
                sink.attachWithPresentation(attach.rect_cells, attach.aspect, attach.z_base);
                self.last_batch_presentation_status = null;
                sink.setTerminalGeometry(attach.terminal);
                sink.setOcclusionRects(attach.occlusion_rects) catch |err| {
                    log.warn("batch occlusion policy failed: {any}", .{err});
                    return;
                };
                sink.setClipCells(attach.clip_cells);
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
                // Presentation kind and image ownership change only through attach.
                if (sink.placeholder != null or viewport.placeholder != null) {
                    const target = viewport.placeholder orelse return;
                    const current = sink.placeholder orelse return;
                    if (target.image_id != current.image_id) return;
                    if (!self.advanceBatchGeneration(sink, viewport.presentation_generation)) return;
                    sink.placeholder = target;
                    sink.viewportWithPresentation(target.localRect(), .stretch, 0);
                    self.last_batch_presentation_status = null;
                    if (!std.meta.eql(current.target_px, target.target_px) and self.placeholder_scene.valid) {
                        const frame = self.placeholder_scene.presentation(self.allocator, target) catch return;
                        sink.presentPlaceholder(frame.rgba, frame.width, frame.height) catch return;
                    } else if (viewport.refresh_placements or !std.meta.eql(current.target_px, target.target_px)) {
                        sink.restorePlaceholder() catch return;
                    } else sink.refreshPlaceholder() catch return;
                    if (sink.hasPendingBytes()) {
                        var file_output_8 = self.batch_writer.?.writerStreaming(&.{});
                        sink.flushFrame(&file_output_8.interface) catch return;
                    }
                    self.updateBatchInputTarget(sink);
                    return;
                }
                const previous = sink.presentationRect();
                const previous_aspect = sink.presentationAspect();
                const previous_z_base = sink.presentationZBase();
                const previous_terminal = sink.terminalGeometry();
                const previous_occlusions = sink.occlusionRects();
                const previous_clip = sink.clipCells();
                const generation_changed = sink.presentation_generation != viewport.presentation_generation;
                if (!self.advanceBatchGeneration(sink, viewport.presentation_generation)) return;
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
                const occlusions_changed = !presentationRectsEqual(previous_occlusions, viewport.occlusion_rects);
                const clip_changed = !std.meta.eql(previous_clip, viewport.clip_cells);
                const presentation_changed = !std.meta.eql(previous, viewport.rect_cells) or previous_aspect != viewport.aspect or previous_z_base != viewport.z_base or terminal_changed or occlusions_changed or clip_changed or generation_changed or viewport.refresh_placements;
                if (presentation_changed) {
                    self.batch_presentation_reset_pending = true;
                    self.last_batch_presentation_status = null;
                }
                sink.viewportWithPresentation(viewport.rect_cells, viewport.aspect, viewport.z_base);
                if (viewport.terminal != null) sink.setTerminalGeometry(viewport.terminal);
                sink.setOcclusionRects(viewport.occlusion_rects) catch |err| {
                    log.warn("batch viewport occlusion policy failed: {any}", .{err});
                    return;
                };
                sink.setClipCells(viewport.clip_cells);
                var reprojected_flag = false;
                if (presentation_changed) {
                    if (self.batch_writer) |writer| {
                        var file_output_9 = writer.writerStreaming(&.{});
                        if (self.frame_builder.flushBatchPresentationReproject(&self.logger, sink, &file_output_9.interface)) {
                            self.batch_presentation_reset_pending = false;
                            reprojected_flag = true;
                        }
                    }
                }
                const applied = sink.presentationRect();
                self.updateBatchInputTarget(sink);
                if (viewport.clip_cells) |clip| {
                    log.info(
                        "batch viewport applied rect=({d},{d} {d}x{d}) clip=({d},{d} {d}x{d}) reproject={any}",
                        .{ applied.row, applied.col, applied.cols, applied.rows, clip.row, clip.col, clip.cols, clip.rows, reprojected_flag },
                    );
                } else {
                    log.info(
                        "batch viewport applied rect=({d},{d} {d}x{d}) clip=none reproject={any}",
                        .{ applied.row, applied.col, applied.cols, applied.rows, reprojected_flag },
                    );
                }
            },
            .discard_batch => |seq| sink.discardBatch(seq),
            .observe => |request| {
                const output = self.batch_writer orelse return;
                var writer_state = output.writerStreaming(&.{});
                const writer = &writer_state.interface;
                const observation = if (sink.placeholder != null and self.placeholder_scene.valid) self.placeholder_scene.observation(self.allocator) catch return else if (sink.placeholder != null) &sink.placeholder_frame else &self.observation;
                const result = switch (request.format) {
                    .rgba => observation.writeRgba(self.io, request.path),
                    .png => observation.writePng(self.io, self.allocator, request.path),
                };
                result catch |err| {
                    writer.print("{{\"type\":\"observation\",\"request_id\":{d},\"error\":\"{s}\"}}\n", .{ request.request_id, @errorName(err) }) catch {};
                    return;
                };
                writer.print("{{\"type\":\"observation\",\"request_id\":{d},\"width\":{d},\"height\":{d},\"frame_id\":{d},\"timestamp_ms\":{d}}}\n", .{
                    request.request_id, observation.width, observation.height, observation.frame_id, observation.timestamp_ms,
                }) catch {};
            },
            .input => |input| {
                if (!self.input_enabled) return;
                self.lockInput("apply_batch_control_input");
                defer self.input_mutex.unlock();
                var parser = &(self.input_parser orelse return);
                switch (input.payload) {
                    .key => |key| parser.injectKey(key) catch |err| {
                        log.warn("batch key inject failed: {any}", .{err});
                        return;
                    },
                    .terminal_bytes => |bytes| {
                        parser.feed(bytes) catch |err| {
                            log.warn("batch input parse failed: {any}", .{err});
                            return;
                        };
                    },
                    .source_pointer => |event| {
                        parser.injectSourcePointer(event) catch |err| {
                            log.warn("source pointer inject failed: {any}", .{err});
                            return;
                        };
                    },
                    .pointer => |event| {
                        parser.injectPointer(event) catch |err| {
                            log.warn("batch input pointer inject failed: {any}", .{err});
                            return;
                        };
                    },
                }
                if (parser.takeMouseActivity()) self.mouse_ownership.claimTerminal();
            },
            .detach => {
                if (self.input_parser) |*model| {
                    model.focus_generation +%= 1;
                }
                self.placeholder_scene.valid = false;
                self.detachBatchWindow(sink, "main");
            },
            .shutdown => {
                self.input_mutex.lock();
                if (self.input_parser) |*model| model.requestQuit() catch {};
                self.input_mutex.unlock();
                self.host_closed = true;
                self.detachBatchWindow(sink, "main");
            },
        }
    }

    // Called under presentation_mutex, before changing geometry. Pending bytes
    // retain the generation under which they were composed, including uploads
    // and deletes the host must process even if it rejects stale placements.
    fn advanceBatchGeneration(self: *Runtime, sink: *RenderBatchSink, generation: u64) bool {
        if (sink.presentation_generation == generation) return true;
        if (sink.hasPendingBytes()) {
            const writer = self.batch_writer orelse return false;
            var output_writer = writer.writerStreaming(&.{});
            sink.flushFrame(&output_writer.interface) catch |err| {
                log.warn("batch generation flush failed: {any}", .{err});
                return false;
            };
        }
        sink.presentation_generation = generation;
        return true;
    }

    fn detachBatchWindow(self: *Runtime, sink: *RenderBatchSink, window_id: []const u8) void {
        const previous = sink.presentationRect();
        log.info(
            "batch detach window={s} rect=({d},{d} {d}x{d}) aspect={s}",
            .{ window_id, previous.row, previous.col, previous.cols, previous.rows, @tagName(sink.presentationAspect()) },
        );
        if (self.batch_writer) |writer| {
            var file_writer_state = writer.writerStreaming(&.{});
            const file_writer = &file_writer_state.interface;
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
        self.lockInput("update_batch_input_target");
        defer self.input_mutex.unlock();
        var parser = &(self.input_parser orelse return);
        const rect = sink.presentationRect();
        var layout = presentation_layout_mod.PresentationLayout{};
        for (relative_layout.regions[0..relative_layout.len]) |region| {
            var translated = region;
            translated.tty_rect.col += rect.col - 1;
            translated.tty_rect.row += rect.row - 1;
            layout.addRegion(translated);
        }
        if (layout.len == 0 or sink.placeholder != null) {
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
            .source_px = if (self.last_batch_presentation_status) |status| status.source_px else null,
            .cell_px = if (sink.terminalGeometry()) |geometry| (if (geometry.pixels) |px| cellPixels(geometry.cells.cols, geometry.cells.rows, px.w, px.h) else null) else null,
            .pixel_origin = mousePixelOrigin(),
        });
    }

    fn maybeReportProducerStats(self: *Runtime) void {
        if (!self.producer_stats.enabled) return;
        const now = system_io.time.nanoTimestamp();
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
        const now = system_io.time.nanoTimestamp();
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
        self.next_present_ns = system_io.time.nanoTimestamp() + extra;
    }

    pub fn rememberQueuedLock(self: *Runtime, texture: core.CoreHandle, rect: ?core.CoreRect, pixels: ?*anyopaque, pitch: i32) void {
        if (texture == 0) return;
        self.lockQueue("remember_queued_lock");
        defer self.queue_mutex.unlock();
        self.queued_lock_captures.put(texture, .{ .rect = rect, .pixels = pixels, .pitch = pitch }) catch |err| {
            log.warn("failed to remember queued lock capture: {any}", .{err});
        };
    }

    pub fn takeQueuedLock(self: *Runtime, texture: core.CoreHandle) ?QueuedLockCapture {
        if (texture == 0) return null;
        self.lockQueue("take_queued_lock");
        defer self.queue_mutex.unlock();
        if (self.queued_lock_captures.fetchRemove(texture)) |entry| return entry.value;
        return null;
    }

    pub fn currentQueueDepth(self: *Runtime) usize {
        self.lockQueue("current_queue_depth");
        defer self.queue_mutex.unlock();
        return self.queue.items.len - self.queue_head;
    }

    pub fn enqueueCommand(self: *Runtime, cmd: Command) void {
        self.lockQueue("enqueue_command");
        defer self.queue_mutex.unlock();
        var owned = cmd;
        if (self.shutdown_worker) {
            self.recycleCommandLocked(&owned);
            return;
        }
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

    fn takeQueuedCommandLocked(self: *Runtime) Command {
        const cmd = self.queue.items[self.queue_head];
        const cmd_is_present = isPresentCommand(cmd);
        const cmd_is_frame_local = isFrameLocalCommand(cmd);
        self.queue_head += 1;
        if (cmd_is_present) {
            if (self.pending_presents > 0) self.pending_presents -= 1;
        }
        if (cmd_is_frame_local or textureUpload(cmd) != null) {
            self.worker_frame_active = true;
        }
        self.maybeCompactQueue();
        return cmd;
    }

    pub fn noteRendererOutputSize(self: *Runtime, renderer: core.CoreHandle, w: i32, h: i32) void {
        if (renderer == 0 or w <= 0 or h <= 0) return;
        const size = PixelSize{ .w = w, .h = h };
        self.queue_mutex.lock();
        if (self.renderer_output_sizes.get(renderer)) |previous| {
            if (std.meta.eql(previous, size)) {
                self.queue_mutex.unlock();
                return;
            }
        }
        // Deduplication is best-effort. A failed cache allocation must not
        // suppress the size update needed for correct composition and input.
        self.renderer_output_sizes.put(self.allocator, renderer, size) catch {};
        self.queue_mutex.unlock();
        log.debug("renderer output size renderer={x} pixels={d}x{d}", .{ renderer, w, h });
        const cmd = Command{ .renderer_output_size = .{ .renderer = renderer, .w = w, .h = h } };
        switch (self.intercept_mode) {
            .sync_compose => core_dispatch.handleCommand(self, cmd),
            .queued_replay => self.enqueueCommand(cmd),
        }
    }

    pub fn forgetRendererOutputSize(self: *Runtime, renderer: core.CoreHandle) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        _ = self.renderer_output_sizes.remove(renderer);
    }

    pub fn acquirePayloadBuffer(self: *Runtime, len: usize) ![]u8 {
        return self.payload_pool.acquire(self.allocator, len);
    }

    pub fn copyPayloads(self: *Runtime, comptime n: usize, sources: [n]?[]const u8) ![n]?[]u8 {
        return self.payload_pool.copyMany(self.allocator, n, sources);
    }

    pub fn recycleCommand(self: *Runtime, cmd: *Command) void {
        self.lockQueue("recycle_command");
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
        // Finish the frame already consumed by the worker, but allow retirement
        // of later complete frames while it is busy composing that first frame.
        var drop_start = self.queue_head;
        if (self.worker_frame_active) {
            while (drop_start < self.queue.items.len) : (drop_start += 1) {
                if (isPresentCommand(self.queue.items[drop_start])) {
                    drop_start += 1;
                    break;
                }
            }
        }
        var last_present_idx: ?usize = null;
        for (self.queue.items[drop_start..], drop_start..) |cmd, idx| {
            if (isPresentCommand(cmd)) last_present_idx = idx;
        }
        const cutoff = last_present_idx orelse return;
        var write_idx = drop_start;
        var dropped_any = false;
        var idx = drop_start;
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
        self.retireSupersededUploads();
        self.pending_presents = 0;
        for (self.queue.items[self.queue_head..]) |queued| {
            if (isPresentCommand(queued)) self.pending_presents += 1;
        }
        if (dropped_any) log.info("dropped stale queued frame-local commands before latest present", .{});
    }

    fn retireSupersededUploads(self: *Runtime) void {
        // Only cross other uploads. Any draw, present, resource lifecycle, or
        // state command is a barrier. This deliberately favors retaining an
        // uncertain dependency over changing the image a surviving draw sees.
        var replacements = std.AutoHashMap(core.CoreHandle, void).init(self.allocator);
        defer replacements.deinit();
        var write_idx = self.queue.items.len;
        var idx = self.queue.items.len;
        while (idx > self.queue_head) {
            idx -= 1;
            const cmd = self.queue.items[idx];
            if (textureUpload(cmd)) |upload| {
                if (replacements.contains(upload.texture)) {
                    var doomed = cmd;
                    self.recycleCommandLocked(&doomed);
                    continue;
                }
                if (upload.full) replacements.put(upload.texture, {}) catch {};
            } else {
                replacements.clearRetainingCapacity();
            }
            write_idx -= 1;
            self.queue.items[write_idx] = cmd;
        }
        const retained = self.queue.items.len - write_idx;
        std.mem.copyForwards(Command, self.queue.items[self.queue_head..][0..retained], self.queue.items[write_idx..]);
        self.queue.items.len = self.queue_head + retained;
    }
};

fn textureUpload(cmd: Command) ?struct { texture: core.CoreHandle, full: bool } {
    return switch (cmd) {
        .update_texture => |c| .{ .texture = c.texture, .full = c.rect == null and c.pixels != null },
        .update_yuv_texture => |c| .{ .texture = c.texture, .full = c.rect == null and c.yplane != null and c.uplane != null and c.vplane != null },
        .update_nv_texture => |c| .{ .texture = c.texture, .full = c.rect == null and c.yplane != null and c.uvplane != null },
        else => null,
    };
}

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

test "stalled replay consumer retains only latest full video upload" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    for (0..100) |frame| {
        const pixels = try runtime.acquirePayloadBuffer(4);
        @memset(pixels, @intCast(frame));
        runtime.enqueueCommand(.{ .update_texture = .{ .texture = 1, .rect = null, .pixels = pixels, .pitch = 4 } });
        runtime.enqueueCommand(.{ .render_copy = .{ .renderer = 2, .texture = 1, .src = null, .dst = null } });
        runtime.enqueueCommand(.{ .render_present = .{ .renderer = 2 } });
    }
    var uploads: usize = 0;
    for (runtime.queue.items[runtime.queue_head..]) |cmd| {
        if (cmd == .update_texture) {
            uploads += 1;
            try std.testing.expectEqual(@as(u8, 99), cmd.update_texture.pixels.?[0]);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), uploads);
}

fn enqueueTestUpload(rt: *Runtime, value: u8, rect: ?core.CoreRect) !void {
    const pixels = try rt.acquirePayloadBuffer(4);
    @memset(pixels, value);
    rt.enqueueCommand(.{ .update_texture = .{ .texture = 1, .rect = rect, .pixels = pixels, .pitch = 4 } });
}

fn enqueueTestDraw(rt: *Runtime) void {
    rt.enqueueCommand(.{ .render_copy = .{ .renderer = 2, .texture = 1, .src = null, .dst = null } });
    rt.enqueueCommand(.{ .render_present = .{ .renderer = 2 } });
}

test "texture conversion in flight protects its draw and present" {
    var rt = Runtime.initShutdownStub();
    defer rt.deinit();
    try enqueueTestUpload(&rt, 0, null);
    enqueueTestDraw(&rt);
    rt.queue_mutex.lock();
    var converting = rt.takeQueuedCommandLocked();
    rt.queue_mutex.unlock();
    defer rt.recycleCommand(&converting);
    for (1..10) |frame| {
        try enqueueTestUpload(&rt, @intCast(frame), null);
        enqueueTestDraw(&rt);
    }
    try std.testing.expectEqual(@as(usize, 2), rt.pending_presents);
    try std.testing.expect(rt.queue.items[rt.queue_head] == .render_copy);
    try std.testing.expect(rt.queue.items[rt.queue_head + 1] == .render_present);
}

test "busy worker keeps its frame while later video uploads are superseded" {
    var rt = Runtime.initShutdownStub();
    defer rt.deinit();
    try enqueueTestUpload(&rt, 0, null);
    enqueueTestDraw(&rt);
    // The worker has started this frame. Its pending upload and present must
    // survive even while later frames accumulate behind it.
    rt.worker_frame_active = true;
    for (1..100) |frame| {
        try enqueueTestUpload(&rt, @intCast(frame), null);
        enqueueTestDraw(&rt);
    }
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(std.testing.allocator);
    for (rt.queue.items[rt.queue_head..]) |cmd| {
        if (cmd == .update_texture) try values.append(std.testing.allocator, cmd.update_texture.pixels.?[0]);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0, 99 }, values.items);
    try std.testing.expectEqual(@as(usize, 2), rt.pending_presents);
    try std.testing.expectEqual(@as(usize, 8), rt.payload_pool.live_bytes);
}

test "partial texture updates survive skipped draws until a full replacement" {
    var rt = Runtime.initShutdownStub();
    defer rt.deinit();
    try enqueueTestUpload(&rt, 1, null);
    enqueueTestDraw(&rt);
    try enqueueTestUpload(&rt, 2, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    enqueueTestDraw(&rt);
    try std.testing.expectEqual(@as(usize, 8), rt.payload_pool.live_bytes);
    try std.testing.expectEqual(@as(u8, 1), rt.queue.items[0].update_texture.pixels.?[0]);
    try std.testing.expectEqual(@as(u8, 2), rt.queue.items[1].update_texture.pixels.?[0]);
    try enqueueTestUpload(&rt, 3, null);
    enqueueTestDraw(&rt);
    try std.testing.expectEqual(@as(usize, 4), rt.payload_pool.live_bytes);
    try std.testing.expectEqual(@as(u8, 3), rt.queue.items[0].update_texture.pixels.?[0]);
}

test "upload retirement preserves surviving draws and resource lifetime barriers" {
    const barriers = [_]Command{
        .{ .render_copy = .{ .renderer = 2, .texture = 1, .src = null, .dst = null } },
        .{ .render_copy_ex = .{ .renderer = 2, .texture = 1, .src = null, .dst = null, .angle = 0, .center = null, .flip = 0 } },
        .{ .render_present = .{ .renderer = 2 } },
        .{ .destroy_texture = .{ .texture = 1 } },
        .{ .create_texture = .{ .texture = 1, .format = core.pixelFormat(.rgba8, .{ .sdl2 = 376840196 }), .w = 1, .h = 1 } },
        .{ .set_texture_color_mod = .{ .texture = 1, .r = 1, .g = 2, .b = 3 } },
    };
    for (barriers) |barrier| {
        var rt = Runtime.initShutdownStub();
        defer rt.deinit();
        try enqueueTestUpload(&rt, 1, null);
        rt.enqueueCommand(barrier);
        try enqueueTestUpload(&rt, 2, null);
        rt.retireSupersededUploads();
        try std.testing.expectEqual(@as(usize, 3), rt.queue.items.len);
        try std.testing.expectEqual(@as(usize, 8), rt.payload_pool.live_bytes);
    }
}

test "planar video replacements release all obsolete planes" {
    var rt = Runtime.initShutdownStub();
    defer rt.deinit();
    const old = try rt.copyPayloads(3, .{ "yyyy", "u", "v" });
    rt.enqueueCommand(.{ .update_yuv_texture = .{ .texture = 1, .rect = null, .yplane = old[0], .ypitch = 2, .uplane = old[1], .upitch = 1, .vplane = old[2], .vpitch = 1 } });
    enqueueTestDraw(&rt);
    const next = try rt.copyPayloads(3, .{ "YYYY", "U", "V" });
    rt.enqueueCommand(.{ .update_yuv_texture = .{ .texture = 1, .rect = null, .yplane = next[0], .ypitch = 2, .uplane = next[1], .upitch = 1, .vplane = next[2], .vpitch = 1 } });
    enqueueTestDraw(&rt);
    try std.testing.expectEqual(@as(usize, 6), rt.payload_pool.live_bytes);
    try std.testing.expectEqualStrings("YYYY", rt.queue.items[0].update_yuv_texture.yplane.?);
}

test "queued replay does not drop present for a frame already started by worker" {
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const renderer: core.CoreHandle = 0x7777;
    try runtime.queue.append(runtime.allocator, .{ .render_copy = .{
        .renderer = renderer,
        .texture = 0x1234,
        .src = null,
        .dst = null,
    } });
    try runtime.queue.append(runtime.allocator, .{ .render_present = .{ .renderer = renderer } });
    runtime.queue_head = 1;
    runtime.pending_presents = 1;
    runtime.worker_frame_active = true;

    runtime.enqueueCommand(.{ .render_present = .{ .renderer = renderer } });

    try std.testing.expectEqual(@as(usize, 3), runtime.queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.queue_head);
    try std.testing.expect(isPresentCommand(runtime.queue.items[1]));
    try std.testing.expect(isPresentCommand(runtime.queue.items[2]));
    try std.testing.expectEqual(@as(usize, 2), runtime.pending_presents);
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
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.active = true;
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");

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
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.active = true;
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");

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
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);

    runtime.processBatchControlLine("{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":6,\"col\":11,\"rows\":30,\"cols\":80},\"aspect\":\"fit\",\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}");
    runtime.processBatchControlLine("{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":7,\"col\":12,\"rows\":28,\"cols\":76},\"aspect\":\"fit\"}");

    try std.testing.expect(runtime.batch_presentation_reset_pending);
    try std.testing.expect(runtime.batch_sink.?.hasPendingBytes() == false);
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 7, .col = 12, .rows = 28, .cols = 76 }, runtime.batch_sink.?.presentationRect());
}

test "app-side input state reads do not apply batch control messages" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[1]);
    runtime.batch_control = .{ .io = io, .handle = pipe[0] };
    setNonblocking(pipe[0]);
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 6, .col = 11, .rows = 30, .cols = 80 });
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);

    const control_writer = system_io.fs.File{ .io = io, .handle = pipe[1] };
    try control_writer.writeAll(
        "{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":7,\"col\":12,\"rows\":28,\"cols\":76},\"aspect\":\"fit\"}\n",
    );

    _ = runtime.terminalMouseState();
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 6, .col = 11, .rows = 30, .cols = 80 }, runtime.batch_sink.?.presentationRect());

    runtime.pollBatchControl();
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 7, .col = 12, .rows = 28, .cols = 76 }, runtime.batch_sink.?.presentationRect());
}

const MouseStateReadProbe = struct {
    runtime: *Runtime,
    done: *std.atomic.Value(bool),
};

fn readMouseStateForProbe(probe: MouseStateReadProbe) void {
    _ = probe.runtime.terminalMouseState();
    probe.done.store(true, .release);
}

test "app-side input state reads do not wait on presentation work" {
    // Timing-based regression: if input state reads still share the
    // presentation mutex, this thread remains blocked while the test holds it.
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);

    var done = std.atomic.Value(bool).init(false);
    runtime.presentation_mutex.lock();
    const thread = try std.Thread.spawn(.{}, readMouseStateForProbe, .{MouseStateReadProbe{ .runtime = &runtime, .done = &done }});
    system_io.time.sleep(10 * std.time.ns_per_ms);
    try std.testing.expect(done.load(.acquire));
    runtime.presentation_mutex.unlock();
    thread.join();
}

test "batch viewport immediately reprojects retained presentation when writer is available" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    var first_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_out.deinit();
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, &first_out.writer);

    setNonblocking(pipe[0]);
    runtime.processBatchControlLine("{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":5,\"col\":11,\"rows\":20,\"cols\":40},\"aspect\":\"fit\"}");

    var buf: [4096]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"placements\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "c=40,r=15") != null);
    try std.testing.expect(!runtime.batch_presentation_reset_pending);
}

test "batch generation fences pending bytes and refreshes unchanged retained placements" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.processBatchControlLine(
        \\{"type":"attach","window_id":"main","presentation_generation":1,"rect_cells":{"row":5,"col":11,"rows":20,"cols":40},"aspect":"fit","id_ranges":{"image":[[100000,100010]],"placement":[[200000,200010]]}}
    );
    const renderer: core.CoreHandle = 0x7777;
    runtime.frame_builder.onCreateWindow(0x6666, 640, 480);
    runtime.frame_builder.onCreateRenderer(0x6666, renderer);
    runtime.frame_builder.onRenderClear(renderer);
    var tty = runtime.batch_sink.?.presentationTty();
    var job = try runtime.frame_builder.buildPresentJob(&runtime.logger, &tty, renderer, false, null);
    defer job.deinit(runtime.allocator);
    var first = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first.deinit();
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, &first.writer);
    try std.testing.expect(std.mem.indexOf(u8, first.written(), "\"presentation_generation\":1") != null);

    // Pending resource operations must keep their old generation; they cannot
    // silently inherit the next viewport's identity during the eventual flush.
    try runtime.batch_sink.?.deleteImageData(100009);
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","presentation_generation":2,"rect_cells":{"row":5,"col":11,"rows":20,"cols":40},"aspect":"fit"}
    );
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","presentation_generation":2,"refresh_placements":true,"rect_cells":{"row":5,"col":11,"rows":20,"cols":40},"aspect":"fit"}
    );
    // An identical request without refresh must not create another batch.
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","presentation_generation":2,"rect_cells":{"row":5,"col":11,"rows":20,"cols":40},"aspect":"fit"}
    );
    setNonblocking(pipe[0]);
    var buf: [16384]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    const pending = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"presentation_generation\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "i=100009") != null);
    for (0..2) |_| {
        const refresh = lines.next().?;
        try std.testing.expect(std.mem.indexOf(u8, refresh, "\"presentation_generation\":2") != null);
        try std.testing.expect(std.mem.indexOf(u8, refresh, "a=p") != null);
    }
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(!runtime.batch_presentation_reset_pending);
}

test "batch present reports source pixels and effective fitted rect" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"frame_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"presentation_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"ready_to_show\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"source_px\":{\"w\":640,\"h\":480}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"effective_rect_cells\":{\"row\":7,\"col\":11,\"rows\":15,\"cols\":40}") != null);
}

test "batch present emits presentation status only when it changes" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 20, .cols = 40 });

    const window: core.CoreHandle = 0x6683;
    const renderer: core.CoreHandle = 0x7783;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 640, 480);
    runtime.createRenderer(window, renderer);
    runtime.frame_builder.onRenderClear(renderer);

    setNonblocking(pipe[0]);
    runtime.adaptive_present_target_ns = std.time.ns_per_s;
    runtime.renderBatchPresent(renderer);
    runtime.next_present_ns = 0;
    runtime.renderBatchPresent(renderer);
    runtime.processBatchControlLine("{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":5,\"col\":11,\"rows\":18,\"cols\":40},\"aspect\":\"fit\"}");
    runtime.next_present_ns = 0;
    runtime.renderBatchPresent(renderer);

    var buf: [32768]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, buf[0..n], "\"type\":\"frame_batch\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, buf[0..n], "\"type\":\"presentation_status\""));
}

test "external framebuffer batch present reports presentation status" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 20, .cols = 40 });
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });

    var pixels = [_]u8{255} ** (4 * 4 * 4);

    setNonblocking(pipe[0]);
    runtime.presentExternalFramebuffer(4, 4, .rgba8, &pixels);

    var buf: [8192]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"frame_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"type\":\"presentation_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"ready_to_show\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"source_px\":{\"w\":4,\"h\":4}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"effective_rect_cells\":{\"row\":5,\"col\":11,\"rows\":20,\"cols\":40}") != null);
}

test "external framebuffer batch present skips detached sink" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.batch_sink.?.attach(.{ .row = 5, .col = 11, .rows = 20, .cols = 40 });
    runtime.batch_sink.?.detach();

    var pixels = [_]u8{255} ** (4 * 4 * 4);

    setNonblocking(pipe[0]);
    runtime.presentExternalFramebuffer(4, 4, .rgba8, &pixels);

    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, system_io.posix.read(pipe[0], &buf));
}

test "batch present uses host terminal pixels for effective fitted rect" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"effective_rect_cells\":{\"row\":9,\"col\":11,\"rows\":12,\"cols\":40}") != null);
}

test "batch renderer destroy emits retained placement deletes before forgetting state" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    var first_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_out.deinit();
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, &first_out.writer);

    setNonblocking(pipe[0]);
    runtime.destroyRenderer(renderer);

    var buf: [4096]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "p=200000") != null);
}

test "batch runtime deinit emits split placement deletes without renderer destroy" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    var runtime_deinited = false;
    defer if (!runtime_deinited) runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.batch_sink.?.attachWithAspect(.{ .row = 1, .col = 1, .rows = 4, .cols = 4 }, .stretch);
    const occlusions = [_]render_batch_protocol.PresentationRectCells{
        .{ .row = 2, .col = 2, .rows = 2, .cols = 2 },
    };
    try runtime.batch_sink.?.setOcclusionRects(&occlusions);

    const window: core.CoreHandle = 0x6682;
    const renderer: core.CoreHandle = 0x7782;
    runtime.frame_builder.setImageIdRange(.{ .start = 100000, .end = 100010 });
    runtime.frame_builder.setCompositePlacementIdRange(.{ .start = 200000, .end = 200010 });
    runtime.frame_builder.onCreateWindow(window, 4, 4);
    runtime.frame_builder.onCreateRenderer(window, renderer);

    var rgba = [_]u8{255} ** (4 * 4 * 4);
    var job = PresentJob{ .framebuffer = .{ .width = 4, .height = 4, .rgba = &rgba, .owns_rgba = false } };
    var first_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_out.deinit();
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, &first_out.writer);

    setNonblocking(pipe[0]);
    runtime.deinit();
    runtime_deinited = true;

    var buf: [4096]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "i=100000,p=200000") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "i=100000,p=200001") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "i=100000,p=200002") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "i=100000,p=200003") != null);
}

test "batch renderer replacement emits retained placement deletes before overwriting state" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
    var first_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer first_out.deinit();
    runtime.frame_builder.renderPresentJobBatch(&runtime.logger, &runtime.batch_sink.?, renderer, &job, &first_out.writer);

    setNonblocking(pipe[0]);
    runtime.createRenderer(window, renderer);

    var buf: [4096]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "p=200000") != null);
}

test "batch input poll drains control pipe before SDL event reads" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();

    const pipe = try system_io.posix.pipe();
    runtime.batch_control = .{ .io = io, .handle = pipe[0] };
    setNonblocking(runtime.batch_control.?.handle);
    const control_writer = system_io.fs.File{ .io = io, .handle = pipe[1] };
    defer control_writer.close();

    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
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
        .cell_px = cellPixels(tty.cols, tty.rows, tty.pixel_width, tty.pixel_height),
        .pixel_origin = mousePixelOrigin(),
    };
}

fn mousePixelOrigin() i32 {
    return ts_kitty.capabilities.mousePixelOrigin(ts_kitty.capabilities.detectTerminalIdentity());
}

fn cellPixels(cols: i32, rows: i32, pixel_w: i32, pixel_h: i32) ?input_mod.CellPixels {
    if (cols <= 0 or rows <= 0 or pixel_w <= 0 or pixel_h <= 0) return null;
    return .{
        .w = @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(cols)),
        .h = @as(f32, @floatFromInt(pixel_h)) / @as(f32, @floatFromInt(rows)),
    };
}

fn workerMain(runtime: *Runtime) void {
    log.info("queued replay worker started", .{});
    while (true) {
        runtime.pollBatchControl();
        runtime.lockQueue("worker_take_command");
        while (!runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_cond.timedWait(&runtime.queue_mutex, worker_control_poll_interval_ns) catch {};
            if (!runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
                runtime.queue_mutex.unlock();
                runtime.pollBatchControl();
                runtime.lockQueue("worker_recheck_queue");
            }
        }
        if (runtime.shutdown_worker and runtime.queue_head >= runtime.queue.items.len) {
            runtime.queue_mutex.unlock();
            log.info("queued replay worker exiting", .{});
            return;
        }
        var cmd = runtime.takeQueuedCommandLocked();
        const cmd_is_present = isPresentCommand(cmd);
        runtime.queue_mutex.unlock();
        core_dispatch.handleCommand(runtime, cmd);
        runtime.lockQueue("worker_recycle_command");
        if (cmd_is_present) runtime.worker_frame_active = false;
        runtime.recycleCommandLocked(&cmd);
        runtime.queue_mutex.unlock();
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
                    runtime.shutdown_worker = true;
                    runtime.payload_pool.close();
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
    const flags = system_io.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    _ = system_io.posix.fcntl(fd, std.posix.F.SETFL, flags | (1 << @bitOffsetOf(std.posix.O, "NONBLOCK"))) catch {};
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
    const io = runtime.io;
    const tty = runtime.tty.?.file;
    const forced_profile = mapOutputProfile(runtime.forced_output_profile);
    if (!runtime.file_transport_enabled) return .{ .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail };

    const high_water = runtime.file_transport_max_bytes;
    const upload_path = try makeUploadPath(allocator);
    errdefer allocator.free(upload_path);

    const probe_file = try system_io.fs.createFileAbsolute(io, upload_path, .{ .read = true, .truncate = true });
    defer probe_file.close();
    const probe_pixel = [_]u8{ 0, 0, 0, 255 };
    try probe_file.writeAll(&probe_pixel);

    const caps = try ts_kitty.capabilities.probe(allocator, tty, upload_path);
    runtime.terminal_identity = @tagName(caps.terminal);
    log.info("shared memory probe={s}", .{@tagName(caps.shared_memory_rgba.probe)});
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
        .shm => blk: {
            system_io.fs.deleteFileAbsolute(io, upload_path) catch {};
            allocator.free(upload_path);
            break :blk .{ .upload_medium = .shm, .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail };
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
        .shm => .shm,
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

fn presentationRectsEqual(a: []const render_batch_protocol.PresentationRectCells, b: []const render_batch_protocol.PresentationRectCells) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.meta.eql(left, right)) return false;
    }
    return true;
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

test "placeholder runtime composes scenes and resizes without uploading or deleting" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.processBatchControlLine(
        \\{"type":"attach","window_id":"main","placeholder":{"image_id":777,"cols":60,"rows":20}}
    );
    const renderer: core.CoreHandle = 0x7799;
    runtime.frame_builder.onCreateWindow(0x6699, 2, 2);
    runtime.createRenderer(0x6699, renderer);
    runtime.frame_builder.onRenderClear(renderer);
    runtime.renderBatchPresent(renderer);
    setNonblocking(pipe[0]);
    var buf: [8192]u8 = undefined;
    var n = try system_io.posix.read(pipe[0], &buf);
    var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
    const first = lines.next().?;
    var batch = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, first, .{});
    defer batch.deinit();
    const groups = batch.value.object.get("groups").?.object;
    try std.testing.expectEqual(@as(usize, 1), groups.get("uploads").?.array.items.len);
    const placement = groups.get("placements").?.array.items[0].string;
    try std.testing.expectEqualStrings("\x1b_Ga=p,U=1,i=777,p=1,c=60,r=20,q=2;\x1b\\", placement);
    try std.testing.expect(std.mem.indexOf(u8, groups.get("uploads").?.array.items[0].string, "s=2,v=2,i=777") != null);
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","placeholder":{"image_id":777,"cols":40,"rows":12}}
    );
    n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "c=40,r=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=d") == null);
    // A terminal clear can discard image data while the app is stationary.
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","placeholder":{"image_id":777,"cols":40,"rows":12},"refresh_placements":true}
    );
    n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "c=40,r=12") != null);
    runtime.processBatchControlLine(
        \\{"type":"viewport","window_id":"main","placeholder":{"image_id":778,"cols":40,"rows":12}}
    );
    try std.testing.expectEqual(@as(u32, 777), runtime.batch_sink.?.placeholder.?.image_id);
    runtime.processBatchControlLine("{\"type\":\"detach\",\"window_id\":\"main\"}");
    n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "d=I,i=777") != null);
    try std.testing.expect(!runtime.batch_sink.?.isAttached());
}

test "placeholder input maps the whole local grid independently of scene layout" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    runtime.input_enabled = true;
    runtime.input_parser = input_mod.TerminalInputParser.init(runtime.allocator);
    runtime.input_window_w = 800;
    runtime.input_window_h = 400;
    var sink = RenderBatchSink.init(io, runtime.allocator, "main");
    defer sink.deinit();
    sink.placeholder = .{ .image_id = 42, .cols = 40, .rows = 10 };
    sink.attach(sink.placeholder.?.localRect());
    var unrelated = presentation_layout_mod.PresentationLayout{};
    unrelated.setSingleSdlRegion(.{ .kind = .sdl_window, .tty_rect = .{ .col = 8, .row = 3, .w = 10, .h = 4 }, .sdl_rect = .{ .x = 0, .y = 0, .w = 800, .h = 400 }, .z = 0 });
    runtime.updateBatchInputTargetFromLayout(&sink, unrelated);
    const target = runtime.input_parser.?.target;
    try std.testing.expectEqual(presentation_layout_mod.Point{ .x = 0, .y = 0 }, target.layout.mapCellToSdl(1, 1).?);
    try std.testing.expect(target.layout.mapCellToSdl(40, 10) != null);
}

test "placeholder presentation uses target pixels without changing source coordinates" {
    const io = std.testing.io;
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    const pipe = try system_io.posix.pipe();
    defer system_io.posix.close(pipe[0]);
    runtime.active = true;
    runtime.batch_writer = .{ .io = io, .handle = pipe[1] };
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    runtime.processBatchControlLine(
        \\{"type":"attach","window_id":"main","placeholder":{"image_id":777,"cols":2,"rows":2,"target_px":{"w":2,"h":2}}}
    );
    runtime.frame_builder.onCreateWindow(0x6699, 4, 4);
    runtime.createRenderer(0x6699, 0x7799);
    runtime.frame_builder.onRenderClear(0x7799);
    runtime.renderBatchPresent(0x7799);
    setNonblocking(pipe[0]);
    var buf: [8192]u8 = undefined;
    const n = try system_io.posix.read(pipe[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "s=2,v=2,i=777") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"source_px\":{\"w\":4,\"h\":4}") != null);
}

test "synchronous external capture receives attach without an SDL renderer or input polling" {
    const io = std.testing.io;
    var tmp = system_io.fs.tmpDir(.{});
    defer tmp.cleanup();
    var runtime = Runtime.initShutdownStub();
    defer runtime.deinit();
    runtime.active = true;
    runtime.input_enabled = false;
    runtime.intercept_mode = .sync_compose;
    runtime.batch_writer = try tmp.dir.createFile("frames", .{});
    runtime.batch_sink = RenderBatchSink.init(io, runtime.allocator, "main");
    const pipe = try system_io.posix.pipe2(.{ .NONBLOCK = true });
    runtime.batch_control = .{ .io = io, .handle = pipe[0] };
    const peer = system_io.fs.File{ .io = io, .handle = pipe[1] };
    defer peer.close();
    try std.testing.expect(!runtime.shouldCaptureExternalFrame());
    try peer.writeAll("{\"type\":\"attach\",\"window_id\":\"main\",\"aspect\":\"fit\",\"rect_cells\":{\"row\":1,\"col\":1,\"rows\":10,\"cols\":20},\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]},\"upload\":{\"profile\":\"direct_apc\",\"high_water\":4096}}\n");
    try std.testing.expect(runtime.shouldCaptureExternalFrame());
    try peer.writeAll("{\"type\":\"detach\",\"window_id\":\"main\"}\n");
    try std.testing.expect(!runtime.shouldCaptureExternalFrame());
}

test "input target carries the terminal cell size when the tty reports pixels" {
    try std.testing.expectEqual(@as(?input_mod.CellPixels, null), cellPixels(80, 24, 0, 0));
    try std.testing.expectEqual(@as(?input_mod.CellPixels, null), cellPixels(0, 24, 800, 480));
    const cell = cellPixels(80, 24, 800, 480).?;
    try std.testing.expectEqual(@as(f32, 10), cell.w);
    try std.testing.expectEqual(@as(f32, 20), cell.h);
}
