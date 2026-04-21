const std = @import("std");
const termscene = @import("termscene/mod.zig");
const core = @import("ttytris_core.zig");
const renderer_mod = @import("ttytris_renderer.zig");

fn kittyDeleteAll(writer: anytype) !void {
    try writer.writeAll("\x1b_Gq=2,a=d,d=A;\x1b\\");
}

fn inputThread(shared: *core.SharedInput) void {
    var stdin = std.fs.File.stdin().deprecatedReader();
    var buf: [16]u8 = undefined;
    while (true) {
        shared.mutex.lock();
        const should_stop = shared.stop;
        shared.mutex.unlock();
        if (should_stop) break;

        const count = stdin.read(&buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            break;
        };
        if (count == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
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

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    const stdout_file = std.fs.File.stdout();
    var writer = stdout_file.deprecatedWriter();
    const stdin_fd = std.fs.File.stdin().handle;

    const original_termios = try std.posix.tcgetattr(stdin_fd);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    if (!try termscene.kitty.detectGraphicsSupport(allocator, writer)) {
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
    var thread = try std.Thread.spawn(.{}, inputThread, .{&shared});
    defer {
        shared.mutex.lock();
        shared.stop = true;
        shared.mutex.unlock();
        thread.join();
    }

    var game = core.Game.init(@intCast(std.time.nanoTimestamp()));
    var timer = try std.time.Timer.start();
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

        std.Thread.sleep(@as(u64, @intFromFloat((1.0 / core.fps) * @as(f32, @floatFromInt(std.time.ns_per_s)))));
    }
}
