//! Shared input handles. Jackstay owns the wire protocol and execution barrier.
//! Work and all handles have one owner; destroy must not race other calls.
const std = @import("std");
const media = @import("media.zig");
const c = @cImport({
    @cInclude("jackstay_input.h");
});

pub const Mode = enum(u32) { physical = c.FT_INPUT_MODE_PHYSICAL, source_text = c.FT_INPUT_MODE_SOURCE_TEXT, cooperative = c.FT_INPUT_MODE_COOPERATIVE };
pub const Action = enum(u32) { down = c.FT_INPUT_DOWN, up = c.FT_INPUT_UP, repeat = c.FT_INPUT_REPEAT };
pub const KeyKind = enum(u32) { physical = c.FT_INPUT_PHYSICAL_KEY, logical = c.FT_INPUT_LOGICAL_KEY };
pub const ScrollUnit = enum(u32) { pixel = c.FT_INPUT_SCROLL_PIXEL, line = c.FT_INPUT_SCROLL_LINE, page = c.FT_INPUT_SCROLL_PAGE };
pub const Scope = enum(u32) { all = c.FT_INPUT_SCOPE_ALL, pointer = c.FT_INPUT_SCOPE_POINTER };
pub const Outcome = enum(u32) { executed = c.FT_INPUT_EXECUTED, rejected = c.FT_INPUT_REJECTED, unsupported = c.FT_INPUT_UNSUPPORTED, partial = c.FT_INPUT_PARTIAL, uncertain = c.FT_INPUT_UNCERTAIN };
pub const Reason = enum(u32) { focus = c.FT_INPUT_REASON_FOCUS, geometry = c.FT_INPUT_REASON_GEOMETRY, disconnect = c.FT_INPUT_REASON_DISCONNECT, expired = c.FT_INPUT_REASON_EXPIRED, overflow = c.FT_INPUT_REASON_OVERFLOW, execution = c.FT_INPUT_REASON_EXECUTION };
pub const Button = enum(u32) { primary = 1, secondary = 2, auxiliary = 3, back = 4, forward = 5 };
pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    alt_graph: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    reserved: u24 = 0,
};
pub const Capabilities = packed struct(u32) {
    physical: bool = false,
    logical: bool = false,
    text: bool = false,
    pointer: bool = false,
    scroll: bool = false,
    reserved: u27 = 0,
};
pub const Geometry = struct {
    revision: u64 = 1,
    width: f64,
    height: f64,

    fn fromC(value: c.ft_input_geometry) Geometry {
        return .{ .revision = value.revision, .width = value.width, .height = value.height };
    }
    fn toC(self: Geometry) c.ft_input_geometry {
        return .{ .revision = self.revision, .width = self.width, .height = self.height };
    }
};
pub const Config = struct {
    mode: Mode = .cooperative,
    capabilities: Capabilities,
    geometry: Geometry,
    // Null limits retain the pinned library defaults.
    max_events: ?u32 = null,
    max_bytes: ?u32 = null,
    max_text_bytes: ?u32 = null,
    idle_timeout_ms: ?u32 = null,
    independent_contributions: bool = false,
    interaction_cancel: bool = false,

    fn toC(self: Config) c.ft_input_config {
        var raw: c.ft_input_config = undefined;
        c.ft_input_config_default(&raw);
        raw.modes = @intFromEnum(self.mode);
        raw.capabilities = @bitCast(self.capabilities);
        raw.geometry = self.geometry.toC();
        if (self.max_events) |limit| raw.max_events = limit;
        if (self.max_bytes) |limit| raw.max_bytes = limit;
        if (self.max_text_bytes) |limit| raw.max_text_bytes = limit;
        if (self.idle_timeout_ms) |limit| raw.idle_timeout_ms = limit;
        raw.independent_contributions = @intFromBool(self.independent_contributions);
        raw.interaction_cancel = @intFromBool(self.interaction_cancel);
        return raw;
    }
};
pub const Key = struct { kind: KeyKind, name: []const u8, press: u64, action: Action, modifiers: Modifiers = .{} };
pub const Position = struct { x: f64, y: f64, revision: u64 };
pub const Event = union(enum) {
    key: Key,
    text: []const u8,
    motion: Position,
    button: struct { button: Button, action: Action, position: Position },
    scroll: struct { x: f64, y: f64, unit: ScrollUnit, position: Position },
};

fn check(status: c.ft_status) !void {
    switch (status) {
        c.FT_STATUS_OK => {},
        c.FT_STATUS_CLOSED => return error.Closed,
        c.FT_STATUS_TIMEOUT => return error.Timeout,
        c.FT_STATUS_CAPACITY => return error.Capacity,
        c.FT_STATUS_DRAINING => return error.Draining,
        c.FT_STATUS_RECOVERY_REQUIRED => return error.RecoveryRequired,
        c.FT_STATUS_INVALID_ARGUMENT => return error.InvalidArgument,
        c.FT_STATUS_INVALID_STATE => return error.InvalidState,
        c.FT_STATUS_UNSUPPORTED => return error.Unsupported,
        c.FT_STATUS_STALE => return error.Stale,
        else => return error.JackstayFailure,
    }
}

pub const Work = struct {
    handle: ?*c.ft_input_work,
    operation: c.ft_input_operation,

    pub fn controller(self: *const Work) u64 {
        return self.operation.controller;
    }
    pub fn epoch(self: *const Work) u64 {
        return self.operation.epoch;
    }
    pub fn sequence(self: *const Work) u64 {
        return self.operation.sequence;
    }
    pub fn mode(self: *const Work) !Mode {
        return enumFromInt(Mode, self.operation.mode);
    }
    pub fn cleanup(self: *const Work) !?struct { scope: Scope, reason: Reason } {
        if (self.operation.event.kind != c.FT_INPUT_CLEANUP) return null;
        return .{ .scope = try enumFromInt(Scope, self.operation.scope), .reason = try enumFromInt(Reason, self.operation.reason) };
    }
    /// Returned key/text slices are borrowed from this work. Keep it alive until
    /// execution settles. Copying into another queue is not execution completion.
    pub fn event(self: *const Work) !Event {
        const e = &self.operation.event;
        const position = Position{ .x = e.x, .y = e.y, .revision = e.geometry_revision };
        return switch (e.kind) {
            c.FT_INPUT_KEY => .{ .key = .{ .kind = try enumFromInt(KeyKind, e.key_kind), .name = std.mem.sliceTo(&e.key, 0), .press = e.press, .action = try enumFromInt(Action, e.action), .modifiers = @bitCast(e.modifiers) } },
            c.FT_INPUT_TEXT => .{ .text = if (e.text_len == 0) "" else e.text[0..e.text_len] },
            c.FT_INPUT_MOTION => .{ .motion = position },
            c.FT_INPUT_BUTTON => .{ .button = .{ .button = try enumFromInt(Button, e.button), .action = try enumFromInt(Action, e.action), .position = position } },
            c.FT_INPUT_SCROLL => .{ .scroll = .{ .x = e.x, .y = e.y, .unit = try enumFromInt(ScrollUnit, e.scroll_unit), .position = .{ .x = e.pointer_x, .y = e.pointer_y, .revision = e.geometry_revision } } },
            else => error.InvalidWork,
        };
    }
    /// Consumes work even when completion reports failed cleanup.
    pub fn complete(self: *Work, outcome: Outcome) !void {
        try check(c.ft_input_work_complete(&self.handle, @intFromEnum(outcome)));
    }
};

pub const Target = struct {
    handle: ?*c.ft_input_target,

    pub fn init(config: Config) !Target {
        try media.checkAbi();
        var handle: ?*c.ft_input_target = null;
        var raw = config.toC();
        try check(c.ft_input_target_create(&raw, &handle));
        return .{ .handle = handle };
    }
    /// The caller authorizes and associates this stream with the selected target.
    /// The library consumes fd, including on failure. No caller I/O afterwards.
    pub fn serve(self: *Target, fd: *i32) !Server {
        var handle: ?*c.ft_input_server = null;
        try check(c.ft_input_target_serve(self.handle, fd, &handle));
        return .{ .handle = handle };
    }
    pub fn next(self: *Target) !?Work {
        var handle: ?*c.ft_input_work = null;
        const status = c.ft_input_target_next(self.handle, &handle);
        if (status == c.FT_STATUS_EMPTY) return null;
        try check(status);
        var operation: c.ft_input_operation = undefined;
        errdefer _ = c.ft_input_work_complete(&handle, c.FT_INPUT_UNCERTAIN);
        try check(c.ft_input_work_describe(handle, &operation));
        return .{ .handle = handle, .operation = operation };
    }
    pub fn setGeometry(self: *Target, geometry: Geometry) !void {
        var raw = geometry.toC();
        try check(c.ft_input_target_geometry(self.handle, &raw));
    }
    /// Only after the host actually rebuilt/resolved the failed executor.
    pub fn resolveFailedCleanup(self: *Target) !void {
        try check(c.ft_input_target_resolve(self.handle));
    }
    /// Stop server handles first and keep pumping cleanup. Draining and
    /// RecoveryRequired retain this live handle; neither permits reclamation.
    pub fn deinit(self: *Target) !void {
        try check(c.ft_input_target_destroy(&self.handle));
    }
};

pub const Server = struct {
    handle: ?*c.ft_input_server,
    pub fn finished(self: *const Server) !bool {
        const status = c.ft_input_server_poll(self.handle);
        if (status == c.FT_STATUS_EMPTY) return false;
        try check(status);
        return true;
    }
    /// Joins transport only. The target still owns the cleanup barrier.
    pub fn deinit(self: *Server) void {
        c.ft_input_server_destroy(&self.handle);
    }
};

pub const Status = union(enum) {
    completed: struct { sequence: u64, outcome: Outcome },
    refused: struct { sequence: u64, result: i32 },
    reset: struct { epoch: u64, geometry: Geometry },
    closed: struct { reason: Reason, clean: bool },
};
pub const Admission = struct {
    controller: u64,
    epoch: u64,
    modes: u32,
    capabilities: Capabilities,
    geometry: Geometry,
    max_text_bytes: u32,
    independent_contributions: bool,
    interaction_cancel: bool,
};
pub const Client = struct {
    handle: ?*c.ft_input_client,

    /// Bounded synchronous handshake: call off the GUI/input thread. fd is
    /// consumed on failure too, after ABI validation. Subsequent I/O has its
    /// own transport worker.
    pub fn connect(fd: *i32, mode: Mode) !Client {
        try media.checkAbi();
        var handle: ?*c.ft_input_client = null;
        try check(c.ft_input_client_connect(fd, @intFromEnum(mode), &handle));
        return .{ .handle = handle };
    }
    pub fn describe(self: *const Client) !Admission {
        var config: c.ft_input_config = undefined;
        var controller: u64 = undefined;
        var epoch: u64 = undefined;
        try check(c.ft_input_client_describe(self.handle, &config, &controller, &epoch));
        return .{ .controller = controller, .epoch = epoch, .modes = config.modes, .capabilities = @bitCast(config.capabilities), .geometry = Geometry.fromC(config.geometry), .max_text_bytes = config.max_text_bytes, .independent_contributions = config.independent_contributions != 0, .interaction_cancel = config.interaction_cancel != 0 };
    }
    /// Success means copied into the bounded send queue. Poll the sequence's
    /// outcome separately; never replay after an uncertain/lost result.
    pub fn send(self: *Client, event: Event) !u64 {
        var raw = std.mem.zeroes(c.ft_input_event);
        switch (event) {
            .key => |key| {
                if (key.name.len >= raw.key.len or std.mem.indexOfScalar(u8, key.name, 0) != null) return error.InvalidArgument;
                raw.kind = c.FT_INPUT_KEY;
                raw.action = @intFromEnum(key.action);
                raw.key_kind = @intFromEnum(key.kind);
                raw.press = key.press;
                raw.modifiers = @bitCast(key.modifiers);
                @memcpy(raw.key[0..key.name.len], key.name);
            },
            .text => |bytes| {
                raw.kind = c.FT_INPUT_TEXT;
                raw.text = bytes.ptr;
                raw.text_len = bytes.len;
            },
            .motion => |pos| {
                raw.kind = c.FT_INPUT_MOTION;
                setPosition(&raw, pos);
            },
            .button => |button| {
                raw.kind = c.FT_INPUT_BUTTON;
                raw.action = @intFromEnum(button.action);
                raw.button = @intFromEnum(button.button);
                setPosition(&raw, button.position);
            },
            .scroll => |scroll| {
                raw.kind = c.FT_INPUT_SCROLL;
                raw.scroll_unit = @intFromEnum(scroll.unit);
                raw.x = scroll.x;
                raw.y = scroll.y;
                raw.pointer_x = scroll.position.x;
                raw.pointer_y = scroll.position.y;
                raw.geometry_revision = scroll.position.revision;
            },
        }
        var sequence: u64 = undefined;
        try check(c.ft_input_client_send(self.handle, &raw, &sequence));
        return sequence;
    }
    pub fn poll(self: *Client) !?Status {
        var status: c.ft_input_status = undefined;
        const result = c.ft_input_client_poll(self.handle, &status);
        if (result == c.FT_STATUS_EMPTY) return null;
        try check(result);
        return switch (status.kind) {
            c.FT_INPUT_COMPLETED => .{ .completed = .{ .sequence = status.sequence, .outcome = try enumFromInt(Outcome, status.result) } },
            c.FT_INPUT_REFUSED => .{ .refused = .{ .sequence = status.sequence, .result = status.result } },
            c.FT_INPUT_RESET => .{ .reset = .{ .epoch = status.epoch, .geometry = Geometry.fromC(status.geometry) } },
            c.FT_INPUT_CLOSED => .{ .closed = .{ .reason = try enumFromInt(Reason, status.reason), .clean = status.clean != 0 } },
            else => error.InvalidStatus,
        };
    }
    pub fn reset(self: *Client) !void {
        try check(c.ft_input_client_reset(self.handle));
    }
    /// Initiates close; poll observes confirmed (or unconfirmed) remote cleanup.
    pub fn close(self: *Client) void {
        c.ft_input_client_close(self.handle);
    }
    /// Joins transport only. This is not confirmed remote cleanup.
    pub fn deinit(self: *Client) void {
        c.ft_input_client_destroy(&self.handle);
    }
};

fn setPosition(raw: *c.ft_input_event, pos: Position) void {
    raw.x = pos.x;
    raw.y = pos.y;
    raw.geometry_revision = pos.revision;
}

fn enumFromInt(comptime E: type, value: anytype) !E {
    return std.enums.fromInt(E, value) orelse error.InvalidEnumTag;
}
