const std = @import("std");

pub const protocol_version = 1;
const max_pending = 16;
const max_registration_bytes = 1024;
const registration_timeout_ms = 5000;

pub const Registration = struct {
    file: std.fs.File,
    title: []const u8,

    pub fn deinit(self: Registration, allocator: std.mem.Allocator) void {
        self.file.close();
        allocator.free(self.title);
    }
};

const Pending = struct {
    file: std.fs.File,
    started_ms: i64,
    bytes: [max_registration_bytes]u8 = undefined,
    len: usize = 0,
};

// Called from the host event loop. Accepts and registration reads are bounded
// and nonblocking; a peer never holds up existing windows while registering.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    path: []const u8,
    inode: std.fs.File.INode,
    pending: [max_pending]Pending = undefined,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, address: []const u8) !Listener {
        const path = if (std.mem.startsWith(u8, address, "~/")) blk: {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, address[2..] });
        } else try allocator.dupe(u8, address);
        errdefer allocator.free(path);
        if (path.len == 0) return error.EmptyListenerPath;
        const addr = try std.net.Address.initUnix(path);
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);
        // Never unlink an existing path: it may belong to another live host.
        try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
        errdefer std.fs.cwd().deleteFile(path) catch {};
        const terminated_path = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated_path);
        if (std.c.chmod(terminated_path, 0o600) != 0) return error.ListenerPermissionsFailed;
        try std.posix.listen(fd, max_pending);
        const stat = try std.fs.cwd().statFile(path);
        return .{ .allocator = allocator, .file = .{ .handle = fd }, .path = path, .inode = stat.inode };
    }

    pub fn deinit(self: *Listener) void {
        for (self.pending[0..self.count]) |pending| pending.file.close();
        self.file.close();
        if (std.fs.cwd().statFile(self.path)) |stat| {
            if (stat.inode == self.inode) std.fs.cwd().deleteFile(self.path) catch {};
        } else |_| {}
        self.allocator.free(self.path);
    }

    pub fn acceptPending(self: *Listener, now_ms: i64) !void {
        for (0..max_pending) |_| {
            const fd = std.posix.accept(self.file.handle, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => return,
                error.ConnectionAborted => continue,
                else => return err,
            };
            if (self.count == max_pending) {
                std.posix.close(fd);
                continue;
            }
            self.pending[self.count] = .{ .file = .{ .handle = fd }, .started_ms = now_ms };
            self.count += 1;
        }
    }

    pub fn nextRegistration(self: *Listener, now_ms: i64) !?Registration {
        var i: usize = 0;
        while (i < self.count) {
            const pending = &self.pending[i];
            if (now_ms - pending.started_ms >= registration_timeout_ms) {
                self.discard(i);
                continue;
            }
            const complete = readRegistration(pending) catch {
                self.discard(i);
                continue;
            };
            if (!complete) {
                i += 1;
                continue;
            }
            const title = parseTitle(self.allocator, pending.bytes[0..pending.len]) catch |err| {
                self.discard(i);
                if (err == error.OutOfMemory) return err;
                continue;
            };
            const file = pending.file;
            self.remove(i);
            return .{ .file = file, .title = title };
        }
        return null;
    }

    fn discard(self: *Listener, index: usize) void {
        self.pending[index].file.close();
        self.remove(index);
    }

    fn remove(self: *Listener, index: usize) void {
        self.count -= 1;
        if (index != self.count) self.pending[index] = self.pending[self.count];
    }
};

fn readRegistration(pending: *Pending) !bool {
    // Read exactly through the newline, retaining subsequent presentation bytes
    // in the socket for the host's ordinary presentation reader.
    while (pending.len < pending.bytes.len) {
        const n = pending.file.read(pending.bytes[pending.len..][0..1]) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return error.Disconnected;
        if (pending.bytes[pending.len] == '\n') return true;
        pending.len += 1;
    }
    return error.RegistrationTooLong;
}

fn parseTitle(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const Message = struct { type: []const u8, version: u32, title: []const u8 };
    const parsed = try std.json.parseFromSlice(Message, allocator, bytes, .{});
    defer parsed.deinit();
    const msg = parsed.value;
    if (!std.mem.eql(u8, msg.type, "register") or msg.version != protocol_version) return error.InvalidRegistration;
    if (msg.title.len == 0 or msg.title.len > 128 or !std.unicode.utf8ValidateSlice(msg.title)) return error.InvalidTitle;
    var codepoints = std.unicode.Utf8View.initUnchecked(msg.title).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return error.InvalidTitle;
    }
    return allocator.dupe(u8, msg.title);
}

test "registration rejects wrong versions and terminal control characters" {
    const allocator = std.testing.allocator;
    const title = try parseTitle(allocator, "{\"type\":\"register\",\"version\":1,\"title\":\"MI2\"}");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("MI2", title);
    try std.testing.expectError(error.InvalidRegistration, parseTitle(allocator, "{\"type\":\"register\",\"version\":2,\"title\":\"MI2\"}"));
    try std.testing.expectError(error.InvalidTitle, parseTitle(allocator, "{\"type\":\"register\",\"version\":1,\"title\":\"\\u001b[2J\"}"));
}

test "listener skips stalled and malformed clients and preserves post registration data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "wm.sock" });
    defer std.testing.allocator.free(path);
    var listener = try Listener.init(std.testing.allocator, path);
    defer listener.deinit();
    const stalled = try std.net.connectUnixSocket(path);
    defer stalled.close();
    try stalled.writeAll("{\"type\":");
    const bad = try std.net.connectUnixSocket(path);
    defer bad.close();
    try bad.writeAll("bad\n");
    const good = try std.net.connectUnixSocket(path);
    defer good.close();
    try good.writeAll("{\"type\":\"register\",\"version\":1,\"title\":\"MI2\"}\nnext\n");
    try listener.acceptPending(0);
    const registered = (try listener.nextRegistration(1)).?;
    defer registered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("MI2", registered.title);
    var buf: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try registered.file.read(&buf));
    try std.testing.expectEqualStrings("next\n", &buf);
    try std.testing.expect((try listener.nextRegistration(1)) == null);
    try std.testing.expect((try listener.nextRegistration(registration_timeout_ms)) == null);
    try std.testing.expectEqual(@as(usize, 0), listener.count);
    // An existing listener must not be replaced by a second host.
    try std.testing.expectError(error.AddressInUse, Listener.init(std.testing.allocator, path));
}
