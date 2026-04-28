const std = @import("std");
const window_policy = @import("window_policy.zig");

const log = std.log.scoped(.config);

pub const CompositeMode = enum {
    fullscreen,
    tiled_strip,
};

pub const InterceptMode = enum {
    sync_compose,
    queued_replay,
};

pub const OutputProfile = enum {
    direct_apc,
    file_whole,
    file_offset_ring,
};

pub const GlCaptureMode = enum {
    disabled,
    sync,
    pbo,
};

pub const RuntimeConfig = struct {
    composite_mode: CompositeMode = .fullscreen,
    intercept_mode: InterceptMode = .sync_compose,
    window_policy: window_policy.WindowPresentationPolicy = .mirror,
    real_window_visibility: window_policy.RealWindowVisibility = .show,
    present_fps: u32 = 0,
    input_enabled: bool = true,
    input_claimed: bool = true,
    gamepad_background: bool = false,
    stats: bool = false,
    image_gc: bool = false,
    debug_protocol_replies: bool = false,
    dump_composites: bool = false,
    debug_composite: bool = false,
    output_profile: ?OutputProfile = null,
    file_transport: bool = true,
    file_transport_max_bytes: u64 = default_file_transport_max_bytes,
    gl_capture: GlCaptureMode = .disabled,
    vulkan_capture: bool = false,
};

pub const default_file_transport_max_bytes: u64 = 10 * 1024 * 1024;

pub const Mutability = enum {
    hot_apply,
    restart_required,
};

pub const RuntimeFieldMetadata = struct {
    name: []const u8,
    env_name: ?[]const u8,
    mutability: Mutability,
};

pub const runtime_field_metadata = [_]RuntimeFieldMetadata{
    .{ .name = "composite_mode", .env_name = "KATZENSTEG_COMPOSITE_MODE", .mutability = .restart_required },
    .{ .name = "intercept_mode", .env_name = "KATZENSTEG_INTERCEPT_MODE", .mutability = .restart_required },
    .{ .name = "window_policy", .env_name = "KATZENSTEG_WINDOW_POLICY", .mutability = .hot_apply },
    .{ .name = "real_window", .env_name = "KATZENSTEG_REAL_WINDOW", .mutability = .hot_apply },
    .{ .name = "present_fps", .env_name = "KATZENSTEG_PRESENT_FPS", .mutability = .hot_apply },
    .{ .name = "input", .env_name = "KATZENSTEG_INPUT", .mutability = .hot_apply },
    .{ .name = "input_claim", .env_name = "KATZENSTEG_INPUT_CLAIM", .mutability = .hot_apply },
    .{ .name = "gamepad_background", .env_name = "KATZENSTEG_GAMEPAD_BACKGROUND", .mutability = .hot_apply },
    .{ .name = "stats", .env_name = "KATZENSTEG_STATS", .mutability = .hot_apply },
    .{ .name = "image_gc", .env_name = "KATZENSTEG_IMAGE_GC", .mutability = .hot_apply },
    .{ .name = "kitty_debug_replies", .env_name = "KATZENSTEG_KITTY_DEBUG_REPLIES", .mutability = .restart_required },
    .{ .name = "composite_dump", .env_name = "KATZENSTEG_COMPOSITE_DUMP", .mutability = .restart_required },
    .{ .name = "composite_debug", .env_name = "KATZENSTEG_COMPOSITE_DEBUG", .mutability = .hot_apply },
    .{ .name = "output_profile", .env_name = "KATZENSTEG_OUTPUT_PROFILE", .mutability = .restart_required },
    .{ .name = "file_transport", .env_name = "KATZENSTEG_FILE_TRANSPORT", .mutability = .restart_required },
    .{ .name = "file_transport_max_bytes", .env_name = "KATZENSTEG_FILE_TRANSPORT_MAX_BYTES", .mutability = .restart_required },
    .{ .name = "gl_capture", .env_name = "KATZENSTEG_GL_CAPTURE", .mutability = .restart_required },
    .{ .name = "vulkan_capture", .env_name = "KATZENSTEG_VULKAN_CAPTURE", .mutability = .restart_required },
};

pub fn getRuntimeFieldMetadata(name: []const u8) ?RuntimeFieldMetadata {
    for (runtime_field_metadata) |metadata| {
        if (std.mem.eql(u8, metadata.name, name)) return metadata;
    }
    return null;
}

pub fn loadRuntimeConfig(allocator: std.mem.Allocator) RuntimeConfig {
    var config = RuntimeConfig{};
    if (getEnvOwned(allocator, "KATZENSTEG_CONFIG")) |path| {
        defer allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| {
            log.warn("failed to read config {s}: {any}", .{ path, err });
            return config;
        };
        defer allocator.free(bytes);
        config = parseRuntimeConfigJsonSlice(allocator, bytes) catch |err| {
            log.warn("failed to parse config {s}: {any}", .{ path, err });
            return config;
        };
        log.info("loaded config from {s}", .{path});
    }

    for (runtime_field_metadata) |metadata| {
        const env_name = metadata.env_name orelse continue;
        if (getEnvOwned(allocator, env_name)) |value| {
            defer allocator.free(value);
            _ = applyRuntimeConfigEnvValue(&config, env_name, value);
        }
    }
    return config;
}

pub fn parseRuntimeConfigJsonSlice(allocator: std.mem.Allocator, bytes: []const u8) !RuntimeConfig {
    var config = RuntimeConfig{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value.object.get("composite_mode")) |value| {
        if (value == .string) {
            config.composite_mode = parseCompositeMode(value.string) orelse blk: {
                log.warn("unknown composite_mode in config: {s}", .{value.string});
                break :blk config.composite_mode;
            };
        }
    }
    if (parsed.value.object.get("intercept_mode")) |value| {
        if (value == .string) {
            config.intercept_mode = parseInterceptMode(value.string) orelse blk: {
                log.warn("unknown intercept_mode in config: {s}", .{value.string});
                break :blk config.intercept_mode;
            };
        }
    }
    if (parsed.value.object.get("window_policy")) |value| {
        if (value == .string) {
            config.window_policy = parseWindowPolicyValue(value.string, config.window_policy);
            if (window_policy.parse(value.string) == null) {
                log.warn("unknown window_policy in config: {s}", .{value.string});
            }
        }
    }
    if (parsed.value.object.get("real_window")) |value| {
        if (value == .string) {
            config.real_window_visibility = parseRealWindowVisibilityValue(value.string, config.real_window_visibility);
            if (window_policy.parseRealWindowVisibility(value.string) == null) {
                log.warn("unknown real_window in config: {s}", .{value.string});
            }
        }
    }
    if (parsed.value.object.get("present_fps")) |value| {
        switch (value) {
            .integer => |n| {
                if (n > 0) config.present_fps = @intCast(n);
            },
            else => {},
        }
    }
    applyJsonBool(parsed.value, "input", &config.input_enabled);
    applyJsonBool(parsed.value, "input_claim", &config.input_claimed);
    applyJsonBool(parsed.value, "gamepad_background", &config.gamepad_background);
    applyJsonBool(parsed.value, "stats", &config.stats);
    applyJsonBool(parsed.value, "image_gc", &config.image_gc);
    applyJsonBool(parsed.value, "kitty_debug_replies", &config.debug_protocol_replies);
    applyJsonBool(parsed.value, "composite_dump", &config.dump_composites);
    applyJsonBool(parsed.value, "composite_debug", &config.debug_composite);
    applyJsonBool(parsed.value, "file_transport", &config.file_transport);
    applyJsonBool(parsed.value, "vulkan_capture", &config.vulkan_capture);
    if (parsed.value.object.get("output_profile")) |value| {
        if (value == .string) config.output_profile = parseOutputProfile(value.string) orelse config.output_profile;
    }
    if (parsed.value.object.get("file_transport_max_bytes")) |value| {
        switch (value) {
            .integer => |n| {
                if (n > 0) config.file_transport_max_bytes = @intCast(n);
            },
            else => {},
        }
    }
    if (parsed.value.object.get("gl_capture")) |value| {
        if (value == .string) config.gl_capture = parseGlCaptureMode(value.string);
    }
    return config;
}

pub fn applyRuntimeConfigEnvValue(config: *RuntimeConfig, env_name: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, env_name, "KATZENSTEG_COMPOSITE_MODE")) {
        if (parseCompositeMode(value)) |parsed| {
            config.composite_mode = parsed;
        } else {
            log.warn("unknown KATZENSTEG_COMPOSITE_MODE value: {s}", .{value});
        }
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_INTERCEPT_MODE")) {
        if (parseInterceptMode(value)) |parsed| {
            config.intercept_mode = parsed;
        } else {
            log.warn("unknown KATZENSTEG_INTERCEPT_MODE value: {s}", .{value});
        }
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_WINDOW_POLICY")) {
        const before = config.window_policy;
        config.window_policy = parseWindowPolicyValue(value, config.window_policy);
        if (config.window_policy == before and window_policy.parse(value) == null) {
            log.warn("unknown KATZENSTEG_WINDOW_POLICY value: {s}", .{value});
        }
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_REAL_WINDOW")) {
        const before = config.real_window_visibility;
        config.real_window_visibility = parseRealWindowVisibilityValue(value, config.real_window_visibility);
        if (config.real_window_visibility == before and window_policy.parseRealWindowVisibility(value) == null) {
            log.warn("unknown KATZENSTEG_REAL_WINDOW value: {s}", .{value});
        }
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_PRESENT_FPS")) {
        config.present_fps = std.fmt.parseInt(u32, value, 10) catch 0;
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_INPUT")) {
        config.input_enabled = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_INPUT_CLAIM")) {
        config.input_claimed = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_GAMEPAD_BACKGROUND")) {
        config.gamepad_background = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_STATS")) {
        config.stats = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_IMAGE_GC")) {
        config.image_gc = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_KITTY_DEBUG_REPLIES")) {
        config.debug_protocol_replies = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_COMPOSITE_DUMP")) {
        config.dump_composites = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_COMPOSITE_DEBUG")) {
        config.debug_composite = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_OUTPUT_PROFILE")) {
        config.output_profile = parseOutputProfile(value) orelse config.output_profile;
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_FILE_TRANSPORT")) {
        config.file_transport = parseEnabledEnvValue(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_FILE_TRANSPORT_MAX_BYTES")) {
        config.file_transport_max_bytes = std.fmt.parseInt(u64, value, 10) catch config.file_transport_max_bytes;
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_GL_CAPTURE")) {
        config.gl_capture = parseGlCaptureMode(value);
        return true;
    }
    if (std.mem.eql(u8, env_name, "KATZENSTEG_VULKAN_CAPTURE")) {
        config.vulkan_capture = parseEnabledEnvValue(value);
        return true;
    }
    return false;
}

pub fn parseCompositeMode(value: []const u8) ?CompositeMode {
    if (std.mem.eql(u8, value, "fullscreen")) return .fullscreen;
    if (std.mem.eql(u8, value, "tiled_strip")) return .tiled_strip;
    return null;
}

pub fn parseInterceptMode(value: []const u8) ?InterceptMode {
    if (std.mem.eql(u8, value, "sync_compose")) return .sync_compose;
    if (std.mem.eql(u8, value, "queued_replay")) return .queued_replay;
    return null;
}

pub fn parseOutputProfile(value: []const u8) ?OutputProfile {
    if (std.mem.eql(u8, value, "direct_apc")) return .direct_apc;
    if (std.mem.eql(u8, value, "file_whole")) return .file_whole;
    if (std.mem.eql(u8, value, "file_offset_ring")) return .file_offset_ring;
    return null;
}

pub fn parseGlCaptureMode(value: []const u8) GlCaptureMode {
    if (!parseEnabledEnvValue(value)) return .disabled;
    if (std.ascii.eqlIgnoreCase(value, "pbo")) return .pbo;
    if (std.ascii.eqlIgnoreCase(value, "async")) return .pbo;
    return .sync;
}

pub fn parseWindowPolicyValue(value: ?[]const u8, fallback: window_policy.WindowPresentationPolicy) window_policy.WindowPresentationPolicy {
    const raw = value orelse return fallback;
    return window_policy.parse(raw) orelse fallback;
}

pub fn parseRealWindowVisibilityValue(value: ?[]const u8, fallback: window_policy.RealWindowVisibility) window_policy.RealWindowVisibility {
    const raw = value orelse return fallback;
    return window_policy.parseRealWindowVisibility(raw) orelse fallback;
}

fn getEnvOwned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

fn applyJsonBool(root: std.json.Value, key: []const u8, field: *bool) void {
    const value = root.object.get(key) orelse return;
    switch (value) {
        .bool => |b| field.* = b,
        .string => |s| field.* = parseEnabledEnvValue(s),
        else => {},
    }
}

pub fn parseEnabledEnvValue(value: []const u8) bool {
    return !(std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"));
}

test "runtime config JSON overrides existing fields" {
    const json =
        \\{
        \\  "composite_mode": "tiled_strip",
        \\  "intercept_mode": "queued_replay",
        \\  "window_policy": "terminal_only",
        \\  "real_window": "hide",
        \\  "present_fps": 30
        \\}
    ;

    const config = try parseRuntimeConfigJsonSlice(std.testing.allocator, json);

    try std.testing.expectEqual(CompositeMode.tiled_strip, config.composite_mode);
    try std.testing.expectEqual(InterceptMode.queued_replay, config.intercept_mode);
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.terminal_only, config.window_policy);
    try std.testing.expectEqual(window_policy.RealWindowVisibility.hide, config.real_window_visibility);
    try std.testing.expectEqual(@as(u32, 30), config.present_fps);
}

test "runtime config JSON ignores invalid values and preserves defaults" {
    const json =
        \\{
        \\  "composite_mode": "bad",
        \\  "intercept_mode": "bad",
        \\  "window_policy": "bad",
        \\  "real_window": "bad",
        \\  "present_fps": -1
        \\}
    ;

    const config = try parseRuntimeConfigJsonSlice(std.testing.allocator, json);

    try std.testing.expectEqual(CompositeMode.fullscreen, config.composite_mode);
    try std.testing.expectEqual(InterceptMode.sync_compose, config.intercept_mode);
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.mirror, config.window_policy);
    try std.testing.expectEqual(window_policy.RealWindowVisibility.show, config.real_window_visibility);
    try std.testing.expectEqual(@as(u32, 0), config.present_fps);
}

test "runtime config defaults to fullscreen composite" {
    const config = RuntimeConfig{};
    try std.testing.expectEqual(CompositeMode.fullscreen, config.composite_mode);
    try std.testing.expectEqual(window_policy.RealWindowVisibility.show, config.real_window_visibility);
}

test "window policy value parser defaults and falls back" {
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.mirror, parseWindowPolicyValue(null, .mirror));
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.terminal_only, parseWindowPolicyValue("terminal_only", .mirror));
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.real_only, parseWindowPolicyValue("real_only", .mirror));
    try std.testing.expectEqual(window_policy.WindowPresentationPolicy.terminal_only, parseWindowPolicyValue("bad", .terminal_only));
}

test "real window visibility value parser defaults and falls back" {
    try std.testing.expectEqual(window_policy.RealWindowVisibility.show, parseRealWindowVisibilityValue(null, .show));
    try std.testing.expectEqual(window_policy.RealWindowVisibility.hide, parseRealWindowVisibilityValue("hide", .show));
    try std.testing.expectEqual(window_policy.RealWindowVisibility.minimize, parseRealWindowVisibilityValue("minimize", .show));
    try std.testing.expectEqual(window_policy.RealWindowVisibility.hide, parseRealWindowVisibilityValue("bad", .hide));
}

test "runtime field metadata describes env names and mutability" {
    const composite = getRuntimeFieldMetadata("composite_mode").?;
    try std.testing.expectEqualStrings("KATZENSTEG_COMPOSITE_MODE", composite.env_name.?);
    try std.testing.expectEqual(Mutability.restart_required, composite.mutability);

    const window = getRuntimeFieldMetadata("window_policy").?;
    try std.testing.expectEqualStrings("KATZENSTEG_WINDOW_POLICY", window.env_name.?);
    try std.testing.expectEqual(Mutability.hot_apply, window.mutability);

    const real_window = getRuntimeFieldMetadata("real_window").?;
    try std.testing.expectEqualStrings("KATZENSTEG_REAL_WINDOW", real_window.env_name.?);
    try std.testing.expectEqual(Mutability.hot_apply, real_window.mutability);

    const present_fps = getRuntimeFieldMetadata("present_fps").?;
    try std.testing.expectEqualStrings("KATZENSTEG_PRESENT_FPS", present_fps.env_name.?);
    try std.testing.expectEqual(Mutability.hot_apply, present_fps.mutability);

    try std.testing.expect(getRuntimeFieldMetadata("missing") == null);
}

test "runtime config JSON parses extended env-compatible fields" {
    const json =
        \\{
        \\  "input": false,
        \\  "input_claim": false,
        \\  "gamepad_background": true,
        \\  "stats": true,
        \\  "image_gc": true,
        \\  "kitty_debug_replies": true,
        \\  "composite_dump": true,
        \\  "composite_debug": true,
        \\  "output_profile": "file_whole",
        \\  "file_transport": false,
        \\  "file_transport_max_bytes": 4096,
        \\  "gl_capture": "pbo",
        \\  "vulkan_capture": true
        \\}
    ;

    const config = try parseRuntimeConfigJsonSlice(std.testing.allocator, json);

    try std.testing.expect(!config.input_enabled);
    try std.testing.expect(!config.input_claimed);
    try std.testing.expect(config.gamepad_background);
    try std.testing.expect(config.stats);
    try std.testing.expect(config.image_gc);
    try std.testing.expect(config.debug_protocol_replies);
    try std.testing.expect(config.dump_composites);
    try std.testing.expect(config.debug_composite);
    try std.testing.expectEqual(OutputProfile.file_whole, config.output_profile.?);
    try std.testing.expect(!config.file_transport);
    try std.testing.expectEqual(@as(u64, 4096), config.file_transport_max_bytes);
    try std.testing.expectEqual(GlCaptureMode.pbo, config.gl_capture);
    try std.testing.expect(config.vulkan_capture);
}

test "runtime config env values override extended fields" {
    var config = RuntimeConfig{};

    try std.testing.expect(applyRuntimeConfigEnvValue(&config, "KATZENSTEG_INPUT", "0"));
    try std.testing.expect(applyRuntimeConfigEnvValue(&config, "KATZENSTEG_OUTPUT_PROFILE", "direct_apc"));
    try std.testing.expect(applyRuntimeConfigEnvValue(&config, "KATZENSTEG_FILE_TRANSPORT_MAX_BYTES", "8192"));
    try std.testing.expect(applyRuntimeConfigEnvValue(&config, "KATZENSTEG_GL_CAPTURE", "async"));
    try std.testing.expect(applyRuntimeConfigEnvValue(&config, "KATZENSTEG_VULKAN_CAPTURE", "1"));

    try std.testing.expect(!config.input_enabled);
    try std.testing.expectEqual(OutputProfile.direct_apc, config.output_profile.?);
    try std.testing.expectEqual(@as(u64, 8192), config.file_transport_max_bytes);
    try std.testing.expectEqual(GlCaptureMode.pbo, config.gl_capture);
    try std.testing.expect(config.vulkan_capture);
    try std.testing.expect(!applyRuntimeConfigEnvValue(&config, "KATZENSTEG_UNKNOWN", "1"));
}
