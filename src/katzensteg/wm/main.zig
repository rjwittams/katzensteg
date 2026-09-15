const std = @import("std");
const system_io = @import("platform");

const cli = @import("cli.zig");
const wm_host = @import("wm_host");

pub fn main(process_init: std.process.Init) !void {
    const io = process_init.io;
    const allocator = std.heap.page_allocator;
    const args = try process_init.minimal.args.toSlice(process_init.arena.allocator());

    if (hasArg(args[1..], "--help") or hasArg(args[1..], "-h")) {
        try system_io.fs.File.stdout(io).writeAll(usage_text);
        return;
    }

    var parsed = cli.parse(allocator, args) catch |err| {
        std.debug.print("{s}error: {s}\n", .{ usage_text, @errorName(err) });
        std.process.exit(64);
    };
    defer parsed.deinit();

    const producer_exe = try siblingProducerExecutablePath(io, allocator);
    defer allocator.free(producer_exe);

    if (parsed.headless) {
        var parent_pid = parsed.parent_pid;
        if (parent_pid == null) {
            if (system_io.process.getEnvVarOwned(allocator, "CLAUDE_PID")) |value| {
                defer allocator.free(value);
                parent_pid = std.fmt.parseInt(i32, value, 10) catch null;
            } else |_| {}
        }
        const code = try wm_host.runHeadless(io, allocator, producer_exe, .{
            .http_address = parsed.http_address orelse "127.0.0.1:0",
            .tty_path = parsed.tty_path,
            .host_file = parsed.host_file,
            .parent_pid = parent_pid,
            .background = parsed.background,
            .idle_refresh_ms = parsed.idle_refresh_ms,
        });
        std.process.exit(code);
    }

    var specs = try allocator.alloc(wm_host.SessionLaunchSpec, parsed.sessions.len);
    defer allocator.free(specs);
    for (parsed.sessions, 0..) |session, i| {
        specs[i] = .{
            .profile_name = session.profile_name,
            .extra_args = session.extra_args,
        };
    }

    const exit_code = try wm_host.runSessionSpecsWithOptions(io, allocator, producer_exe, specs, .{
        .listen_path = parsed.listen_path,
        .presentation = switch (parsed.presentation) {
            .positioned => .positioned,
            .placeholder => .placeholder,
        },
    });
    std.process.exit(exit_code);
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn siblingProducerExecutablePath(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const self_exe = try system_io.fs.selfExePathAlloc(io, allocator);
    defer allocator.free(self_exe);

    const dir = std.fs.path.dirname(self_exe) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "katzensteg" });
}

const usage_text =
    \\Usage:
    \\  katzensteg-wm --headless [--background] [--tty <device>] [--parent-pid <pid>] [--http 127.0.0.1:<port>] [--host-file <path>] [--idle-refresh-ms <ms; 0 disables>]
    \\  katzensteg-wm [--presentation positioned|placeholder] [--listen <socket-path>] [profile...]
    \\  katzensteg-wm [--presentation positioned|placeholder] [--listen <socket-path>] --session <profile> [-- arg...] [--session <profile> [-- arg...] ...]
    \\
;
