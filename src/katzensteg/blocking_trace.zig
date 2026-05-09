const std = @import("std");

pub const default_threshold_ns: i128 = 5 * std.time.ns_per_ms;

pub const Settings = struct {
    enabled: bool = false,
    threshold_ns: i128 = default_threshold_ns,
};

pub fn settingsFromEnv() Settings {
    return .{
        .enabled = std.c.getenv("KATZENSTEG_TRACE_BLOCKING") != null,
        .threshold_ns = parseThresholdMs(optionalEnvSpan("KATZENSTEG_TRACE_BLOCKING_THRESHOLD_MS")),
    };
}

pub fn parseThresholdMs(raw: ?[]const u8) i128 {
    const value = raw orelse return default_threshold_ns;
    if (value.len == 0) return default_threshold_ns;
    const parsed = std.fmt.parseInt(i128, value, 10) catch return default_threshold_ns;
    if (parsed < 0) return default_threshold_ns;
    return parsed * std.time.ns_per_ms;
}

pub fn shouldLog(enabled: bool, duration_ns: i128, threshold_ns: i128) bool {
    return enabled and duration_ns >= threshold_ns;
}

pub fn start(settings: Settings) ?i128 {
    return if (settings.enabled) std.time.nanoTimestamp() else null;
}

pub fn elapsedMaybe(start_ns: ?i128) ?i128 {
    return if (start_ns) |value| elapsedSince(value) else null;
}

pub fn elapsedSince(start_ns: i128) i128 {
    const elapsed = std.time.nanoTimestamp() - start_ns;
    return if (elapsed < 0) 0 else elapsed;
}

pub fn micros(duration_ns: i128) i128 {
    return @divTrunc(duration_ns, std.time.ns_per_us);
}

fn optionalEnvSpan(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

test "blocking trace parses threshold milliseconds" {
    try std.testing.expectEqual(@as(i128, 5 * std.time.ns_per_ms), parseThresholdMs(null));
    try std.testing.expectEqual(@as(i128, 5 * std.time.ns_per_ms), parseThresholdMs(""));
    try std.testing.expectEqual(@as(i128, 5 * std.time.ns_per_ms), parseThresholdMs("bad"));
    try std.testing.expectEqual(@as(i128, 0), parseThresholdMs("0"));
    try std.testing.expectEqual(@as(i128, 12 * std.time.ns_per_ms), parseThresholdMs("12"));
}

test "blocking trace only logs enabled durations over threshold" {
    try std.testing.expect(!shouldLog(false, 10, 5));
    try std.testing.expect(!shouldLog(true, 4, 5));
    try std.testing.expect(shouldLog(true, 5, 5));
    try std.testing.expect(shouldLog(true, 6, 5));
}

test "blocking trace start is absent when disabled" {
    try std.testing.expect(start(.{}) == null);
    try std.testing.expect(start(.{ .enabled = true }) != null);
}
