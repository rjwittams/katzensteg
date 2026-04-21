const std = @import("std");
const termscene = @import("termscene");
const Logger = @import("log.zig").Logger;
const DirectTty = @import("direct_tty.zig").DirectTty;
const FrameBuilder = @import("frame_builder.zig").FrameBuilder;

const ts_scene = termscene.scene;
const ts_kitty = termscene.kitty;

var global_mutex: std.Thread.Mutex = .{};
var global_runtime: ?Runtime = null;
var atexit_registered = false;
extern fn atexit(func: *const fn () callconv(.c) void) c_int;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    logger: Logger,
    tty: ?DirectTty = null,
    engine: ?ts_scene.SceneEngine = null,
    backend: ?ts_kitty.Backend = null,
    frame_builder: FrameBuilder,
    bg_only: bool = false,
    active: bool = false,

    fn init() Runtime {
        const allocator = std.heap.c_allocator;
        const logger = Logger.init(allocator);
        var runtime = Runtime{
            .allocator = allocator,
            .logger = logger,
            .frame_builder = FrameBuilder.init(allocator),
            .bg_only = std.c.getenv("KATZENSTEG_BG_ONLY") != null,
        };
        runtime.tty = DirectTty.init() catch |err| {
            runtime.logger.writeFmt("katzensteg: direct tty init failed: {any}", .{err});
            return runtime;
        };
        runtime.engine = ts_scene.SceneEngine.init(allocator);
        runtime.backend = ts_kitty.Backend.init(allocator, runtime.tty.?.file);
        runtime.active = true;
        runtime.logger.write("katzensteg: runtime initialized in direct tty mode");
        if (runtime.bg_only) runtime.logger.write("katzensteg: background-only debug mode enabled");
        return runtime;
    }

    fn deinit(self: *Runtime) void {
        self.frame_builder.deinit();
        if (self.backend) |*backend| backend.deinit();
        if (self.engine) |*engine| engine.deinit();
        if (self.tty) |*tty| tty.deinit();
        self.logger.deinit();
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

fn onExit() callconv(.c) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_runtime) |*runtime| {
        runtime.deinit();
        global_runtime = null;
    }
}
