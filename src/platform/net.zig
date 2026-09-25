const std = @import("std");
const p = std.posix;
const raw = @import("posix.zig");
pub const Address = extern union {
    any: p.sockaddr,
    in: p.sockaddr.in,
    un: p.sockaddr.un,
    pub fn parseIp4(text: []const u8, port: u16) !Address {
        const ip = try std.Io.net.Ip4Address.parse(text, port);
        return .{ .in = .{ .addr = @bitCast(ip.bytes), .port = std.mem.nativeToBig(u16, port) } };
    }
    pub fn initUnix(path: []const u8) !Address {
        var value: Address = .{ .un = .{ .path = undefined } };
        if (path.len >= value.un.path.len) return error.NameTooLong;
        @memset(&value.un.path, 0);
        @memcpy(value.un.path[0..path.len], path);
        return value;
    }
    pub fn getOsSockLen(self: Address) p.socklen_t {
        return if (self.any.family == p.AF.UNIX) @sizeOf(p.sockaddr.un) else @sizeOf(p.sockaddr.in);
    }
    pub fn getPort(self: Address) u16 {
        return std.mem.bigToNative(u16, self.in.port);
    }
};
// Windows sockets are not inherited unless a handle is made inheritable.
const cloexec: u32 = if (@import("builtin").os.tag == .windows) 0 else p.SOCK.CLOEXEC;

pub fn connectUnixSocket(io: std.Io, path: []const u8) !@import("fs.zig").File {
    const address = try Address.initUnix(path);
    const fd = try raw.socket(p.AF.UNIX, p.SOCK.STREAM | cloexec, 0);
    errdefer raw.close(fd);
    try raw.connect(fd, &address.any, address.getOsSockLen());
    return .{ .handle = fd, .io = io };
}

pub fn tcpConnectToAddress(io: std.Io, address: Address) !@import("fs.zig").File {
    const fd = try raw.socket(address.any.family, p.SOCK.STREAM | cloexec, p.IPPROTO.TCP);
    errdefer raw.close(fd);
    try raw.connect(fd, &address.any, address.getOsSockLen());
    return .{ .handle = fd, .io = io };
}
