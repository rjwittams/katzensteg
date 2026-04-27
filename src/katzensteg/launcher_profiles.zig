const std = @import("std");
const config = @import("config.zig");

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
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
    output_profile: bool = false,
    gl_capture: bool = false,
    vulkan_capture: bool = false,
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
        return parseDocuments(allocator, &.{bytes});
    }

    pub fn parseDocuments(allocator: std.mem.Allocator, documents: []const []const u8) !ProfileCatalog {
        if (documents.len == 0) return error.MissingProfiles;

        var profiles = std.ArrayList(LaunchProfile).empty;
        errdefer {
            for (profiles.items) |*profile| profile.deinit();
            profiles.deinit(allocator);
        }

        for (documents, 0..) |bytes, index| {
            const document_name = try std.fmt.allocPrint(allocator, "document[{d}]", .{index});
            defer allocator.free(document_name);
            try parseDocumentInto(allocator, &profiles, bytes, document_name);
        }
        try resolveInheritance(allocator, profiles.items);

        return .{
            .allocator = allocator,
            .profiles = try profiles.toOwnedSlice(allocator),
        };
    }

    pub fn parseDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !ProfileCatalog {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var profiles = std.ArrayList(LaunchProfile).empty;
        errdefer {
            for (profiles.items) |*profile| profile.deinit();
            profiles.deinit(allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const bytes = try dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
            defer allocator.free(bytes);
            try parseDocumentInto(allocator, &profiles, bytes, entry.name);
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

fn parseDocumentInto(allocator: std.mem.Allocator, profiles: *std.ArrayList(LaunchProfile), bytes: []const u8, document_name: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "document parse failed: {s}", .{@errorName(err)}));
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try profiles.append(allocator, try makeBrokenProfile(allocator, document_name, "document root is not an object", .{}));
        return;
    }
    const profiles_value = parsed.value.object.get("profiles") orelse {
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
        const profile = parseProfile(allocator, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
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

fn parseProfile(allocator: std.mem.Allocator, name: []const u8, value: std.json.Value) !LaunchProfile {
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
    if (object.get("target")) |target_value| profile.target = try dupeOptionalString(allocator, target_value, error.InvalidTarget);
    if (object.get("args")) |args_value| {
        profile.args = try parseStringArray(allocator, args_value, error.InvalidArgs);
    }
    if (object.get("cwd")) |cwd_value| profile.cwd = try dupeOptionalString(allocator, cwd_value, error.InvalidCwd);
    if (object.get("stdout")) |stdout_value| profile.stdout = try dupeOptionalString(allocator, stdout_value, error.InvalidStdout);
    if (object.get("stderr")) |stderr_value| profile.stderr = try dupeOptionalString(allocator, stderr_value, error.InvalidStderr);
    if (object.get("env")) |env_value| profile.env = try parseEnvMap(allocator, env_value);
    if (object.get("seed_files")) |seed_files_value| profile.seed_files = try parseSeedFiles(allocator, seed_files_value);
    if (object.get("runtime")) |runtime_value| {
        const parsed_runtime = try parseRuntimeObject(runtime_value);
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

fn dupeOptionalString(allocator: std.mem.Allocator, value: std.json.Value, err: anyerror) ![]const u8 {
    if (value != .string) return err;
    return allocator.dupe(u8, value.string);
}

fn parseEnvMap(allocator: std.mem.Allocator, value: std.json.Value) ![]const EnvVar {
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
        if (entry.value_ptr.* != .string) return error.InvalidEnv;
        try env.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.string),
        });
    }
    return env.toOwnedSlice(allocator);
}

fn parseSeedFiles(allocator: std.mem.Allocator, value: std.json.Value) ![]const SeedFile {
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
        if (path_value != .string) return error.InvalidSeedFiles;
        var seed_file = SeedFile{
            .path = try allocator.dupe(u8, path_value.string),
        };
        errdefer {
            allocator.free(seed_file.path);
            if (seed_file.source) |source| allocator.free(source);
            if (seed_file.content) |content| allocator.free(content);
        }
        if (item.object.get("source")) |source_value| {
            if (source_value != .string) return error.InvalidSeedFiles;
            seed_file.source = try allocator.dupe(u8, source_value.string);
        }
        if (item.object.get("content")) |content_value| {
            if (content_value != .string) return error.InvalidSeedFiles;
            seed_file.content = try allocator.dupe(u8, content_value.string);
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

fn parseRuntimeObject(value: std.json.Value) !ParsedRuntime {
    if (value != .object) return error.InvalidRuntime;
    var runtime = config.RuntimeConfig{};
    var fields = RuntimeFieldSet{};
    if (value.object.get("composite_mode")) |mode| {
        if (mode != .string) return error.InvalidRuntime;
        runtime.composite_mode = config.parseCompositeMode(mode.string) orelse return error.InvalidRuntime;
        fields.composite_mode = true;
    }
    if (value.object.get("intercept_mode")) |mode| {
        if (mode != .string) return error.InvalidRuntime;
        runtime.intercept_mode = config.parseInterceptMode(mode.string) orelse return error.InvalidRuntime;
        fields.intercept_mode = true;
    }
    if (value.object.get("window_policy")) |policy| {
        if (policy != .string) return error.InvalidRuntime;
        runtime.window_policy = config.parseWindowPolicyValue(policy.string, runtime.window_policy);
        fields.window_policy = true;
    }
    if (value.object.get("real_window")) |visibility| {
        if (visibility != .string) return error.InvalidRuntime;
        runtime.real_window_visibility = config.parseRealWindowVisibilityValue(visibility.string, runtime.real_window_visibility);
        fields.real_window = true;
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
        switch (input) {
            .bool => |b| runtime.input_enabled = b,
            .string => |s| runtime.input_enabled = config.parseEnabledEnvValue(s),
            else => return error.InvalidRuntime,
        }
        fields.input = true;
    }
    if (value.object.get("input_claim")) |input_claim| {
        switch (input_claim) {
            .bool => |b| runtime.input_claimed = b,
            .string => |s| runtime.input_claimed = config.parseEnabledEnvValue(s),
            else => return error.InvalidRuntime,
        }
        fields.input_claim = true;
    }
    if (value.object.get("output_profile")) |profile| {
        if (profile != .string) return error.InvalidRuntime;
        runtime.output_profile = config.parseOutputProfile(profile.string) orelse return error.InvalidRuntime;
        fields.output_profile = true;
    }
    if (value.object.get("gl_capture")) |mode| {
        if (mode != .string) return error.InvalidRuntime;
        runtime.gl_capture = config.parseGlCaptureMode(mode.string);
        fields.gl_capture = true;
    }
    if (value.object.get("vulkan_capture")) |enabled| {
        switch (enabled) {
            .bool => |b| runtime.vulkan_capture = b,
            .string => |s| runtime.vulkan_capture = config.parseEnabledEnvValue(s),
            else => return error.InvalidRuntime,
        }
        fields.vulkan_capture = true;
    }
    return .{ .config = runtime, .fields = fields };
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

test "bundled profiles include smb3 ANESE launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("smb3").?;
    try std.testing.expectEqualStrings("$HOME/dev/ANESE/build/anese", profile.target);
    try std.testing.expectEqualStrings("$HOME/roms/smb3.nes", profile.args[0]);
}

test "bundled profiles include Cannonball launch target" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("cannonball").?;
    try std.testing.expectEqualStrings("$HOME/dev/cannonball/build/cannonball", profile.target);
    try std.testing.expectEqualStrings("-cfgfile", profile.args[0]);
    try std.testing.expectEqualStrings("$HOME/dev/cannonball/build/config.xml", profile.args[1]);
}

test "bundled profiles include gamescope SDL Vulkan probe" {
    var catalog = try ProfileCatalog.parseDirectory(std.testing.allocator, "profiles");
    defer catalog.deinit();

    const profile = catalog.find("probe.gamescope").?;
    try std.testing.expectEqualStrings("$HOME/dev/gamescope/build-sdl/src/gamescope", profile.target);
    try std.testing.expectEqualStrings("--backend", profile.args[0]);
    try std.testing.expectEqualStrings("sdl", profile.args[1]);
    try std.testing.expectEqualStrings("--", profile.args[10]);
    try std.testing.expectEqualStrings("vkcube", profile.args[11]);
    try std.testing.expectEqualStrings("--c", profile.args[12]);
    try std.testing.expectEqualStrings("120", profile.args[13]);
    try std.testing.expect(profile.runtime.vulkan_capture);
    try std.testing.expect(profile.runtime.input_enabled);
    try std.testing.expectEqual(config.OutputProfile.file_whole, profile.runtime.output_profile.?);
    try expectEnvValue(profile, "PATH", "$HOME/dev/gamescope/build-sdl/src:$PATH");
    try expectEnvValue(profile, "LD_PRELOAD", "{repo}/zig-out/lib/libkatzensteg-unlinked.so");
    try expectEnvValue(profile, "VK_INSTANCE_LAYERS", "VK_LAYER_KATZENSTEG_capture");
    try expectEnvValue(profile, "KATZENSTEG_TRACE_VULKAN", "1");
    try expectEnvValue(profile, "KATZENSTEG_TRACE_SDL", "1");
}

fn expectEnvValue(profile: *const LaunchProfile, name: []const u8, value: []const u8) !void {
    for (profile.env) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            try std.testing.expectEqualStrings(value, entry.value);
            return;
        }
    }
    return error.EnvVarNotFound;
}
