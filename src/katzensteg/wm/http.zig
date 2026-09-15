const std = @import("std");

const max_connections = 16;
const max_request_bytes = 64 * 1024;
const max_header_bytes = 8 * 1024;
const header_separator = "\r\n\r\n";
// Reserve the maximum header and its separator even for requests with shorter
// headers, so the accepted body size is independent of header length.
const max_body_bytes = max_request_bytes - max_header_bytes - header_separator.len;
const timeout_ms = 2000;

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authorization: []const u8 = "",
    client: []const u8 = "",
    body: []const u8,
};

pub const Response = struct {
    pending: ?u32 = null,
    status: u16 = 200,
    body: []const u8 = "{}",
};

const Connection = struct {
    file: std.fs.File,
    started: i64,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    responding: bool = false,
    pending: ?u32 = null,

    fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.file.close();
        self.input.deinit(allocator);
        self.output.deinit(allocator);
    }
};

// Bounded, nonblocking HTTP/1.1 requests with cancellable deferred responses.
// An incomplete request or slow reader must not stop producer frame draining.
pub const Server = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    port: u16,
    connections: [max_connections]Connection = undefined,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, address: []const u8) !Server {
        if (!std.mem.startsWith(u8, address, "127.0.0.1:")) return error.LoopbackRequired;
        const port = try std.fmt.parseInt(u16, address[10..], 10);
        var addr = try std.net.Address.parseIp4("127.0.0.1", port);
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);
        try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
        try std.posix.listen(fd, max_connections);
        var len = addr.getOsSockLen();
        try std.posix.getsockname(fd, &addr.any, &len);
        return .{ .allocator = allocator, .file = .{ .handle = fd }, .port = addr.getPort() };
    }

    pub fn deinit(self: *Server) void {
        for (self.connections[0..self.count]) |*connection| connection.deinit(self.allocator);
        self.file.close();
    }

    pub fn poll(self: *Server, now: i64, context: anytype) !void {
        for (0..max_connections) |_| {
            const fd = std.posix.accept(self.file.handle, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => break,
                error.ConnectionAborted => continue,
                else => return err,
            };
            if (self.count == max_connections) {
                std.posix.close(fd);
                continue;
            }
            self.connections[self.count] = .{ .file = .{ .handle = fd }, .started = now };
            self.count += 1;
        }
        var i: usize = 0;
        while (i < self.count) {
            const connection = &self.connections[i];
            const keep = if (now - connection.started >= (if (connection.pending != null) @as(i64, 5000) else timeout_ms)) false else self.advance(connection, context, now) catch false;
            if (keep) {
                i += 1;
            } else {
                if (connection.pending) |id| context.cancelResponse(id);
                connection.deinit(self.allocator);
                self.count -= 1;
                if (i != self.count) self.connections[i] = self.connections[self.count];
            }
        }
    }

    fn advance(self: *Server, connection: *Connection, context: anytype, now: i64) !bool {
        if (connection.pending) |id| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const response = (try context.pollResponse(arena.allocator(), id, now)) orelse return true;
            context.cancelResponse(id);
            connection.pending = null;
            connection.started = now;
            try self.respond(connection, response);
        }
        if (!connection.responding) {
            var buf: [8192]u8 = undefined;
            const n = connection.file.read(&buf) catch |err| switch (err) {
                error.WouldBlock => return true,
                else => return err,
            };
            if (n == 0) return false;
            if (connection.input.items.len + n > max_request_bytes) return false;
            try connection.input.appendSlice(self.allocator, buf[0..n]);
            const parsed = parse(connection.input.items) catch {
                try self.respond(connection, .{ .status = 400 });
                return true;
            };
            const request = parsed orelse return true;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const response = context.handle(arena.allocator(), request) catch |err| switch (err) {
                // Do not ask the failing handler allocator for another JSON
                // allocation just to report memory pressure as a server failure.
                error.OutOfMemory => Response{ .status = 503, .body = "{\"error\":\"OutOfMemory\"}" },
                else => Response{
                    .status = 400,
                    .body = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .@"error" = @errorName(err) }, .{}),
                },
            };
            if (response.pending) |id| {
                connection.pending = id;
                connection.started = now;
                return true;
            }
            try self.respond(connection, response);
        }
        const n = connection.file.write(connection.output.items[connection.sent..]) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return err,
        };
        connection.sent += n;
        return connection.sent < connection.output.items.len;
    }

    fn respond(self: *Server, connection: *Connection, response: Response) !void {
        var output = std.Io.Writer.Allocating.fromArrayList(self.allocator, &connection.output);
        defer connection.output = output.toArrayList();
        const writer = &output.writer;
        try writer.print("HTTP/1.1 {d} Response\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", .{ response.status, response.body.len });
        try writer.writeAll(response.body);
        connection.responding = true;
    }
};

fn parse(bytes: []const u8) !?Request {
    const header_end = std.mem.indexOf(u8, bytes, header_separator) orelse {
        if (bytes.len > max_header_bytes + header_separator.len - 1) return error.HeadersTooLarge;
        return null;
    };
    if (header_end > max_header_bytes) return error.HeadersTooLarge;
    var lines = std.mem.splitSequence(u8, bytes[0..header_end], "\r\n");
    var first = std.mem.splitScalar(u8, lines.next() orelse return error.BadRequest, ' ');
    const method = first.next() orelse return error.BadRequest;
    const path = first.next() orelse return error.BadRequest;
    const version = first.next() orelse return error.BadRequest;
    if (first.next() != null or !std.mem.eql(u8, version, "HTTP/1.1") or !std.mem.startsWith(u8, path, "/")) return error.BadRequest;
    var request = Request{ .method = method, .path = path, .body = "" };
    var length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Content-Length")) {
            if (length != null) return error.DuplicateLength;
            length = try std.fmt.parseInt(usize, value, 10);
            if (length.? > max_body_bytes) return error.BodyTooLarge;
        } else if (std.ascii.eqlIgnoreCase(key, "Transfer-Encoding")) {
            return error.ChunkedNotSupported;
        } else if (std.ascii.eqlIgnoreCase(key, "Authorization")) {
            if (request.authorization.len != 0) return error.DuplicateAuthorization;
            request.authorization = value;
        } else if (std.ascii.eqlIgnoreCase(key, "X-Katzensteg-Client")) {
            if (request.client.len != 0) return error.DuplicateClient;
            request.client = value;
        }
    }
    const end = header_end + header_separator.len + (length orelse 0);
    if (bytes.len < end) return null;
    request.body = bytes[header_end + header_separator.len .. end];
    return request;
}

pub fn authorized(header: []const u8, token: []const u8) bool {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, header, prefix) or header.len != prefix.len + token.len) return false;
    var difference: u8 = 0;
    for (header[prefix.len..], token) |a, b| difference |= a ^ b;
    return difference == 0;
}

test "HTTP framing waits for bodies and rejects ambiguous lengths" {
    try std.testing.expect((try parse("POST /v1/sessions HTTP/1.1\r\nContent-Length: 2\r\n\r\n{")) == null);
    const request = (try parse("POST /v1/sessions HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")).?;
    try std.testing.expectEqualStrings("{}", request.body);
    try std.testing.expectError(error.DuplicateLength, parse("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n"));
    try std.testing.expectError(error.ChunkedNotSupported, parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
}

test "HTTP token is mandatory and exact" {
    try std.testing.expect(!authorized("", "secret"));
    try std.testing.expect(!authorized("Bearer secrets", "secret"));
    try std.testing.expect(!authorized("Bearer secreT", "secret"));
    try std.testing.expect(authorized("Bearer secret", "secret"));
}

test "HTTP size budget includes the separator and accepts fragmented maximum headers" {
    const allocator = std.testing.allocator;
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    try bytes.writer.print("POST / HTTP/1.1\r\nContent-Length: {d}\r\nX-Pad: ", .{max_body_bytes});
    try bytes.writer.splatByteAll('a', max_header_bytes - bytes.written().len);
    try bytes.writer.writeAll(header_separator[0..2]);
    try std.testing.expect((try parse(bytes.written())) == null);
    try bytes.writer.writeAll(header_separator[2..]);
    try bytes.writer.splatByteAll('b', max_body_bytes);
    try std.testing.expectEqual(max_request_bytes, bytes.written().len);
    try std.testing.expectEqual(max_body_bytes, (try parse(bytes.written())).?.body.len);
    const excessive = try std.fmt.allocPrint(allocator, "POST / HTTP/1.1\r\nContent-Length: {d}\r\n\r\n", .{max_body_bytes + 1});
    defer allocator.free(excessive);
    try std.testing.expectError(error.BodyTooLarge, parse(excessive));
}

test "HTTP handler memory pressure returns 503 while invalid input remains 400" {
    const Context = struct {
        failure: anyerror,
        pub fn handle(self: *@This(), _: std.mem.Allocator, _: Request) anyerror!Response {
            return self.failure;
        }
        pub fn pollResponse(_: *@This(), _: std.mem.Allocator, _: u32, _: i64) !?Response {
            return null;
        }
        pub fn cancelResponse(_: *@This(), _: u32) void {}
    };
    var server = try Server.init(std.testing.allocator, "127.0.0.1:0");
    defer server.deinit();
    for ([_]anyerror{ error.OutOfMemory, error.InvalidInput }) |failure| {
        var fds: [2]std.posix.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        const client = std.fs.File{ .handle = fds[0] };
        defer client.close();
        var connection = Connection{ .file = .{ .handle = fds[1] }, .started = 0 };
        defer connection.deinit(std.testing.allocator);
        try client.writeAll("GET /v1/test HTTP/1.1\r\n\r\n");
        var context = Context{ .failure = failure };
        try std.testing.expect(!try server.advance(&connection, &context, 0));
        var response: [512]u8 = undefined;
        const n = try client.read(&response);
        try std.testing.expect(std.mem.startsWith(u8, response[0..n], if (failure == error.OutOfMemory) "HTTP/1.1 503 " else "HTTP/1.1 400 "));
        try std.testing.expect(std.mem.indexOf(u8, response[0..n], @errorName(failure)) != null);
    }
}
