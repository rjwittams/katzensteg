//! Optional daemon provider. Handles are owned by the caller, on one owner
//! thread. Release each render borrow before pulling again or destroying its
//! session; destroy all sessions before closing their provider.
const std = @import("std");
const options = @import("cleat_options");
pub const c = @cImport({
    @cInclude("cleat_provider.h");
});
pub const Pin = struct { abi: u32, protocol: u32 };
pub const pin = Pin{ .abi = options.abi, .protocol = options.protocol };
pub const VersionMismatch = struct { expected: Pin, actual: Pin };
pub const VersionCheck = union(enum) { compatible, mismatch: VersionMismatch };

pub fn compareVersions(expected: Pin, actual: Pin) VersionCheck {
    if (expected.abi != actual.abi or expected.protocol != actual.protocol)
        return .{ .mismatch = .{ .expected = expected, .actual = actual } };
    return .compatible;
}

pub fn protocolVersion(text: []const u8) !u32 {
    const marker = "protocol ";
    const start = (std.mem.indexOf(u8, text, marker) orelse return error.InvalidVersion) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, ',') orelse return error.InvalidVersion;
    return std.fmt.parseInt(u32, text[start..end], 10) catch error.InvalidVersion;
}

/// Runs the installed binary directly (no shell). A mismatch preserves both
/// expected and reported ABI/protocol pairs for the host's status message.
pub fn checkVersions(a: std.mem.Allocator, io: std.Io, binary: []const u8, expected: Pin) !VersionCheck {
    const result = try std.process.run(a, io, .{ .argv = &.{ binary, "--version" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.VersionCommandFailed,
        else => return error.VersionCommandFailed,
    }
    return compareVersions(expected, .{ .abi = c.cleat_provider_abi_version(), .protocol = try protocolVersion(result.stdout) });
}

pub const OpenResult = union(enum) { provider: Provider, mismatch: VersionMismatch };
pub const Provider = struct {
    handle: *c.cleat_provider,

    /// Check versions before opening the daemon connection. runtime_root is
    /// explicit so callers can isolate tests from any user's daemon.
    pub fn open(a: std.mem.Allocator, io: std.Io, binary: []const u8, runtime_root: []const u8, expected: Pin) !OpenResult {
        switch (try checkVersions(a, io, binary, expected)) {
            .mismatch => |m| return .{ .mismatch = m },
            .compatible => {},
        }
        var desc = std.mem.zeroes(c.cleat_provider_desc);
        desc.abi_version = expected.abi;
        desc.backend = c.CLEAT_PROVIDER_BACKEND_DAEMON;
        desc.requested_features = c.CLEAT_PROVIDER_FEATURE_RENDER_UPDATES | c.CLEAT_PROVIDER_FEATURE_IMAGE_STATE;
        desc.runtime_root = runtime_root.ptr;
        desc.runtime_root_len = runtime_root.len;
        return .{ .provider = .{ .handle = c.cleat_provider_open(&desc) orelse return error.ProviderOpenFailed } };
    }
    pub fn close(self: Provider) void {
        c.cleat_provider_close(self.handle);
    }
    pub fn create(self: Provider, desc: c.cleat_session_desc) !Session {
        return .{ .handle = c.cleat_session_create(self.handle, &desc) orelse return error.SessionCreateFailed };
    }
    pub fn attach(self: Provider, id: []const u8, cols: u16, rows: u16) !Session {
        var desc = std.mem.zeroes(c.cleat_session_desc);
        desc.id = id.ptr;
        desc.id_len = id.len;
        desc.cols = cols;
        desc.rows = rows;
        desc.role = c.CLEAT_ROLE_CONTROLLER;
        return .{ .handle = c.cleat_session_attach(self.handle, &desc) orelse return error.SessionAttachFailed };
    }
};
pub const Session = struct {
    handle: *c.cleat_session,
    /// Detaches this handle; daemon session lifetime is independent.
    pub fn destroy(self: Session) void {
        c.cleat_session_destroy(self.handle);
    }
    pub fn id(self: Session) ![]const u8 {
        var value: c.cleat_str = undefined;
        if (!c.cleat_session_id(self.handle, &value)) return error.NoSessionId;
        return value.ptr[0..value.len];
    }
    pub fn pull(self: Session) ?c.cleat_render_update {
        _ = c.cleat_session_poll(self.handle);
        var update = std.mem.zeroes(c.cleat_render_update);
        if (!c.cleat_session_render_update(self.handle, &update)) return null;
        return update;
    }
    pub fn release(self: Session, update: *c.cleat_render_update) void {
        c.cleat_session_release_render_update(self.handle, update);
    }
    pub fn sendInput(self: Session, event: c.cleat_input_event) !void {
        if (!c.cleat_session_send_input(self.handle, &event)) return error.InputFailed;
    }
    pub fn resize(self: Session, cols: u16, rows: u16) !void {
        if (!c.cleat_session_resize(self.handle, cols, rows)) return error.ResizeFailed;
    }
    pub fn scrollViewport(self: Session, kind: u32, delta_rows: i32) !void {
        var command = std.mem.zeroes(c.cleat_viewport_command);
        command.kind = kind;
        command.delta_rows = delta_rows;
        var result = std.mem.zeroes(c.cleat_viewport_command_result);
        if (!c.cleat_session_scroll_viewport(self.handle, &command, &result)) return error.ScrollFailed;
    }
    pub fn reportGeometry(self: Session, geometry: c.cleat_terminal_geometry) !void {
        if (!c.cleat_session_update_geometry(self.handle, &geometry)) return error.GeometryFailed;
    }
};

test "pin rejects each incompatible ABI or protocol and carries both pairs" {
    // The issue requires exact ABI and protocol agreement, with both versions
    // available on mismatch. Enumerate neighbours and the zero boundary.
    for ([_]u32{ 0, pin.abi - 1, pin.abi, pin.abi + 1 }) |abi| {
        for ([_]u32{ 0, pin.protocol - 1, pin.protocol, pin.protocol + 1 }) |protocol| {
            const actual = Pin{ .abi = abi, .protocol = protocol };
            const result = compareVersions(pin, actual);
            if (abi == pin.abi and protocol == pin.protocol) {
                try std.testing.expect(result == .compatible);
            } else {
                try std.testing.expect(result == .mismatch);
                try std.testing.expectEqualDeep(VersionMismatch{ .expected = pin, .actual = actual }, result.mismatch);
            }
        }
    }
}
test "version output parses the pinned binary format and rejects missing or invalid protocol" {
    // Glue: the installed CLI reports a numeric protocol inside its build identity.
    try std.testing.expectEqual(@as(u32, 11), try protocolVersion("cleat 0.1.0 (sha, release, opt 3, linux, protocol 11, vt ghostty)\n"));
    for ([_][]const u8{ "", "cleat 0.1.0", "protocol ,", "protocol x,", "protocol 11" }) |text|
        try std.testing.expectError(error.InvalidVersion, protocolVersion(text));
}
