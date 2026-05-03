const std = @import("std");
const config = @import("config.zig");

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const ProfilePlatform = enum {
    linux,
    macos,
    other,
};

pub const SeedFile = struct {
    path: []const u8,
    source: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const RuntimeFieldSet = struct {
    composite_mode: bool = false,
    intercept_mode: bool = false,
    window_policy: bool = false,
    real_window: bool = false,
    present_fps: bool = false,
    input: bool = false,
    input_claim: bool = false,
    input_claim_focus: bool = false,
    output_profile: bool = false,
    gl_capture: bool = false,
    vulkan_capture: bool = false,
    presentation_sink: bool = false,
    presentation_fd: bool = false,
    presentation_control_fd: bool = false,
};

pub const LaunchProfile = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    extends: []const []const u8 = &.{},
    hidden: bool = false,
    target: []const u8 = "",
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    seed_files: []const SeedFile = &.{},
    runtime: config.RuntimeConfig = .{},
    runtime_fields: RuntimeFieldSet = .{},
    error_summary: ?[]const u8 = null,

    fn deinit(self: *LaunchProfile) void {
        self.allocator.free(self.name);
        for (self.extends) |parent| self.allocator.free(parent);
        self.allocator.free(self.extends);
        if (self.target.len > 0) self.allocator.free(self.target);
        for (self.args) |arg| self.allocator.free(arg);
        self.allocator.free(self.args);
        if (self.cwd) |value| self.allocator.free(value);
        if (self.stdout) |value| self.allocator.free(value);
        if (self.stderr) |value| self.allocator.free(value);
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
        if (self.error_summary) |summary| self.allocator.free(summary);
    }

    pub fn isBroken(self: *const LaunchProfile) bool {
        return self.error_summary != null;
    }
};

pub const ProfileCatalog = struct {
    allocator: std.mem.Allocator,
    profiles: []LaunchProfile,

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !ProfileCatalog {
        return parseForPlatform(allocator, bytes, currentProfilePlatform());
    }

    pub fn parseForPlatform(allocator: std.mem.Allocator, bytes: []const u8, platform: ProfilePlatform) !ProfileCatalog {
        return parseDocumentsForPlatform(allocator, &.{bytes}, platform);
    }

    pub fn parseDocuments(allocator: std.mem.Allocator, documents: []const []const u8) !ProfileCatalog {
        return parseDocumentsForPlatform(allocator, documents, currentProfilePlatform());
    }

    pub fn parseDocumentsForPlatform(allocator: std.mem.Allocator, documents: []const []const u8, platform: ProfilePlatform) !ProfileCatalog {
        if (documents.len == 0) return error.MissingProfiles;

        var profiles = std.ArrayList(LaunchProfile).empty;
        errdefer {
            for (profiles.items) |*profile| profile.deinit();
            profiles.deinit(allocator);
        }

        for (documents, 0..) |bytes, index| {
            const document_name = try std.fmt.allocPrint(allocator, "document[{d}]", .{index});
            defer allocator.free(document_name);
            try parseDocumentInto(allocator, &profiles, bytes, document_name, .strict, platform);
        }
        try resolveInheritance(allocator, profiles.items);

        return .{
            .allocator = allocator,
            .profiles = try profiles.toOwnedSlice(allocator),
        };
    }

    pub fn parseDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !ProfileCatalog {
        return parseDirectoryForPlatform(allocator, dir_path, currentProfilePlatform());
    }

    pub fn parseDirectoryForPlatform(allocator: std.mem.Allocator, dir_path: []const u8, platform: ProfilePlatform) !ProfileCatalog {
        return parseDirectoriesForPlatform(allocator, &.{dir_path}, platform);
    }

    pub fn parseDirectories(allocator: std.mem.Allocator, dir_paths: []const []const u8) !ProfileCatalog {
        return parseDirectoriesForPlatform(allocator, dir_paths, currentProfilePlatform());
    }

    pub fn parseDirectoriesForPlatform(allocator: std.mem.Allocator, dir_paths: []const []const u8, platform: ProfilePlatform) !ProfileCatalog {
        if (dir_paths.len == 0) return error.MissingProfiles;

        var profiles = std.ArrayList(LaunchProfile).empty;
        errdefer {
            for (profiles.items) |*profile| profile.deinit();
            profiles.deinit(allocator);
        }

        for (dir_paths) |dir_path| {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            defer dir.close();

            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
                const bytes = try dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
                defer allocator.free(bytes);
                try parseDocumentInto(allocator, &profiles, bytes, entry.name, .ignore_non_profile, platform);
            }
        }

        try resolveInheritance(allocator, profiles.items);

        return .{
            .allocator = allocator,
            .profiles = try profiles.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *ProfileCatalog) void {
        for (self.profiles) |*profile| profile.deinit();
        self.allocator.free(self.profiles);
    }

    pub fn find(self: *const ProfileCatalog, name: []const u8) ?*const LaunchProfile {
        for (self.profiles) |*profile| {
            if (std.mem.eql(u8, profile.name, name)) return profile;
        }
        return null;
    }
};

fn currentProfilePlatform() ProfilePlatform {
    return switch (@import("builtin").os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => .other,
    };
}

const DocumentParseMode = enum {
    strict,
    ignore_non_profile,
};

fn parseDocumentInto(allocator: std.mem.Allocator, profiles: *std.ArrayList(LaunchProfile), bytes: []const u8, document_name: []const u8, mode: DocumentParseMode, platform: ProfilePlatform) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "document parse failed: {s}", .{@errorName(err)}));
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        if (mode == .ignore_non_profile) return;
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "document root is not an object", .{}));
        return;
    }
    const profiles_value = parsed.value.object.get("profiles") orelse {
        if (mode == .ignore_non_profile) return;
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "missing profiles object", .{}));
        return;
    };
    if (profiles_value != .object) {
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "profiles is not an object", .{}));
        return;
    }

    var it = profiles_value.object.iterator();
    while (it.next()) |entry| {
        if (findProfileIndex(profiles.items, entry.key_ptr.*) != null) {
            try profiles.append(allocator, try makeBrokenProfile(allocator, entry.key_ptr.*, "duplicate profile name", .{}));
            continue;
        }
        if (entry.value_ptr.* != .object) {
            try profiles.append(allocator, try makeBrokenProfile(allocator, entry.key_ptr.*, "profile body is not an object", .{}));
            continue;
        }
        const profile = parseProfile(allocator, entry.key_ptr.*, entry.value_ptr.*, platform) catch |err| {
            if (err == error.OutOfMemory) return err;
            try profiles.append(allocator, try makeBrokenProfile(allocator, entry.key_ptr.*, "profile parse failed: {s}", .{@errorName(err)}));
            continue;
        };
        try profiles.append(allocator, profile);
    }
}

fn makeBrokenProfile(allocator: std.mem.Allocator, name: []const u8, comptime fmt: []const u8, args: anytype) !LaunchProfile {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{
        .allocator = allocator,
        .name = owned_name,
        .error_summary = try std.fmt.allocPrint(allocator, fmt, args),
    };
}

fn parseProfile(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value, platform: ProfilePlatform) !LaunchProfile {
    const object = value.object;

    var profile = LaunchProfile{
        .allocator = allocator,
        .name = try allocator.dupe(u8, name),
    };
    errdefer profile.deinit();

    if (object.get("extends")) |extends_value| profile.extends = try parseStringArray(allocator, extends_value, error.InvalidExtends);
    if (object.get("hidden")) |hidden_value| {
        if (hidden_value != .bool) return error.InvalidHidden;
        profile.hidden = hidden_value.bool;
    }
    if (object.get("target")) |target_value| profile.target = try dupeRequiredPlatformString(allocator, target_value, platform, error.InvalidTarget);
    if (object.get("args")) |args_value| {
        profile.args = try parsePlatformStringArray(allocator, args_value, platform, error.InvalidArgs);
    }
    if (object.get("cwd")) |cwd_value| profile.cwd = try dupeOptionalPlatformString(allocator, cwd_value, platform, error.InvalidCwd);
    if (object.get("stdout")) |stdout_value| profile.stdout = try dupeOptionalPlatformString(allocator, stdout_value, platform, error.InvalidStdout);
    if (object.get("stderr")) |stderr_value| profile.stderr = try dupeOptionalPlatformString(allocator, stderr_value, platform, error.InvalidStderr);
    if (object.get("env")) |env_value| profile.env = try parseEnvMap(allocator, env_value, platform);
    if (object.get("seed_files")) |seed_files_value| profile.seed_files = try parseSeedFiles(allocator, seed_files_value, platform);
    if (object.get("runtime")) |runtime_value| {
        const parsed_runtime = try parseRuntimeObject(runtime_value, platform);
        profile.runtime = parsed_runtime.config;
        profile.runtime_fields = parsed_runtime.fields;
    }
    return profile;
}

fn parseStringArray(allocator: std.mem.Allocator, value: std.json.Value, err: anyerror) ![]const []const u8 {
    if (value != .array) return err;
    var items = std.ArrayList([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (value.array.items) |item_value| {
        if (item_value != .string) return err;
        try items.append(allocator, try allocator.dupe(u8, item_value.string));
    }
    return items.toOwnedSlice(allocator);
}

fn parsePlatformStringArray(allocator: std.mem.Allocator, value: std.json.Value, platform: ProfilePlatform, err: anyerror) ![]const []const u8 {
    if (value != .array) return err;
    var items = std.ArrayList([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (value.array.items) |item_value| {
        if (try dupeOptionalPlatformString(allocator, item_value, platform, err)) |item| {
            items.append(allocator, item) catch |append_err| {
                allocator.free(item);
                return append_err;
            };
        }
    }
    return items.toOwnedSlice(allocator);
}

fn dupeRequiredPlatformString(allocator: std.mem.Allocator, value: std.json.Value, platform: ProfilePlatform, err: anyerror) ![]const u8 {
    return try dupeOptionalPlatformString(allocator, value, platform, err) orelse err;
}

fn dupeOptionalPlatformString(allocator: std.mem.Allocator, value: std.json.Value, platform: ProfilePlatform, err: anyerror) !?[]const u8 {
    const selected = try selectedPlatformString(value, platform, err) orelse return null;
    return try allocator.dupe(u8, selected);
}

fn selectedPlatformString(value: std.json.Value, platform: ProfilePlatform, err: anyerror) !?[]const u8 {
    if (value == .string) return value.string;
    if (value != .object) return err;
    validatePlatformStringObject(value, err) catch |validate_err| return validate_err;
    const selected = value.object.get(platformKey(platform)) orelse return null;
    if (selected != .string) return err;
    return selected.string;
}

fn validatePlatformStringObject(value: std.json.Value, err: anyerror) !void {
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (!isPlatformKey(entry.key_ptr.*)) return err;
        if (entry.value_ptr.* != .string) return err;
    }
}

fn isPlatformKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "linux") or
        std.mem.eql(u8, key, "macos") or
        std.mem.eql(u8, key, "other");
}

fn platformKey(platform: ProfilePlatform) []const u8 {
    return switch (platform) {
        .linux => "linux",
        .macos => "macos",
        .other => "other",
    };
}

fn parseEnvMap(allocator: std.mem.Allocator, value: std.json.Value, platform: ProfilePlatform) ![]const EnvVar {
    if (value != .object) return error.InvalidEnv;
    var env = std.ArrayList(EnvVar).empty;
    errdefer {
        for (env.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        env.deinit(allocator);
    }
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const env_value = try dupeOptionalPlatformString(allocator, entry.value_ptr.*, platform, error.InvalidEnv) orelse continue;
        const env_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(env_name);
        env.append(allocator, .{
            .name = env_name,
            .value = env_value,
        }) catch |append_err| {
            allocator.free(env_value);
            return append_err;
        };
    }
    return env.toOwnedSlice(allocator);
}

fn parseSeedFiles(allocator: std.mem.Allocator, value: std.json.Value, platform: ProfilePlatform) ![]const SeedFile {
    if (value != .array) return error.InvalidSeedFiles;
    var seed_files = std.ArrayList(SeedFile).empty;
    errdefer {
        for (seed_files.items) |entry| {
            allocator.free(entry.path);
            if (entry.source) |source| allocator.free(source);
            if (entry.content) |content| allocator.free(content);
        }
        seed_files.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.InvalidSeedFiles;
        const path_value = item.object.get("path") orelse return error.InvalidSeedFiles;
        const path = try dupeOptionalPlatformString(allocator, path_value, platform, error.InvalidSeedFiles) orelse continue;
        var seed_file = SeedFile{
            .path = path,
        };
        errdefer {
            allocator.free(seed_file.path);
            if (seed_file.source) |source| allocator.free(source);
            if (seed_file.content) |content| allocator.free(content);
        }
        if (item.object.get("source")) |source_value| {
            seed_file.source = try dupeOptionalPlatformString(allocator, source_value, platform, error.InvalidSeedFiles);
        }
        if (item.object.get("content")) |content_value| {
            seed_file.content = try dupeOptionalPlatformString(allocator, content_value, platform, error.InvalidSeedFiles);
        }
        if ((seed_file.source == null) == (seed_file.content == null)) return error.InvalidSeedFiles;
        try seed_files.append(allocator, seed_file);
    }
    return seed_files.toOwnedSlice(allocator);
}

const ParsedRuntime = struct {
    config: config.RuntimeConfig,
    fields: RuntimeFieldSet,
};

fn parseRuntimeObject(value: std.json.Value, platform: ProfilePlatform) !ParsedRuntime {
    if (value != .object) return error.InvalidRuntime;
    var runtime = config.RuntimeConfig{};
    var fields = RuntimeFieldSet{};
    if (value.object.get("composite_mode")) |mode| {
        const selected = try selectedPlatformString(mode, platform, error.InvalidRuntime) orelse null;
        if (selected) |mode_value| {
            runtime.composite_mode = config.parseCompositeMode(mode_value) orelse return error.InvalidRuntime;
            fields.composite_mode = true;
        }
    }
    if (value.object.get("intercept_mode")) |mode| {
        const selected = try selectedPlatformString(mode, platform, error.InvalidRuntime) orelse null;
        if (selected) |mode_value| {
            runtime.intercept_mode = config.parseInterceptMode(mode_value) orelse return error.InvalidRuntime;
            fields.intercept_mode = true;
        }
    }
    if (value.object.get("window_policy")) |policy| {
        const selected = try selectedPlatformString(policy, platform, error.InvalidRuntime) orelse null;
        if (selected) |policy_value| {
            runtime.window_policy = config.parseWindowPolicyValue(policy_value, runtime.window_policy);
            fields.window_policy = true;
        }
    }
    if (value.object.get("real_window")) |visibility| {
        const selected = try selectedPlatformString(visibility, platform, error.InvalidRuntime) orelse null;
        if (selected) |visibility_value| {
            runtime.real_window_visibility = config.parseRealWindowVisibilityValue(visibility_value, runtime.real_window_visibility);
            fields.real_window = true;
        }
    }
    if (value.object.get("present_fps")) |fps| {
        switch (fps) {
            .integer => |n| {
                if (n < 0) return error.InvalidRuntime;
                runtime.present_fps = @intCast(n);
            },
            else => return error.InvalidRuntime,
        }
        fields.present_fps = true;
    }
    if (value.object.get("input")) |input| {
        if (try selectedRuntimeBool(input, platform)) |input_value| {
            runtime.input_enabled = input_value;
            fields.input = true;
        }
    }
    if (value.object.get("input_claim")) |input_claim| {
        if (try selectedRuntimeBool(input_claim, platform)) |input_claim_value| {
            runtime.input_claimed = input_claim_value;
            fields.input_claim = true;
        }
    }
    if (value.object.get("input_claim_focus")) |input_claim_focus| {
        if (try selectedRuntimeBool(input_claim_focus, platform)) |input_claim_focus_value| {
            runtime.input_claim_focus = input_claim_focus_value;
            fields.input_claim_focus = true;
        }
    }
    if (value.object.get("output_profile")) |profile| {
        const selected = try selectedPlatformString(profile, platform, error.InvalidRuntime) orelse null;
        if (selected) |profile_value| {
            runtime.output_profile = config.parseOutputProfile(profile_value) orelse return error.InvalidRuntime;
            fields.output_profile = true;
        }
    }
    if (value.object.get("gl_capture")) |mode| {
        const selected = try selectedPlatformString(mode, platform, error.InvalidRuntime) orelse null;
        if (selected) |mode_value| {
            runtime.gl_capture = config.parseGlCaptureMode(mode_value);
            fields.gl_capture = true;
        }
    }
    if (value.object.get("vulkan_capture")) |enabled| {
        if (try selectedRuntimeBool(enabled, platform)) |enabled_value| {
            runtime.vulkan_capture = enabled_value;
            fields.vulkan_capture = true;
        }
    }
    if (value.object.get("presentation_sink")) |sink| {
        const selected = try selectedPlatformString(sink, platform, error.InvalidRuntime) orelse null;
        if (selected) |sink_value| {
            runtime.presentation_sink = config.parsePresentationSink(sink_value) orelse return error.InvalidRuntime;
            fields.presentation_sink = true;
        }
    }
    if (value.object.get("presentation_fd")) |fd| {
        switch (fd) {
            .integer => |n| {
                if (n < 0) return error.InvalidRuntime;
                runtime.presentation_fd = @intCast(n);
            },
            else => return error.InvalidRuntime,
        }
        fields.presentation_fd = true;
    }
    if (value.object.get("presentation_control_fd")) |fd| {
        switch (fd) {
            .integer => |n| {
                if (n < 0) return error.InvalidRuntime;
                runtime.presentation_control_fd = @intCast(n);
            },
            else => return error.InvalidRuntime,
        }
        fields.presentation_control_fd = true;
    }
    return .{ .config = runtime, .fields = fields };
}

fn selectedRuntimeBool(value: std.json.Value, platform: ProfilePlatform) !?bool {
    return switch (value) {
        .bool => |b| b,
        .string => |s| config.parseEnabledEnvValue(s),
        .object => {
            const selected = try selectedPlatformString(value, platform, error.InvalidRuntime) orelse return null;
            return config.parseEnabledEnvValue(selected);
        },
        else => error.InvalidRuntime,
    };
}

fn resolveInheritance(allocator: std.mem.Allocator, profiles: []LaunchProfile) !void {
    const resolved = try allocator.alloc(bool, profiles.len);
    defer allocator.free(resolved);
    @memset(resolved, false);
    const resolving = try allocator.alloc(bool, profiles.len);
    defer allocator.free(resolving);
    @memset(resolving, false);

    for (profiles, 0..) |_, idx| try resolveProfileAt(allocator, profiles, idx, resolved, resolving);
}

fn resolveProfileAt(allocator: std.mem.Allocator, profiles: []LaunchProfile, idx: usize, resolved: []bool, resolving: []bool) !void {
    if (resolved[idx]) return;
    if (profiles[idx].isBroken()) {
        resolved[idx] = true;
        return;
    }
    if (resolving[idx]) {
        try setProfileError(allocator, &profiles[idx], "profile inheritance cycle", .{});
        resolved[idx] = true;
        return;
    }
    resolving[idx] = true;
    defer resolving[idx] = false;

    const parent_names = profiles[idx].extends;
    for (parent_names) |parent_name| {
        const parent_idx = findProfileIndex(profiles, parent_name) orelse {
            try setProfileError(allocator, &profiles[idx], "unknown parent profile: {s}", .{parent_name});
            resolved[idx] = true;
            return;
        };
        try resolveProfileAt(allocator, profiles, parent_idx, resolved, resolving);
        if (profiles[parent_idx].error_summary) |summary| {
            try setProfileError(allocator, &profiles[idx], "parent profile is broken: {s}: {s}", .{ parent_name, summary });
            resolved[idx] = true;
            return;
        }
        try inheritFrom(allocator, &profiles[idx], &profiles[parent_idx]);
    }
    resolved[idx] = true;
}

fn setProfileError(allocator: std.mem.Allocator, profile: *LaunchProfile, comptime fmt: []const u8, args: anytype) !void {
    if (profile.error_summary != null) return;
    profile.error_summary = try std.fmt.allocPrint(allocator, fmt, args);
}

fn inheritFrom(allocator: std.mem.Allocator, child: *LaunchProfile, parent: *const LaunchProfile) !void {
    if (child.target.len == 0 and parent.target.len > 0) child.target = try allocator.dupe(u8, parent.target);
    if (child.args.len == 0 and parent.args.len > 0) child.args = try dupeStringSlice(allocator, parent.args);
    if (child.cwd == null and parent.cwd != null) child.cwd = try allocator.dupe(u8, parent.cwd.?);
    if (child.stdout == null and parent.stdout != null) child.stdout = try allocator.dupe(u8, parent.stdout.?);
    if (child.stderr == null and parent.stderr != null) child.stderr = try allocator.dupe(u8, parent.stderr.?);
    try inheritEnv(allocator, child, parent);
    try inheritSeedFiles(allocator, child, parent);
    inheritRuntime(child, parent);
}

fn dupeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var copy = std.ArrayList([]const u8).empty;
    errdefer {
        for (copy.items) |value| allocator.free(value);
        copy.deinit(allocator);
    }
    for (values) |value| try copy.append(allocator, try allocator.dupe(u8, value));
    return copy.toOwnedSlice(allocator);
}

fn inheritEnv(allocator: std.mem.Allocator, child: *LaunchProfile, parent: *const LaunchProfile) !void {
    var env = std.ArrayList(EnvVar).empty;
    errdefer {
        for (env.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.value);
        }
        env.deinit(allocator);
    }
    for (parent.env) |entry| {
        if (envContains(child.env, entry.name)) continue;
        try env.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .value = try allocator.dupe(u8, entry.value),
        });
    }
    for (child.env) |entry| {
        try env.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .value = try allocator.dupe(u8, entry.value),
        });
    }
    for (child.env) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.value);
    }
    allocator.free(child.env);
    child.env = try env.toOwnedSlice(allocator);
}

fn inheritSeedFiles(allocator: std.mem.Allocator, child: *LaunchProfile, parent: *const LaunchProfile) !void {
    var seed_files = std.ArrayList(SeedFile).empty;
    errdefer {
        for (seed_files.items) |entry| {
            allocator.free(entry.path);
            if (entry.source) |source| allocator.free(source);
            if (entry.content) |content| allocator.free(content);
        }
        seed_files.deinit(allocator);
    }
    for (parent.seed_files) |entry| {
        if (seedFileContains(child.seed_files, entry.path)) continue;
        try seed_files.append(allocator, try dupeSeedFile(allocator, entry));
    }
    for (child.seed_files) |entry| {
        try seed_files.append(allocator, try dupeSeedFile(allocator, entry));
    }
    for (child.seed_files) |entry| {
        allocator.free(entry.path);
        if (entry.source) |source| allocator.free(source);
        if (entry.content) |content| allocator.free(content);
    }
    allocator.free(child.seed_files);
    child.seed_files = try seed_files.toOwnedSlice(allocator);
}

fn dupeSeedFile(allocator: std.mem.Allocator, entry: SeedFile) !SeedFile {
    var out = SeedFile{
        .path = try allocator.dupe(u8, entry.path),
    };
    errdefer {
        allocator.free(out.path);
        if (out.source) |source| allocator.free(source);
        if (out.content) |content| allocator.free(content);
    }
    if (entry.source) |source| out.source = try allocator.dupe(u8, source);
    if (entry.content) |content| out.content = try allocator.dupe(u8, content);
    return out;
}

fn seedFileContains(seed_files: []const SeedFile, path: []const u8) bool {
    for (seed_files) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

fn envContains(env: []const EnvVar, name: []const u8) bool {
    for (env) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

fn inheritRuntime(child: *LaunchProfile, parent: *const LaunchProfile) void {
    if (!child.runtime_fields.composite_mode and parent.runtime_fields.composite_mode) {
        child.runtime.composite_mode = parent.runtime.composite_mode;
        child.runtime_fields.composite_mode = true;
    }
    if (!child.runtime_fields.intercept_mode and parent.runtime_fields.intercept_mode) {
        child.runtime.intercept_mode = parent.runtime.intercept_mode;
        child.runtime_fields.intercept_mode = true;
    }
    if (!child.runtime_fields.window_policy and parent.runtime_fields.window_policy) {
        child.runtime.window_policy = parent.runtime.window_policy;
        child.runtime_fields.window_policy = true;
    }
    if (!child.runtime_fields.real_window and parent.runtime_fields.real_window) {
        child.runtime.real_window_visibility = parent.runtime.real_window_visibility;
        child.runtime_fields.real_window = true;
    }
    if (!child.runtime_fields.present_fps and parent.runtime_fields.present_fps) {
        child.runtime.present_fps = parent.runtime.present_fps;
        child.runtime_fields.present_fps = true;
    }
    if (!child.runtime_fields.input and parent.runtime_fields.input) {
        child.runtime.input_enabled = parent.runtime.input_enabled;
        child.runtime_fields.input = true;
    }
    if (!child.runtime_fields.input_claim and parent.runtime_fields.input_claim) {
        child.runtime.input_claimed = parent.runtime.input_claimed;
        child.runtime_fields.input_claim = true;
    }
    if (!child.runtime_fields.input_claim_focus and parent.runtime_fields.input_claim_focus) {
        child.runtime.input_claim_focus = parent.runtime.input_claim_focus;
        child.runtime_fields.input_claim_focus = true;
    }
    if (!child.runtime_fields.output_profile and parent.runtime_fields.output_profile) {
        child.runtime.output_profile = parent.runtime.output_profile;
        child.runtime_fields.output_profile = true;
    }
    if (!child.runtime_fields.gl_capture and parent.runtime_fields.gl_capture) {
        child.runtime.gl_capture = parent.runtime.gl_capture;
        child.runtime_fields.gl_capture = true;
    }
    if (!child.runtime_fields.vulkan_capture and parent.runtime_fields.vulkan_capture) {
        child.runtime.vulkan_capture = parent.runtime.vulkan_capture;
        child.runtime_fields.vulkan_capture = true;
    }
    if (!child.runtime_fields.presentation_sink and parent.runtime_fields.presentation_sink) {
        child.runtime.presentation_sink = parent.runtime.presentation_sink;
        child.runtime_fields.presentation_sink = true;
    }
    if (!child.runtime_fields.presentation_fd and parent.runtime_fields.presentation_fd) {
        child.runtime.presentation_fd = parent.runtime.presentation_fd;
        child.runtime_fields.presentation_fd = true;
    }
    if (!child.runtime_fields.presentation_control_fd and parent.runtime_fields.presentation_control_fd) {
        child.runtime.presentation_control_fd = parent.runtime.presentation_control_fd;
        child.runtime_fields.presentation_control_fd = true;
    }
}

fn findProfileIndex(profiles: []const LaunchProfile, name: []const u8) ?usize {
    for (profiles, 0..) |profile, idx| {
        if (std.mem.eql(u8, profile.name, name)) return idx;
    }
    return null;
}

test "profile parser reads launch and runtime fields" {
    const json =
        \\{
        \\  "profiles": {
        \\    "example": {
        \\      "target": "/usr/bin/env",
        \\      "args": ["A=B"],
        \\      "cwd": "/tmp",
        \\      "stdout": "/tmp/example.out",
        \\      "stderr": "stdout",
        \\      "env": {
        \\        "KATZENSTEG_INPUT": "1"
        \\      },
        \\      "seed_files": [
        \\        {
        \\          "path": "/tmp/example.cfg",
        \\          "content": "video_driver = \"sdl2\"\n"
        \\        }
        \\      ],
        \\      "runtime": {
        \\        "composite_mode": "fullscreen",
        \\        "intercept_mode": "queued_replay",
        \\        "window_policy": "terminal_only",
        \\        "real_window": "show",
        \\        "present_fps": 30,
        \\        "input": true,
        \\        "input_claim_focus": false,
        \\        "output_profile": "file_whole",
        \\        "gl_capture": "pbo",
        \\        "vulkan_capture": true
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    const profile = catalog.find("example").?;
    try std.testing.expectEqualStrings("example", profile.name);
    try std.testing.expectEqualStrings("/usr/bin/env", profile.target);
    try std.testing.expectEqualStrings("A=B", profile.args[0]);
    try std.testing.expectEqualStrings("/tmp", profile.cwd.?);
    try std.testing.expectEqualStrings("/tmp/example.out", profile.stdout.?);
    try std.testing.expectEqualStrings("stdout", profile.stderr.?);
    try std.testing.expectEqualStrings("KATZENSTEG_INPUT", profile.env[0].name);
    try std.testing.expectEqualStrings("1", profile.env[0].value);
    try std.testing.expectEqualStrings("/tmp/example.cfg", profile.seed_files[0].path);
    try std.testing.expectEqualStrings("video_driver = \"sdl2\"\n", profile.seed_files[0].content.?);
    try std.testing.expect(!profile.hidden);
    try std.testing.expectEqual(config.RuntimeConfig{
        .intercept_mode = .queued_replay,
        .window_policy = .terminal_only,
        .present_fps = 30,
        .input_claim_focus = false,
        .output_profile = .file_whole,
        .gl_capture = .pbo,
        .vulkan_capture = true,
    }, profile.runtime);
}

test "profile parser supports hidden internal fragments" {
    const json =
        \\{
        \\  "profiles": {
        \\    "app.env": {
        \\      "hidden": true,
        \\      "target": "/usr/bin/env"
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    const profile = catalog.find("app.env").?;
    try std.testing.expect(profile.hidden);
    try std.testing.expectEqualStrings("/usr/bin/env", profile.target);
}

test "launcher profiles parse render batch runtime settings" {
    const json =
        \\{
        \\  "profiles": {
        \\    "embed": {
        \\      "target": "/bin/echo",
        \\      "runtime": {
        \\        "presentation_sink": "jsonl_fd",
        \\        "presentation_fd": 3,
        \\        "presentation_control_fd": 4
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    const profile = catalog.find("embed").?;
    try std.testing.expectEqual(config.PresentationSink.jsonl_fd, profile.runtime.presentation_sink);
    try std.testing.expectEqual(@as(i32, 3), profile.runtime.presentation_fd.?);
    try std.testing.expectEqual(@as(i32, 4), profile.runtime.presentation_control_fd.?);
    try std.testing.expect(profile.runtime_fields.presentation_sink);
    try std.testing.expect(profile.runtime_fields.presentation_fd);
    try std.testing.expect(profile.runtime_fields.presentation_control_fd);
}

test "profile parser resolves platform-specific string values" {
    const json =
        \\{
        \\  "profiles": {
        \\    "example": {
        \\      "target": {
        \\        "linux": "/usr/bin/env",
        \\        "macos": "/bin/env"
        \\      },
        \\      "args": [
        \\        "--common",
        \\        {
        \\          "linux": "--linux",
        \\          "macos": "--macos"
        \\        },
        \\        {
        \\          "macos": "--macos-only"
        \\        }
        \\      ],
        \\      "env": {
        \\        "COMMON": "1",
        \\        "VK_LAYER_PATH": {
        \\          "linux": "{repo}/profiles/vulkan/linux",
        \\          "macos": "{repo}/profiles/vulkan/macos"
        \\        },
        \\        "MACOS_ONLY": {
        \\          "macos": "1"
        \\        }
        \\      },
        \\      "seed_files": [
        \\        {
        \\          "path": {
        \\            "linux": "/tmp/linux.cfg",
        \\            "macos": "/tmp/macos.cfg"
        \\          },
        \\          "content": {
        \\            "linux": "linux\n",
        \\            "macos": "macos\n"
        \\          }
        \\        },
        \\        {
        \\          "path": {
        \\            "macos": "/tmp/macos-only.cfg"
        \\          },
        \\          "content": "unused on linux\n"
        \\        }
        \\      ],
        \\      "runtime": {
        \\        "window_policy": {
        \\          "linux": "terminal_only",
        \\          "macos": "mirror"
        \\        },
        \\        "input": {
        \\          "linux": "1"
        \\        },
        \\        "gl_capture": {
        \\          "macos": "pbo"
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parseForPlatform(std.testing.allocator, json, .linux);
    defer catalog.deinit();

    const profile = catalog.find("example").?;
    try std.testing.expectEqualStrings("/usr/bin/env", profile.target);
    try std.testing.expectEqual(@as(usize, 2), profile.args.len);
    try std.testing.expectEqualStrings("--common", profile.args[0]);
    try std.testing.expectEqualStrings("--linux", profile.args[1]);
    try std.testing.expectEqual(@as(usize, 2), profile.env.len);
    try std.testing.expectEqualStrings("COMMON", profile.env[0].name);
    try std.testing.expectEqualStrings("1", profile.env[0].value);
    try std.testing.expectEqualStrings("VK_LAYER_PATH", profile.env[1].name);
    try std.testing.expectEqualStrings("{repo}/profiles/vulkan/linux", profile.env[1].value);
    try std.testing.expectEqual(@as(usize, 1), profile.seed_files.len);
    try std.testing.expectEqualStrings("/tmp/linux.cfg", profile.seed_files[0].path);
    try std.testing.expectEqualStrings("linux\n", profile.seed_files[0].content.?);
    try std.testing.expectEqual(.terminal_only, profile.runtime.window_policy);
    try std.testing.expect(profile.runtime.input_enabled);
    try std.testing.expect(!profile.runtime_fields.gl_capture);
}

test "profile inheritance fills missing fields and preserves child overrides" {
    const json =
        \\{
        \\  "profiles": {
        \\    "base": {
        \\      "target": "/usr/bin/env",
        \\      "args": ["BASE=1"],
        \\      "env": {
        \\        "KEEP": "base",
        \\        "OVERRIDE": "base"
        \\      },
        \\      "seed_files": [
        \\        {
        \\          "path": "/tmp/retroarch-sdl2.cfg",
        \\          "content": "video_driver = \"sdl2\"\n"
        \\        }
        \\      ],
        \\      "runtime": {
        \\        "intercept_mode": "queued_replay",
        \\        "window_policy": "terminal_only",
        \\        "input": false,
        \\        "output_profile": "file_whole"
        \\      }
        \\    },
        \\    "child": {
        \\      "extends": ["base"],
        \\      "args": ["CHILD=1"],
        \\      "env": {
        \\        "OVERRIDE": "child"
        \\      },
        \\      "runtime": {
        \\        "input": true
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    const profile = catalog.find("child").?;
    try std.testing.expectEqualStrings("/usr/bin/env", profile.target);
    try std.testing.expectEqualStrings("CHILD=1", profile.args[0]);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
    try std.testing.expectEqual(config.InterceptMode.queued_replay, profile.runtime.intercept_mode);
    try std.testing.expectEqual(config.RuntimeConfig{ .window_policy = .terminal_only }, config.RuntimeConfig{ .window_policy = profile.runtime.window_policy });
    try std.testing.expect(profile.runtime.input_enabled);
    try std.testing.expectEqualStrings("KEEP", profile.env[0].name);
    try std.testing.expectEqualStrings("base", profile.env[0].value);
    try std.testing.expectEqualStrings("OVERRIDE", profile.env[1].name);
    try std.testing.expectEqualStrings("child", profile.env[1].value);
    try std.testing.expectEqualStrings("/tmp/retroarch-sdl2.cfg", profile.seed_files[0].path);
}

test "profile inheritance resolves across multiple profile documents" {
    const base_json =
        \\{
        \\  "profiles": {
        \\    "app.echo": {
        \\      "target": "/bin/echo",
        \\      "runtime": {
        \\        "window_policy": "terminal_only"
        \\      }
        \\    }
        \\  }
        \\}
    ;
    const child_json =
        \\{
        \\  "profiles": {
        \\    "echo.hello": {
        \\      "extends": ["app.echo"],
        \\      "args": ["hello"]
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parseDocuments(std.testing.allocator, &.{ base_json, child_json });
    defer catalog.deinit();

    const profile = catalog.find("echo.hello").?;
    try std.testing.expectEqualStrings("/bin/echo", profile.target);
    try std.testing.expectEqualStrings("hello", profile.args[0]);
    try std.testing.expectEqual(config.RuntimeConfig{ .window_policy = .terminal_only }, config.RuntimeConfig{ .window_policy = profile.runtime.window_policy });
}

test "profile parser keeps broken profile entries after parse failures" {
    const json =
        \\{
        \\  "profiles": {
        \\    "good": {
        \\      "target": "/bin/echo"
        \\    },
        \\    "bad": {
        \\      "target": 123
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    try std.testing.expectEqualStrings("/bin/echo", catalog.find("good").?.target);
    const bad = catalog.find("bad").?;
    try std.testing.expect(bad.isBroken());
    try std.testing.expect(bad.error_summary != null);
}

test "profile parser marks profiles with missing parents as broken" {
    const json =
        \\{
        \\  "profiles": {
        \\    "child": {
        \\      "extends": ["missing.parent"]
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parse(std.testing.allocator, json);
    defer catalog.deinit();

    const child = catalog.find("child").?;
    try std.testing.expect(child.isBroken());
    try std.testing.expect(std.mem.indexOf(u8, child.error_summary.?, "missing.parent") != null);
}

test "profile parser keeps loading documents after a malformed document" {
    const malformed_json = "{";
    const good_json =
        \\{
        \\  "profiles": {
        \\    "good": {
        \\      "target": "/bin/echo"
        \\    }
        \\  }
        \\}
    ;

    var catalog = try ProfileCatalog.parseDocuments(std.testing.allocator, &.{ malformed_json, good_json });
    defer catalog.deinit();

    try std.testing.expect(catalog.find("document[0]").?.isBroken());
    try std.testing.expectEqualStrings("/bin/echo", catalog.find("good").?.target);
}

test "bundled retroarch profiles use neutral ROM paths" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const sonic = catalog.find("sonic").?;
    try std.testing.expectEqualStrings("$HOME/roms/sonic.md", sonic.args[sonic.args.len - 1]);

    const jsr = catalog.find("jsr").?;
    try std.testing.expectEqualStrings("$HOME/roms/jgr/jgr.cue", jsr.args[jsr.args.len - 1]);

    const spyro = catalog.find("spyro").?;
    try std.testing.expectEqualStrings("$HOME/roms/spyro/spyro.cue", spyro.args[spyro.args.len - 1]);

    try std.testing.expect(catalog.find("smw") == null);
    try std.testing.expect(catalog.find("sm64ds") == null);
    try std.testing.expect(catalog.find("smb3") == null);
}

test "parseDirectories silently skips non-existent directories" {
    var catalog = try ProfileCatalog.parseDirectories(
        std.testing.allocator,
        &.{ "profiles", "/tmp/katzensteg-nonexistent-profiles-dir-xyzzy" },
    );
    defer catalog.deinit();

    try std.testing.expect(catalog.find("sonic") != null);
    try std.testing.expect(catalog.find("cannonball") != null);
}

test "parseDirectories overlays profiles from multiple directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const overlay_json =
        \\{
        \\  "profiles": {
        \\    "overlay.example": {
        \\      "target": "/bin/echo",
        \\      "args": ["hello"]
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "overlay.json", .data = overlay_json });

    const overlay_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(overlay_dir);

    var catalog = try ProfileCatalog.parseDirectories(
        std.testing.allocator,
        &.{ "profiles", overlay_dir },
    );
    defer catalog.deinit();

    try std.testing.expect(catalog.find("sonic") != null);
    try std.testing.expect(catalog.find("cannonball") != null);

    const overlay = catalog.find("overlay.example").?;
    try std.testing.expectEqualStrings("/bin/echo", overlay.target);
    try std.testing.expectEqualStrings("hello", overlay.args[0]);
}

test "bundled profile directory ignores non-profile JSON documents" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    try std.testing.expect(catalog.find("external-projects.json") == null);
    try std.testing.expect(catalog.find("VK_LAYER_KATZENSTEG_capture.json") == null);
}

test "bundled profiles include Cannonball launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("cannonball").?;
    try std.testing.expectEqualStrings("$HOME/dev/cannonball/build/cannonball", profile.target);
    try std.testing.expectEqualStrings("-cfgfile", profile.args[0]);
    try std.testing.expectEqualStrings("$HOME/dev/cannonball/build/config.xml", profile.args[1]);
}

test "bundled profiles include ffplay passthrough launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("ffplay").?;
    try std.testing.expect(!profile.hidden);
    try std.testing.expectEqualStrings("ffplay", profile.target);
    try std.testing.expectEqual(@as(usize, 0), profile.args.len);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
    try std.testing.expectEqualStrings("software", envValue(profile, "SDL_RENDER_DRIVER").?);
    try std.testing.expect(envValue(profile, "LD_PRELOAD") != null or envValue(profile, "DYLD_INSERT_LIBRARIES") != null);
}

test "bundled Vulkan capture profile resolves platform layer paths" {
    var linux_catalog = try ProfileCatalog.parseDirectoryForPlatform(std.testing.allocator, "profiles", .linux);
    defer linux_catalog.deinit();
    var macos_catalog = try ProfileCatalog.parseDirectoryForPlatform(std.testing.allocator, "profiles", .macos);
    defer macos_catalog.deinit();

    const linux_profile = linux_catalog.find("capture.vulkan").?;
    const macos_profile = macos_catalog.find("capture.vulkan").?;

    try std.testing.expectEqualStrings("{repo}/profiles/vulkan/linux", envValue(linux_profile, "VK_LAYER_PATH").?);
    try std.testing.expectEqualStrings("{repo}/profiles/vulkan/macos", envValue(macos_profile, "VK_LAYER_PATH").?);
    try std.testing.expectEqualStrings("{repo}/zig-out/lib/libkatzensteg-core.so", envValue(linux_profile, "KATZENSTEG_CORE_LIB").?);
    try std.testing.expectEqualStrings("{repo}/zig-out/lib/libkatzensteg-core.dylib", envValue(macos_profile, "KATZENSTEG_CORE_LIB").?);
    try std.testing.expectEqualStrings("VK_LAYER_KATZENSTEG_capture", envValue(linux_profile, "VK_INSTANCE_LAYERS").?);
    try std.testing.expectEqualStrings("1", envValue(macos_profile, "KATZENSTEG_VULKAN_CAPTURE").?);
}

test "bundled profiles include experimental macOS SDL2 rebind adapter" {
    var catalog = try ProfileCatalog.parseDirectoryForPlatform(std.testing.allocator, "profiles", .macos);
    defer catalog.deinit();

    const profile = catalog.find("adapter.sdl2_rebind_preload").?;
    try std.testing.expect(profile.hidden);
    try std.testing.expectEqualStrings(
        "{repo}/zig-out/lib/libkatzensteg-sdl2-rebind.dylib",
        envValue(profile, "DYLD_INSERT_LIBRARIES").?,
    );
    try std.testing.expect(envValue(profile, "LD_PRELOAD") == null);
}

test "bundled RetroArch profiles disable pause when inactive" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    for ([_][]const u8{ "sonic", "jsr", "spyro" }) |name| {
        const profile = catalog.find(name).?;
        var found = false;
        for (profile.seed_files) |seed| {
            if (seed.content) |content| {
                if (std.mem.indexOf(u8, content, "pause_nonactive = \"false\"\n") != null) found = true;
            }
        }
        try std.testing.expect(found);
    }
}

fn envValue(profile: *const LaunchProfile, name: []const u8) ?[]const u8 {
    for (profile.env) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

test "bundled profiles include gamescope SDL Vulkan probe" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("probe.gamescope").?;
    try std.testing.expect(!profile.isBroken());
    try std.testing.expect(profile.target.len > 0);
    try std.testing.expect(profile.args.len > 0);
    try std.testing.expect(profile.runtime.vulkan_capture);
    try std.testing.expect(profile.runtime.input_enabled);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
    try std.testing.expect(profile.seed_files.len > 0);
}

test "bundled profiles include embed basic SDL probe" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("probe.embed.basic_sdl").?;
    try std.testing.expect(!profile.isBroken());
    try std.testing.expectEqualStrings("{repo}/zig-out/bin/basic-sdl-demo", profile.target);
    try std.testing.expectEqual(config.PresentationSink.tty, profile.runtime.presentation_sink);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
}

test "bundled profiles include embed luchs static probe" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("probe.embed.luchs_static").?;
    try std.testing.expect(!profile.isBroken());
    try std.testing.expectEqualStrings("{repo}/zig-out/bin/luchs", profile.target);
    try std.testing.expect(profile.args.len >= 1);
    try std.testing.expectEqual(config.PresentationSink.tty, profile.runtime.presentation_sink);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
}

test "bundled profiles include embed luchs interactive probe" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("probe.embed.luchs_interactive").?;
    try std.testing.expect(!profile.isBroken());
    try std.testing.expectEqualStrings("{repo}/zig-out/bin/luchs", profile.target);
    try std.testing.expect(profile.args.len >= 1);
    try std.testing.expectEqualStrings("{repo}/tools/luchs/testdata/interactive.html", profile.args[profile.args.len - 1]);
    try std.testing.expectEqual(config.PresentationSink.tty, profile.runtime.presentation_sink);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
}

test "bundled profiles include Tempest Rising gamescope launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("steam.tempest_rising").?;
    try expectSteamGamescopeProfile(profile);
    try std.testing.expectEqualStrings("1486920", envValue(profile, "SteamAppId").?);
    try std.testing.expect(std.mem.indexOf(u8, profile.args[profile.args.len - 1], "Tempest-Win64-Shipping.exe") != null);
}

test "bundled profiles include Space Marine 2 gamescope launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("steam.space_marine_2").?;
    try expectSteamGamescopeProfile(profile);
    try std.testing.expectEqualStrings("2183900", envValue(profile, "SteamAppId").?);
    try std.testing.expectEqualStrings("$HOME/.local/share/Steam/steamapps/common/Space Marine 2", profile.cwd.?);
    try std.testing.expect(std.mem.indexOf(u8, profile.args[profile.args.len - 3], "Warhammer 40000 Space Marine 2.exe") != null);
    try std.testing.expectEqualStrings("--cwd", profile.args[profile.args.len - 2]);
    try std.testing.expectEqualStrings("client_pc\\root\\bin\\pc", profile.args[profile.args.len - 1]);
}

fn expectSteamGamescopeProfile(profile: *const LaunchProfile) !void {
    try std.testing.expect(!profile.isBroken());
    try std.testing.expect(profile.target.len > 0);
    try std.testing.expect(profile.args.len > 0);
    try std.testing.expect(profile.runtime.vulkan_capture);
    try std.testing.expect(profile.runtime.input_enabled);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
    try std.testing.expect(profile.seed_files.len > 0);
    var child_boundary: ?usize = null;
    for (profile.args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) {
            child_boundary = index;
            break;
        }
    }
    try std.testing.expect(child_boundary != null);
    try std.testing.expectEqualStrings("/usr/bin/env", profile.args[child_boundary.? + 1]);
    var child_vk_layer_path_scoped = false;
    for (profile.args[child_boundary.? + 1 ..]) |arg| {
        if (std.mem.eql(u8, arg, "VK_LAYER_PATH=/tmp/katzensteg-vulkan-layers")) {
            child_vk_layer_path_scoped = true;
        }
    }
    try std.testing.expect(child_vk_layer_path_scoped);
    try std.testing.expect(!colonEnvContains(envValue(profile, "VK_LAYER_PATH").?, "/tmp"));
    var found_wsi_seed = false;
    for (profile.seed_files) |seed| {
        if (std.mem.indexOf(u8, seed.path, "/tmp/katzensteg-vulkan-layers/") != null) {
            found_wsi_seed = true;
        }
    }
    try std.testing.expect(found_wsi_seed);
}

fn colonEnvContains(value: []const u8, needle: []const u8) bool {
    var rest = value;
    while (true) {
        const next = std.mem.indexOfScalar(u8, rest, ':');
        const segment = if (next) |index| rest[0..index] else rest;
        if (std.mem.eql(u8, segment, needle)) return true;
        if (next) |index| {
            rest = rest[index + 1 ..];
        } else {
            return false;
        }
    }
}
