const std = @import("std");
const system_io = @import("platform");
const http = @import("http.zig");
const producer_mod = @import("producer.zig");
const Producer = producer_mod.Producer;
const control = @import("producer_control.zig");
const protocol = @import("../render_batch_protocol.zig");
const peer_protocol = @import("../attach_protocol.zig");
const Listener = @import("listener.zig").Listener;
const graphics = @import("graphics_output.zig");
const terminal_mod = @import("host_terminal.zig");
const Logger = @import("../log.zig").Logger;

pub const Options = struct {
    http_address: []const u8 = "127.0.0.1:0",
    tty_path: ?[]const u8 = null,
    host_file: ?[]const u8 = null,
    parent_pid: ?i32 = null,
    background: bool = false,
    idle_refresh_ms: u32 = 500,
    wrap_command: []const []const u8 = &.{},
};

const lease_ms = 120_000;
const idle_ms = 30_000;
const max_clients = 16;
const max_sessions = 128;
var stopping = std.atomic.Value(u8).init(0);
fn stop(signal: std.posix.SIG) callconv(.c) void {
    stopping.store(@intCast(@intFromEnum(signal)), .seq_cst);
}

const Client = struct {
    id: [32]u8,
    listener: Listener,
    seen: i64,
    parent_pid: ?i32 = null,
    parent_checked_at: i64 = 0,
};
const Grid = struct { cols: i32, rows: i32 };
const Session = struct {
    io: std.Io,
    id: u32,
    owner: [32]u8,
    title: []const u8,
    producer: Producer,
    directory: []const u8,
    upload_path: []const u8,
    upload_profile: protocol.UploadProfile = .file_whole,
    image_id: u32,
    observation_path: []const u8,
    grid: ?Grid = null,
    last_target_px: ?protocol.SourcePixels = null,
    buttons: u32 = 0,
    source_px: ?protocol.SourcePixels = null,
    input_supported: bool = true,
    ready: bool = false,
    restore_pending: bool = false,
    last_frame_at: i64 = 0,
    last_refresh_at: i64 = 0,
    closing_at: ?i64 = null,
    exited_at: ?i64 = null,
    line: std.ArrayList(u8) = .empty,

    fn close(self: *Session, now: i64) void {
        if (self.closing_at != null or self.exited_at != null) return;
        self.closing_at = now;
        self.producer.shutdown();
    }

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        const io = self.io;
        self.producer.deinit();
        self.line.deinit(allocator);
        system_io.fs.cwd(io).deleteTree(self.directory) catch {};
        allocator.free(self.directory);
        allocator.free(self.upload_path);
        allocator.free(self.observation_path);
        allocator.free(self.title);
    }
};

const PendingObservation = struct {
    id: u32,
    session_id: u32,
    owner: [32]u8,
    after_frame: ?u64,
    deadline: i64,
    sent_at: i64 = 0,
    in_flight: bool = false,
    latest: ?peer_protocol.Observation = null,
};

const Host = struct {
    allocator: std.mem.Allocator,
    executable: []const u8,
    terminal: *terminal_mod.Terminal,
    directory: []const u8,
    token: [32]u8,
    server: http.Server,
    logger: Logger,
    clients: std.ArrayList(Client) = .empty,
    sessions: std.ArrayList(Session) = .empty,
    next_session: u32 = 1,
    presentation_start: usize = 0,
    next_observation: u32 = 1,
    observations: [16]?PendingObservation = @splat(null),
    idle_since: i64,
    pending_deletes: std.ArrayList(u32) = .empty,
    idle_refresh_ms: u32 = 500,

    fn deinit(self: *Host) void {
        for (self.sessions.items) |*session| {
            if (session.exited_at == null) {
                self.deleteImage(session.image_id) catch {};
            }
            session.deinit(self.allocator);
        }
        for (self.clients.items) |*client| client.listener.deinit();
        self.clients.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.flushDeletes() catch {};
        if (self.terminal.relay) |relay| {
            const deadline = system_io.time.milliTimestamp() + 250;
            while (self.pending_deletes.items.len > 0 and relay.boundary.safe() and system_io.time.milliTimestamp() < deadline) {
                relay.tick() catch break;
                self.flushDeletes() catch break;
                if (self.pending_deletes.items.len > 0) system_io.time.sleep(std.time.ns_per_ms);
            }
        }
        self.pending_deletes.deinit(self.allocator);
        self.server.deinit();
        self.logger.deinit();
    }

    fn deleteImage(self: *Host, id: u32) !void {
        if (self.terminal.relay == null) {
            var writer = self.terminal.file.writerStreaming(&.{});
            return graphics.delete(&writer.interface, id);
        }
        if (self.pending_deletes.items.len >= max_sessions) return error.DeferredDeletesFull;
        try self.pending_deletes.append(self.allocator, id);
        try self.flushDeletes();
    }
    fn flushDeletes(self: *Host) !void {
        if (self.pending_deletes.items.len == 0) return;
        // Only deleteImage's relay path queues deletes; direct output is immediate.
        std.debug.assert(self.terminal.relay != null);
        if (self.terminal.outputQueued()) return;
        var bytes = std.Io.Writer.Allocating.init(self.allocator);
        defer bytes.deinit();
        for (self.pending_deletes.items) |id| try graphics.delete(&bytes.writer, id);
        try self.terminal.relay.?.graphics(bytes.written());
        self.pending_deletes.clearRetainingCapacity();
    }

    fn loop(self: *Host) !void {
        while (stopping.load(.seq_cst) == 0) {
            if (self.terminal.relay) |relay| {
                try relay.tick();
                if (relay.boundary.cleared) {
                    relay.boundary.cleared = false;
                    for (self.sessions.items) |*session| session.restore_pending = true;
                }
                if (relay.done()) break;
            }
            const now = system_io.time.milliTimestamp();
            try self.server.poll(now, self);
            try self.tick(now);
            if (self.clients.items.len > 0) self.idle_since = now;
            if (self.terminal.relay == null and self.clients.items.len == 0 and now - self.idle_since >= idle_ms) break;
            var fds: [max_sessions + max_clients + 20]std.posix.pollfd = undefined;
            var count: usize = 0;
            fds[count] = .{ .fd = self.server.file.handle, .events = std.posix.POLL.IN, .revents = 0 };
            count += 1;
            for (self.server.connections[0..self.server.count]) |connection| {
                fds[count] = .{ .fd = connection.file.handle, .events = if (connection.responding) std.posix.POLL.OUT else std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
            for (self.clients.items) |client| {
                fds[count] = .{ .fd = client.listener.file.handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            }
            for (self.sessions.items) |session| if (session.producer.channel.presentationFile()) |file| {
                fds[count] = .{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 };
                count += 1;
            };
            if (self.terminal.relay) |relay| count += relay.pollDescriptors(fds[count..]);
            _ = system_io.posix.poll(fds[0..count], 20) catch {};
        }
        const deadline = system_io.time.milliTimestamp() + 2100;
        while (self.clients.items.len > 0) self.closeClient(0, system_io.time.milliTimestamp());
        for (self.sessions.items) |*session| session.close(system_io.time.milliTimestamp());
        while (system_io.time.milliTimestamp() < deadline) {
            if (self.terminal.relay) |relay| relay.tick() catch {};
            try self.tick(system_io.time.milliTimestamp());
            const alive = for (self.sessions.items) |session| {
                if (session.exited_at == null) break true;
            } else false;
            if (!alive) break;
            system_io.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn tick(self: *Host, now: i64) !void {
        const io = self.terminal.file.io;
        try self.flushDeletes();
        var ci: usize = 0;
        while (ci < self.clients.items.len) {
            const client = &self.clients.items[ci];
            const parent_gone = if (now - client.parent_checked_at >= 1000) blk: {
                client.parent_checked_at = now;
                break :blk if (client.parent_pid) |pid| !processExists(pid) else false;
            } else false;
            if (parent_gone or now - client.seen > lease_ms) {
                self.closeClient(ci, now);
                continue;
            }
            client.listener.acceptPending(now) catch {};
            for (0..16) |_| {
                const registration = (client.listener.nextRegistration(now) catch null) orelse break;
                defer self.allocator.free(registration.title);
                var producer = Producer{ .channel = .{ .socket = .{ .file = registration.file, .allocator = self.allocator } } };
                const session = self.addSession(client.id, registration.title, &producer) catch |err| {
                    self.logger.writeFmtScoped(.warn, .wm, "external launch failed: {s}", .{@errorName(err)});
                    producer.deinit();
                    continue;
                };
                // Acknowledgement must precede attach on the shared socket.
                session.producer.channel.writer().print("{{\"type\":\"registered\",\"version\":1,\"session_id\":{d}}}\n", .{session.id}) catch {};
                self.attach(session) catch {
                    session.close(now);
                };
            }
            ci += 1;
        }
        // Give different sessions first access to each quiet output interval.
        // A continuously drawing first panel must not monopolize the terminal.
        for (0..self.sessions.items.len) |offset| {
            const session = &self.sessions.items[(self.presentation_start + offset) % self.sessions.items.len];
            if (session.exited_at != null) continue;
            session.producer.channel.flushControl() catch {
                session.close(now);
            };
            self.drain(session) catch |err| {
                self.logger.writeFmtScoped(.warn, .wm, "producer {d}: {s}", .{ session.id, @errorName(err) });
                session.close(now);
            };
            const term = session.producer.pollExit() catch null;
            const eof = session.producer.channel.presentationFile() == null;
            const timed_out = if (session.closing_at) |at| now - at >= 2000 else false;
            if (timed_out or (eof and (session.producer.child == null or term != null))) {
                session.producer.deinit();
                session.exited_at = now;
                self.deleteImage(session.image_id) catch |err| {
                    self.logger.writeFmtScoped(.warn, .wm, "producer {d} graphics cleanup failed: {s}", .{ session.id, @errorName(err) });
                };
                system_io.fs.cwd(io).deleteTree(session.directory) catch {};
            } else if (eof or term != null) session.close(now);
            const target_changed = if (session.grid) |grid| !std.meta.eql(session.last_target_px, self.placeholderTarget(session, grid).target_px) else false;
            if ((target_changed and session.closing_at == null and session.exited_at == null) or restoreDue(session, now, self.idle_refresh_ms, self.terminal.outputQueued())) {
                self.refresh(session, now) catch {
                    session.close(now);
                };
            }
        }
        self.presentation_start = (self.presentation_start + 1) % @max(1, self.sessions.items.len);
        var si: usize = 0;
        while (si < self.sessions.items.len) {
            const session = &self.sessions.items[si];
            if (session.exited_at) |at| {
                if (now - at >= idle_ms) {
                    session.deinit(self.allocator);
                    _ = self.sessions.orderedRemove(si);
                    continue;
                }
            }
            si += 1;
        }
    }

    fn closeClient(self: *Host, index: usize, now: i64) void {
        const id = self.clients.items[index].id;
        for (self.sessions.items) |*session| if (std.mem.eql(u8, &session.owner, &id)) {
            session.close(now);
        };
        self.clients.items[index].listener.deinit();
        _ = self.clients.orderedRemove(index);
    }

    // Takes producer ownership only on success. New sessions receive a private
    // image ID and upload directory; the plugin supplies the eventual grid.
    fn addSession(self: *Host, owner: [32]u8, title: []const u8, producer: *Producer) !*Session {
        const io = self.terminal.file.io;
        if (self.sessions.items.len >= max_sessions) return error.SessionLimit;
        if (self.next_session > 0xffffff - 100000) return error.ImageIdsExhausted;
        const id = self.next_session;
        self.next_session += 1;
        const directory = try std.fmt.allocPrint(self.allocator, "{s}/s{d}", .{ self.directory, id });
        errdefer self.allocator.free(directory);
        try system_io.posix.mkdir(directory, 0o700);
        errdefer system_io.fs.cwd(io).deleteTree(directory) catch {};
        const path = try std.fmt.allocPrint(self.allocator, "{s}/frame.rgba", .{directory});
        errdefer self.allocator.free(path);
        const observation_path = try std.fmt.allocPrint(self.allocator, "{s}/obs-{d}.png", .{ directory, id });
        errdefer self.allocator.free(observation_path);
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);
        const image_id = 100000 + id;
        // Session ids restart with every host, so the terminal may still hold an
        // image and virtual placements under this id from a host that did not
        // exit cleanly. Placeholder cells resolve to the first virtual placement
        // of the image, so stale ones would size (and briefly show) this session.
        self.deleteImage(image_id) catch |err| {
            // A relay must reserve the delete before accepting a reused image id.
            // Refuse the session if its bounded queue is full, rather than risk
            // a stale placement or bypass serialization with a direct write.
            if (self.terminal.relay != null) return err;
            self.logger.writeFmtScoped(.warn, .wm, "session {d} stale graphics cleanup failed: {s}", .{ id, @errorName(err) });
        };
        try self.sessions.append(self.allocator, .{ .io = io, .id = id, .owner = owner, .title = owned_title, .producer = producer.*, .directory = directory, .upload_path = path, .image_id = image_id, .observation_path = observation_path });
        producer.* = .{};
        return &self.sessions.items[self.sessions.items.len - 1];
    }

    fn attach(_: *Host, session: *Session) !void {
        if (std.c.getenv("KATZENSTEG_OUTPUT_PROFILE")) |value| {
            if (std.mem.eql(u8, std.mem.span(value), "shm")) session.upload_profile = .shm;
        }
        try control.writeInitialControl(session.producer.channel.writer(), .{
            .rect_cells = .{ .row = 1, .col = 1, .cols = 1, .rows = 1 },
            .placeholder = .{ .image_id = session.image_id, .cols = 1, .rows = 1 },
            // This host does not own terminal input and must not consume probe
            // replies intended for the wrapped application. SHM is explicit here.
            .upload = .{ .profile = session.upload_profile, .path = session.upload_path },
        });
    }

    fn discardBatch(session: *Session, seq: u64) !void {
        if (session.upload_profile != .shm) return;
        try session.producer.channel.writer().print("{{\"type\":\"discard_batch\",\"window_id\":\"main\",\"seq\":{d}}}\n", .{seq});
    }

    fn drain(self: *Host, session: *Session) !void {
        const file = session.producer.channel.presentationFile() orelse return;
        var buf: [16384]u8 = undefined;
        const n = file.read(&buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                session.producer.channel.closePresentation();
                return err;
            },
        };
        if (n == 0) {
            session.producer.channel.closePresentation();
            return;
        }
        for (buf[0..n]) |byte| {
            if (byte != '\n') {
                if (session.line.items.len >= 65536) return error.ProducerLineTooLong;
                try session.line.append(self.allocator, byte);
                continue;
            }
            defer session.line.clearRetainingCapacity();
            var message = peer_protocol.parsePeerMessage(self.allocator, session.line.items) catch continue;
            defer message.deinit(self.allocator);
            switch (message) {
                .observation => |reply| {
                    for (&self.observations) |*slot| if (slot.*) |*pending| {
                        if (pending.session_id == session.id and pending.id == reply.request_id and pending.in_flight) {
                            pending.in_flight = false;
                            if (!reply.failed) pending.latest = reply;
                            break;
                        }
                    };
                },
                .presentation_status => |status| {
                    session.input_supported = status.input_supported;
                    session.source_px = status.source_px;
                    session.ready = status.ready_to_show;
                },
                .frame_batch => |batch| {
                    if (session.grid == null or session.closing_at != null) {
                        try discardBatch(session, batch.seq);
                        continue;
                    }
                    // Do not start an APC while the host application's output
                    // is still queued. Drop the whole batch before any bytes are
                    // written; ask the producer for its latest retained scene
                    // when the terminal clears, even with idle refresh disabled.
                    if (self.terminal.outputQueued()) {
                        session.restore_pending = true;
                        try discardBatch(session, batch.seq);
                        continue;
                    }
                    const groups = @import("../terminal_batch_applier.zig").BatchGroupsView{ .deletes = batch.groups.deletes, .uploads = batch.groups.uploads, .placements = batch.groups.placements, .after = batch.groups.after };
                    if (self.terminal.relay) |relay| {
                        var output_writer = std.Io.Writer.Allocating.init(self.allocator);
                        defer output_writer.deinit();
                        try graphics.apply(self.allocator, &output_writer.writer, session.image_id, groups);
                        try relay.graphics(output_writer.written());
                    } else {
                        var output_writer = self.terminal.file.writerStreaming(&.{});
                        try graphics.apply(self.allocator, &output_writer.interface, session.image_id, groups);
                    }
                    session.last_frame_at = system_io.time.milliTimestamp();
                    if (batch.groups.uploads.len != 0) session.restore_pending = false;
                },
                .detached => {},
            }
        }
    }

    pub fn handle(self: *Host, allocator: std.mem.Allocator, request: http.Request) !http.Response {
        const io = self.terminal.file.io;
        if (!http.authorized(request.authorization, &self.token)) return .{ .status = 401, .body = "" };
        const post = std.mem.eql(u8, request.method, "POST");
        const get = std.mem.eql(u8, request.method, "GET");
        if (get and std.mem.eql(u8, request.path, "/v1/health")) return json(allocator, .{ .pid = std.c.getpid(), .tty = self.terminal.path, .version = 1, .cell_px = self.terminal.cellPixels() });
        if (post and std.mem.eql(u8, request.path, "/v1/clients")) {
            if (self.clients.items.len >= max_clients) return error.ClientLimit;
            const parsed = try std.json.parseFromSlice(struct { parent_pid: ?i32 = null }, allocator, request.body, .{});
            const parent_pid = parsed.value.parent_pid;
            if (parent_pid) |pid| if (pid <= 1 or !processExists(pid)) {
                return error.InvalidParentPid;
            };
            const id = terminal_mod.randomId(io);
            const path = try std.fmt.allocPrint(allocator, "{s}/c{s}.sock", .{ self.directory, id[0..12] });
            var listener = try Listener.init(io, self.allocator, path);
            errdefer listener.deinit();
            try self.clients.append(self.allocator, .{ .id = id, .listener = listener, .seen = system_io.time.milliTimestamp(), .parent_pid = parent_pid });
            return json(allocator, .{ .id = &id, .target = try std.fmt.allocPrint(allocator, "jsonl:{s}", .{path}), .lease_ms = lease_ms });
        }
        const client_index = for (self.clients.items, 0..) |client, i| {
            if (std.mem.eql(u8, &client.id, request.client)) break i;
        } else return .{ .status = 403, .body = "" };
        self.clients.items[client_index].seen = system_io.time.milliTimestamp();
        const owner = self.clients.items[client_index].id;
        if (post and std.mem.eql(u8, request.path, "/v1/client/heartbeat")) return .{};
        if (post and std.mem.eql(u8, request.path, "/v1/client/close")) {
            self.closeClient(client_index, system_io.time.milliTimestamp());
            return .{};
        }
        if (std.mem.eql(u8, request.path, "/v1/sessions")) {
            if (get) {
                var list = std.ArrayList(std.json.Value).empty;
                for (self.sessions.items) |session| {
                    if (!std.mem.eql(u8, &session.owner, &owner)) continue;
                    const state: []const u8 = if (session.exited_at != null) "exited" else if (session.closing_at != null) "closing" else if (session.ready and session.grid != null) "ready" else "starting";
                    const value = try std.json.parseFromSlice(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, .{ .id = session.id, .title = session.title, .image_id = session.image_id, .state = state, .source_px = session.source_px, .input_supported = session.input_supported, .grid = session.grid }, .{}), .{});
                    try list.append(allocator, value.value);
                }
                return json(allocator, list.items);
            }
            if (post) {
                const Open = struct { profile: []const u8, args: []const []const u8 = &.{} };
                const parsed = try std.json.parseFromSlice(Open, allocator, request.body, .{});
                const spec = parsed.value;
                if (spec.profile.len == 0 or spec.profile.len > 128 or spec.profile[0] == '-' or spec.args.len > 64) return error.InvalidProfile;
                var producer = try Producer.spawn(io, self.allocator, self.executable, spec.profile, spec.args);
                defer producer.deinit();
                const session = try self.addSession(owner, spec.profile, &producer);
                self.attach(session) catch |err| {
                    session.close(system_io.time.milliTimestamp());
                    return err;
                };
                return json(allocator, .{ .id = session.id });
            }
        }
        if (!std.mem.startsWith(u8, request.path, "/v1/sessions/") or !post) return .{ .status = 404 };
        var parts = std.mem.splitScalar(u8, request.path[13..], '/');
        const id = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidPath, 10);
        const action = parts.next() orelse return error.InvalidPath;
        if (parts.next() != null) return error.InvalidPath;
        const session = for (self.sessions.items) |*item| {
            if (item.id == id and std.mem.eql(u8, &item.owner, &owner)) break item;
        } else return .{ .status = 404 };
        if (std.mem.eql(u8, action, "close")) {
            session.close(system_io.time.milliTimestamp());
            return .{};
        }
        if (session.closing_at != null or session.exited_at != null) return .{ .status = 409 };
        if (std.mem.eql(u8, action, "observe")) {
            const parsed = try std.json.parseFromSlice(struct { after_frame: ?u64 = null }, allocator, request.body, .{});
            for (self.observations) |slot| if (slot) |pending| {
                if (pending.session_id == id) return .{ .status = 409, .body = "{\"error\":\"ObservationPending\"}" };
            };
            const slot = for (&self.observations) |*item| {
                if (item.* == null) break item;
            } else return error.ObservationLimit;
            if (self.next_observation == std.math.maxInt(u32)) return error.ObservationIdsExhausted;
            const request_id = self.next_observation;
            self.next_observation += 1;
            slot.* = .{ .id = request_id, .session_id = id, .owner = owner, .after_frame = parsed.value.after_frame, .deadline = system_io.time.milliTimestamp() + 2000 };
            return .{ .pending = request_id };
        }
        if (std.mem.eql(u8, action, "refresh")) {
            if (session.grid == null) return error.GridRequired;
            if (self.terminal.outputQueued()) {
                session.restore_pending = true;
            } else try self.refresh(session, system_io.time.milliTimestamp());
            return .{};
        }
        if (std.mem.eql(u8, action, "grid")) {
            const parsed = try std.json.parseFromSlice(Grid, allocator, request.body, .{});
            const grid = parsed.value;
            const target = self.placeholderTarget(session, grid);
            try target.validate();
            if (session.grid) |current| if (std.meta.eql(current, grid) and std.meta.eql(session.last_target_px, target.target_px)) {
                return .{};
            };
            // The first grid may follow a paused producer's only frame. A
            // resize may also accompany a terminal clear, so restore pixels.
            try control.writeViewportControl(session.producer.channel.writer(), .{ .rect_cells = target.localRect(), .placeholder = target, .refresh_placements = true });
            session.grid = grid;
            session.last_target_px = target.target_px;
            session.last_refresh_at = system_io.time.milliTimestamp();
            return .{};
        }
        if (std.mem.eql(u8, action, "input")) {
            if (!session.input_supported) return error.InputUnsupported;
            const grid = session.grid orelse return error.GridRequired;
            const parsed = try std.json.parseFromSlice(struct { events: []const std.json.Value }, allocator, request.body, .{});
            if (parsed.value.events.len > 64) return error.TooManyEvents;
            var bytes = std.Io.Writer.Allocating.init(allocator);
            var buttons = self.pointerButtons(session.id);
            // Validate the whole request before enqueuing any input.
            for (parsed.value.events) |event| encodeInput(allocator, &bytes.writer, event, grid, session.source_px, &buttons) catch |err| {
                // Allocating writers report allocation failure as WriteFailed.
                // Keep resource failures on the HTTP 503 path.
                return if (err == error.WriteFailed) error.OutOfMemory else err;
            };
            try session.producer.channel.writer().writeAll(bytes.written());
            self.setPointerButtons(session.id, buttons);
            return .{};
        }
        return .{ .status = 404 };
    }

    pub fn cancelResponse(self: *Host, id: u32) void {
        for (&self.observations) |*slot| if (slot.*) |pending| {
            if (pending.id == id) {
                slot.* = null;
                return;
            }
        };
    }

    pub fn pollResponse(self: *Host, allocator: std.mem.Allocator, id: u32, now: i64) !?http.Response {
        const pending = for (&self.observations) |*slot| {
            if (slot.*) |*item| if (item.id == id) {
                break item;
            };
        } else return http.Response{ .status = 404 };
        const alive = for (self.clients.items) |client| {
            if (std.mem.eql(u8, &client.id, &pending.owner)) break true;
        } else false;
        if (!alive) return http.Response{ .status = 403 };
        const session = for (self.sessions.items) |*item| {
            if (item.id == pending.session_id) break item;
        } else return http.Response{ .status = 404 };
        if (session.closing_at != null or session.exited_at != null) return http.Response{ .status = 409 };
        if (pending.latest) |latest| {
            const newer = if (pending.after_frame) |after| latest.frame_id > after else true;
            if (newer or now >= pending.deadline) return try json(allocator, .{
                .path = session.observation_path,
                .width = latest.width,
                .height = latest.height,
                .frame_id = latest.frame_id,
                .timestamp_ms = latest.timestamp_ms,
                .newer = newer,
            });
        }
        if (now >= pending.deadline) return http.Response{ .status = 503, .body = "{\"error\":\"NoFrame\"}" };
        if (!pending.in_flight and now - pending.sent_at >= 100 and (pending.latest == null or session.last_frame_at >= pending.sent_at)) {
            var bytes = std.Io.Writer.Allocating.init(allocator);
            defer bytes.deinit();
            const writer = &bytes.writer;
            writer.print("{{\"type\":\"observe\",\"window_id\":\"main\",\"request_id\":{d},\"format\":\"png\",\"path\":", .{id}) catch return error.OutOfMemory;
            protocol.writeJsonString(writer, session.observation_path) catch return error.OutOfMemory;
            writer.writeAll("}\n") catch return error.OutOfMemory;
            session.producer.channel.writer().writeAll(bytes.written()) catch {
                session.close(now);
                return http.Response{ .status = 409 };
            };
            pending.sent_at = now;
            pending.in_flight = true;
        }
        return null;
    }

    fn placeholderTarget(self: *Host, session: *Session, grid: Grid) protocol.PlaceholderPresentation {
        return .{ .image_id = session.image_id, .cols = grid.cols, .rows = grid.rows, .target_px = if (self.terminal.cellPixels()) |cell| .{
            .w = @intFromFloat(@max(1, @floor(cell.w * @as(f64, @floatFromInt(grid.cols))))),
            .h = @intFromFloat(@max(1, @floor(cell.h * @as(f64, @floatFromInt(grid.rows))))),
        } else null };
    }

    fn refresh(self: *Host, session: *Session, now: i64) !void {
        const grid = session.grid orelse return;
        const target = self.placeholderTarget(session, grid);
        try control.writeViewportControl(session.producer.channel.writer(), .{ .rect_cells = target.localRect(), .placeholder = target, .refresh_placements = true });
        session.last_target_px = target.target_px;
        session.last_refresh_at = now;
        session.restore_pending = false;
    }

    // Button state belongs to each producer session, never to the HTTP connection.
    fn pointerButtons(self: *Host, id: u32) u32 {
        for (self.sessions.items) |session| if (session.id == id) return session.buttons;
        return 0;
    }
    fn setPointerButtons(self: *Host, id: u32, buttons: u32) void {
        for (self.sessions.items) |*session| if (session.id == id) {
            session.buttons = buttons;
            return;
        };
    }
};

// Liveness only: EPERM still means a process exists. Client authorization is
// checked separately; this probe does not assert process ownership.
fn processExists(pid: i32) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

fn restoreDue(session: *const Session, now: i64, interval: u32, output_queued: bool) bool {
    return !output_queued and session.grid != null and session.closing_at == null and session.exited_at == null and (session.restore_pending or refreshDue(session, now, interval));
}

fn refreshDue(session: *const Session, now: i64, interval: u32) bool {
    return interval != 0 and session.ready and session.grid != null and session.closing_at == null and session.exited_at == null and now - @max(session.last_frame_at, session.last_refresh_at) >= interval;
}

fn json(allocator: std.mem.Allocator, value: anytype) !http.Response {
    return .{ .body = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
}

// A pointer event names a cell (x, y). It may also carry the point in
// source pixels (px, py), which a client that knows the frame's size uses to
// hit a target smaller than a cell; that goes to the producer as a
// source_pointer, exact, and only while the producer's size is known.
fn encodeInput(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value, grid: Grid, source: ?protocol.SourcePixels, buttons: *u32) !void {
    if (value != .object) return error.InvalidInput;
    const kind = value.object.get("type") orelse return error.InvalidInput;
    if (kind != .string) return error.InvalidInput;
    if (std.mem.eql(u8, kind.string, "key")) {
        const parsed = try std.json.parseFromValue(protocol.KeyInput, allocator, value, .{ .ignore_unknown_fields = true });
        const key = parsed.value;
        if (!key.valid()) return error.InvalidKey;
        const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "input", .window_id = "main", .event = "key", .key = key.key, .action = key.action, .ctrl = key.ctrl, .shift = key.shift, .alt = key.alt, .meta = key.meta }, .{});
        try writer.writeAll(encoded);
    } else if (std.mem.eql(u8, kind.string, "pointer")) {
        const Pointer = struct { kind: enum { down, move, up }, x: i32, y: i32, px: ?i32 = null, py: ?i32 = null, button: ?enum { left, middle, right } = null };
        const parsed = try std.json.parseFromValue(Pointer, allocator, value, .{ .ignore_unknown_fields = true });
        const pointer = parsed.value;
        if (pointer.x < 0 or pointer.y < 0 or pointer.x >= grid.cols or pointer.y >= grid.rows) return error.PointerOutsideGrid;
        const button: i32 = if (pointer.button) |button| switch (button) {
            .left => 0,
            .middle => 1,
            .right => 2,
        } else -1;
        if (pointer.kind != .move and button < 0) return error.ButtonRequired;
        if (button >= 0) {
            const mask = @as(u32, 1) << @as(u5, @intCast(button));
            if (pointer.kind == .down) buttons.* |= mask;
            if (pointer.kind == .up) buttons.* &= ~mask;
        }
        const kind_name = switch (pointer.kind) {
            .down => "pointerdown",
            .move => "pointermove",
            .up => "pointerup",
        };
        if (pointer.px != null and pointer.py != null and source != null) {
            const px = pointer.px.?;
            const py = pointer.py.?;
            if (px < 0 or py < 0 or px >= source.?.w or py >= source.?.h) return error.PointerOutsideSource;
            const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "input", .window_id = "main", .event = "source_pointer", .kind = kind_name, .x = px, .y = py, .width = source.?.w, .height = source.?.h, .button = button, .buttons = buttons.* }, .{});
            try writer.writeAll(encoded);
        } else {
            const encoded = try std.json.Stringify.valueAlloc(allocator, .{ .type = "input", .window_id = "main", .event = "pointer", .kind = kind_name, .col = pointer.x + 1, .row = pointer.y + 1, .button = button, .buttons = buttons.* }, .{});
            try writer.writeAll(encoded);
        }
    } else return error.InvalidInput;
    try writer.writeAll("\n");
}

fn readLiveDescriptor(io: std.Io, allocator: std.mem.Allocator, lock: system_io.fs.File, tty: []const u8) ![]const u8 {
    const deadline = system_io.time.milliTimestamp() + 8000;
    while (system_io.time.milliTimestamp() < deadline) {
        try lock.seekTo(0);
        const bytes = try lock.readToEndAlloc(allocator, 8192);
        if (descriptorIsLive(io, allocator, bytes, tty)) return bytes;
        allocator.free(bytes);
        system_io.time.sleep(20 * std.time.ns_per_ms);
    }
    return error.HostStarting;
}

fn descriptorIsLive(io: std.Io, allocator: std.mem.Allocator, bytes: []const u8, tty: []const u8) bool {
    const Descriptor = struct { port: u16, token: []const u8, tty: []const u8 };
    const parsed = std.json.parseFromSlice(Descriptor, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    if (!std.mem.eql(u8, tty, parsed.value.tty) or parsed.value.token.len != 32) return false;
    const address = system_io.net.Address.parseIp4("127.0.0.1", parsed.value.port) catch return false;
    const stream = system_io.net.tcpConnectToAddress(io, address) catch return false;
    defer stream.close();
    producer_mod.nonblocking(stream.handle) catch return false;
    var buffer: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&buffer, "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{parsed.value.token}) catch return false;
    stream.writeAll(request) catch return false;
    var fds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if ((system_io.posix.poll(&fds, 250) catch return false) == 0) return false;
    const n = stream.read(&buffer) catch return false;
    return std.mem.startsWith(u8, buffer[0..n], "HTTP/1.1 200 ");
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8, options: Options) !u8 {
    var terminal = try terminal_mod.Terminal.open(io, allocator, options.tty_path, options.parent_pid);
    defer terminal.deinit();
    const root = try terminal_mod.privateRoot(allocator);
    defer allocator.free(root);
    const identity = std.hash.Wyhash.hash(0, terminal.path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/{x}.lock", .{ root, identity });
    defer allocator.free(lock_path);
    const discovery = if (options.host_file) |path| try allocator.dupe(u8, path) else try std.fmt.allocPrint(allocator, "{s}/{x}.json", .{ root, identity });
    defer allocator.free(discovery);
    const lock = try system_io.fs.createFileAbsolute(io, lock_path, .{ .read = true, .truncate = false, .mode = 0o600 });
    defer lock.close();
    if (!(try lock.tryLock(.exclusive))) {
        if (!options.background) return error.HostAlreadyRunning;
        // The live host owns the lock for its entire lifetime. Discovery is also
        // stored here, so callers using different --host-file paths converge.
        const bytes = try readLiveDescriptor(io, allocator, lock, terminal.path);
        defer allocator.free(bytes);
        try system_io.fs.File.stdout(io).writeAll(bytes);
        return 0;
    }
    try lock.setEndPos(0);
    var ready: ?system_io.fs.File = null;
    if (options.background) {
        const pipe = try system_io.posix.pipe();
        const pid = system_io.posix.fork() catch |err| {
            system_io.posix.close(pipe[0]);
            system_io.posix.close(pipe[1]);
            return err;
        };
        if (pid != 0) {
            system_io.posix.close(pipe[1]);
            const input = system_io.fs.File{ .io = io, .handle = pipe[0] };
            defer input.close();
            var pollfd = [_]std.posix.pollfd{.{ .fd = input.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try system_io.posix.poll(&pollfd, 8000) == 0) {
                std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                return error.HostStartupTimeout;
            }
            const bytes = try input.readToEndAlloc(allocator, 8192);
            defer allocator.free(bytes);
            if (bytes.len == 0) return error.HostStartupFailed;
            try system_io.fs.File.stdout(io).writeAll(bytes);
            return 0;
        }
        system_io.posix.close(pipe[0]);
        ready = .{ .io = io, .handle = pipe[1] };
        // The concrete terminal device is already open; it survives detach.
        _ = try system_io.posix.setsid();
        const null_file = try system_io.fs.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
        defer null_file.close();
        inline for (.{ 0, 1, 2 }) |fd| try system_io.posix.dup2(null_file.handle, fd);
    }
    defer if (ready) |file| file.close();
    const token = terminal_mod.randomId(io);
    const directory = try std.fmt.allocPrint(allocator, "{s}/h{s}", .{ root, token[0..12] });
    defer allocator.free(directory);
    try system_io.posix.mkdir(directory, 0o700);
    defer system_io.fs.cwd(io).deleteTree(directory) catch {};
    var relay: ?@import("wrap.zig").Relay = null;
    defer if (relay) |*value| value.deinit();
    var host = Host{ .allocator = allocator, .executable = executable, .terminal = &terminal, .directory = directory, .token = token, .server = try http.Server.init(io, allocator, options.http_address), .logger = Logger.init(allocator), .idle_since = system_io.time.milliTimestamp(), .idle_refresh_ms = options.idle_refresh_ms };
    defer host.deinit();
    stopping.store(0, .seq_cst);
    const action = std.posix.Sigaction{ .handler = .{ .handler = stop }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]std.posix.SIG{ std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.HUP }) |signal| std.posix.sigaction(signal, &action, null);
    const descriptor = try std.json.Stringify.valueAlloc(allocator, .{ .pid = std.c.getpid(), .port = host.server.port, .token = &token, .tty = terminal.path, .host_file = discovery, .version = 1 }, .{});
    defer allocator.free(descriptor);
    // Publish only after HTTP is listening. The lock file is never unlinked.
    const temporary = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ discovery, token[0..8] });
    defer allocator.free(temporary);
    const file = try system_io.fs.createFileAbsolute(io, temporary, .{ .mode = 0o600, .exclusive = true });
    {
        defer file.close();
        try file.writeAll(descriptor);
    }
    try system_io.fs.renameAbsolute(io, temporary, discovery);
    defer system_io.fs.deleteFileAbsolute(io, discovery) catch {};
    try lock.setEndPos(0);
    try lock.writeAll(descriptor);
    if (ready) |output| {
        try output.writeAll(descriptor);
        output.close();
        ready = null;
    }
    if (options.wrap_command.len != 0) {
        relay = try @import("wrap.zig").Relay.init(allocator, terminal.path, options.wrap_command, descriptor);
        terminal.relay = &relay.?;
    }
    try host.loop();
    if (relay) |value| {
        const signal = stopping.load(.seq_cst);
        return if (signal != 0) 128 + signal else value.exit_code orelse 128;
    }
    return 0;
}

test {
    _ = @import("wrap.zig");
    _ = @import("http.zig");
    _ = @import("graphics_output.zig");
    _ = @import("producer.zig");
}

test "idle refresh waits for silence, throttles requests and skips closed sessions" {
    var session: Session = undefined;
    session.ready = true;
    session.grid = .{ .cols = 30, .rows = 10 };
    session.closing_at = null;
    session.exited_at = null;
    session.last_frame_at = 1000;
    session.last_refresh_at = 0;
    try std.testing.expect(!refreshDue(&session, 1499, 500));
    try std.testing.expect(refreshDue(&session, 1500, 500));
    session.last_refresh_at = 1500;
    try std.testing.expect(!refreshDue(&session, 1999, 500));
    try std.testing.expect(refreshDue(&session, 2000, 500));
    session.last_frame_at = 1950;
    try std.testing.expect(!refreshDue(&session, 2000, 500));
    try std.testing.expect(!refreshDue(&session, 3000, 0));
    session.closing_at = 2000;
    try std.testing.expect(!refreshDue(&session, 3000, 500));
    session.closing_at = null;
    session.grid = null;
    try std.testing.expect(!refreshDue(&session, 3000, 500));
}

test "busy output defers recovery without losing it when idle refresh is disabled" {
    var session: Session = undefined;
    session.ready = true;
    session.grid = .{ .cols = 30, .rows = 10 };
    session.closing_at = null;
    session.exited_at = null;
    session.last_frame_at = 1000;
    session.last_refresh_at = 1000;
    session.restore_pending = true;
    try std.testing.expect(!restoreDue(&session, 1100, 0, true));
    try std.testing.expect(restoreDue(&session, 1100, 0, false));
    session.closing_at = 1050;
    try std.testing.expect(!restoreDue(&session, 1100, 0, false));
    session.closing_at = null;
    session.restore_pending = false;
    try std.testing.expect(!restoreDue(&session, 1100, 0, false));
    try std.testing.expect(!restoreDue(&session, 1600, 500, true));
    try std.testing.expect(restoreDue(&session, 1600, 500, false));
}

test "encodeInput sends a pointer with source pixels as an exact source_pointer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"pointer\",\"kind\":\"down\",\"x\":24,\"y\":10,\"px\":686,\"py\":528,\"button\":\"left\"}", .{});
    defer parsed.deinit();
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    var buttons: u32 = 0;
    try encodeInput(allocator, &bytes.writer, parsed.value, .{ .cols = 46, .rows = 16 }, .{ .w = 1288, .h = 800 }, &buttons);
    try std.testing.expectEqualStrings("{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"source_pointer\",\"kind\":\"pointerdown\",\"x\":686,\"y\":528,\"width\":1288,\"height\":800,\"button\":0,\"buttons\":1}\n", bytes.written());
    try std.testing.expectEqual(@as(u32, 1), buttons);
}

test "encodeInput falls back to the cell when the source size is unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"pointer\",\"kind\":\"move\",\"x\":24,\"y\":10,\"px\":686,\"py\":528}", .{});
    defer parsed.deinit();
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    var buttons: u32 = 0;
    try encodeInput(allocator, &bytes.writer, parsed.value, .{ .cols = 46, .rows = 16 }, null, &buttons);
    try std.testing.expectEqualStrings("{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"pointer\",\"kind\":\"pointermove\",\"col\":25,\"row\":11,\"button\":-1,\"buttons\":0}\n", bytes.written());
}

test "encodeInput rejects source pixels outside the frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"pointer\",\"kind\":\"move\",\"x\":0,\"y\":0,\"px\":1288,\"py\":0}", .{});
    defer parsed.deinit();
    var bytes = std.Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    var buttons: u32 = 0;
    try std.testing.expectError(error.PointerOutsideSource, encodeInput(allocator, &bytes.writer, parsed.value, .{ .cols = 46, .rows = 16 }, .{ .w = 1288, .h = 800 }, &buttons));
}
