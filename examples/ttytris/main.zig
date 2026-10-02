const std = @import("std");
const system_io = @import("platform");
const termscene = @import("termscene");
const core = @import("core.zig");
const renderer_mod = @import("renderer.zig");

fn kittyDeleteAll(writer: anytype) !void {
    try writer.writeAll("\x1b_Gq=2,a=d,d=A;\x1b\\");
}

fn inputThread(io: std.Io, shared: *core.SharedInput) void {
    var stdin = system_io.fs.File.stdin(io);
    var buf: [16]u8 = undefined;
    while (true) {
        shared.mutex.lock();
        const should_stop = shared.stop;
        shared.mutex.unlock();
        if (should_stop) break;

        const count = stdin.read(&buf) catch |err| {
            if (err == error.WouldBlock) {
                system_io.time.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            break;
        };
        if (count == 0) {
            system_io.time.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        shared.mutex.lock();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ch = buf[i];
            switch (ch) {
                'q', 'Q' => shared.state.quit = true,
                'r', 'R' => shared.state.restart = true,
                'z', 'Z' => shared.state.rotate_ccw = true,
                'x', 'X', '\r' => shared.state.rotate_cw = true,
                'c', 'C' => shared.state.hold = true,
                'p', 'P' => shared.state.pause = true,
                '?' => shared.state.help = true,
                ' ' => shared.state.hard_drop = true,
                else => if (ch == 0x1b and i + 2 < count and buf[i + 1] == '[') {
                    switch (buf[i + 2]) {
                        'A' => shared.state.rotate_cw = true,
                        'B' => shared.state.soft_drop = true,
                        'C' => shared.state.right = true,
                        'D' => shared.state.left = true,
                        else => {},
                    }
                    i += 2;
                },
            }
        }
        shared.mutex.unlock();
    }
}

pub fn main(process_init: std.process.Init) !void {
    const io = process_init.io;
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    const stdout_file = system_io.fs.File.stdout(io);
    var writer_state = stdout_file.writerStreaming(&.{});
    const writer = &writer_state.interface;
    const raw_mode = try system_io.terminal.RawMode.enter(system_io.fs.File.stdin(io), stdout_file);
    defer raw_mode.restore();

    if (!try termscene.kitty.detectGraphicsSupport(io, allocator, writer)) {
        std.debug.print("ttytris: kitty graphics protocol not detected in this terminal session. Try `zig build termscene-demo` to verify graphics support and scene rendering in this terminal.\n", .{});
        return;
    }

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer {
        kittyDeleteAll(writer) catch {};
        writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    }

    var renderer = try renderer_mod.Renderer.init(allocator, stdout_file, writer);
    defer renderer.deinit();

    var shared = core.SharedInput{};
    defer shared.mutex.deinit();
    var thread = try std.Thread.spawn(.{}, inputThread, .{io, &shared});
    defer {
        shared.mutex.lock();
        shared.stop = true;
        shared.mutex.unlock();
        thread.join();
    }

    var game = core.Game.init(@intCast(system_io.time.nanoTimestamp()));
    var timer = try system_io.time.Timer.start();
    var elapsed_t: f32 = 0;

    while (true) {
        const dt_ns = timer.lap();
        const dt = @min(@as(f32, @floatFromInt(dt_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s)), 0.05);
        elapsed_t += dt;

        shared.mutex.lock();
        const input = shared.state;
        shared.state = .{};
        shared.mutex.unlock();
        if (input.quit) break;

        game.update(dt, input);
        try renderer.render(writer, &game, elapsed_t);

        system_io.time.sleep(@as(u64, @intFromFloat((1.0 / core.fps) * @as(f32, @floatFromInt(std.time.ns_per_s)))));
    }
}
