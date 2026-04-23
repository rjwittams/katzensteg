const std = @import("std");
const termscene = @import("termscene");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;
const frame_builder_mod = @import("frame_builder.zig");
const FrameBuilder = frame_builder_mod.FrameBuilder;
const CompositeMode = frame_builder_mod.CompositeMode;

const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;

var global_mutex: std.Thread.Mutex = .{};
var global_runtime: ?Runtime = null;
var atexit_registered = false;
extern fn atexit(func: *const fn () callconv(.c) void) c_int;

const RuntimeConfig = struct {
    composite_mode: CompositeMode = .tiled_strip,
    present_fps: u32 = 0,
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
    dump_composites: bool = false,
    debug_composite: bool = false,
    active: bool = false,
    present_interval_ns: i128 = 0,
    adaptive_present_target_ns: i128 = std.time.ns_per_s / 60,
    next_present_ns: i128 = 0,
    skipped_presents: u64 = 0,

    fn init() Runtime {
        const allocator = std.heap.c_allocator;
        var logger = Logger.init(allocator);
        const config = loadConfig(allocator, &logger);
        const bg_only = std.c.getenv("KATZENSTEG_BG_ONLY") != null;
        const stats = std.c.getenv("KATZENSTEG_STATS") != null;
        const debug_protocol_replies = std.c.getenv("KATZENSTEG_KITTY_DEBUG_REPLIES") != null;
        const image_gc = std.c.getenv("KATZENSTEG_IMAGE_GC") != null;
        const dump_composites = std.c.getenv("KATZENSTEG_COMPOSITE_DUMP") != null;
        const debug_composite = std.c.getenv("KATZENSTEG_COMPOSITE_DEBUG") != null;
        var runtime = Runtime{
            .allocator = allocator,
            .logger = logger,
            .frame_builder = FrameBuilder.init(allocator, stats, config.composite_mode, dump_composites, debug_composite),
            .bg_only = bg_only,
            .stats = stats,
            .debug_protocol_replies = debug_protocol_replies,
            .image_gc = image_gc,
            .dump_composites = dump_composites,
            .debug_composite = debug_composite,
            .present_interval_ns = if (config.present_fps > 0) @divTrunc(std.time.ns_per_s, config.present_fps) else 0,
        };
        runtime.tty = DirectTty.init() catch |err| {
            runtime.logger.writeFmt("katzensteg: direct tty init failed: {any}", .{err});
            return runtime;
        };
        runtime.engine = ts_scene.SceneEngine.init(allocator);

        const backend_options = selectBackendOptions(allocator, &runtime) catch |err| blk: {
            runtime.logger.writeFmt("katzensteg: upload transport selection failed; falling back to direct APC: {any}", .{err});
            break :blk ts_kitty.Options{};
        };
        runtime.backend = ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, backend_options) catch |err| blk: {
            runtime.logger.writeFmt("katzensteg: backend init failed: {any}", .{err});
            runtime.logger.write("katzensteg: retrying backend init with direct APC fallback");
            break :blk ts_kitty.Backend.initWithOptions(allocator, runtime.tty.?.file, .{
                .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail,
            }) catch |fallback_err| {
                runtime.logger.writeFmt("katzensteg: direct APC fallback backend init failed: {any}", .{fallback_err});
                return runtime;
            };
        };
        runtime.active = true;
        runtime.logger.write("katzensteg: runtime initialized in direct tty mode");
        switch (backend_options.upload_medium) {
            .direct => runtime.logger.write("katzensteg: upload transport profile = direct_apc"),
            .file_whole => {
                runtime.logger.writeFmt("katzensteg: upload transport profile = file_whole path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
                allocator.free(backend_options.upload_file_path.?);
            },
            .file_offset => {
                runtime.logger.writeFmt("katzensteg: upload transport profile = file_offset_ring path {s} (high-water {d} bytes)", .{ backend_options.upload_file_path.?, backend_options.upload_file_high_water });
                allocator.free(backend_options.upload_file_path.?);
            },
        }
        if (runtime.bg_only) runtime.logger.write("katzensteg: background-only debug mode enabled");
        if (runtime.stats) runtime.logger.write("katzensteg: periodic stats enabled");
        if (runtime.debug_protocol_replies) runtime.logger.write("katzensteg: kitty protocol reply logging enabled (q=0)");
        runtime.logger.writeFmt("katzensteg: composite mode = {s}", .{@tagName(config.composite_mode)});
        if (config.present_fps > 0) runtime.logger.writeFmt("katzensteg: present fps cap = {d}", .{config.present_fps});
        if (runtime.image_gc) runtime.logger.write("katzensteg: old image GC enabled");
        if (runtime.dump_composites) runtime.logger.write("katzensteg: composite framebuffer dump enabled");
        if (runtime.debug_composite) runtime.logger.write("katzensteg: composite debug logging enabled");
        return runtime;
    }

    fn deinit(self: *Runtime) void {
        self.frame_builder.deinit();
        if (self.backend) |*backend| backend.deinit();
        if (self.engine) |*engine| engine.deinit();
        if (self.tty) |*tty| tty.deinit();
        self.logger.deinit();
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
};

pub fn get() *Runtime {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime == null) {
        global_runtime = Runtime.init();
        if (!atexit_registered) {
            _ = atexit(onExit);
            atexit_registered = true;
        }
    }
    return &global_runtime.?;
}

fn loadConfig(allocator: std.mem.Allocator, logger: *Logger) RuntimeConfig {
    var config = RuntimeConfig{};
    if (std.c.getenv("KATZENSTEG_CONFIG")) |path_z| {
        const path = std.mem.span(path_z);
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| {
            logger.writeFmt("katzensteg: failed to read config {s}: {any}", .{ path, err });
            return config;
        };
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
            logger.writeFmt("katzensteg: failed to parse config {s}: {any}", .{ path, err });
            return config;
        };
        defer parsed.deinit();
        if (parsed.value.object.get("composite_mode")) |value| {
            if (value == .string) {
                config.composite_mode = parseCompositeMode(value.string) orelse blk: {
                    logger.writeFmt("katzensteg: unknown composite_mode in config: {s}", .{value.string});
                    break :blk config.composite_mode;
                };
            }
        }
        if (parsed.value.object.get("present_fps")) |value| {
            switch (value) {
                .integer => |n| {
                    if (n > 0) config.present_fps = @intCast(n);
                },
                else => {},
            }
        }
        logger.writeFmt("katzensteg: loaded config from {s}", .{path});
    }
    if (std.c.getenv("KATZENSTEG_COMPOSITE_MODE")) |mode_z| {
        const mode = std.mem.span(mode_z);
        if (parseCompositeMode(mode)) |parsed| {
            config.composite_mode = parsed;
        } else {
            logger.writeFmt("katzensteg: unknown KATZENSTEG_COMPOSITE_MODE value: {s}", .{mode});
        }
    }
    if (std.c.getenv("KATZENSTEG_PRESENT_FPS")) |fps_z| {
        const fps = std.fmt.parseInt(u32, std.mem.span(fps_z), 10) catch 0;
        config.present_fps = fps;
    }
    return config;
}

fn parseCompositeMode(value: []const u8) ?CompositeMode {
    if (std.mem.eql(u8, value, "fullscreen")) return .fullscreen;
    if (std.mem.eql(u8, value, "tiled_strip")) return .tiled_strip;
    return null;
}

fn onExit() callconv(.c) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime) |*runtime| {
        runtime.deinit();
        global_runtime = null;
    }
}

fn selectBackendOptions(allocator: std.mem.Allocator, runtime: *Runtime) !ts_kitty.Options {
    const tty = runtime.tty.?.file;
    const forced_profile = parseForcedOutputProfile();
    const file_transport_env = std.c.getenv("KATZENSTEG_FILE_TRANSPORT");
    const file_transport_disabled = if (file_transport_env) |value|
        std.mem.eql(u8, std.mem.span(value), "0")
    else
        false;
    if (file_transport_disabled) return .{ .quiet = if (runtime.debug_protocol_replies) .none else .suppress_fail };

    const high_water = parseHighWaterBytes();
    const upload_path = try makeUploadPath(allocator);
    errdefer allocator.free(upload_path);

    const probe_file = try std.fs.createFileAbsolute(upload_path, .{ .read = true, .truncate = true });
    defer probe_file.close();
    const probe_pixel = [_]u8{ 0, 0, 0, 255 };
    try probe_file.writeAll(&probe_pixel);

    const caps = try ts_kitty.capabilities.probe(allocator, tty, upload_path);
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

fn parseHighWaterBytes() u64 {
    const default_bytes: u64 = 10 * 1024 * 1024;
    const env_value = std.c.getenv("KATZENSTEG_FILE_TRANSPORT_MAX_BYTES") orelse return default_bytes;
    return std.fmt.parseInt(u64, std.mem.span(env_value), 10) catch default_bytes;
}

fn parseForcedOutputProfile() ?ts_kitty.OutputProfile {
    const env_value = std.c.getenv("KATZENSTEG_OUTPUT_PROFILE") orelse return null;
    const value = std.mem.span(env_value);
    if (std.mem.eql(u8, value, "direct_apc")) return .direct_apc;
    if (std.mem.eql(u8, value, "file_whole")) return .file_whole;
    if (std.mem.eql(u8, value, "file_offset_ring")) return .file_offset_ring;
    return null;
}
