// Adapted from libxev src/posix.zig, MIT, Copyright Mitchell Hashimoto.
// Raw descriptor operations deliberately preserve WouldBlock for host loops.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;
const maxInt = std.math.maxInt;

// This module also runs inside foreign processes. Never diagnose errors on
// stderr; the caller owns file-based logging.
fn unexpectedErrno(_: posix.E) error{Unexpected} {
    return error.Unexpected;
}

pub const ReadError = error{
    AccessDenied,
    InputOutput,
    IsDir,
    NotOpenForReading,
    ProcessNotFound,
    SocketNotConnected,
    SystemResources,
    WouldBlock,
    ConnectionResetByPeer,
    ConnectionTimedOut,
} || posix.UnexpectedError;

pub const PReadError = ReadError || error{Unseekable};

pub const WriteError = error{
    AccessDenied,
    BrokenPipe,
    DeviceBusy,
    DiskQuota,
    FileTooBig,
    InputOutput,
    InvalidArgument,
    MessageTooBig,
    NoSpaceLeft,
    NotOpenForWriting,
    PermissionDenied,
    ProcessNotFound,
    SystemResources,
    WouldBlock,
    ConnectionResetByPeer,
} || posix.UnexpectedError;

pub const PWriteError = WriteError || error{Unseekable};

pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    ProcessFdQuotaExceeded,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    SystemFdQuotaExceeded,
    SystemResources,
} || posix.UnexpectedError;

pub const BindError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    AlreadyBound,
    FileNotFound,
    NameTooLong,
    NotDir,
    ReadOnlyFileSystem,
    SymLinkLoop,
    SystemResources,
} || posix.UnexpectedError;

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    SocketNotBound,
    SystemResources,
} || posix.UnexpectedError;

pub const PipeError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || posix.UnexpectedError;

pub const AcceptError = std.Io.net.Server.AcceptError;

pub const GetSockNameError = error{
    FileDescriptorNotASocket,
    SocketNotBound,
    SystemResources,
} || posix.UnexpectedError;

pub const ConnectError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    AddressInUse,
    AddressNotAvailable,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    FileNotFound,
    NetworkUnreachable,
    PermissionDenied,
    SystemResources,
    WouldBlock,
} || posix.UnexpectedError;

pub fn connect(sock: posix.socket_t, sock_addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
    while (true) {
        switch (posix.errno(system.connect(sock, sock_addr, len))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .INTR => continue,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE, .CONNABORTED => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn getsockoptError(sockfd: posix.fd_t) ConnectError!void {
    const E = std.posix.E;
    const SOL = if (@hasDecl(std.posix, "SOL")) std.posix.SOL else std.os.linux.SOL;
    const SO = if (@hasDecl(std.posix, "SO")) std.posix.SO else std.os.linux.SO;
    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = system.getsockopt(sockfd, SOL.SOCKET, SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (posix.errno(rc)) {
        .SUCCESS => switch (@as(E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .HOSTUNREACH, .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE => unreachable,
            else => |err| return unexpectedErrno(err),
        },
        .BADF, .FAULT, .INVAL => unreachable,
        .NOPROTOOPT, .NOTSOCK => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn close(fd: posix.fd_t) void {
    switch (posix.errno(system.close(fd))) {
        .SUCCESS, .INTR => {},
        .BADF => unreachable,
        else => unreachable,
    }
}

pub fn setCloexec(fd: posix.fd_t) !void {
    while (true) switch (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return unexpectedErrno(err),
    };
}

fn getStatusFlags(fd: posix.fd_t) !u32 {
    while (true) {
        const rc = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn setStatusFlags(fd: posix.fd_t, flags: u32) !void {
    while (true) switch (posix.errno(system.fcntl(fd, posix.F.SETFL, flags))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return unexpectedErrno(err),
    };
}

fn setSockFlags(sock: posix.socket_t, flags: u32) !void {
    if ((flags & posix.SOCK.CLOEXEC) != 0) try setCloexec(sock);
    if ((flags & posix.SOCK.NONBLOCK) != 0) {
        const current = try getStatusFlags(sock);
        try setStatusFlags(sock, current | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    }
}

pub fn accept(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) AcceptError!posix.socket_t {
    while (true) {
        const rc = system.accept(sock, addr, addr_size);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const fd: posix.socket_t = @intCast(rc);
                errdefer close(fd);
                try setSockFlags(fd, flags);
                return fd;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NETDOWN => return error.NetworkDown,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    const have_sock_flags = !builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .haiku;
    const filtered_sock_type = if (have_sock_flags)
        socket_type
    else
        socket_type & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);

    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            const fd: posix.socket_t = @intCast(rc);
            errdefer close(fd);
            if (!have_sock_flags) try setSockFlags(fd, socket_type);
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolNotSupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    switch (posix.errno(system.bind(sock, addr, len))) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .INVAL => return error.AlreadyBound,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .FAULT, .NOTSOCK => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn listen(sock: posix.socket_t, backlog: u31) ListenError!void {
    switch (posix.errno(system.listen(sock, backlog))) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .INVAL => return error.SocketNotBound,
        .MFILE, .NFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        .BADF => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn getsockname(sock: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) GetSockNameError!void {
    switch (posix.errno(system.getsockname(sock, addr, addrlen))) {
        .SUCCESS => return,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        .BADF, .FAULT, .INVAL => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    while (true) {
        const rc = system.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .FAULT, .DESTADDRREQ => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn read(fd: posix.fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .FAULT, .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn pwrite(fd: posix.fd_t, bytes: []const u8, offset: u64) PWriteError!usize {
    if (bytes.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    const pwrite_fn = if (builtin.target.os.tag == .linux and !builtin.target.abi.isMusl() and @hasDecl(system, "pwrite64")) system.pwrite64 else system.pwrite;
    while (true) {
        const rc = pwrite_fn(fd, bytes.ptr, @min(bytes.len, max_count), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => return error.InvalidArgument,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .BUSY => return error.DeviceBusy,
            .NXIO, .SPIPE, .OVERFLOW => return error.Unseekable,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .FAULT, .DESTADDRREQ => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn pread(fd: posix.fd_t, buf: []u8, offset: u64) PReadError!usize {
    if (buf.len == 0) return 0;

    const max_count = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };

    const pread_fn = if (builtin.target.os.tag == .linux and !builtin.target.abi.isMusl() and @hasDecl(system, "pread64")) system.pread64 else system.pread;
    while (true) {
        const rc = pread_fn(fd, buf.ptr, @min(buf.len, max_count), @bitCast(offset));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NXIO, .SPIPE, .OVERFLOW => return error.Unseekable,
            .FAULT, .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn pipe2(flags: posix.O) PipeError![2]posix.fd_t {
    if (!builtin.target.os.tag.isDarwin() and @hasDecl(system, "pipe2")) {
        var fds: [2]posix.fd_t = undefined;
        switch (posix.errno(system.pipe2(&fds, flags))) {
            .SUCCESS => return fds,
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .INVAL, .FAULT => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    var fds: [2]posix.fd_t = undefined;
    switch (posix.errno(system.pipe(&fds))) {
        .SUCCESS => {},
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .INVAL, .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
    }
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }

    if (flags.CLOEXEC) {
        try setCloexec(fds[0]);
        try setCloexec(fds[1]);
    }

    var status_flags = flags;
    status_flags.CLOEXEC = false;
    const status_flags_int = @as(u32, @bitCast(status_flags));
    if (status_flags_int != 0) {
        try setStatusFlags(fds[0], status_flags_int);
        try setStatusFlags(fds[1], status_flags_int);
    }

    return fds;
}

pub fn pipe() ![2]posix.fd_t {
    return pipe2(.{});
}
pub fn fcntl(fd: posix.fd_t, cmd: c_int, arg: usize) !usize {
    while (true) {
        const rc = std.c.fcntl(fd, cmd, arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadFileDescriptor,
            else => |err| return unexpectedErrno(err),
        }
    }
}
pub fn poll(fds: []posix.pollfd, timeout: i32) !usize {
    while (true) {
        const rc = std.c.poll(fds.ptr, @intCast(fds.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => |err| return unexpectedErrno(err),
        }
    }
}
pub fn tcgetattr(fd: posix.fd_t) !posix.termios {
    var attrs: posix.termios = undefined;
    while (true) switch (posix.errno(std.c.tcgetattr(fd, &attrs))) {
        .SUCCESS => return attrs,
        .INTR => continue,
        .NOTTY => return error.NotATerminal,
        .BADF => return error.BadFileDescriptor,
        else => |err| return unexpectedErrno(err),
    };
}
pub fn tcsetattr(fd: posix.fd_t, action: std.c.TCSA, attrs: posix.termios) !void {
    while (std.c.tcsetattr(fd, action, &attrs) != 0) {
        switch (posix.errno(-1)) {
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .BADF => return error.BadFileDescriptor,
            .INVAL => return error.InvalidArgument,
            else => |err| return unexpectedErrno(err),
        }
    }
}
pub fn setsid() !posix.pid_t {
    const rc = std.c.setsid();
    if (rc < 0) return error.PermissionDenied;
    return rc;
}
pub fn fork() !posix.pid_t {
    const rc = std.c.fork();
    if (rc < 0) return error.SystemResources;
    return rc;
}
pub const WaitResult = struct { pid: posix.pid_t, status: u32 };
pub fn waitpid(pid: posix.pid_t, flags: u32) !WaitResult {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, @intCast(flags));
        if (rc >= 0) return .{ .pid = rc, .status = @bitCast(status) };
        switch (posix.errno(rc)) {
            .INTR => continue,
            .CHILD => return error.NoChild,
            else => |err| return unexpectedErrno(err),
        }
    }
}
pub fn shutdown(fd: posix.fd_t, how: enum { recv, send, both }) !void {
    const flags: c_int = switch (how) {
        .recv => 0,
        .send => 1,
        .both => 2,
    };
    if (std.c.shutdown(fd, flags) != 0) return error.SocketNotConnected;
}
pub fn setsockopt(fd: posix.fd_t, level: i32, option: u32, value: []const u8) !void {
    if (std.c.setsockopt(fd, level, option, value.ptr, @intCast(value.len)) != 0) return error.InvalidArgument;
}
pub fn open(path: []const u8, flags: posix.O, mode: std.c.mode_t) !posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    while (true) {
        const rc = std.c.open(z, flags, mode);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .NODEV, .NXIO => return error.NoDevice,
            else => |err| return unexpectedErrno(err),
        }
    }
}
pub fn mkdir(path: []const u8, mode: std.c.mode_t) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    switch (posix.errno(std.c.mkdir(z, mode))) {
        .SUCCESS => {},
        .EXIST => return error.PathAlreadyExists,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOSPC => return error.NoSpaceLeft,
        else => |err| return unexpectedErrno(err),
    }
}
pub fn fstatat(fd: posix.fd_t, path: []const u8, flags: u32) !struct { uid: posix.uid_t, mode: u32 } {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    while (true) {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            switch (linux.errno(linux.statx(fd, z, flags, .{ .UID = true, .MODE = true, .TYPE = true }, &stat))) {
                .SUCCESS => {
                    if (!stat.mask.UID or !stat.mask.MODE or !stat.mask.TYPE) return error.Unexpected;
                    return .{ .uid = stat.uid, .mode = stat.mode };
                },
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        } else {
            var stat: std.c.Stat = undefined;
            switch (posix.errno(std.c.fstatat(fd, z, &stat, @intCast(flags)))) {
                .SUCCESS => return .{ .uid = stat.uid, .mode = stat.mode },
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .ACCES => return error.AccessDenied,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}

pub fn dup2(old: posix.fd_t, new: posix.fd_t) !void {
    while (std.c.dup2(old, new) < 0) {
        if (posix.errno(-1) != .INTR) return error.BadFileDescriptor;
    }
}
