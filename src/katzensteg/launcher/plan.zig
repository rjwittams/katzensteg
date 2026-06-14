const std = @import("std");
const context = @import("context.zig");
const profiles = @import("../launcher_profiles.zig");
pub const RuntimeConfig = @TypeOf(@as(profiles.LaunchProfile, .{ .allocator = undefined, .name = "" }).runtime);
pub const PresentationSink = @TypeOf(@as(RuntimeConfig, .{}).presentation_sink);

pub const OutputSpec = union(enum) {
    inherit,
    ignore,
    stdout,
    file: []const u8,

    pub fn deinit(self: OutputSpec, allocator: std.mem.Allocator) void {
        switch (self) {
            .file => |path| allocator.free(path),
            else => {},
        }
    }
};

pub const ResolvedLaunchPlan = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    target: []const u8,
    argv: [][]const u8,
    cwd: ?[]const u8,
    stdout: OutputSpec,
    stderr: OutputSpec,
    env: []profiles.EnvVar,
    seed_files: []profiles.SeedFile,
    runtime: RuntimeConfig,

    pub fn fromProfile(allocator: std.mem.Allocator, profile: *const profiles.LaunchProfile, expansion: context.ExpansionContext, extra_args: []const []const u8) !ResolvedLaunchPlan {
        var plan = ResolvedLaunchPlan{
            .allocator = allocator,
            .profile_name = try allocator.dupe(u8, profile.name),
            .target = try context.expandString(allocator, profile.target, expansion),
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
        if (profile.cwd) |raw| plan.cwd = try context.expandString(allocator, raw, expansion);
        plan.stdout = try resolveProfileStdout(allocator, profile, expansion);
        plan.stderr = try resolveProfileStderr(allocator, profile, expansion);
        plan.env = try expandProfileEnv(allocator, profile.env, expansion);
        plan.seed_files = try expandProfileSeedFiles(allocator, profile.seed_files, expansion);
        return plan;
    }

    pub fn deinit(self: *ResolvedLaunchPlan) void {
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

pub fn buildChildArgv(allocator: std.mem.Allocator, profile: *const profiles.LaunchProfile, expansion: context.ExpansionContext, extra_args: []const []const u8) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try context.expandString(allocator, profile.target, expansion));
    for (profile.args) |arg| try argv.append(allocator, try context.expandString(allocator, arg, expansion));
    // Extra args are forwarded verbatim. They are runtime data, not profile
    // templates: a shell caller has already done its own ~/$VAR expansion and
    // any quoting intent must be preserved, and expandString would otherwise
    // rewrite literal $HOME/{repo}/etc. substrings anywhere in the arg. Callers
    // without a shell (the pi extension) expand a leading ~ themselves.
    for (extra_args) |arg| try argv.append(allocator, try allocator.dupe(u8, arg));
    return argv.toOwnedSlice(allocator);
}

pub fn freeChildArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn expandProfileEnv(allocator: std.mem.Allocator, env: []const profiles.EnvVar, expansion: context.ExpansionContext) ![]profiles.EnvVar {
    var out = std.ArrayList(profiles.EnvVar).empty;
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
            .value = try context.expandString(allocator, entry.value, expansion),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn expandProfileSeedFiles(allocator: std.mem.Allocator, seed_files: []const profiles.SeedFile, expansion: context.ExpansionContext) ![]profiles.SeedFile {
    var out = std.ArrayList(profiles.SeedFile).empty;
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
            .path = try context.expandString(allocator, entry.path, expansion),
            .source = if (entry.source) |source| try context.expandString(allocator, source, expansion) else null,
            .content = if (entry.content) |content| try context.expandString(allocator, content, expansion) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn defaultRuntimeConfig() RuntimeConfig {
    return .{
        .intercept_mode = .queued_replay,
        .window_policy = .terminal_only,
        .input_enabled = true,
        .input_claimed = true,
        .output_profile = .file_whole,
    };
}

pub fn resolvedRuntimeConfig(profile: *const profiles.LaunchProfile) RuntimeConfig {
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

fn resolveProfileStdout(allocator: std.mem.Allocator, profile: *const profiles.LaunchProfile, expansion: context.ExpansionContext) !OutputSpec {
    if (profile.stdout) |value| return resolveOutputSpec(allocator, value, expansion);
    const log_name = try sanitizedProfileName(allocator, profile.name);
    defer allocator.free(log_name);
    return .{ .file = try std.fmt.allocPrint(allocator, "/tmp/katzensteg-{s}.out", .{log_name}) };
}

fn resolveProfileStderr(allocator: std.mem.Allocator, profile: *const profiles.LaunchProfile, expansion: context.ExpansionContext) !OutputSpec {
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

pub fn resolveOutputSpec(allocator: std.mem.Allocator, value: ?[]const u8, expansion: context.ExpansionContext) !OutputSpec {
    const raw = value orelse return .inherit;
    if (std.mem.eql(u8, raw, "inherit")) return .inherit;
    if (std.mem.eql(u8, raw, "ignore")) return .ignore;
    if (std.mem.eql(u8, raw, "stdout")) return .stdout;
    return .{ .file = try context.expandString(allocator, raw, expansion) };
}

pub fn outputSpecLabel(spec: OutputSpec) []const u8 {
    return switch (spec) {
        .inherit => "inherit",
        .ignore => "ignore",
        .stdout => "stdout",
        .file => |path| path,
    };
}

test "launch plan appends extra args after profile args" {
    var profile = profiles.LaunchProfile{
        .allocator = std.testing.allocator,
        .name = "demo",
        .target = "$HOME/bin/demo",
        .args = &.{ "--profile-default" },
    };

    const expansion = context.ExpansionContext{ .home = "/Users/test", .repo = "/repo" };
    var plan = try ResolvedLaunchPlan.fromProfile(std.testing.allocator, &profile, expansion, &.{"--extra"});
    defer plan.deinit();

    try std.testing.expectEqualStrings("/Users/test/bin/demo", plan.argv[0]);
    try std.testing.expectEqualStrings("--profile-default", plan.argv[1]);
    try std.testing.expectEqualStrings("--extra", plan.argv[2]);
}
