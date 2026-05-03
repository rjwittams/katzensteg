const std = @import("std");
const attach_host = @import("attach_host.zig");
const profiles_mod = @import("launcher_profiles.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");
const wm_host = @import("wm_host.zig");

const Command = enum {
    help,
    menu,
    run,
    attach,
    wm,
    unknown,
};

const AttachArgs = struct {
    exec_argv: []const []const u8,
    rect_cells: ?@import("render_batch_protocol.zig").PresentationRectCells = null,
    aspect: @import("render_batch_protocol.zig").PresentationAspect = .fit,
};

const WmArgs = struct {
    profile_names: []const []const u8,
};

const ExpansionContext = struct {
    home: []const u8,
    repo: []const u8,
    path: []const u8 = "",
    owns_home: bool = false,
    owns_repo: bool = false,
    owns_path: bool = false,

    fn init(allocator: std.mem.Allocator) !ExpansionContext {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        errdefer allocator.free(home);
        const path = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        errdefer allocator.free(path);
        const repo = try resolveRepoRoot(allocator);
        return .{ .home = home, .repo = repo, .path = path, .owns_home = true, .owns_repo = true, .owns_path = true };
    }

    fn deinit(self: ExpansionContext, allocator: std.mem.Allocator) void {
        if (self.owns_home) allocator.free(self.home);
        if (self.owns_repo) allocator.free(self.repo);
        if (self.owns_path) allocator.free(self.path);
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

var embed_signal_child_pgid = std.atomic.Value(std.posix.pid_t).init(0);

const ResolvedLaunchPlan = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    target: []const u8,
    argv: [][]const u8,
    cwd: ?[]const u8,
    stdout: OutputSpec,
    stderr: OutputSpec,
    env: []profiles_mod.EnvVar,
    seed_files: []profiles_mod.SeedFile,
    runtime: @import("config.zig").RuntimeConfig,

    fn fromProfile(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext, extra_args: []const []const u8) !ResolvedLaunchPlan {
        var plan = ResolvedLaunchPlan{
            .allocator = allocator,
            .profile_name = try allocator.dupe(u8, profile.name),
            .target = try expandLauncherString(allocator, profile.target, expansion),
            .argv = &.{},
            .cwd = null,
            .stdout = .inherit,
            .stderr = .inherit,
            .env = &.{},
            .seed_files = &.{},
            .runtime = resolvedRuntimeConfig(profile),
        };
        errdefer plan.deinit();

        plan.argv = try buildChildArgv(allocator, profile, expansion, extra_args);
        if (profile.cwd) |raw| plan.cwd = try expandLauncherString(allocator, raw, expansion);
        plan.stdout = try resolveProfileStdout(allocator, profile, expansion);
        plan.stderr = try resolveProfileStderr(allocator, profile, expansion);
        plan.env = try expandProfileEnv(allocator, profile.env, expansion);
        plan.seed_files = try expandProfileSeedFiles(allocator, profile.seed_files, expansion);
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
        for (self.seed_files) |entry| {
            self.allocator.free(entry.path);
            if (entry.source) |source| self.allocator.free(source);
            if (entry.content) |content| self.allocator.free(content);
        }
        self.allocator.free(self.seed_files);
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
    stop: *std.atomic.Value(bool),
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 0 and isProxyExecutablePath(args[0])) {
        const exit_code = try runProxy(allocator, args[1..]);
        std.process.exit(exit_code);
    }

    switch (parseCommand(args)) {
        .help => try std.fs.File.stdout().writeAll(usageText()),
        .menu => try showProfiles(allocator),
        .run => {
            const target_idx = targetArgIndex(args) orelse unreachable;
            const target = args[target_idx];
            if (launcherDryRun(args)) {
                try dryRunTarget(allocator, target, args[target_idx + 1 ..], launcherEmbedJsonl(args));
                return;
            }
            const exit_code = try runTarget(allocator, target, args[target_idx + 1 ..], launcherEmbedJsonl(args));
            std.process.exit(exit_code);
        },
        .attach => {
            const attach = parseAttachArgs(args) orelse {
                std.debug.print("{s}", .{usageText()});
                std.process.exit(64);
            };
            const exit_code = try attach_host.runExec(allocator, attach.exec_argv, .{
                .rect_cells = attach.rect_cells,
                .aspect = attach.aspect,
            });
            std.process.exit(exit_code);
        },
        .wm => {
            const wm = parseWmArgs(args) orelse {
                std.debug.print("{s}", .{usageText()});
                std.process.exit(64);
            };
            const exit_code = try wm_host.runProfiles(allocator, wm.profile_names);
            std.process.exit(exit_code);
        },
        .unknown => {
            std.debug.print("{s}", .{usageText()});
            std.process.exit(64);
        },
    }
}

fn usageText() []const u8 {
    return usage_text;
}

const usage_text =
    \\Usage:
    \\  katzensteg --help
    \\  katzensteg [options] <target>
    \\  katzensteg attach [--rect x,y,w,h] [--aspect fit|stretch|cover] --exec -- <program> [args...]
    \\  katzensteg wm [target...]
    \\  katzensteg
    \\
    \\Options:
    \\  --dry-run      Resolve the target and print what would run.
    \\  --embed-jsonl  Quiet launcher mode; stdout is Katzensteg JSONL batches.
    \\
    \\Targets:
    \\  A target can be a named profile or, later, a command/path/URL matched by the launcher.
    \\  With no target, Katzensteg lists available profiles.
    \\
    \\Environment:
    \\  KATZENSTEG_PROFILE_DIR    Profile directories, ':'-separated. First match wins;
    \\                            non-existent dirs are silently skipped.
    \\                            Default: <repo>/profiles plus
    \\                            $XDG_CONFIG_HOME/katzensteg/profiles
    \\                            (or ~/.config/katzensteg/profiles).
    \\  KATZENSTEG_REPO           Override {repo}/$ROOT expansion.
    \\  KATZENSTEG_PROXY_PROFILE  Child profile used by katzensteg-proxy.
    \\
;

fn isProxyExecutablePath(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), "katzensteg-proxy");
}

fn parseCommand(args: []const []const u8) Command {
    if (args.len <= 1) return .menu;
    if (hasArg(args[1..], "--help") or hasArg(args[1..], "-h")) return .help;
    if (std.mem.eql(u8, args[1], "attach")) return if (parseAttachArgs(args) != null) .attach else .unknown;
    if (std.mem.eql(u8, args[1], "wm")) return if (parseWmArgs(args) != null) .wm else .unknown;
    if (targetArgIndex(args) != null) return .run;
    return .unknown;
}

fn parseWmArgs(args: []const []const u8) ?WmArgs {
    if (args.len < 2) return null;
    if (!std.mem.eql(u8, args[1], "wm")) return null;
    for (args[2..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return null;
    }
    return .{ .profile_names = args[2..] };
}

fn parseAttachArgs(args: []const []const u8) ?AttachArgs {
    if (args.len < 5) return null;
    if (!std.mem.eql(u8, args[1], "attach")) return null;

    var saw_exec = false;
    var rect_cells: ?@import("render_batch_protocol.zig").PresentationRectCells = null;
    var aspect: @import("render_batch_protocol.zig").PresentationAspect = .fit;
    var idx: usize = 2;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--")) {
            if (!saw_exec or idx + 1 >= args.len) return null;
            return .{ .exec_argv = args[idx + 1 ..], .rect_cells = rect_cells, .aspect = aspect };
        }
        if (std.mem.eql(u8, arg, "--exec")) {
            if (saw_exec) return null;
            saw_exec = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--rect")) {
            if (idx + 1 >= args.len or rect_cells != null) return null;
            idx += 1;
            rect_cells = parseAttachRect(args[idx]) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--aspect")) {
            if (idx + 1 >= args.len) return null;
            idx += 1;
            aspect = @import("render_batch_protocol.zig").parseAspect(args[idx]) orelse return null;
            continue;
        }
        return null;
    }
    return null;
}

fn parseAttachRect(value: []const u8) ?@import("render_batch_protocol.zig").PresentationRectCells {
    var parts = std.mem.splitScalar(u8, value, ',');
    const x = parsePositiveI32(parts.next() orelse return null) orelse return null;
    const y = parsePositiveI32(parts.next() orelse return null) orelse return null;
    const w = parsePositiveI32(parts.next() orelse return null) orelse return null;
    const h = parsePositiveI32(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return .{ .row = y, .col = x, .rows = h, .cols = w };
}

fn parsePositiveI32(value: []const u8) ?i32 {
    const parsed = std.fmt.parseInt(i32, value, 10) catch return null;
    if (parsed <= 0) return null;
    return parsed;
}

fn launcherDryRun(args: []const []const u8) bool {
    const target_idx = targetArgIndex(args) orelse args.len;
    for (args[1..target_idx]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) return true;
    }
    return false;
}

fn launcherEmbedJsonl(args: []const []const u8) bool {
    const target_idx = targetArgIndex(args) orelse args.len;
    for (args[1..target_idx]) |arg| {
        if (std.mem.eql(u8, arg, "--embed-jsonl")) return true;
    }
    return false;
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
        if (std.mem.eql(u8, arg, "--embed-jsonl")) continue;
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
        if (profile.error_summary) |summary| {
            try writer.interface.print("  {s} [broken: {s}]\n", .{ profile.name, summary });
            continue;
        }
        if (profile.hidden) continue;
        if (profile.target.len == 0) continue;
        try writer.interface.print("  {s}\n", .{profile.name});
    }
    try writer.interface.flush();
}

fn dryRunTarget(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8, embed_jsonl: bool) !void {
    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const profile = catalog.find(target) orelse {
        const line = try dryRunCommandLineForDisplay(allocator, target, extra_args);
        defer allocator.free(line);
        std.debug.print("katzensteg dry-run\ncommandline={s}\n", .{line});
        return;
    };
    if (profileLaunchProblem(profile)) |problem| {
        printProfileLaunchProblem(target, problem);
        std.process.exit(66);
    }

    var expansion = try ExpansionContext.init(allocator);
    defer expansion.deinit(allocator);
    var plan = try ResolvedLaunchPlan.fromProfile(allocator, profile, expansion, extra_args);
    defer plan.deinit();
    if (embed_jsonl) applyEmbedJsonlRuntime(&plan.runtime, defaultEmbedRuntimeFds());

    std.debug.print(
        "katzensteg dry-run\nprofile={s}\ntarget={s}\ncwd={s}\nstdout={s}\nstderr={s}\n",
        .{
            plan.profile_name,
            plan.target,
            plan.cwd orelse "<inherit>",
            outputSpecLabel(plan.stdout),
            outputSpecLabel(plan.stderr),
        },
    );
    const line = try commandLineForDisplay(allocator, plan.argv);
    defer allocator.free(line);
    std.debug.print("commandline={s}\n", .{line});
    std.debug.print("env:\n", .{});
    if (plan.env.len == 0) {
        std.debug.print("  <none>\n", .{});
    } else {
        for (plan.env) |entry| {
            std.debug.print("  {s}={s}\n", .{ entry.name, entry.value });
        }
    }
    std.debug.print("seed_files:\n", .{});
    if (plan.seed_files.len == 0) {
        std.debug.print("  <none>\n", .{});
    } else {
        for (plan.seed_files) |entry| {
            if (entry.source) |source| {
                std.debug.print("  {s} <- {s}\n", .{ entry.path, source });
            } else {
                std.debug.print("  {s} <- inline content\n", .{entry.path});
            }
        }
    }
    std.debug.print(
        "runtime:\n  intercept_mode={s}\n  composite_mode={s}\n  window_policy={s}\n  real_window={s}\n  present_fps={d}\n  input={}\n  input_claim={}\n  input_claim_focus={}\n  output_profile={s}\n  gl_capture={s}\n  vulkan_capture={}\n",
        .{
            @tagName(plan.runtime.intercept_mode),
            @tagName(plan.runtime.composite_mode),
            @tagName(plan.runtime.window_policy),
            @tagName(plan.runtime.real_window_visibility),
            plan.runtime.present_fps,
            plan.runtime.input_enabled,
            plan.runtime.input_claimed,
            plan.runtime.input_claim_focus,
            if (plan.runtime.output_profile) |output_profile| @tagName(output_profile) else "auto",
            @tagName(plan.runtime.gl_capture),
            plan.runtime.vulkan_capture,
        },
    );
}

fn runTarget(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8, embed_jsonl: bool) !u8 {
    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const profile = catalog.find(target) orelse {
        if (embed_jsonl) return 66;
        return runCommand(allocator, target, extra_args);
    };
    if (profileLaunchProblem(profile)) |problem| {
        printProfileLaunchProblem(target, problem);
        return 66;
    }

    var expansion = try ExpansionContext.init(allocator);
    defer expansion.deinit(allocator);
    var plan = try ResolvedLaunchPlan.fromProfile(allocator, profile, expansion, extra_args);
    defer plan.deinit();

    var embed_pipes: ?EmbedPipes = null;
    if (embed_jsonl) {
        embed_pipes = try EmbedPipes.init();
        applyEmbedJsonlRuntime(&plan.runtime, embed_pipes.?.runtimeFds());
    }
    defer if (embed_pipes) |*pipes| pipes.deinit();

    const runtime_config_path = try writeRuntimeConfig(allocator, plan.runtime);
    defer allocator.free(runtime_config_path);
    defer std.fs.deleteFileAbsolute(runtime_config_path) catch {};

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    for (plan.env) |entry| try env_map.put(entry.name, entry.value);
    try env_map.put("KATZENSTEG_CONFIG", runtime_config_path);

    if (!embed_jsonl) {
        std.debug.print("katzensteg: launching {s}\n", .{plan.profile_name});
        std.debug.print("  target: {s}\n", .{plan.target});
        std.debug.print("  runtime config: {s}\n", .{runtime_config_path});
        std.debug.print("  output: {s}\n", .{outputSpecLabel(plan.stdout)});
    }
    try ensureSeedFiles(allocator, plan.seed_files);

    var child = std.process.Child.init(plan.argv, allocator);
    child.env_map = &env_map;
    child.cwd = plan.cwd;
    child.stdin_behavior = if (embed_jsonl) .Ignore else .Inherit;
    child.stdout_behavior = stdioForStdout(plan.stdout);
    child.stderr_behavior = stdioForStderr(plan.stdout, plan.stderr);

    const term = if (embed_jsonl)
        spawnAndWaitEmbedJsonl(allocator, &child, plan.stdout, plan.stderr, &embed_pipes.?) catch |err| {
            printSpawnFailure(allocator, plan.profile_name, plan.argv, err);
            return spawnFailureExitCode(err);
        }
    else
        spawnAndWaitWithOutput(allocator, &child, plan.stdout, plan.stderr) catch |err| {
            resetTerminalBestEffort();
            printSpawnFailure(allocator, plan.profile_name, plan.argv, err);
            return spawnFailureExitCode(err);
        };
    if (!embed_jsonl) {
        resetTerminalBestEffort();
    }
    const exit_code = childExitCode(term);
    if (exit_code != 0 and !embed_jsonl) {
        reportExecutedCommand(allocator, plan.argv);
        reportOutputTail(allocator, plan.stdout, plan.stderr);
    }
    return exit_code;
}

const ProfileLaunchProblem = union(enum) {
    broken: []const u8,
    fragment,
};

fn profileLaunchProblem(profile: *const profiles_mod.LaunchProfile) ?ProfileLaunchProblem {
    if (profile.error_summary) |summary| return .{ .broken = summary };
    if (profile.target.len == 0) return .fragment;
    return null;
}

fn printProfileLaunchProblem(name: []const u8, problem: ProfileLaunchProblem) void {
    switch (problem) {
        .broken => |summary| std.debug.print("katzensteg: profile is broken: {s}: {s}\n", .{ name, summary }),
        .fragment => std.debug.print("katzensteg: profile is a fragment, not a launch target: {s}\n", .{name}),
    }
}

fn runCommand(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) !u8 {
    const argv = try buildCommandArgv(allocator, target, extra_args);
    defer freeChildArgv(allocator, argv);

    std.debug.print("katzensteg: launching command {s}\n", .{target});
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        resetTerminalBestEffort();
        printSpawnFailure(allocator, "command", argv, err);
        return spawnFailureExitCode(err);
    };
    resetTerminalBestEffort();
    return childExitCode(term);
}

fn runProxy(allocator: std.mem.Allocator, extra_args: []const []const u8) !u8 {
    const profile_name = std.process.getEnvVarOwned(allocator, "KATZENSTEG_PROXY_PROFILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("katzensteg-proxy: missing KATZENSTEG_PROXY_PROFILE\n", .{});
            return 64;
        },
        else => return err,
    };
    defer allocator.free(profile_name);

    var catalog = try loadProfileCatalog(allocator);
    defer catalog.deinit();

    const profile = catalog.find(profile_name) orelse {
        std.debug.print("katzensteg-proxy: child profile not found: {s}\n", .{profile_name});
        return 66;
    };
    if (profileLaunchProblem(profile)) |problem| {
        printProfileLaunchProblem(profile_name, problem);
        return 66;
    }

    var expansion = try ExpansionContext.init(allocator);
    defer expansion.deinit(allocator);
    var plan = try ResolvedLaunchPlan.fromProfile(allocator, profile, expansion, extra_args);
    defer plan.deinit();

    const runtime_config_path = try writeRuntimeConfig(allocator, plan.runtime);
    defer {
        std.fs.deleteFileAbsolute(runtime_config_path) catch {};
        allocator.free(runtime_config_path);
    }

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    for (plan.env) |entry| try env_map.put(entry.name, entry.value);
    try env_map.put("KATZENSTEG_CONFIG", runtime_config_path);
    try ensureSeedFiles(allocator, plan.seed_files);

    const err = std.process.execve(allocator, plan.argv, &env_map);
    std.debug.print("katzensteg-proxy: exec failed for {s}: {s}\n", .{ plan.target, @errorName(err) });
    return 127;
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

fn spawnFailureExitCode(err: anyerror) u8 {
    return switch (err) {
        error.FileNotFound => 127,
        error.AccessDenied, error.PermissionDenied => 126,
        else => 1,
    };
}

fn printSpawnFailure(allocator: std.mem.Allocator, label: []const u8, argv: []const []const u8, err: anyerror) void {
    std.debug.print("katzensteg: failed to launch {s}: {s}\n", .{ label, @errorName(err) });
    const commandline = commandLineForDisplay(allocator, argv) catch null;
    if (commandline) |line| {
        defer allocator.free(line);
        std.debug.print("  commandline={s}\n", .{line});
    }
    if (argv.len > 0) {
        const reason = spawnFailureReasonForDisplay(allocator, argv[0], err) catch null;
        if (reason) |text| {
            defer allocator.free(text);
            std.debug.print("  {s}\n", .{text});
        }
    }
}

fn spawnFailureReasonForDisplay(allocator: std.mem.Allocator, executable: []const u8, err: anyerror) ![]const u8 {
    if (err == error.FileNotFound) {
        if (usesPathLookup(executable)) {
            return std.fmt.allocPrint(allocator, "executable not found on PATH: {s}", .{executable});
        }
        return std.fmt.allocPrint(allocator, "executable not found: {s}", .{executable});
    }
    return std.fmt.allocPrint(allocator, "spawn failed before the target process started", .{});
}

fn usesPathLookup(executable: []const u8) bool {
    return std.mem.indexOfScalar(u8, executable, '/') == null;
}

fn loadProfileCatalog(allocator: std.mem.Allocator) !profiles_mod.ProfileCatalog {
    var dirs = try resolveProfileDirs(allocator);
    defer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }
    return profiles_mod.ProfileCatalog.parseDirectories(allocator, dirs.items);
}

fn resolveProfileDirs(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var dirs = std.ArrayList([]const u8).empty;
    errdefer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    if (std.process.getEnvVarOwned(allocator, "KATZENSTEG_PROFILE_DIR")) |raw| {
        defer allocator.free(raw);
        var it = std.mem.splitScalar(u8, raw, ':');
        while (it.next()) |segment| {
            const trimmed = std.mem.trim(u8, segment, " \t");
            if (trimmed.len == 0) continue;
            try dirs.append(allocator, try allocator.dupe(u8, trimmed));
        }
        if (dirs.items.len > 0) return dirs;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const repo = try resolveRepoRoot(allocator);
    defer allocator.free(repo);
    try dirs.append(allocator, try std.fs.path.join(allocator, &.{ repo, "profiles" }));

    if (try userConfigProfilesDir(allocator)) |user_dir| {
        try dirs.append(allocator, user_dir);
    }
    return dirs;
}

fn userConfigProfilesDir(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        if (xdg.len > 0) return try std.fs.path.join(allocator, &.{ xdg, "katzensteg", "profiles" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        if (home.len > 0) return try std.fs.path.join(allocator, &.{ home, ".config", "katzensteg", "profiles" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return null;
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
    var dir = std.fs.cwd().openDir("profiles", .{}) catch |err| switch (err) {
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

fn buildChildArgv(allocator: std.mem.Allocator, profile: *const profiles_mod.LaunchProfile, expansion: ExpansionContext, extra_args: []const []const u8) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try expandLauncherString(allocator, profile.target, expansion));
    for (profile.args) |arg| try argv.append(allocator, try expandLauncherString(allocator, arg, expansion));
    for (extra_args) |arg| try argv.append(allocator, try allocator.dupe(u8, arg));
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

fn expandProfileSeedFiles(allocator: std.mem.Allocator, seed_files: []const profiles_mod.SeedFile, expansion: ExpansionContext) ![]profiles_mod.SeedFile {
    var out = std.ArrayList(profiles_mod.SeedFile).empty;
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.path);
            if (entry.source) |source| allocator.free(source);
            if (entry.content) |content| allocator.free(content);
        }
        out.deinit(allocator);
    }
    for (seed_files) |entry| {
        try out.append(allocator, .{
            .path = try expandLauncherString(allocator, entry.path, expansion),
            .source = if (entry.source) |source| try expandLauncherString(allocator, source, expansion) else null,
            .content = if (entry.content) |content| try expandLauncherString(allocator, content, expansion) else null,
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
    if (fields.input_claim_focus) runtime.input_claim_focus = profile.runtime.input_claim_focus;
    if (fields.output_profile) runtime.output_profile = profile.runtime.output_profile;
    if (fields.gl_capture) runtime.gl_capture = profile.runtime.gl_capture;
    if (fields.vulkan_capture) runtime.vulkan_capture = profile.runtime.vulkan_capture;
    if (fields.presentation_sink) runtime.presentation_sink = profile.runtime.presentation_sink;
    if (fields.presentation_fd) runtime.presentation_fd = profile.runtime.presentation_fd;
    if (fields.presentation_control_fd) runtime.presentation_control_fd = profile.runtime.presentation_control_fd;
    return runtime;
}

const EmbedRuntimeFds = struct {
    presentation_fd: i32,
    control_fd: i32,
};

fn defaultEmbedRuntimeFds() EmbedRuntimeFds {
    return .{ .presentation_fd = 100, .control_fd = 101 };
}

fn applyEmbedJsonlRuntime(runtime: *@import("config.zig").RuntimeConfig, fds: EmbedRuntimeFds) void {
    runtime.presentation_sink = .jsonl_fd;
    runtime.presentation_fd = fds.presentation_fd;
    runtime.presentation_control_fd = fds.control_fd;
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

    var drain_stop = std.atomic.Value(bool).init(false);
    var stdout_thread: ?std.Thread = null;
    if (child.stdout) |stdout_file| {
        child.stdout = null;
        const sink = if (stdout_sink) |*sink| sink else unreachable;
        stdout_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stdout_file, .sink = sink, .stop = &drain_stop }});
    }

    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        child.stderr = null;
        const sink = switch (stderr_spec) {
            .stdout => if (stdout_sink) |*sink| sink else unreachable,
            .file => if (stderr_sink) |*sink| sink else unreachable,
            else => unreachable,
        };
        stderr_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stderr_file, .sink = sink, .stop = &drain_stop }});
    }

    const term = try child.wait();
    drain_stop.store(true, .seq_cst);
    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();
    return term;
}

const embed_fd_min: std.posix.fd_t = 100;

const EmbedPipes = struct {
    render_read: ?std.fs.File,
    control_write: ?std.fs.File,
    child_render_fd: ?std.posix.fd_t,
    child_control_fd: ?std.posix.fd_t,

    fn init() !EmbedPipes {
        const render_pipe = try std.posix.pipe();
        errdefer destroyRawPipe(render_pipe);
        const control_pipe = try std.posix.pipe();
        errdefer destroyRawPipe(control_pipe);

        const child_render_fd = try dupFdAtLeast(render_pipe[1], embed_fd_min);
        errdefer std.posix.close(child_render_fd);
        const child_control_fd = try dupFdAtLeast(control_pipe[0], child_render_fd + 1);
        errdefer std.posix.close(child_control_fd);

        std.posix.close(render_pipe[1]);
        std.posix.close(control_pipe[0]);

        return .{
            .render_read = .{ .handle = render_pipe[0] },
            .control_write = .{ .handle = control_pipe[1] },
            .child_render_fd = child_render_fd,
            .child_control_fd = child_control_fd,
        };
    }

    fn runtimeFds(self: *const EmbedPipes) EmbedRuntimeFds {
        return .{
            .presentation_fd = @intCast(self.child_render_fd.?),
            .control_fd = @intCast(self.child_control_fd.?),
        };
    }

    fn closeChildFds(self: *EmbedPipes) void {
        if (self.child_render_fd) |fd| std.posix.close(fd);
        if (self.child_control_fd) |fd| std.posix.close(fd);
        self.child_render_fd = null;
        self.child_control_fd = null;
    }

    fn takeRenderRead(self: *EmbedPipes) std.fs.File {
        const file = self.render_read.?;
        self.render_read = null;
        return file;
    }

    fn takeControlWrite(self: *EmbedPipes) std.fs.File {
        const file = self.control_write.?;
        self.control_write = null;
        return file;
    }

    fn deinit(self: *EmbedPipes) void {
        if (self.render_read) |file| file.close();
        if (self.control_write) |file| file.close();
        self.closeChildFds();
    }
};

fn spawnAndWaitEmbedJsonl(_: std.mem.Allocator, child: *std.process.Child, stdout_spec: OutputSpec, stderr_spec: OutputSpec, pipes: *EmbedPipes) !std.process.Child.Term {
    var stdout_sink: ?FileSink = try openStdoutSink(stdout_spec);
    defer if (stdout_sink) |*sink| sink.deinit();
    var stderr_sink: ?FileSink = try openStderrSink(stdout_spec, stderr_spec, if (stdout_sink) |*sink| sink else null);
    defer if (stderr_sink) |*sink| sink.deinit();

    child.pgid = 0;
    try child.spawn();
    pipes.closeChildFds();
    var signal_handlers = installEmbedSignalHandlers(child.id);
    defer signal_handlers.restore();

    var drain_stop = std.atomic.Value(bool).init(false);
    var stdout_thread: ?std.Thread = null;
    if (child.stdout) |stdout_file| {
        child.stdout = null;
        const sink = if (stdout_sink) |*sink| sink else unreachable;
        stdout_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stdout_file, .sink = sink, .stop = &drain_stop }});
    }

    var stderr_thread: ?std.Thread = null;
    if (child.stderr) |stderr_file| {
        child.stderr = null;
        const sink = switch (stderr_spec) {
            .stdout => if (stdout_sink) |*sink| sink else unreachable,
            .file => if (stderr_sink) |*sink| sink else unreachable,
            else => unreachable,
        };
        stderr_thread = try std.Thread.spawn(.{}, drainPipeToSink, .{DrainArgs{ .source = stderr_file, .sink = sink, .stop = &drain_stop }});
    }

    const render_thread = try std.Thread.spawn(.{}, copyFileToFile, .{CopyFileArgs{
        .source = pipes.takeRenderRead(),
        .dest = std.fs.File.stdout(),
        .close_source = true,
        .close_dest = false,
    }});
    const control_thread = try std.Thread.spawn(.{}, forwardEmbedControl, .{EmbedControlForwardArgs{
        .source = std.fs.File.stdin(),
        .dest = pipes.takeControlWrite(),
        .child_pgid = child.id,
    }});
    control_thread.detach();

    const term = try child.wait();
    drain_stop.store(true, .seq_cst);
    if (stdout_thread) |thread| thread.join();
    if (stderr_thread) |thread| thread.join();
    render_thread.join();
    return term;
}

const EmbedSignalHandlers = struct {
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,

    fn restore(self: *const EmbedSignalHandlers) void {
        embed_signal_child_pgid.store(0, .seq_cst);
        std.posix.sigaction(std.posix.SIG.INT, &self.old_int, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.old_term, null);
    }
};

fn installEmbedSignalHandlers(child_pgid: std.posix.pid_t) EmbedSignalHandlers {
    embed_signal_child_pgid.store(child_pgid, .seq_cst);
    const action = std.posix.Sigaction{
        .handler = .{ .handler = embedSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var handlers: EmbedSignalHandlers = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &action, &handlers.old_int);
    std.posix.sigaction(std.posix.SIG.TERM, &action, &handlers.old_term);
    return handlers;
}

fn embedSignalHandler(sig: i32) callconv(.c) void {
    const pgid = embed_signal_child_pgid.load(.seq_cst);
    if (pgid > 0) {
        std.posix.kill(-pgid, std.posix.SIG.TERM) catch {};
    }
    std.posix.exit(@intCast(128 + sig));
}

const EmbedControlForwardArgs = struct {
    source: std.fs.File,
    dest: std.fs.File,
    child_pgid: std.posix.pid_t,
};

fn forwardEmbedControl(args: EmbedControlForwardArgs) void {
    var source = args.source;
    var dest = args.dest;
    defer dest.close();

    var line = std.ArrayList(u8).empty;
    defer line.deinit(std.heap.page_allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = source.read(&buf) catch {
            terminateEmbedChildAfterGrace(args.child_pgid);
            return;
        };
        if (n == 0) {
            terminateEmbedChildAfterGrace(args.child_pgid);
            return;
        }
        dest.writeAll(buf[0..n]) catch {
            terminateEmbedChildAfterGrace(args.child_pgid);
            return;
        };
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                if (embedControlLineRequestsShutdown(line.items)) {
                    terminateEmbedChildAfterGrace(args.child_pgid);
                    return;
                }
                line.clearRetainingCapacity();
            } else if (byte != '\r') {
                if (line.items.len < 64 * 1024) {
                    line.append(std.heap.page_allocator, byte) catch {
                        line.clearRetainingCapacity();
                    };
                } else {
                    line.clearRetainingCapacity();
                }
            }
        }
    }
}

fn embedControlLineRequestsShutdown(line: []const u8) bool {
    var control = render_batch_protocol.parseControlMessage(std.heap.page_allocator, line) catch return false;
    defer render_batch_protocol.deinitControlMessage(std.heap.page_allocator, &control);
    return switch (control) {
        .shutdown => true,
        else => false,
    };
}

fn terminateEmbedChildAfterGrace(child_pgid: std.posix.pid_t) void {
    if (child_pgid <= 0) return;
    std.Thread.sleep(1500 * std.time.ns_per_ms);
    terminateProcessGroup(child_pgid);
}

fn terminateProcessGroup(pgid: std.posix.pid_t) void {
    std.posix.kill(-pgid, std.posix.SIG.TERM) catch {};
    std.Thread.sleep(250 * std.time.ns_per_ms);
    std.posix.kill(-pgid, std.posix.SIG.KILL) catch {};
}

const CopyFileArgs = struct {
    source: std.fs.File,
    dest: std.fs.File,
    close_source: bool,
    close_dest: bool,
};

fn copyFileToFile(args: CopyFileArgs) void {
    var source = args.source;
    var dest = args.dest;
    defer if (args.close_source) source.close();
    defer if (args.close_dest) dest.close();
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = source.read(&buf) catch return;
        if (n == 0) return;
        dest.writeAll(buf[0..n]) catch return;
    }
}

fn dupFdAtLeast(fd: std.posix.fd_t, min: std.posix.fd_t) !std.posix.fd_t {
    return @intCast(try std.posix.fcntl(fd, std.posix.F.DUPFD, @intCast(min)));
}

fn destroyRawPipe(pipe: [2]std.posix.fd_t) void {
    std.posix.close(pipe[0]);
    std.posix.close(pipe[1]);
}

fn drainPipeToSink(args: DrainArgs) void {
    defer args.source.close();
    setNonBlocking(args.source.handle);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = args.source.read(&buf) catch |err| switch (err) {
            error.WouldBlock => {
                if (args.stop.load(.seq_cst)) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return,
        };
        if (n == 0) return;
        args.sink.writeAll(buf[0..n]);
    }
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    var typed_flags: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    typed_flags.NONBLOCK = true;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed_flags))) catch {};
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
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, .{ .truncate = true, .read = false });
    return std.fs.cwd().createFile(path, .{ .truncate = true, .read = false });
}

fn ensureSeedFiles(allocator: std.mem.Allocator, seed_files: []const profiles_mod.SeedFile) !void {
    for (seed_files) |entry| {
        if (try fileExists(entry.path)) continue;
        const bytes = if (entry.content) |content|
            content
        else blk: {
            const source = entry.source orelse return error.InvalidSeedFile;
            break :blk try readWholeFile(allocator, source);
        };
        defer if (entry.content == null) allocator.free(bytes);
        const file = try createOutputFile(entry.path);
        defer file.close();
        try file.writeAll(bytes);
    }
}

fn fileExists(path: []const u8) !bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    else
        std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    file.close();
    return true;
}

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        defer file.close();
        return file.readToEndAlloc(allocator, 1024 * 1024);
    }
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn reportOutputTail(allocator: std.mem.Allocator, stdout_spec: OutputSpec, stderr_spec: OutputSpec) void {
    switch (stdout_spec) {
        .file => |path| reportFileTail(allocator, path),
        else => {},
    }
    switch (stderr_spec) {
        .file => |path| reportFileTail(allocator, path),
        .stdout => {},
        else => {},
    }
}

fn reportExecutedCommand(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const line = commandLineForDisplay(allocator, argv) catch return;
    defer allocator.free(line);
    std.debug.print("katzensteg: command: {s}\n", .{line});
}

fn commandLineForDisplay(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index != 0) try out.append(allocator, ' ');
        try appendShellQuotedArg(allocator, &out, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn dryRunCommandLineForDisplay(allocator: std.mem.Allocator, target: []const u8, extra_args: []const []const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, target);
    try argv.appendSlice(allocator, extra_args);
    return commandLineForDisplay(allocator, argv.items);
}

fn appendShellQuotedArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and shellArgCanBeBare(arg)) {
        try out.appendSlice(allocator, arg);
        return;
    }

    try out.append(allocator, '\'');
    for (arg) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

fn shellArgCanBeBare(arg: []const u8) bool {
    for (arg) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '@' or c == '%' or c == '+' or c == '=' or c == ':' or c == ',' or c == '.' or c == '/' or c == '-')) {
            return false;
        }
    }
    return true;
}

fn reportFileTail(allocator: std.mem.Allocator, path: []const u8) void {
    const bytes = readTailFile(allocator, path) catch return;
    defer allocator.free(bytes);
    const tail = lastLines(allocator, bytes, 20) catch return;
    defer allocator.free(tail);
    if (tail.len == 0) return;
    std.debug.print("katzensteg: last output from {s}:\n{s}", .{ path, tail });
    if (tail[tail.len - 1] != '\n') std.debug.print("\n", .{});
}

fn readTailFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const max_tail_bytes: u64 = 64 * 1024;
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{ .mode = .read_only })
    else
        try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    const size = try file.getEndPos();
    const start = if (size > max_tail_bytes) size - max_tail_bytes else 0;
    try file.seekTo(start);
    return file.readToEndAlloc(allocator, @intCast(max_tail_bytes));
}

fn lastLines(allocator: std.mem.Allocator, bytes: []const u8, line_count: usize) ![]const u8 {
    if (line_count == 0 or bytes.len == 0) return allocator.dupe(u8, "");
    var lines_seen: usize = 0;
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        if (bytes[i] == '\n' and i + 1 < bytes.len) {
            lines_seen += 1;
            if (lines_seen == line_count) {
                return allocator.dupe(u8, bytes[i + 1 ..]);
            }
        }
    }
    return allocator.dupe(u8, bytes);
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
        if (std.mem.startsWith(u8, input[i..], "${PATH}")) {
            try out.appendSlice(allocator, expansion.path);
            i += "${PATH}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$PATH")) {
            try out.appendSlice(allocator, expansion.path);
            i += "$PATH".len;
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
        "{{\"composite_mode\":\"{s}\",\"intercept_mode\":\"{s}\",\"window_policy\":\"{s}\",\"real_window\":\"{s}\",\"present_fps\":{d},\"input\":{},\"input_claim\":{},\"input_claim_focus\":{},\"output_profile\":",
        .{
            @tagName(runtime.composite_mode),
            @tagName(runtime.intercept_mode),
            @tagName(runtime.window_policy),
            @tagName(runtime.real_window_visibility),
            runtime.present_fps,
            runtime.input_enabled,
            runtime.input_claimed,
            runtime.input_claim_focus,
        },
    );
    if (runtime.output_profile) |output_profile| {
        try writer.print("\"{s}\"", .{@tagName(output_profile)});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"gl_capture\":\"{s}\",\"vulkan_capture\":{},\"presentation_sink\":\"{s}\",\"presentation_fd\":",
        .{ @tagName(runtime.gl_capture), runtime.vulkan_capture, @tagName(runtime.presentation_sink) },
    );
    if (runtime.presentation_fd) |fd| {
        try writer.print("{d}", .{fd});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"presentation_control_fd\":");
    if (runtime.presentation_control_fd) |fd| {
        try writer.print("{d}", .{fd});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
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
    const argv = try buildChildArgv(std.testing.allocator, &profile, expansion, &.{});
    defer freeChildArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("/repo/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("/Users/test/hello", argv[1]);
    try std.testing.expectEqualStrings("world", argv[2]);
}

test "launcher appends extra profile arguments after configured args" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "chiaki.sdl",
        .target = "$HOME/dev/chiaki-ng/build-sdl/sdl/chiaki-sdl",
        .args = &.{"--profile-default"},
    };
    const argv = try buildChildArgv(std.testing.allocator, &profile, expansion, &.{ "--host", "192.168.1.100" });
    defer freeChildArgv(std.testing.allocator, argv);

    try std.testing.expectEqualStrings("/Users/test/dev/chiaki-ng/build-sdl/sdl/chiaki-sdl", argv[0]);
    try std.testing.expectEqualStrings("--profile-default", argv[1]);
    try std.testing.expectEqualStrings("--host", argv[2]);
    try std.testing.expectEqualStrings("192.168.1.100", argv[3]);
}

test "launcher output tail keeps the last requested lines" {
    const tail = try lastLines(std.testing.allocator, "one\ntwo\nthree\nfour\n", 2);
    defer std.testing.allocator.free(tail);

    try std.testing.expectEqualStrings("three\nfour\n", tail);
}

test "launcher formats executed command line for failure output" {
    const line = try commandLineForDisplay(std.testing.allocator, &.{ "/bin/echo", "plain", "two words", "it's", "" });
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("/bin/echo plain 'two words' 'it'\\''s' ''", line);
}

test "launcher formats direct dry-run command line with extra args" {
    const line = try dryRunCommandLineForDisplay(std.testing.allocator, "retroarch", &.{ "--fullscreen", "two words" });
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("retroarch --fullscreen 'two words'", line);
}

test "launcher describes missing absolute executable paths" {
    const reason = try spawnFailureReasonForDisplay(std.testing.allocator, "/missing/scummvm", error.FileNotFound);
    defer std.testing.allocator.free(reason);

    try std.testing.expectEqualStrings("executable not found: /missing/scummvm", reason);
}

test "launcher describes missing path lookup commands" {
    const reason = try spawnFailureReasonForDisplay(std.testing.allocator, "scummvm", error.FileNotFound);
    defer std.testing.allocator.free(reason);

    try std.testing.expectEqualStrings("executable not found on PATH: scummvm", reason);
}

test "launcher detects proxy executable basename" {
    try std.testing.expect(isProxyExecutablePath("/repo/zig-out/bin/katzensteg-proxy"));
    try std.testing.expect(isProxyExecutablePath("katzensteg-proxy"));
    try std.testing.expect(!isProxyExecutablePath("/repo/zig-out/bin/katzensteg"));
}

test "launcher resolves profile into launch plan with default log and runtime policy" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "retroarch.sonic",
        .target = "$HOME/dev/RetroArch/retroarch",
        .args = &.{ "-L", "$HOME/core.dylib" },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{});
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

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{});
    defer plan.deinit();

    try std.testing.expectEqualStrings("/repo/probe.out", plan.stdout.file);
    try std.testing.expectEqual(OutputSpec.ignore, plan.stderr);
    try std.testing.expectEqualStrings("DYLD_INSERT_LIBRARIES", plan.env[0].name);
    try std.testing.expectEqualStrings("/repo/zig-out/lib/libkatzensteg-unlinked.dylib", plan.env[0].value);
}

test "launcher resolves and seeds missing files without overwriting existing files" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "retroarch",
        .target = "/bin/echo",
        .seed_files = &.{
            .{ .path = "/tmp/katzensteg-launcher-seed-test.cfg", .content = "video_driver = \"sdl2\"\n" },
        },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{});
    defer plan.deinit();
    try std.testing.expectEqualStrings("/tmp/katzensteg-launcher-seed-test.cfg", plan.seed_files[0].path);

    std.fs.deleteFileAbsolute(plan.seed_files[0].path) catch {};
    defer std.fs.deleteFileAbsolute(plan.seed_files[0].path) catch {};

    try ensureSeedFiles(std.testing.allocator, plan.seed_files);
    const seeded = try readWholeFile(std.testing.allocator, plan.seed_files[0].path);
    defer std.testing.allocator.free(seeded);
    try std.testing.expectEqualStrings("video_driver = \"sdl2\"\n", seeded);

    {
        const file = try std.fs.createFileAbsolute(plan.seed_files[0].path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("keep\n");
    }
    try ensureSeedFiles(std.testing.allocator, plan.seed_files);
    const preserved = try readWholeFile(std.testing.allocator, plan.seed_files[0].path);
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("keep\n", preserved);
}

test "launcher creates seed file parent directories" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "gamescope",
        .target = "/bin/echo",
        .seed_files = &.{
            .{ .path = "/tmp/katzensteg-launcher-seed-parent-test/layer.json", .content = "{}\n" },
        },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{});
    defer plan.deinit();

    std.fs.deleteFileAbsolute("/tmp/katzensteg-launcher-seed-parent-test/layer.json") catch {};
    std.fs.deleteDirAbsolute("/tmp/katzensteg-launcher-seed-parent-test") catch {};
    defer std.fs.deleteFileAbsolute("/tmp/katzensteg-launcher-seed-parent-test/layer.json") catch {};
    defer std.fs.deleteDirAbsolute("/tmp/katzensteg-launcher-seed-parent-test") catch {};

    try ensureSeedFiles(std.testing.allocator, plan.seed_files);
    const seeded = try readWholeFile(std.testing.allocator, plan.seed_files[0].path);
    defer std.testing.allocator.free(seeded);
    try std.testing.expectEqualStrings("{}\n", seeded);
}

test "launcher output drain does not wait for orphaned descendants" {
    const output_path = "/tmp/katzensteg-launcher-orphan-output-test.out";
    std.fs.deleteFileAbsolute(output_path) catch {};
    defer std.fs.deleteFileAbsolute(output_path) catch {};

    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 2 & exit 0" };
    var child = std.process.Child.init(&argv, std.testing.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    const start = try std.time.Instant.now();
    const term = try spawnAndWaitWithOutput(std.testing.allocator, &child, .{ .file = output_path }, .stdout);
    const elapsed = (try std.time.Instant.now()).since(start);

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    try std.testing.expect(elapsed < 1500 * std.time.ns_per_ms);
}

test "launcher expands seed file content placeholders" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "gamescope",
        .target = "/bin/echo",
        .seed_files = &.{
            .{
                .path = "/tmp/katzensteg-launcher-seed-content-test.json",
                .content = "{\"library_path\":\"$HOME/dev/gamescope/layer.so\",\"repo\":\"{repo}\"}\n",
            },
        },
    };

    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{});
    defer plan.deinit();

    try std.testing.expectEqualStrings("{\"library_path\":\"/Users/test/dev/gamescope/layer.so\",\"repo\":\"/repo\"}\n", plan.seed_files[0].content.?);
}

test "launcher refuses broken profiles before resolving launch plan" {
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "moonlight.steam",
        .error_summary = "unknown parent profile: app.moonlight",
    };

    const problem = profileLaunchProblem(&profile).?;
    try std.testing.expectEqualStrings("unknown parent profile: app.moonlight", problem.broken);
}

test "launcher still treats valid fragments as non-launch targets" {
    var profile = profiles_mod.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "runtime.fullscreen_file",
    };

    try std.testing.expectEqual(ProfileLaunchProblem.fragment, profileLaunchProblem(&profile).?);
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

test "launcher expands path placeholders" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo", .path = "/usr/bin:/bin" };
    const path = try expandLauncherString(std.testing.allocator, "{repo}/tools:$PATH:${PATH}", expansion);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/repo/tools:/usr/bin:/bin:/usr/bin:/bin", path);
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

test "launcher command parser recognizes embed jsonl before target" {
    const args = &.{ "katzensteg", "--embed-jsonl", "probe.embed.basic_sdl" };
    try std.testing.expectEqual(Command.run, parseCommand(args));
    try std.testing.expectEqualStrings("probe.embed.basic_sdl", targetArg(args).?);
    try std.testing.expect(launcherEmbedJsonl(args));
}

test "launcher command parser recognizes wm profile target" {
    try std.testing.expectEqual(Command.wm, parseCommand(&.{ "katzensteg", "wm", "probe.embed.basic_sdl" }));
}

test "launcher command parser recognizes wm without initial target" {
    try std.testing.expectEqual(Command.wm, parseCommand(&.{ "katzensteg", "wm" }));
    const wm = parseWmArgs(&.{ "katzensteg", "wm" }).?;
    try std.testing.expectEqual(@as(usize, 0), wm.profile_names.len);
}

test "launcher parses wm target" {
    const wm = parseWmArgs(&.{ "katzensteg", "wm", "probe.embed.basic_sdl" }).?;
    try std.testing.expectEqualStrings("probe.embed.basic_sdl", wm.profile_names[0]);
}

test "launcher parses multiple wm targets" {
    const wm = parseWmArgs(&.{ "katzensteg", "wm", "sonic", "mi2" }).?;
    try std.testing.expectEqual(@as(usize, 2), wm.profile_names.len);
    try std.testing.expectEqualStrings("sonic", wm.profile_names[0]);
    try std.testing.expectEqualStrings("mi2", wm.profile_names[1]);
}

test "launcher parses attach exec argv command" {
    const args = &.{ "katzensteg", "attach", "--exec", "--", "katzensteg", "--embed-jsonl", "probe.embed.basic_sdl" };
    try std.testing.expectEqual(Command.attach, parseCommand(args));
    const attach = parseAttachArgs(args).?;
    try std.testing.expectEqualStrings("katzensteg", attach.exec_argv[0]);
    try std.testing.expectEqualStrings("--embed-jsonl", attach.exec_argv[1]);
    try std.testing.expectEqualStrings("probe.embed.basic_sdl", attach.exec_argv[2]);
    try std.testing.expectEqual(@as(?@import("render_batch_protocol.zig").PresentationRectCells, null), attach.rect_cells);
    try std.testing.expectEqual(@import("render_batch_protocol.zig").PresentationAspect.fit, attach.aspect);
}

test "launcher parses attach rect and aspect before exec argv" {
    const args = &.{ "katzensteg", "attach", "--rect", "5,3,80,24", "--aspect", "stretch", "--exec", "--", "katzensteg", "--embed-jsonl", "probe.embed.basic_sdl" };
    const attach = parseAttachArgs(args).?;

    try std.testing.expectEqual(@import("render_batch_protocol.zig").PresentationRectCells{ .row = 3, .col = 5, .rows = 24, .cols = 80 }, attach.rect_cells.?);
    try std.testing.expectEqual(@import("render_batch_protocol.zig").PresentationAspect.stretch, attach.aspect);
    try std.testing.expectEqualStrings("katzensteg", attach.exec_argv[0]);
}

test "launcher rejects attach exec without argv terminator" {
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--exec", "katzensteg" }) == null);
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--exec", "--" }) == null);
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--rect", "0,1,80,24", "--exec", "--", "katzensteg" }) == null);
    try std.testing.expect(parseAttachArgs(&.{ "katzensteg", "attach", "--aspect", "contain", "--exec", "--", "katzensteg" }) != null);
}

test "launcher embed jsonl overrides runtime presentation fds" {
    var runtime = defaultRuntimeConfig();
    const original_output_profile = runtime.output_profile;
    applyEmbedJsonlRuntime(&runtime, .{ .presentation_fd = 100, .control_fd = 101 });
    try std.testing.expectEqual(@import("config.zig").PresentationSink.jsonl_fd, runtime.presentation_sink);
    try std.testing.expectEqual(@as(i32, 100), runtime.presentation_fd.?);
    try std.testing.expectEqual(@as(i32, 101), runtime.presentation_control_fd.?);
    try std.testing.expectEqual(original_output_profile, runtime.output_profile);
}

test "launcher recognizes shutdown as an embed session lifetime command" {
    try std.testing.expect(!embedControlLineRequestsShutdown(
        "{\"type\":\"attach\",\"window_id\":\"main\",\"rect_cells\":{\"row\":1,\"col\":1,\"rows\":24,\"cols\":80},\"aspect\":\"fit\",\"id_ranges\":{\"image\":[[100000,199999]],\"placement\":[[200000,299999]]}}",
    ));
    try std.testing.expect(embedControlLineRequestsShutdown("{\"type\":\"shutdown\"}"));
    try std.testing.expect(embedControlLineRequestsShutdown("{\"type\":\"shutdown\",\"reason\":\"host_closed\"}"));
    try std.testing.expect(!embedControlLineRequestsShutdown("{\"type\":\"detach\",\"window_id\":\"main\"}"));
}

test "launcher target parser skips options and supports option terminator" {
    try std.testing.expectEqualStrings("example", targetArg(&.{ "katzensteg", "--dry-run", "example" }).?);
    try std.testing.expectEqualStrings("--odd-command-name", targetArg(&.{ "katzensteg", "--", "--odd-command-name" }).?);
    try std.testing.expectEqual(@as(usize, 2), targetArgIndex(&.{ "katzensteg", "--dry-run", "example", "extra" }).?);
    try std.testing.expect(targetArg(&.{ "katzensteg", "--dry-run" }) == null);
}

test "launcher dry-run option is only consumed before target" {
    try std.testing.expect(launcherDryRun(&.{ "katzensteg", "--dry-run", "example" }));
    try std.testing.expect(!launcherDryRun(&.{ "katzensteg", "example", "--dry-run" }));
}

test "runtime config JSON includes render batch fds" {
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var runtime = defaultRuntimeConfig();
    applyEmbedJsonlRuntime(&runtime, .{ .presentation_fd = 100, .control_fd = 101 });
    try writeRuntimeConfigJson(&writer, runtime);
    const out = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"presentation_sink\":\"jsonl_fd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"presentation_fd\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"presentation_control_fd\":101") != null);
}
