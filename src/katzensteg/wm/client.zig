const std = @import("std");

// Early model types for separating WM session lifecycle and transport policy
// from the current stdio-only host implementation.
pub const SessionId = u32;

pub const OwnedChild = struct {
    pid: i32,
};

pub const AttachedProcess = struct {
    pid: ?i32 = null,
};

pub const ClientLifecycle = union(enum) {
    owned_child: OwnedChild,
    attached_process: AttachedProcess,
    external: void,

    pub fn ownsProcess(self: ClientLifecycle) bool {
        return self == .owned_child;
    }
};

pub const StdioChannel = struct {
    stdin_open: bool = true,
    stdout_open: bool = true,
};

pub const SocketChannel = struct {
    fd: i32,
};

pub const ClientChannel = union(enum) {
    stdio: StdioChannel,
    socket: SocketChannel,
};

test "owned child lifecycle reports ownership" {
    const lifecycle = ClientLifecycle{ .owned_child = .{ .pid = 1234 } };
    try std.testing.expect(lifecycle.ownsProcess());
}

test "external lifecycle does not own process" {
    const lifecycle = ClientLifecycle{ .external = {} };
    try std.testing.expect(!lifecycle.ownsProcess());
}
