//! Same-user local setup endpoints. No selection preface or private media protocol.
const std = @import("std");
const os = @import("platform");
const builtin = @import("builtin");

extern "c" fn getpeereid(c_int, *c_uint, *c_uint) c_int;

pub fn sameUser(fd: i32) !void {
    var uid: c_uint = undefined;
    if (builtin.os.tag == .macos) {
        var gid: c_uint = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) return error.PeerIdentityUnavailable;
    } else {
        var credentials: extern struct { pid: c_int, uid: c_uint, gid: c_uint } = undefined;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(credentials));
        if (std.c.getsockopt(fd, std.posix.SOL.SOCKET, 17, @ptrCast(&credentials), &len) != 0 or len != @sizeOf(@TypeOf(credentials))) return error.PeerIdentityUnavailable;
        uid = credentials.uid;
    }
    if (uid != std.c.geteuid()) return error.PeerNotAuthorized;
}

pub fn connect(path: []const u8) !i32 {
    const addr = try os.net.Address.initUnix(path);
    const fd = try os.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    errdefer os.posix.close(fd);
    try os.posix.connect(fd, &addr.any, addr.getOsSockLen());
    try sameUser(fd);
    return fd;
}

pub const Listener = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: i32,
    path: []const u8,
    inode: os.fs.File.INode,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Listener {
        if (!std.fs.path.isAbsolute(path)) return error.AbsoluteEndpointRequired;
        const addr = try os.net.Address.initUnix(path);
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        const fd = try os.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0);
        errdefer os.posix.close(fd);
        // Never unlink another publication, even if its owner appears dead.
        try os.posix.bind(fd, &addr.any, addr.getOsSockLen());
        errdefer os.fs.deleteFileAbsolute(io, path) catch {};
        const terminated = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated);
        if (std.c.chmod(terminated, 0o600) != 0) return error.EndpointPermissions;
        try os.posix.listen(fd, 16);
        const info = try os.fs.cwd(io).statFile(path);
        return .{ .io = io, .allocator = allocator, .fd = fd, .path = owned, .inode = info.inode };
    }

    pub fn accept(self: *Listener) !?i32 {
        const fd = os.posix.accept(self.fd, null, null, std.posix.SOCK.CLOEXEC) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        errdefer os.posix.close(fd);
        // Darwin accepted sockets inherit NONBLOCK; Jackstay owns blocking setup.
        const flags = try os.posix.fcntl(fd, std.posix.F.GETFL, 0);
        var typed: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        typed.NONBLOCK = false;
        _ = try os.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed)));
        try sameUser(fd);
        return fd;
    }

    pub fn deinit(self: *Listener) void {
        os.posix.close(self.fd);
        if (os.fs.cwd(self.io).statFile(self.path)) |info| {
            if (info.inode == self.inode) os.fs.deleteFileAbsolute(self.io, self.path) catch {};
        } else |_| {}
        self.allocator.free(self.path);
    }
};
