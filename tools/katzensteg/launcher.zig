const std = @import("std");
const profiles_mod = @import("launcher_profiles.zig");

const Command = enum {
    help,
    menu,
    run,
    unknown,
};

const ExpansionContext = struct {
    home: []const u8,
    repo: []const u8,
    owns_home: bool = false,
    owns_repo: bool = false,

    fn init(allocator: std.mem.Allocator) !ExpansionContext {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        errdefer allocator.free(home);
        const repo = try resolveRepoRoot(allocator);
        return .{ .home = home, .repo = repo, .owns_home = true, .owns_repo = true };
    }

    fn deinit(self: ExpansionContext, allocator: std.mem.Allocator) void {
        if (self.owns_home) allocator.free(self.home);
        if (self.owns_repo) allocator.free(self.repo);
    }
};

const OutputSpec = union(enum) {
    inherit,
    ignore,
    stdout,
    file: []const u8,

    fn deinit(self: OutputSpec, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |path| allocator.free(path),
            else => {},
        }
    }
};

const ResolvedLaunchPlan = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    target: []const u8,
    argv: [][]const u8,
    cwd: ?[]const u8,
    stdout: OutputSpec,
    stderr: OutputSpec,
    env: []profiles_mod.EnvVar,
    runtime: @import("config.zig").RuntimeConfig,

    fn fromProfile(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext) !ResolvedLaunchPlan {
        var plan = ResolvedLaunchPlan{
            .allocator = allocator,
            .profile_name = try allocator.dupe(u8, profile.name),
            .target = try expandLauncherString(allocator, profile.target, expansion),
            .argv = &.{},
            .cwd = null,
            .stdout = .inherit,
            .stderr = .inherit,
            .env = &.{},
            .runtime = resolvedRuntimeConfig(profile),
        };
        errdefer plan.deinit();

        plan.argv = try buildChildArgv(allocator, profile, expansion);
        if (profile.cwd) |raw| plan.cwd = try expandLauncherString(allocator, raw, expansion);
        plan.stdout = try resolveProfileStdout(allocator, profile, expansion);
        plan.stderr = try resolveProfileStderr(allocator, profile, expansion);
        plan.env = try expandProfileEnv(allocator, profile.env, expansion);
        return plan;
    }

    fn deinit(self: *ResolvedLaunchPlan) void {
        self.allocator.free(self.profile_name);
        self.allocator.free(self.target);
        freeChildArgv(self.allocator, self.argv);
        if (self.cwd) |cwd| self.allocator.free(cwd);
        self.stdout.deinit(self.allocator);
        self.stderr.deinit(self.allocator);
        for (self.env) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.allocator.free(self.env);
    }
};

const FileSink = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},

    fn deinit(self: *FileSink) void {
        self.file.close();
    }

    fn writeAll(self: *FileSink, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.file.writeAll(bytes) catch {};
    }
};

const DrainArgs = struct {
    source: std.fs.File,
    sink: *FileSink,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    switch (parseCommand(args)) {
        .help => try std.fs.File.stdout().writeAll(usageText()),
        .menu => try showProfiles(allocator),
        .run => {
            const target_idx = targetArgIndex(args) orelse unreachable;
            const target = args[target_idx];
            if (hasArg(args[1..], "--dry-run")) {
                try dryRunTarget(allocator, target, args[target_idx + 1 ..]);
                return;
            }
            const exit_code = try runTarget(allocator, target, args[target_idx + 1 ..]);
            std.process.exit(exit_code);
        },
        .unknown => {
            std.debug.print("{s}", .{usageText()});
            std.process.exit(64);
        },
    }
}

fn usageText() []const u8 {
    return
        \\Usage:
        \\  katzensteg --help
        \\  katzensteg [options] <target>
        \\  katzensteg
        \\
        \\Options:
        \\  --dry-run  Resolve the target and print what would run.
        \\
        \\Targets:
        \\  A target can be a named profile or, later, a command/path/URL matched by the launcher.
        \\  With no target, Katzensteg lists available profiles.
        \\
        \\Environment:
        \\  KATZENSTEG_PROFILE_DIR  Override the profile directory.
        \\  KATZENSTEG_REPO         Override {repo}/$ROOT expansion.
        \\
    ;
}

fn parseCommand(args: []const []const u8) Command {
    if (args.len <= 1) return .menu;
    if (hasArg(args[1..], "--help") or hasArg(args[1..], "-h")) return .help;
    if (targetArgIndex(args) != null) return .run;
    return .unknown;
}

fn targetArg(args: []const []const u8) ?[]const u8 {
    const idx = targetArgIndex(args) orelse return null;
    return args[idx];
}

fn targetArgIndex(args: []const []const u8) ?usize {
    if (args.len <= 1) return null;
    var force_command = false;
    for (args[1..], 1..) |arg, idx| {
        if (force_command) return idx;
        if (std.mem.eql(u8, arg, "--")) {
            force_command = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) continue;
        if (std.mem.startsWith(u8, arg, "-")) continue;
        return idx;
    }
    return null;
}

fn hasArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn showProfiles(allocator: std.mem.Allocator) !void {
    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const stdout = std.fs.File.stdout();
    var writer = stdout.writerStreaming(&.{});
    try writer.interface.writeAll("katzensteg profiles:\n");
    for (catalog.profiles) |profile| {
        if (profile.hidden) continue;
        if (profile.target.len == 0) continue;
        try writer.interface.print("  {s}\n", .{profile.name});
    }
    try writer.interface.flush();
}

fn dryRunTarget(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) !void {
    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const profile = catalog.find(target) orelse {
        std.debug.print("katzensteg dry-run\ncommand={s}\nargs={d}\n", .{ target, extra_args.len });
        return;
    };
    if (profile.target.len == 0) {
        std.debug.print("katzensteg: profile is a fragment, not a launch target: {s}\n", .{target});
        std.process.exit(66);
    }

    var expansion = try ExpansionContext.init(allocator);
    defer expansion.deinit(allocator);
    var plan = try ResolvedLaunchPlan.fromProfile(allocator, profile, expansion);
    defer plan.deinit();

    std.debug.print(
        "katzensteg dry-run\nprofile={s}\ntarget={s}\nstdout={s}\nstderr={s}\n",
        .{
            plan.profile_name,
            plan.target,
            outputSpecLabel(plan.stdout),
            outputSpecLabel(plan.stderr),
        },
    );
    std.debug.print("argv:\n", .{});
    for (plan.argv, 0..) |arg, index| {
        std.debug.print("  [{d}] {s}\n", .{ index, arg });
    }
    std.debug.print("env:\n", .{});
    if (plan.env.len == 0) {
        std.debug.print("  <none>\n", .{});
    } else {
        for (plan.env) |entry| {
            std.debug.print("  {s}={s}\n", .{ entry.name, entry.value });
        }
    }
    std.debug.print(
        "runtime:\n  intercept_mode={s}\n  composite_mode={s}\n  window_policy={s}\n  real_window={s}\n  present_fps={d}\n  input={}\n  input_claim={}\n  output_profile={s}\n  gl_capture={s}\n  vulkan_capture={}\n",
        .{
            @tagName(plan.runtime.intercept_mode),
            @tagName(plan.runtime.composite_mode),
            @tagName(plan.runtime.window_policy),
            @tagName(plan.runtime.real_window_visibility),
            plan.runtime.present_fps,
            plan.runtime.input_enabled,
            plan.runtime.input_claimed,
            if (plan.runtime.output_profile) |output_profile| @tagName(output_profile) else "auto",
            @tagName(plan.runtime.gl_capture),
            plan.runtime.vulkan_capture,
        },
    );
}

fn runTarget(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) !u8 {
    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const profile = catalog.find(target) orelse {
        return runCommand(allocator, target, extra_args);
    };
    if (profile.target.len == 0) {
        std.debug.print("katzensteg: profile is a fragment, not a launch target: {s}\n", .{target});
        return 66;
    }

    var expansion = try ExpansionContext.init(allocator);
    defer expansion.deinit(allocator);
    var plan = try ResolvedLaunchPlan.fromProfile(allocator, profile, expansion);
    defer plan.deinit();

    const runtime_config_path = try writeRuntimeConfig(allocator, plan.runtime);
    defer allocator.free(runtime_config_path);
    defer std.fs.deleteFileAbsolute(runtime_config_path) catch {};

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    for (plan.env) |entry| try env_map.put(entry.name, entry.value);
    try env_map.put("KATZENSTEG_CONFIG", runtime_config_path);

    std.debug.print("katzensteg: launching {s}\n", .{plan.profile_name});
    std.debug.print("  target: {s}\n", .{plan.target});
    std.debug.print("  runtime config: {s}\n", .{runtime_config_path});
    std.debug.print("  output: {s}\n", .{outputSpecLabel(plan.stdout)});

    var child = std.process.Child.init(plan.argv, allocator);
    child.env_map = &env_map;
    child.cwd = plan.cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = stdioForStdout(plan.stdout);
    child.stderr_behavior = stdioForStderr(plan.stdout, plan.stderr);

    const term = try spawnAndWaitWithOutput(allocator, &child, plan.stdout, plan.stderr);
    resetTerminalBestEffort();
    return childExitCode(term);
}

fn runCommand(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) !u8 {
    const argv = try buildCommandArgv(allocator, target, extra_args);
    defer freeChildArgv(allocator, argv);

    std.debug.print("katzensteg: launching command {s}\n", .{target});
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    resetTerminalBestEffort();
    return childExitCode(term);
}

fn childExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(@min(code, 255)),
        .Signal => |signal| blk: {
            std.debug.print("katzensteg: child terminated by signal {d}\n", .{signal});
            break :blk 128 + @as(u8, @intCast(@min(signal, 127)));
        },
        else => 1,
    };
}

fn loadProfileCatalog(allocator: std.mem.Allocator) !profiles_mod.ProfileCatalog {
    const profile_dir = try resolveProfileDir(allocator);
    defer allocator.free(profile_dir);
    return profiles_mod.ProfileCatalog.parseDirectory(allocator, profile_dir);
}

fn resolveProfileDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "KATZENSTEG_PROFILE_DIR")) |dir| return dir else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const repo = try resolveRepoRoot(allocator);
    defer allocator.free(repo);
    return std.fs.path.join(allocator, &.{ repo, "tools", "katzensteg", "profiles" });
}

fn resolveRepoRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "KATZENSTEG_REPO")) |repo| return repo else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (try cwdLooksLikeRepo()) return std.fs.cwd().realpathAlloc(allocator, ".");
    return repoRootFromExecutable(allocator) catch std.fs.cwd().realpathAlloc(allocator, ".");
}

fn cwdLooksLikeRepo() !bool {
    var dir = std.fs.cwd().openDir("tools/katzensteg/profiles", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close();
    return true;
}

fn repoRootFromExecutable(allocator: std.mem.Allocator) ![]const u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    return repoRootFromExecutablePath(allocator, exe_path);
}

fn repoRootFromExecutablePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const bin_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const build_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidExecutablePath;
    const repo = std.fs.path.dirname(build_dir) orelse return error.InvalidExecutablePath;
    return allocator.dupe(u8, repo);
}

fn buildChildArgv(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try expandLauncherString(allocator, profile.target, expansion));
    for (profile.args) |arg| try argv.append(allocator, try expandLauncherString(allocator, arg, expansion));
    return argv.toOwnedSlice(allocator);
}

fn buildCommandArgv(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try allocator.dupe(u8, target));
    for (extra_args) |arg| try argv.append(allocator, try allocator.dupe(u8, arg));
    return argv.toOwnedSlice(allocator);
}

fn expandProfileEnv(allocator: std.mem.Allocator, env: []const profiles_mod.EnvVar, expansion: ExpansionContext) ![]profiles_mod.EnvVar {
    var out = std.ArrayList(profiles_mod.EnvVar).empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        out.deinit(allocator);
    }
    for (env) |entry| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .value = try expandLauncherString(allocator, entry.value, expansion),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn defaultRuntimeConfig() @import("config.zig").RuntimeConfig {
    return .{
        .intercept_mode = .queued_replay,
        .window_policy = .terminal_only,
        .input_enabled = true,
        .input_claimed = true,
        .output_profile = .file_whole,
    };
}

fn resolvedRuntimeConfig(profile: *const profiles_mod.LaunchProfile) @import("config.zig").RuntimeConfig {
    var runtime = defaultRuntimeConfig();
    const fields = profile.runtime_fields;
    if (fields.composite_mode) runtime.composite_mode = profile.runtime.composite_mode;
    if (fields.intercept_mode) runtime.intercept_mode = profile.runtime.intercept_mode;
    if (fields.window_policy) runtime.window_policy = profile.runtime.window_policy;
    if (fields.real_window) runtime.real_window_visibility = profile.runtime.real_window_visibility;
    if (fields.present_fps) runtime.present_fps = profile.runtime.present_fps;
    if (fields.input) runtime.input_enabled = profile.runtime.input_enabled;
    if (fields.input_claim) runtime.input_claimed = profile.runtime.input_claimed;
    if (fields.output_profile) runtime.output_profile = profile.runtime.output_profile;
    if (fields.gl_capture) runtime.gl_capture = profile.runtime.gl_capture;
    if (fields.vulkan_capture) runtime.vulkan_capture = profile.runtime.vulkan_capture;
    return runtime;
}

fn resolveProfileStdout(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext) !OutputSpec {
    if (profile.stdout) |value| return resolveOutputSpec(allocator, value, expansion);
    const log_name = try sanitizedProfileName(allocator, profile.name);
    defer allocator.free(log_name);
    return .{ .file = try std.fmt.allocPrint(allocator, "/tmp/katzensteg-{s}.out", .{log_name}) };
}

fn resolveProfileStderr(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext) !OutputSpec {
    if (profile.stderr) |value| return resolveOutputSpec(allocator, value, expansion);
    return .stdout;
}

fn sanitizedProfileName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c)) c else '-';
    }
    return out;
}

fn spawnAndWaitWithOutput(_: std.mem.Allocator, child: *std.process.Child, stdout_spec: OutputSpec, stderr_spec: OutputSpec) !std.process.Child.Term {
    var stdout_sink: ?FileSink = try openStdoutSink(stdout_spec);
    defer if (stdout_sink) |*sink| sink.deinit();
    var stderr_sink: ?FileSink = try openStderrSink(stdout_spec, stderr_spec, if (stdout_sink) |*sink| sink else null);
    defer if (stderr_sink) |*sink| sink.deinit();

    try child.spawn();

    var stdout_thread: ?std.Thread = null;
    if (child.stdout) |stdout_file| {
        child.stdout = null;
        const sink = if (stdout_sink) |*sink| sink else unreachable;
        stdout_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stdout_file, .sink = sink }});
    }

    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        child.stderr = null;
        const sink = switch (stderr_spec) {
            .stdout => if (stdout_sink) |*sink| sink else unreachable,
            .file => if (stderr_sink) |*sink| sink else unreachable,
            else => unreachable,
        };
        stderr_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stderr_file, .sink = sink }});
    }

    const term = try child.wait();
    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();
    return term;
}

fn drainPipeToSink(args: DrainArgs) void {
    defer args.source.close();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = args.source.read(&buf) catch return;
        if (n == 0) return;
        args.sink.writeAll(buf[0..n]);
    }
}

fn openStdoutSink(spec: OutputSpec) !?FileSink {
    return switch (spec) {
        .file => |path| .{ .file = try createOutputFile(path) },
        else => null,
    };
}

fn openStderrSink(stdout_spec: OutputSpec, stderr_spec: OutputSpec, stdout_sink: ?*FileSink) !?FileSink {
    _ = stdout_spec;
    return switch (stderr_spec) {
        .file => |path| .{ .file = try createOutputFile(path) },
        .stdout => if (stdout_sink != null) null else null,
        else => null,
    };
}

fn createOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true, .read = false });
    return std.fs.cwd().createFile(path, .{ .truncate = true, .read = false });
}

fn stdioForStdout(spec: OutputSpec) std.process.Child.StdIo {
    return switch (spec) {
        .inherit, .stdout => .Inherit,
        .ignore => .Ignore,
        .file => .Pipe,
    };
}

fn stdioForStderr(stdout_spec: OutputSpec, stderr_spec: OutputSpec) std.process.Child.StdIo {
    return switch (stderr_spec) {
        .inherit => .Inherit,
        .ignore => .Ignore,
        .file => .Pipe,
        .stdout => switch (stdout_spec) {
            .file => .Pipe,
            .ignore => .Ignore,
            else => .Inherit,
        },
    };
}

fn resolveOutputSpec(allocator: std.mem.Allocator, value: ?[]const u8, expansion: ExpansionContext) !OutputSpec {
    const raw = value orelse return .inherit;
    if (std.mem.eql(u8, raw, "inherit")) return .inherit;
    if (std.mem.eql(u8, raw, "ignore")) return .ignore;
    if (std.mem.eql(u8, raw, "stdout")) return .stdout;
    return .{ .file = try expandLauncherString(allocator, raw, expansion) };
}

fn outputSpecLabel(spec: OutputSpec) []const u8 {
    return switch (spec) {
        .inherit => "inherit",
        .ignore => "ignore",
        .stdout => "stdout",
        .file => |path| path,
    };
}

fn expandLauncherString(allocator: std.mem.Allocator, input: []const u8, expansion: ExpansionContext) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    if (std.mem.eql(u8, input, "~")) {
        try out.appendSlice(allocator, expansion.home);
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.startsWith(u8, input, "~/")) {
        try out.appendSlice(allocator, expansion.home);
        try out.appendSlice(allocator, input[1..]);
        return out.toOwnedSlice(allocator);
    }

    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "{repo}") or std.mem.startsWith(u8, input[i..], "${ROOT}")) {
            try out.appendSlice(allocator, expansion.repo);
            i += if (std.mem.startsWith(u8, input[i..], "{repo}")) "{repo}".len else "${ROOT}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$ROOT")) {
            try out.appendSlice(allocator, expansion.repo);
            i += "$ROOT".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "${HOME}")) {
            try out.appendSlice(allocator, expansion.home);
            i += "${HOME}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$HOME")) {
            try out.appendSlice(allocator, expansion.home);
            i += "$HOME".len;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn freeChildArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn writeRuntimeConfig(allocator: std.mem.Allocator, runtime: @import("config.zig").RuntimeConfig) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/katzensteg-runtime-{d}.json", .{std.time.nanoTimestamp()});
    errdefer allocator.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true, .read = true });
    defer file.close();
    var writer = file.writerStreaming(&.{});
    try writeRuntimeConfigJson(&writer.interface, runtime);
    try writer.interface.flush();
    return path;
}

fn writeRuntimeConfigJson(writer: *std.Io.Writer, runtime: @import("config.zig").RuntimeConfig) !void {
    try writer.print(
        "{{\"composite_mode\":\"{s}\",\"intercept_mode\":\"{s}\",\"window_policy\":\"{s}\",\"real_window\":\"{s}\",\"present_fps\":{d},\"input\":{},\"input_claim\":{},\"output_profile\":",
        .{
            @tagName(runtime.composite_mode),
            @tagName(runtime.intercept_mode),
            @tagName(runtime.window_policy),
            @tagName(runtime.real_window_visibility),
            runtime.present_fps,
            runtime.input_enabled,
            runtime.input_claimed,
        },
    );
    if (runtime.output_profile) |output_profile| {
        try writer.print("\"{s}\"", .{@tagName(output_profile)});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"gl_capture\":\"{s}\",\"vulkan_capture\":{}}}\n", .{ @tagName(runtime.gl_capture), runtime.vulkan_capture });
}

fn resetTerminalBestEffort() void {
    const file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .write_only }) catch return;
    defer file.close();
    var writer = file.writerStreaming(&.{});
    writer.interface.writeAll(terminalResetSequence()) catch return;
    writer.interface.flush() catch return;
}

fn terminalResetSequence() []const u8 {
    return "\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?1006l\x1b[?1016l\x1b[?1004l" ++
        "\x1b[0m\x1b[?25h\x1b[?1049l" ++
        "\x1b_Gq=2,a=d,d=A;\x1b\\";
}

test "launcher builds child argv from profile target and args" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "test",
        .target = "{repo}/bin/echo",
        .args = &.{ "$HOME/hello", "world" },
    };
    const argv = try buildChildArgv(std.testing.allocator, &profile, expansion);
    defer freeChildArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("/repo/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("/Users/test/hello", argv[1]);
    try std.testing.expectEqualStrings("world", argv[2]);
}

test "launcher resolves profile into launch plan with default log and runtime policy" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "retroarch.sonic",
        .target = "$HOME/dev/RetroArch/retroarch",
        .args = &.{ "-L", "$HOME/core.dylib" },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion);
    defer plan.deinit();

    try std.testing.expectEqualStrings("retroarch.sonic", plan.profile_name);
    try std.testing.expectEqualStrings("/Users/test/dev/RetroArch/retroarch", plan.target);
    try std.testing.expectEqualStrings("/Users/test/core.dylib", plan.argv[2]);
    try std.testing.expectEqualStrings("/tmp/katzensteg-retroarch-sonic.out", plan.stdout.file);
    try std.testing.expectEqual(OutputSpec.stdout, plan.stderr);
    try std.testing.expectEqual(@as(usize, 0), plan.env.len);
    try std.testing.expectEqual(.queued_replay, plan.runtime.intercept_mode);
    try std.testing.expectEqual(.terminal_only, plan.runtime.window_policy);
    try std.testing.expectEqual(.file_whole, plan.runtime.output_profile.?);
}

test "launcher resolved plan expands profile env and preserves explicit output" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "probe.input",
        .target = "{repo}/zig-out/bin/probe",
        .stdout = "{repo}/probe.out",
        .stderr = "ignore",
        .env = &.{
            .{ .name = "DYLD_INSERT_LIBRARIES", .value = "{repo}/zig-out/lib/libkatzensteg-unlinked.dylib" },
        },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion);
    defer plan.deinit();

    try std.testing.expectEqualStrings("/repo/probe.out", plan.stdout.file);
    try std.testing.expectEqual(OutputSpec.ignore, plan.stderr);
    try std.testing.expectEqualStrings("DYLD_INSERT_LIBRARIES", plan.env[0].name);
    try std.testing.expectEqualStrings("/repo/zig-out/lib/libkatzensteg-unlinked.dylib", plan.env[0].value);
}

test "launcher builds child argv from direct command target and remaining args" {
    const argv = try buildCommandArgv(std.testing.allocator, "/bin/echo", &.{ "hello", "world" });
    defer freeChildArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hello", argv[1]);
    try std.testing.expectEqualStrings("world", argv[2]);
}

test "launcher terminal reset disables mouse tracking and clears kitty graphics" {
    const seq = terminalResetSequence();
    try std.testing.expect(std.mem.indexOf(u8, seq, "\x1b[?1000l") != null);
    try std.testing.expect(std.mem.indexOf(u8, seq, "\x1b[?1049l") != null);
    try std.testing.expect(std.mem.indexOf(u8, seq, "\x1b_Gq=2,a=d,d=A;\x1b\\") != null);
}

test "launcher expands home and repo placeholders" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    const home_path = try expandLauncherString(std.testing.allocator, "~/roms/game.md", expansion);
    defer std.testing.allocator.free(home_path);
    try std.testing.expectEqualStrings("/Users/test/roms/game.md", home_path);

    const repo_path = try expandLauncherString(std.testing.allocator, "{repo}/zig-out/lib/libkatzensteg.dylib", expansion);
    defer std.testing.allocator.free(repo_path);
    try std.testing.expectEqualStrings("/repo/zig-out/lib/libkatzensteg.dylib", repo_path);

    const env_path = try expandLauncherString(std.testing.allocator, "$HOME/dev:$ROOT/bin:${HOME}/x:${ROOT}/y", expansion);
    defer std.testing.allocator.free(env_path);
    try std.testing.expectEqualStrings("/Users/test/dev:/repo/bin:/Users/test/x:/repo/y", env_path);
}

test "launcher derives repo root from zig-out executable path" {
    const repo = try repoRootFromExecutablePath(std.testing.allocator, "/repo/zig-out/bin/katzensteg");
    defer std.testing.allocator.free(repo);
    try std.testing.expectEqualStrings("/repo", repo);
}

test "launcher resolves output specs" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    const inherit = try resolveOutputSpec(std.testing.allocator, null, expansion);
    defer inherit.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputSpec.inherit, inherit);

    const stdout = try resolveOutputSpec(std.testing.allocator, "stdout", expansion);
    defer stdout.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputSpec.stdout, stdout);

    const file = try resolveOutputSpec(std.testing.allocator, "{repo}/log.out", expansion);
    defer file.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/repo/log.out", file.file);
}

test "launcher help describes direct target syntax" {
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "katzensteg [options] <target>") != null);
}

test "launcher command parser recognizes help menu and run targets" {
    try std.testing.expectEqual(Command.menu, parseCommand(&.{"katzensteg"}));
    try std.testing.expectEqual(Command.help, parseCommand(&.{ "katzensteg", "--help" }));
    try std.testing.expectEqual(Command.run, parseCommand(&.{ "katzensteg", "retroarch.sonic" }));
    try std.testing.expectEqual(Command.run, parseCommand(&.{ "katzensteg", "--dry-run", "retroarch.sonic" }));
    try std.testing.expectEqual(Command.run, parseCommand(&.{ "katzensteg", "--", "--odd-command-name" }));
    try std.testing.expectEqual(Command.unknown, parseCommand(&.{ "katzensteg", "--dry-run" }));
}

test "launcher target parser skips options and supports option terminator" {
    try std.testing.expectEqualStrings("example", targetArg(&.{ "katzensteg", "--dry-run", "example" }).?);
    try std.testing.expectEqualStrings("--odd-command-name", targetArg(&.{ "katzensteg", "--", "--odd-command-name" }).?);
    try std.testing.expectEqual(@as(usize, 2), targetArgIndex(&.{ "katzensteg", "--dry-run", "example", "extra" }).?);
    try std.testing.expect(targetArg(&.{ "katzensteg", "--dry-run" }) == null);
}
