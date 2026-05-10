const std = @import("std");

const cli = @import("cli.zig");
const wm_host = @import("wm_host");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (hasArg(args[1..], "--help") or hasArg(args[1..], "-h")) {
        try std.fs.File.stdout().writeAll(usage_text);
        return;
    }

    var parsed = cli.parse(allocator, args) catch |err| {
        std.debug.print("{s}error: {s}\n", .{ usage_text, @errorName(err) });
        std.process.exit(64);
    };
    defer parsed.deinit();

    const producer_exe = try siblingProducerExecutablePath(allocator);
    defer allocator.free(producer_exe);

    var specs = try allocator.alloc(wm_host.SessionLaunchSpec, parsed.sessions.len);
    defer allocator.free(specs);
    for (parsed.sessions, 0..) |session, i| {
        specs[i] = .{
            .profile_name = session.profile_name,
            .extra_args = session.extra_args,
        };
    }

    const exit_code = try wm_host.runSessionSpecsWithProducerExe(allocator, producer_exe, specs);
    std.process.exit(exit_code);
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn siblingProducerExecutablePath(allocator: std.mem.Allocator) ![]const u8 {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    const dir = std.fs.path.dirname(self_exe) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, "katzensteg" });
}

const usage_text =
    \\Usage:
    \\  katzensteg-wm [profile...]
    \\  katzensteg-wm --session <profile> [-- arg...] [--session <profile> [-- arg...] ...]
    \\
;
