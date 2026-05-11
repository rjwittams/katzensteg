const std = @import("std");
const xev = @import("xev");
const render_batch_protocol = @import("render_batch_protocol.zig");
const attach_protocol = @import("attach_protocol.zig");
const terminal_batch_applier = @import("terminal_batch_applier.zig");
const blocking_trace = @import("blocking_trace.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;
const Logger = @import("log.zig").Logger;
const config_mod = @import("config.zig");
const upload_path_mod = @import("upload_path.zig");
const ts_kitty = @import("termscene").kitty;

const wm_peer_line_queue_max_entries: usize = 256;
const wm_lifecycle_tick_ms: u64 = 20;

pub const TerminalSize = struct {
    rows: i32,
    cols: i32,
    pixel_width: i32 = 0,
    pixel_height: i32 = 0,
};

pub const Rect = struct {
    row: i32,
    col: i32,
    rows: i32,
    cols: i32,

    pub fn toPresentationRectCells(self: Rect) render_batch_protocol.PresentationRectCells {
        return .{
            .row = self.row,
            .col = self.col,
            .rows = self.rows,
            .cols = self.cols,
        };
    }
};

pub const EventKind = enum {
    launch_started,
    launch_prompt,
    attach_sent,
    viewport_sent,
    input_sent,
    detach_sent,
    detached_received,
    shutdown_sent,
    process_exited,
    parse_error,
    focus_changed,
};

pub const ProtocolEvent = struct {
    kind: EventKind,
    detail: []const u8,

    fn deinit(self: ProtocolEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.detail);
    }
};

pub const ProtocolEventLog = struct {
    allocator: std.mem.Allocator,
    events: []ProtocolEvent,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ProtocolEventLog {
        const events = try allocator.alloc(ProtocolEvent, capacity);
        return .{ .allocator = allocator, .events = events };
    }

    pub fn deinit(self: *ProtocolEventLog) void {
        for (self.events[0..self.count]) |event| event.deinit(self.allocator);
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn record(self: *ProtocolEventLog, kind: EventKind, detail: []const u8) !void {
        if (self.events.len == 0) return;
        if (self.count == self.events.len) {
            self.events[0].deinit(self.allocator);
            std.mem.copyForwards(ProtocolEvent, self.events[0 .. self.events.len - 1], self.events[1..self.events.len]);
            self.count -= 1;
        }
        self.events[self.count] = .{ .kind = kind, .detail = try self.allocator.dupe(u8, detail) };
        self.count += 1;
    }

    pub fn len(self: *const ProtocolEventLog) usize {
        return self.count;
    }

    pub fn at(self: *const ProtocolEventLog, index: usize) ?ProtocolEvent {
        if (index >= self.count) return null;
        return self.events[index];
    }

    pub fn last(self: *const ProtocolEventLog) ?ProtocolEvent {
        if (self.count == 0) return null;
        return self.events[self.count - 1];
    }
};

pub const ProducerSessionState = enum {
    launching,
    running,
    draining,
    exited,
};

pub const WmWindowState = struct {
    window_id: []const u8,
    outer: Rect,
    attached: bool = false,

    pub fn init(window_id: []const u8, outer: Rect) WmWindowState {
        return .{ .window_id = window_id, .outer = outer };
    }

    pub fn markAttached(self: *WmWindowState) void {
        self.attached = true;
    }

    pub fn markDetached(self: *WmWindowState) void {
        self.attached = false;
    }
};

pub const WindowAction = enum {
    move_left,
    move_down,
    move_up,
    move_right,
    resize_narrower,
    resize_shorter,
    resize_taller,
    resize_wider,
};

pub const LayoutAction = enum {
    cascade,
    tile,
};

pub const LaunchPromptAction = union(enum) {
    none,
    changed,
    cancel,
    submit,
};

pub const Cell = struct {
    row: i32,
    col: i32,
};

pub const WmMouseHit = enum {
    desktop,
    content,
    close,
    title,
    resize_right,
    resize_bottom,
    resize_bottom_right,
};

pub const WmMouseDrag = struct {
    hit: WmMouseHit,
    start_cell: Cell,
    start_outer: Rect,

    pub fn start(hit: WmMouseHit, cell: Cell, outer: Rect) WmMouseDrag {
        return .{ .hit = hit, .start_cell = cell, .start_outer = outer };
    }

    pub fn update(self: WmMouseDrag, cell: Cell, terminal: TerminalSize) Rect {
        const drow = cell.row - self.start_cell.row;
        const dcol = cell.col - self.start_cell.col;
        var next = self.start_outer;
        switch (self.hit) {
            .title => {
                next.row += drow;
                next.col += dcol;
            },
            .resize_right => next.cols += dcol,
            .resize_bottom => next.rows += drow,
            .resize_bottom_right => {
                next.rows += drow;
                next.cols += dcol;
            },
            .desktop, .content, .close => {},
        }
        next.rows = @max(min_outer_rows, next.rows);
        next.cols = @max(min_outer_cols, next.cols);
        return clampOuterRect(next, terminal);
    }
};

pub const WmMouseInputState = struct {
    drag: ?WmMouseDrag = null,

    pub fn readMouseInput(self: *WmMouseInputState, bytes: []u8, outer: Rect, content: Rect, terminal: TerminalSize) InputRead {
        const mouse = parseSgrMouseAt(bytes, 0) orelse return .{ .action = .none };
        const cell = Cell{ .row = mouse.row, .col = mouse.col };
        if (!mouse.pressed) {
            const had_drag = self.drag != null;
            self.drag = null;
            return .{ .action = if (had_drag) .consume else .none };
        }
        if (self.drag) |drag| return .{ .action = .{ .mouse_drag = drag.update(cell, terminal) } };
        if ((mouse.button & 3) != 0) return .{ .action = .none };

        const hit = mouseHitTest(outer, cell);
        switch (hit) {
            .close => return .{ .action = .close_focused },
            .title, .resize_right, .resize_bottom, .resize_bottom_right => {
                self.drag = WmMouseDrag.start(hit, cell, outer);
                return .{ .action = .{ .mouse_drag = outer } };
            },
            .content => {
                if (rectContainsCell(content, cell.row, cell.col)) return .{ .action = .forward, .bytes = bytes[0..mouse.len] };
                return .{ .action = .none };
            },
            .desktop => return .{ .action = .none },
        }
    }
};

pub const ChromeOptions = struct {
    outer: Rect,
    title: []const u8,
    focused: bool = true,
    // When set, chrome writes outside the terminal viewport are clipped so a
    // window dragged off the edge doesn't wrap onto the wrong terminal row.
    terminal: ?TerminalSize = null,
};

pub const StatusBandOptions = struct {
    terminal: TerminalSize,
    window: WmWindowState,
    upload_profile: render_batch_protocol.UploadProfile,
    presentation_status: WmPresentationStatus = .{},
    events: *const ProtocolEventLog,
};

pub const WmPresentationStatus = struct {
    seen: bool = false,
    ready_to_show: bool = false,
    source_px: ?render_batch_protocol.SourcePixels = null,
    effective_rect_cells: ?render_batch_protocol.PresentationRectCells = null,
};

const WmChromeSnapshot = struct {
    session_index: usize,
    outer: Rect,
};

pub const WmDesktopRedrawState = struct {
    previous_chrome: [default_wm_session_capacity]WmChromeSnapshot = undefined,
    previous_count: usize = 0,

    fn capture(self: *WmDesktopRedrawState, sessions: []const WmProducerSession, z_order: []const usize) void {
        self.previous_count = 0;
        for (z_order) |session_index| {
            if (session_index >= sessions.len) continue;
            const session = &sessions[session_index];
            if (!sessionIsDrawable(session)) continue;
            // Only the default interactive capacity gets previous-chrome cleanup tracking.
            if (self.previous_count >= self.previous_chrome.len) break;
            self.previous_chrome[self.previous_count] = .{ .session_index = session_index, .outer = session.window.outer };
            self.previous_count += 1;
        }
    }
};

pub const RunExecOptions = struct {
    title: []const u8,
    terminal: TerminalSize,
    aspect: render_batch_protocol.PresentationAspect = .fit,
    upload: render_batch_protocol.UploadPolicy,
};

const min_outer_rows: i32 = 6;
const min_outer_cols: i32 = 20;
const default_wm_session_capacity: usize = 32;
const max_launch_prompt_len: usize = 96;

const text_box = struct {
    const top_left = "┌";
    const top_right = "┐";
    const bottom_left = "└";
    const bottom_right = "┘";
    const tee_left = "├";
    const tee_right = "┤";
    const tee_down = "┬";
    const tee_up = "┴";
    const horizontal = "─";
    const vertical = "│";
};

pub fn applyWindowAction(window: *WmWindowState, action: WindowAction, terminal: TerminalSize) bool {
    return applyWindowActionWithPresentation(window, action, terminal, .{});
}

pub fn applyWindowActionWithPresentation(window: *WmWindowState, action: WindowAction, terminal: TerminalSize, presentation_status: WmPresentationStatus) bool {
    const previous = window.outer;
    var next = window.outer;
    switch (action) {
        .move_left => next.col -= 1,
        .move_down => next.row += 1,
        .move_up => next.row -= 1,
        .move_right => next.col += 1,
        .resize_narrower => next.cols -= 2,
        .resize_shorter => next.rows -= 1,
        .resize_taller => next.rows += 1,
        .resize_wider => next.cols += 2,
    }
    next.rows = @max(min_outer_rows, next.rows);
    next.cols = @max(min_outer_cols, next.cols);
    next = constrainOuterForPresentation(next, resizeAxisForAction(action), terminal, presentation_status);
    window.outer = clampOuterRect(next, terminal);
    return !std.meta.eql(previous, window.outer);
}

const ResizeAxis = enum {
    none,
    width,
    height,
};

fn resizeAxisForAction(action: WindowAction) ResizeAxis {
    return switch (action) {
        .resize_narrower, .resize_wider => .width,
        .resize_shorter, .resize_taller => .height,
        else => .none,
    };
}

fn resizeAxisForMouseHit(hit: WmMouseHit) ResizeAxis {
    return switch (hit) {
        .resize_right, .resize_bottom_right => .width,
        .resize_bottom => .height,
        else => .none,
    };
}

fn constrainOuterForPresentation(proposed: Rect, axis: ResizeAxis, terminal: TerminalSize, status: WmPresentationStatus) Rect {
    if (axis == .none) return proposed;
    const source = status.source_px orelse return proposed;
    if (source.w <= 0 or source.h <= 0 or terminal.pixel_width <= 0 or terminal.pixel_height <= 0 or terminal.cols <= 0 or terminal.rows <= 0) return proposed;

    var next = proposed;
    const content_cols = @max(1, next.cols - 2);
    const content_rows = @max(1, next.rows - 4);
    switch (axis) {
        .width => next.rows = rowsForContentCols(content_cols, source, terminal) + 4,
        .height => next.cols = colsForContentRows(content_rows, source, terminal) + 2,
        .none => {},
    }
    next.rows = @max(min_outer_rows, next.rows);
    next.cols = @max(min_outer_cols, next.cols);
    return next;
}

fn resolveInitialReadyPresentations(sessions: []WmProducerSession, terminal: TerminalSize) bool {
    var changed = false;
    for (sessions) |*session| {
        if (session.initial_presentation_resolved or !sessionIsVisible(session)) continue;
        if (!session.presentation_status.ready_to_show) continue;
        const next = initialResolvedOuterForPresentation(terminal, session.presentation_status) orelse {
            session.initial_presentation_resolved = true;
            continue;
        };
        session.initial_presentation_resolved = true;
        if (!std.meta.eql(session.window.outer, next)) {
            session.window.outer = next;
            changed = true;
        }
    }
    return changed;
}

fn initialResolvedOuterForPresentation(terminal: TerminalSize, status: WmPresentationStatus) ?Rect {
    const effective = status.effective_rect_cells orelse return null;
    if (effective.rows <= 0 or effective.cols <= 0) return null;
    return clampOuterRect(.{
        .row = effective.row - 3,
        .col = effective.col - 1,
        .rows = @max(min_outer_rows, effective.rows + 4),
        .cols = @max(min_outer_cols, effective.cols + 2),
    }, terminal);
}

fn rowsForContentCols(content_cols: i32, source: render_batch_protocol.SourcePixels, terminal: TerminalSize) i32 {
    const numerator = @as(i64, content_cols) * terminal.pixel_width * source.h * terminal.rows;
    const denominator = @as(i64, terminal.cols) * terminal.pixel_height * source.w;
    return @intCast(@min(@as(i64, std.math.maxInt(i32)), @max(@as(i64, 1), divRoundI64(numerator, denominator))));
}

fn colsForContentRows(content_rows: i32, source: render_batch_protocol.SourcePixels, terminal: TerminalSize) i32 {
    const numerator = @as(i64, content_rows) * terminal.pixel_height * source.w * terminal.cols;
    const denominator = @as(i64, terminal.rows) * terminal.pixel_width * source.h;
    return @intCast(@min(@as(i64, std.math.maxInt(i32)), @max(@as(i64, 1), divRoundI64(numerator, denominator))));
}

fn divRoundI64(numerator: i64, denominator: i64) i64 {
    if (denominator <= 0) return numerator;
    return @divTrunc(numerator + @divTrunc(denominator, 2), denominator);
}

pub const SessionLaunchSpec = struct {
    profile_name: []const u8,
    extra_args: []const []const u8 = &.{},
};

pub fn runProfile(allocator: std.mem.Allocator, profile_name: []const u8) !u8 {
    return runSessionSpecs(allocator, &.{.{ .profile_name = profile_name }});
}

pub fn runProfiles(allocator: std.mem.Allocator, profile_names: []const []const u8) !u8 {
    var specs = try allocator.alloc(SessionLaunchSpec, profile_names.len);
    defer allocator.free(specs);
    for (profile_names, 0..) |profile_name, i| {
        specs[i] = .{ .profile_name = profile_name };
    }
    return runSessionSpecs(allocator, specs);
}

pub fn runSessionSpecs(allocator: std.mem.Allocator, specs: []const SessionLaunchSpec) !u8 {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);
    return runSessionSpecsWithProducerExe(allocator, exe, specs);
}

pub fn runSessionSpecsWithProducerExe(allocator: std.mem.Allocator, producer_exe: []const u8, specs: []const SessionLaunchSpec) !u8 {
    return runMultiProfile(allocator, producer_exe, specs);
}

const WmProducerSession = struct {
    profile_name: []const u8,
    window: WmWindowState,
    upload: render_batch_protocol.UploadPolicy,
    presentation_status: WmPresentationStatus = .{},
    initial_presentation_resolved: bool = false,
    child: std.process.Child,
    child_stdin: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,
    stdout_buffer: std.ArrayList(u8) = .empty,
    stdout_ready: bool = false,
    stdout_poll_armed: bool = false,
    stdout_poll_supported: bool = true,
    stdout_poll_completion: xev.Completion = .{},
    wait_state: ChildWaitState = .{},
    state: ProducerSessionState = .launching,
    control_open: bool = true,
    stdin_closed: bool = false,

    fn focusedContent(self: WmProducerSession) Rect {
        return contentRectForOuter(self.window.outer);
    }
};

const WmPeerLineQueueEntry = struct {
    session: ?*WmProducerSession,
    line: []u8,
};

const WmPeerLineQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    not_full: std.Thread.Condition = .{},
    entries: std.ArrayList(WmPeerLineQueueEntry) = .empty,
    head: usize = 0,
    max_entries: usize = wm_peer_line_queue_max_entries,
    blocked_enqueue_count: usize = 0,
    closed: bool = false,
    blocking_trace_settings: blocking_trace.Settings = .{},
    blocking_trace_logger: ?*Logger = null,

    fn init(allocator: std.mem.Allocator) WmPeerLineQueue {
        return initWithMaxEntries(allocator, wm_peer_line_queue_max_entries);
    }

    fn initWithMaxEntries(allocator: std.mem.Allocator, max_entries: usize) WmPeerLineQueue {
        std.debug.assert(max_entries > 0);
        return .{ .allocator = allocator, .max_entries = max_entries };
    }

    fn enableBlockingTrace(self: *WmPeerLineQueue, settings: blocking_trace.Settings, logger: *Logger) void {
        self.blocking_trace_settings = settings;
        self.blocking_trace_logger = logger;
    }

    fn close(self: *WmPeerLineQueue) void {
        self.mutex.lock();
        self.closed = true;
        self.not_full.broadcast();
        self.mutex.unlock();
    }

    fn deinit(self: *WmPeerLineQueue) void {
        self.close();
        self.mutex.lock();
        for (self.entries.items[self.head..]) |entry| self.allocator.free(entry.line);
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    fn enqueueCopy(self: *WmPeerLineQueue, session: ?*WmProducerSession, line: []const u8) !void {
        const owned_line = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned_line);

        const trace_enabled = self.blocking_trace_settings.enabled;
        const lock_start_ns = if (trace_enabled) std.time.nanoTimestamp() else 0;
        self.mutex.lock();
        const lock_duration_ns = if (trace_enabled) blocking_trace.elapsedSince(lock_start_ns) else 0;
        defer self.mutex.unlock();
        self.traceBlocking("wm_peer_queue_lock", lock_duration_ns, line.len, self.entries.items.len - self.head);
        var wait_duration_ns: i128 = 0;
        while (!self.closed and self.entries.items.len - self.head >= self.max_entries) {
            self.blocked_enqueue_count += 1;
            const wait_start_ns = if (trace_enabled) std.time.nanoTimestamp() else 0;
            self.not_full.wait(&self.mutex);
            if (trace_enabled) wait_duration_ns += blocking_trace.elapsedSince(wait_start_ns);
            self.blocked_enqueue_count -= 1;
        }
        self.traceBlocking("wm_peer_queue_full_wait", wait_duration_ns, line.len, self.entries.items.len - self.head);
        if (self.closed) return error.QueueClosed;
        try self.entries.append(self.allocator, .{ .session = session, .line = owned_line });
    }

    fn traceBlocking(self: *WmPeerLineQueue, comptime context: []const u8, duration_ns: i128, line_bytes: usize, depth: usize) void {
        const settings = self.blocking_trace_settings;
        if (!blocking_trace.shouldLog(settings.enabled, duration_ns, settings.threshold_ns)) return;
        if (self.blocking_trace_logger) |logger| {
            logger.writeFmtScoped(.info, .wm, "blocking trace context={s} duration_us={d} line_bytes={d} queue_depth={d}", .{
                context,
                blocking_trace.micros(duration_ns),
                line_bytes,
                depth,
            });
        }
    }

    fn take(self: *WmPeerLineQueue, allocator: std.mem.Allocator, max_items: usize) !std.ArrayList(WmPeerLineQueueEntry) {
        var batch = std.ArrayList(WmPeerLineQueueEntry).empty;
        errdefer batch.deinit(allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        const available = self.entries.items.len - self.head;
        const count = if (max_items == 0) available else @min(max_items, available);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            try batch.append(allocator, self.entries.items[self.head + index]);
        }
        self.head += count;
        if (count > 0) self.not_full.broadcast();
        self.compactRetainedEntries();
        return batch;
    }

    fn compactRetainedEntries(self: *WmPeerLineQueue) void {
        if (self.head == 0) return;
        if (self.head == self.entries.items.len) {
            self.entries.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < 256 or self.head * 2 < self.entries.items.len) return;

        const remaining = self.entries.items[self.head..];
        std.mem.copyForwards(WmPeerLineQueueEntry, self.entries.items[0..remaining.len], remaining);
        self.entries.shrinkRetainingCapacity(remaining.len);
        self.head = 0;
    }
};

const WmEventLoop = struct {
    loop: xev.Loop,
    lifecycle_timer: xev.Timer,
    tty_poll_completion: xev.Completion = .{},
    lifecycle_timer_completion: xev.Completion = .{},
    tty_ready: bool = false,
    tty_poll_armed: bool = false,
    tty_poll_supported: bool = ttyXevPollSupported(),
    lifecycle_ready: bool = false,
    lifecycle_timer_armed: bool = false,

    fn init() !WmEventLoop {
        return .{
            .loop = try xev.Loop.init(.{}),
            .lifecycle_timer = try xev.Timer.init(),
        };
    }

    fn deinit(self: *WmEventLoop) void {
        self.lifecycle_timer.deinit();
        self.loop.deinit();
    }
};

fn ttyXevPollSupported() bool {
    // Keep this as a capability hook rather than inlining `true`; the main loop
    // has a lifecycle-tick fallback for platforms where tty readiness polling
    // later proves unreliable.
    return true;
}

fn armWmEventSources(events: *WmEventLoop, tty: *DirectTty, sessions: []WmProducerSession) void {
    armWmTtyRead(events, tty);
    armWmLifecycleTick(events);
    for (sessions) |*session| armWmSessionStdoutRead(events, session);
}

fn armWmTtyRead(events: *WmEventLoop, tty: *DirectTty) void {
    if (!events.tty_poll_supported) return;
    if (events.tty_ready or events.tty_poll_armed) return;
    const file = xev.File.initFd(tty.file.handle);
    file.poll(&events.loop, &events.tty_poll_completion, .read, WmEventLoop, events, onWmTtyReadable);
    events.tty_poll_armed = true;
}

fn armWmLifecycleTick(events: *WmEventLoop) void {
    if (events.lifecycle_ready or events.lifecycle_timer_armed) return;
    events.lifecycle_timer.run(&events.loop, &events.lifecycle_timer_completion, wm_lifecycle_tick_ms, WmEventLoop, events, onWmLifecycleTick);
    events.lifecycle_timer_armed = true;
}

fn armWmSessionStdoutRead(events: *WmEventLoop, session: *WmProducerSession) void {
    if (!session.stdout_poll_supported) return;
    if (session.stdout_ready or session.stdout_poll_armed) return;
    const stdout_file = session.stdout_file orelse return;
    const file = xev.File.initFd(stdout_file.handle);
    file.poll(&events.loop, &session.stdout_poll_completion, .read, WmProducerSession, session, onWmSessionStdoutReadable);
    session.stdout_poll_armed = true;
}

fn onWmTtyReadable(
    events: ?*WmEventLoop,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const state = events orelse return .disarm;
    _ = result catch {
        state.tty_poll_armed = false;
        state.tty_poll_supported = false;
        return .disarm;
    };
    state.tty_ready = true;
    state.tty_poll_armed = false;
    return .disarm;
}

fn onWmLifecycleTick(
    events: ?*WmEventLoop,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch {};
    const state = events orelse return .disarm;
    state.lifecycle_ready = true;
    state.lifecycle_timer_armed = false;
    return .disarm;
}

fn onWmSessionStdoutReadable(
    session: ?*WmProducerSession,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const producer = session orelse return .disarm;
    _ = result catch {
        producer.stdout_poll_armed = false;
        producer.stdout_poll_supported = false;
        return .disarm;
    };
    producer.stdout_ready = true;
    producer.stdout_poll_armed = false;
    return .disarm;
}

fn runMultiProfile(allocator: std.mem.Allocator, producer_exe: []const u8, specs: []const SessionLaunchSpec) !u8 {
    var tty = try DirectTty.init();
    defer tty.deinit();

    var logger = Logger.init(allocator);
    defer logger.deinit();
    var event_log = try ProtocolEventLog.init(allocator, 16);
    defer event_log.deinit();
    var tty_lock = std.Thread.Mutex{};
    var redraw_requested = std.atomic.Value(bool).init(false);
    var peer_queue = WmPeerLineQueue.init(allocator);
    defer peer_queue.deinit();
    const trace_blocking = blocking_trace.settingsFromEnv();
    if (trace_blocking.enabled) {
        logger.writeFmtScoped(.info, .wm, "blocking trace enabled threshold_ms={d}", .{@divTrunc(trace_blocking.threshold_ns, std.time.ns_per_ms)});
        peer_queue.enableBlockingTrace(trace_blocking, &logger);
    }

    const terminal = TerminalSize{ .rows = tty.rows, .cols = tty.cols, .pixel_width = tty.pixel_width, .pixel_height = tty.pixel_height };
    const session_capacity = @max(specs.len, default_wm_session_capacity);
    var sessions = try allocator.alloc(WmProducerSession, session_capacity);
    defer allocator.free(sessions);
    var z_order = try allocator.alloc(usize, session_capacity);
    defer allocator.free(z_order);
    var initialized: usize = 0;
    defer {
        peer_queue.close();
        for (sessions[0..initialized]) |*session| {
            closeSessionControl(session);
            if (session.stdout_file) |file| file.close();
            session.stdout_buffer.deinit(allocator);
            deinitUploadPolicy(allocator, &session.upload);
            allocator.free(session.profile_name);
        }
    }

    try tty.enableInputCapture();
    for (specs, 0..) |spec, i| {
        z_order[i] = i;
        sessions[i] = try launchProducerSession(allocator, producer_exe, tty.file, terminal, spec, i, &event_log);
        initialized += 1;
        try startSessionProcessPolling(&sessions[i]);
    }

    var focused_index: usize = 0;
    var redraw_state = WmDesktopRedrawState{};
    const writer = tty.file.deprecatedWriter();
    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
    for (sessions[0..initialized]) |*session| {
        try startSessionStdoutPolling(session);
    }
    logger.writeFmtScoped(.info, .wm, "multi-profile launch count={d}", .{initialized});

    var shutdown_sent = false;
    const keep_alive_when_empty = specs.len == 0;
    var input_buf: [256]u8 = undefined;
    var mouse_state = WmMouseInputState{};
    var launch_prompt = std.ArrayList(u8).empty;
    defer launch_prompt.deinit(allocator);
    var prompt_active = false;
    var wm_events = try WmEventLoop.init();
    defer wm_events.deinit();
    while (!shutdown_sent and (keep_alive_when_empty or !allSessionsDone(sessions[0..initialized]))) {
        armWmEventSources(&wm_events, &tty, sessions[0..initialized]);
        try wm_events.loop.run(.once);
        for (sessions[0..initialized]) |*session| {
            if (!session.stdout_ready) continue;
            session.stdout_ready = false;
            _ = try drainSessionStdoutChunk(allocator, session, &peer_queue);
            _ = try drainMainLoopPeerLinesWithTrace(allocator, &peer_queue, writer, &tty_lock, &redraw_requested, trace_blocking, &logger);
        }
        if (wm_events.lifecycle_ready) {
            wm_events.lifecycle_ready = false;
            if (!wm_events.tty_poll_supported) wm_events.tty_ready = true;
            for (sessions[0..initialized]) |*session| {
                if (!session.stdout_poll_supported) session.stdout_ready = true;
            }
            _ = try pollSessionChildExits(sessions[0..initialized]);
            const lifecycle = try reconcileExitedSessions(sessions[0..initialized], z_order[0..initialized], &focused_index, &mouse_state, &event_log, &logger);
            if (lifecycle.changed) {
                if (lifecycle.focus_changed or lifecycle.z_order_changed) try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
            }
        }
        if (redraw_requested.swap(false, .seq_cst)) {
            const initial_ready_changed = blk: {
                tty_lock.lock();
                defer tty_lock.unlock();
                break :blk resolveInitialReadyPresentations(sessions[0..initialized], terminal);
            };
            if (initial_ready_changed) {
                try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
            }
            try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
        }
        if (prompt_active and wm_events.tty_ready) {
            wm_events.tty_ready = false;
            const prompt = try readLaunchPromptInput(&tty, &input_buf, &launch_prompt, allocator);
            switch (prompt) {
                .none => {},
                .changed => {
                    try recordLaunchPrompt(&event_log, launch_prompt.items);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
                .cancel => {
                    prompt_active = false;
                    launch_prompt.clearRetainingCapacity();
                    try event_log.record(.launch_prompt, "cancelled");
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
                .submit => {
                    prompt_active = false;
                    if (launch_prompt.items.len == 0) {
                        try event_log.record(.launch_prompt, "empty");
                    } else if (initialized >= session_capacity) {
                        try event_log.record(.parse_error, "session limit reached");
                    } else {
                        const new_index = initialized;
                        z_order[new_index] = new_index;
                        sessions[new_index] = try launchProducerSession(allocator, producer_exe, tty.file, terminal, .{ .profile_name = launch_prompt.items }, new_index, &event_log);
                        initialized += 1;
                        try startSessionProcessPolling(&sessions[new_index]);
                        focused_index = new_index;
                        bringWindowToFront(z_order[0..initialized], focused_index);
                        mouse_state = .{};
                        try startSessionStdoutPolling(&sessions[new_index]);
                        try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                    }
                    launch_prompt.clearRetainingCapacity();
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
            }
            continue;
        }
        if (!shutdown_sent and wm_events.tty_ready) {
            wm_events.tty_ready = false;
            const input = readInputForSessionsLocked(&tty_lock, &tty, &input_buf, &mouse_state, sessions[0..initialized], z_order[0..initialized], &focused_index, terminal);
            if (input.focus_changed) {
                try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
            }
            switch (input.action) {
                .none, .consume => {},
                .start_launch => {
                    prompt_active = true;
                    launch_prompt.clearRetainingCapacity();
                    try recordLaunchPrompt(&event_log, launch_prompt.items);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
                .focus_next => {
                    if (nextVisibleSessionIndex(sessions[0..initialized], focused_index)) |next_index| {
                        focused_index = next_index;
                        bringWindowToFront(z_order[0..initialized], focused_index);
                        mouse_state = .{};
                        try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                    }
                },
                .close_focused => {
                    if (initialized == 0) continue;
                    const focused = &sessions[focused_index];
                    try shutdownSession(focused, &event_log, &logger);
                    if (nextVisibleSessionIndex(sessions[0..initialized], focused_index)) |next_index| {
                        focused_index = next_index;
                        bringWindowToFront(z_order[0..initialized], focused_index);
                        mouse_state = .{};
                        try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                    }
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
                .forward => {
                    if (initialized == 0) continue;
                    try forwardInputToSession(&sessions[focused_index], input.bytes, &event_log, &logger);
                },
                .quit => {
                    shutdown_sent = true;
                    for (sessions[0..initialized]) |*session| try shutdownSession(session, &event_log, &logger);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                },
                .window => |action| {
                    if (initialized == 0) continue;
                    const focused = &sessions[focused_index];
                    const presentation_status = blk: {
                        tty_lock.lock();
                        defer tty_lock.unlock();
                        break :blk focused.presentation_status;
                    };
                    if (applyWindowActionWithPresentation(&focused.window, action, terminal, presentation_status)) {
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                    }
                },
                .layout => |action| {
                    if (applyLayoutAction(sessions[0..initialized], action, terminal)) {
                        mouse_state = .{};
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                    }
                },
                .mouse_drag => |outer| {
                    if (initialized == 0) continue;
                    const focused = &sessions[focused_index];
                    const presentation_status = blk: {
                        tty_lock.lock();
                        defer tty_lock.unlock();
                        break :blk focused.presentation_status;
                    };
                    const next_outer = if (mouse_state.drag) |drag|
                        constrainOuterForPresentation(outer, resizeAxisForMouseHit(drag.hit), terminal, presentation_status)
                    else
                        outer;
                    if (!std.meta.eql(focused.window.outer, next_outer)) {
                        focused.window.outer = clampOuterRect(next_outer, terminal);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], terminal, .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
                    }
                },
            }
        }
    }

    for (sessions[0..initialized]) |*session| {
        closeSessionControl(session);
    }
    for (sessions[0..initialized]) |*session| {
        try waitForSessionChildExit(session);
        const already_recorded_exit = session.state == .exited;
        session.state = .exited;
        _ = try drainSessionStdoutAvailable(allocator, session, &peer_queue);
        if (!already_recorded_exit) try event_log.record(.process_exited, session.profile_name);
    }
    peer_queue.close();
    while (try drainQueuedPeerLinesWithTrace(allocator, &peer_queue, writer, &tty_lock, &redraw_requested, 0, trace_blocking, &logger)) {}
    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log, &redraw_state);
    if (shutdown_sent) return 0;
    for (sessions[0..initialized]) |*session| {
        const code = childTermExitCode(session.wait_state.term);
        if (code != 0) return code;
    }
    return 0;
}

fn launchProducerSession(allocator: std.mem.Allocator, producer_exe: []const u8, tty_file: std.fs.File, terminal: TerminalSize, spec: SessionLaunchSpec, session_index: usize, events: *ProtocolEventLog) !WmProducerSession {
    var upload = try uploadPolicyForSession(allocator, tty_file, session_index);
    errdefer deinitUploadPolicy(allocator, &upload);

    const owned_profile_name = try allocator.dupe(u8, spec.profile_name);
    errdefer allocator.free(owned_profile_name);

    const child_argv = try buildProducerArgv(allocator, producer_exe, owned_profile_name, spec.extra_args);
    defer allocator.free(child_argv);

    var child = std.process.Child.init(child_argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    // Producers run inside the terminal surface, so stderr must not inherit it.
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var session = WmProducerSession{
        .profile_name = owned_profile_name,
        .window = WmWindowState.init("main", cascadedOuterRect(terminal, session_index)),
        .upload = upload,
        .child = child,
    };
    errdefer closeSessionControl(&session);

    session.child_stdin = session.child.stdin.?;
    session.child.stdin = null;
    const ranges = idRangesForSession(session_index);
    const session_rect = session.focusedContent().toPresentationRectCells();
    try writeInitialControl(session.child_stdin.?.deprecatedWriter(), .{
        .rect_cells = session_rect,
        .aspect = .fit,
        .z_base = zBaseForSlot(session_index),
        .terminal = terminal,
        .clip_cells = computeClipForRect(session_rect, terminal),
        .image_ids = ranges.image,
        .placement_ids = ranges.placement,
        .upload = session.upload,
    });
    session.window.markAttached();
    session.state = .running;
    try events.record(.attach_sent, owned_profile_name);

    session.stdout_file = session.child.stdout.?;
    session.child.stdout = null;
    return session;
}

fn buildProducerArgv(allocator: std.mem.Allocator, producer_exe: []const u8, profile_name: []const u8, extra_args: []const []const u8) ![]const []const u8 {
    var argv = try allocator.alloc([]const u8, 3 + extra_args.len);
    argv[0] = producer_exe;
    argv[1] = "--embed-jsonl";
    argv[2] = profile_name;
    for (extra_args, 0..) |arg, i| {
        argv[3 + i] = arg;
    }
    return argv;
}

fn startSessionStdoutPolling(session: *WmProducerSession) !void {
    const stdout_file = session.stdout_file orelse return;
    setNonBlocking(stdout_file.handle);
}

fn drainSessionStdoutAvailable(allocator: std.mem.Allocator, session: *WmProducerSession, peer_queue: *WmPeerLineQueue) !bool {
    var made_progress = false;
    while (try drainSessionStdoutChunk(allocator, session, peer_queue)) {
        made_progress = true;
    }
    return made_progress;
}

fn drainSessionStdoutChunk(allocator: std.mem.Allocator, session: *WmProducerSession, peer_queue: *WmPeerLineQueue) !bool {
    return drainSessionStdoutChunkWithLimit(allocator, session, peer_queue, 8192);
}

fn drainSessionStdoutChunkWithLimit(allocator: std.mem.Allocator, session: *WmProducerSession, peer_queue: *WmPeerLineQueue, max_bytes: usize) !bool {
    const stdout_file = session.stdout_file orelse return false;

    var buf: [8192]u8 = undefined;
    const limit = @min(max_bytes, buf.len);
    if (limit == 0) return false;
    const n = stdout_file.read(buf[0..limit]) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => {
            stdout_file.close();
            session.stdout_file = null;
            try flushPeerStdoutBuffer(session, peer_queue);
            return false;
        },
    };
    if (n == 0) {
        stdout_file.close();
        session.stdout_file = null;
        try flushPeerStdoutBuffer(session, peer_queue);
        return true;
    }
    try queuePeerStdoutBytes(allocator, session, peer_queue, buf[0..n]);
    return true;
}

fn queuePeerStdoutBytes(allocator: std.mem.Allocator, session: *WmProducerSession, peer_queue: *WmPeerLineQueue, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '\n') {
            try peer_queue.enqueueCopy(session, session.stdout_buffer.items);
            session.stdout_buffer.clearRetainingCapacity();
        } else if (byte != '\r') {
            try session.stdout_buffer.append(allocator, byte);
        }
    }
}

fn flushPeerStdoutBuffer(session: *WmProducerSession, peer_queue: *WmPeerLineQueue) !void {
    if (session.stdout_buffer.items.len == 0) return;
    try peer_queue.enqueueCopy(session, session.stdout_buffer.items);
    session.stdout_buffer.clearRetainingCapacity();
}

fn setNonBlocking(fd: std.posix.fd_t) void {
    const flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    var typed_flags: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
    typed_flags.NONBLOCK = true;
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, @as(u32, @bitCast(typed_flags))) catch {};
}

fn startSessionProcessPolling(session: *WmProducerSession) !void {
    try session.child.waitForSpawn();
}

fn pollSessionChildExits(sessions: []WmProducerSession) !bool {
    var changed = false;
    for (sessions) |*session| {
        if (try pollSessionChildExit(session)) changed = true;
    }
    return changed;
}

fn pollSessionChildExit(session: *WmProducerSession) !bool {
    if (session.wait_state.done.load(.seq_cst)) return false;
    try session.child.waitForSpawn();

    const result = std.posix.waitpid(session.child.id, std.posix.W.NOHANG);
    if (result.pid == 0) return false;

    markSessionChildExited(session, childTermFromStatus(result.status));
    return true;
}

fn waitForSessionChildExit(session: *WmProducerSession) !void {
    if (session.wait_state.done.load(.seq_cst)) return;
    markSessionChildExited(session, session.child.wait() catch .{ .Unknown = 0 });
}

fn markSessionChildExited(session: *WmProducerSession, term: std.process.Child.Term) void {
    session.child.term = term;
    session.wait_state.term = term;
    // term is safe to read after done is observed true; seq_cst releases the write.
    session.wait_state.done.store(true, .seq_cst);
}

fn childTermFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

pub fn runExecWithWriter(allocator: std.mem.Allocator, argv: []const []const u8, writer: anytype, options: RunExecOptions) !u8 {
    if (argv.len == 0) return 64;

    const outer = initialOuterRect(options.terminal);
    try renderChrome(writer, .{ .outer = outer, .title = options.title, .focused = true, .terminal = options.terminal });

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    if (child.stdin) |stdin_file| {
        child.stdin = null;
        const exec_rect = contentRectForOuter(outer).toPresentationRectCells();
        try writeInitialControl(stdin_file.deprecatedWriter(), .{
            .rect_cells = exec_rect,
            .aspect = options.aspect,
            .terminal = options.terminal,
            .clip_cells = computeClipForRect(exec_rect, options.terminal),
            .upload = options.upload,
        });
        stdin_file.close();
    }

    if (child.stdout) |stdout_file| {
        child.stdout = null;
        try applyPeerStdout(allocator, stdout_file, writer);
    }

    return childTermExitCode(try child.wait());
}

fn initialOuterRect(terminal: TerminalSize) Rect {
    return clampOuterRect(.{
        .row = 1,
        .col = 1,
        .rows = @max(min_outer_rows, terminal.rows - 2),
        .cols = @max(min_outer_cols, terminal.cols - 4),
    }, terminal);
}

fn cascadedOuterRect(terminal: TerminalSize, index: usize) Rect {
    const base = initialOuterRect(terminal);
    const offset: i32 = @intCast(@min(index, @as(usize, 16)));
    return clampOuterRect(.{
        .row = base.row + offset,
        .col = base.col + offset * 2,
        .rows = base.rows,
        .cols = base.cols,
    }, terminal);
}

fn hitWindowIndex(windows: []const WmWindowState, z_order: []const usize, cell: Cell) ?usize {
    var index = z_order.len;
    while (index > 0) {
        index -= 1;
        const window_index = z_order[index];
        if (window_index < windows.len and rectContainsCell(windows[window_index].outer, cell.row, cell.col)) return window_index;
    }
    return null;
}

fn hitSessionIndex(sessions: []const WmProducerSession, z_order: []const usize, cell: Cell) ?usize {
    var index = z_order.len;
    while (index > 0) {
        index -= 1;
        const session_index = z_order[index];
        if (session_index < sessions.len and sessionIsDrawable(&sessions[session_index]) and rectContainsCell(sessions[session_index].window.outer, cell.row, cell.col)) return session_index;
    }
    return null;
}

fn sessionIsVisible(session: *const WmProducerSession) bool {
    return session.state == .running and !session.wait_state.done.load(.seq_cst);
}

fn sessionIsDrawable(session: *const WmProducerSession) bool {
    return sessionIsVisible(session) and session.presentation_status.ready_to_show;
}

const LifecycleReconcileResult = struct {
    changed: bool = false,
    focus_changed: bool = false,
    z_order_changed: bool = false,
};

fn reconcileExitedSessions(sessions: []WmProducerSession, z_order: []usize, focused_index: *usize, mouse: *WmMouseInputState, events: *ProtocolEventLog, logger: *Logger) !LifecycleReconcileResult {
    var result = LifecycleReconcileResult{};
    if (sessions.len == 0) return result;
    for (sessions, 0..) |*session, session_index| {
        if (session.state == .exited or !session.wait_state.done.load(.seq_cst)) continue;

        session.state = .exited;
        closeSessionControl(session);
        result.changed = true;
        logger.writeFmtScoped(.info, .wm, "producer exited profile={s} {s}", .{ session.profile_name, childTermSummary(session.wait_state.term) });
        try events.record(.process_exited, session.profile_name);

        if (session_index == focused_index.*) {
            if (nextVisibleSessionIndex(sessions, focused_index.*)) |next_index| {
                focused_index.* = next_index;
                mouse.* = .{};
                result.focus_changed = true;
                try events.record(.focus_changed, sessions[focused_index.*].profile_name);
                bringWindowToFront(z_order, focused_index.*);
            }
        }
    }

    if (focused_index.* >= sessions.len) {
        focused_index.* = 0;
        result.focus_changed = true;
        result.changed = true;
    }
    if (sessions.len > 0 and !sessionIsVisible(&sessions[focused_index.*])) {
        if (nextVisibleSessionIndex(sessions, focused_index.*)) |next_index| {
            focused_index.* = next_index;
            mouse.* = .{};
            result.focus_changed = true;
            result.changed = true;
            try events.record(.focus_changed, sessions[focused_index.*].profile_name);
            bringWindowToFront(z_order, focused_index.*);
        }
    }

    if (compactVisibleZOrder(sessions, z_order)) {
        result.changed = true;
        result.z_order_changed = true;
    }
    return result;
}

fn nextVisibleSessionIndex(sessions: []const WmProducerSession, current_index: usize) ?usize {
    if (sessions.len == 0) return null;
    var offset: usize = 1;
    while (offset <= sessions.len) : (offset += 1) {
        const index = (current_index + offset) % sessions.len;
        if (sessionIsVisible(&sessions[index])) return index;
    }
    return null;
}

fn compactVisibleZOrder(sessions: []const WmProducerSession, z_order: []usize) bool {
    var first_visible: usize = 0;
    while (first_visible < z_order.len and !zOrderEntryVisible(sessions, z_order[first_visible])) : (first_visible += 1) {}

    var changed = false;
    var scan = first_visible + 1;
    while (scan < z_order.len) : (scan += 1) {
        if (zOrderEntryVisible(sessions, z_order[scan])) continue;
        const value = z_order[scan];
        var shift = scan;
        while (shift > first_visible) : (shift -= 1) z_order[shift] = z_order[shift - 1];
        z_order[first_visible] = value;
        first_visible += 1;
        changed = true;
    }
    return changed;
}

fn zOrderEntryVisible(sessions: []const WmProducerSession, session_index: usize) bool {
    return session_index < sessions.len and sessionIsVisible(&sessions[session_index]);
}

fn bringWindowToFront(z_order: []usize, window_index: usize) void {
    const pos = std.mem.indexOfScalar(usize, z_order, window_index) orelse return;
    var index = pos;
    while (index + 1 < z_order.len) : (index += 1) z_order[index] = z_order[index + 1];
    z_order[z_order.len - 1] = window_index;
}

fn applyLayoutAction(sessions: []WmProducerSession, action: LayoutAction, terminal: TerminalSize) bool {
    return switch (action) {
        .cascade => applyCascadeLayout(sessions, terminal),
        .tile => applyTileLayout(sessions, terminal),
    };
}

fn applyCascadeLayout(sessions: []WmProducerSession, terminal: TerminalSize) bool {
    var changed = false;
    var visible_index: usize = 0;
    for (sessions) |*session| {
        if (!sessionIsVisible(session)) continue;
        const next = cascadedOuterRect(terminal, visible_index);
        if (!std.meta.eql(session.window.outer, next)) {
            session.window.outer = next;
            changed = true;
        }
        visible_index += 1;
    }
    return changed;
}

fn applyTileLayout(sessions: []WmProducerSession, terminal: TerminalSize) bool {
    const visible_count = countVisibleSessions(sessions);
    if (visible_count == 0) return false;

    const columns = ceilSqrt(visible_count);
    const rows = ceilDiv(visible_count, columns);
    const usable_rows: i32 = @max(min_outer_rows, terminal.rows - 1);
    const cell_rows: i32 = @max(min_outer_rows, @divFloor(usable_rows, @as(i32, @intCast(rows))));
    const cell_cols: i32 = @max(min_outer_cols, @divFloor(terminal.cols, @as(i32, @intCast(columns))));

    var changed = false;
    var visible_index: usize = 0;
    for (sessions) |*session| {
        if (!sessionIsVisible(session)) continue;

        const tile_row: i32 = @intCast(visible_index / columns);
        const tile_col: i32 = @intCast(visible_index % columns);
        const row = 1 + tile_row * cell_rows;
        const col = 1 + tile_col * cell_cols;
        const rect_rows = if (@as(usize, @intCast(tile_row + 1)) == rows) usable_rows - tile_row * cell_rows else cell_rows;
        const rect_cols = if (@as(usize, @intCast(tile_col + 1)) == columns) terminal.cols - tile_col * cell_cols else cell_cols;
        const next = clampOuterRect(.{
            .row = row,
            .col = col,
            .rows = @max(min_outer_rows, rect_rows),
            .cols = @max(min_outer_cols, rect_cols),
        }, terminal);
        if (!std.meta.eql(session.window.outer, next)) {
            session.window.outer = next;
            changed = true;
        }
        visible_index += 1;
    }
    return changed;
}

fn countVisibleSessions(sessions: []const WmProducerSession) usize {
    var count: usize = 0;
    for (sessions) |*session| {
        if (sessionIsVisible(session)) count += 1;
    }
    return count;
}

fn ceilSqrt(value: usize) usize {
    var out: usize = 1;
    while (out * out < value) : (out += 1) {}
    return out;
}

fn ceilDiv(numerator: usize, denominator: usize) usize {
    return (numerator + denominator - 1) / denominator;
}

pub fn renderChrome(writer: anytype, options: ChromeOptions) !void {
    if (options.outer.rows < 3 or options.outer.cols < 4) return;

    try writer.writeAll(if (options.focused) "\x1b[1;36m" else "\x1b[2m");
    defer writer.writeAll("\x1b[0m") catch {};

    const horizontal_len: usize = @intCast(@max(0, options.outer.cols - 2));
    var emitter = ChromeEmitter{ .terminal = options.terminal };

    // Top border
    emitter.startRow(options.outer.row, options.outer.col);
    try emitter.cell(writer, text_box.top_left);
    if (horizontal_len > 1) {
        try emitter.cell(writer, text_box.horizontal);
        try emitter.cell(writer, text_box.tee_down);
        try emitter.repeat(writer, text_box.horizontal, horizontal_len - 2);
    } else {
        try emitter.repeat(writer, text_box.horizontal, horizontal_len);
    }
    try emitter.cell(writer, text_box.top_right);

    // Title row: left vertical, ╳, vertical, space, label/title, padding, right vertical.
    // Preserves the existing byte-truncate semantics (each ASCII byte = one cell).
    emitter.startRow(options.outer.row + 1, options.outer.col);
    try emitter.cell(writer, text_box.vertical);
    try emitter.cell(writer, "╳");
    try emitter.cell(writer, text_box.vertical);
    try emitter.cell(writer, " ");
    const label_prefix = if (options.focused) "*katzensteg wm " else " katzensteg wm ";
    const title_space: usize = @intCast(@max(0, options.outer.cols - 2));
    var written: usize = @min(3, title_space);
    written += try emitter.bytes(writer, label_prefix, title_space -| written);
    written += try emitter.bytes(writer, options.title, title_space -| written);
    if (written < title_space) try emitter.repeat(writer, " ", title_space - written);
    try emitter.cell(writer, text_box.vertical);

    // Separator row
    emitter.startRow(options.outer.row + 2, options.outer.col);
    try emitter.cell(writer, text_box.tee_left);
    if (horizontal_len > 1) {
        try emitter.cell(writer, text_box.horizontal);
        try emitter.cell(writer, text_box.tee_up);
        try emitter.repeat(writer, text_box.horizontal, horizontal_len - 2);
    } else {
        try emitter.repeat(writer, text_box.horizontal, horizontal_len);
    }
    try emitter.cell(writer, text_box.tee_right);

    // Side rows: only the two vertical bars.
    var row = options.outer.row + 3;
    while (row < options.outer.row + options.outer.rows - 1) : (row += 1) {
        emitter.startRow(row, options.outer.col);
        try emitter.cell(writer, text_box.vertical);
        emitter.startRow(row, options.outer.col + options.outer.cols - 1);
        try emitter.cell(writer, text_box.vertical);
    }

    // Bottom border
    emitter.startRow(options.outer.row + options.outer.rows - 1, options.outer.col);
    try emitter.cell(writer, text_box.bottom_left);
    try emitter.repeat(writer, text_box.horizontal, horizontal_len);
    try emitter.cell(writer, text_box.bottom_right);

    const content = contentRectForOuter(options.outer);
    // Park the cursor at content's top-left only if visible; out-of-bounds
    // cursor moves are themselves harmlessly clamped by the terminal.
    try moveCursor(writer, content.row, content.col);
}

const ChromeEmitter = struct {
    terminal: ?TerminalSize,
    row: i32 = 0,
    col: i32 = 0,
    in_run: bool = false,

    fn startRow(self: *ChromeEmitter, row: i32, col: i32) void {
        self.row = row;
        self.col = col;
        self.in_run = false;
    }

    fn cell(self: *ChromeEmitter, writer: anytype, glyph: []const u8) !void {
        const visible = if (self.terminal) |term|
            self.row >= 1 and self.row <= term.rows and self.col >= 1 and self.col <= term.cols
        else
            true;
        if (visible) {
            if (!self.in_run) {
                try moveCursor(writer, self.row, self.col);
                self.in_run = true;
            }
            try writer.writeAll(glyph);
        } else {
            self.in_run = false;
        }
        self.col += 1;
    }

    fn repeat(self: *ChromeEmitter, writer: anytype, glyph: []const u8, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) try self.cell(writer, glyph);
    }

    /// Emit up to `max_cells` bytes from `bytes`, treating each byte as one cell.
    /// Matches the existing byte-truncate behaviour the chrome title used.
    fn bytes(self: *ChromeEmitter, writer: anytype, source: []const u8, max_cells: usize) !usize {
        const n = @min(source.len, max_cells);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.cell(writer, source[i .. i + 1]);
        }
        return n;
    }
};

pub fn renderStatusBand(writer: anytype, options: StatusBandOptions) !void {
    if (options.terminal.rows < 1 or options.terminal.cols < 1) return;

    try moveCursor(writer, options.terminal.rows, 1);
    try writer.writeAll("\x1b[2K\x1b[7m");

    var remaining: usize = @intCast(options.terminal.cols);
    try writeStatusPart(writer, &remaining, " wm");

    var scratch: [256]u8 = undefined;
    const content = contentRectForOuter(options.window.outer);
    const geometry = try std.fmt.bufPrint(&scratch, " upload={s} outer={d},{d} {d}x{d} content={d},{d} {d}x{d}", .{
        @tagName(options.upload_profile),
        options.window.outer.row,
        options.window.outer.col,
        options.window.outer.cols,
        options.window.outer.rows,
        content.row,
        content.col,
        content.cols,
        content.rows,
    });
    try writeStatusPart(writer, &remaining, geometry);

    if (options.presentation_status.seen) {
        const status = options.presentation_status;
        const ready = try std.fmt.bufPrint(&scratch, " ready={}", .{status.ready_to_show});
        try writeStatusPart(writer, &remaining, ready);
        if (status.source_px) |source| {
            const source_text = try std.fmt.bufPrint(&scratch, " src={d}x{d}", .{ source.w, source.h });
            try writeStatusPart(writer, &remaining, source_text);
        }
        if (status.effective_rect_cells) |rect| {
            const effective_text = try std.fmt.bufPrint(&scratch, " eff={d},{d} {d}x{d}", .{ rect.row, rect.col, rect.cols, rect.rows });
            try writeStatusPart(writer, &remaining, effective_text);
        }
    }

    if (options.events.last()) |event| {
        const event_prefix = try std.fmt.bufPrint(&scratch, " last={s} ", .{@tagName(event.kind)});
        try writeStatusPart(writer, &remaining, event_prefix);
        try writeStatusPart(writer, &remaining, event.detail);
    } else {
        try writeStatusPart(writer, &remaining, " last=none");
    }

    if (remaining > 0) try writer.writeByteNTimes(' ', remaining);
    try writer.writeAll("\x1b[0m");
}

fn writeStatusPart(writer: anytype, remaining: *usize, bytes: []const u8) !void {
    if (remaining.* == 0) return;
    const len = @min(bytes.len, remaining.*);
    try writer.writeAll(bytes[0..len]);
    remaining.* -= len;
}

fn moveCursor(writer: anytype, row: i32, col: i32) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

fn writeTruncated(writer: anytype, bytes: []const u8, max_len: usize) !usize {
    const len = @min(bytes.len, max_len);
    if (len > 0) try writer.writeAll(bytes[0..len]);
    return len;
}

fn writeRepeated(writer: anytype, bytes: []const u8, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try writer.writeAll(bytes);
}

fn applyPeerStdout(allocator: std.mem.Allocator, stdout_file: std.fs.File, writer: anytype) !void {
    defer stdout_file.close();
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stdout_file.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                try applyPeerLine(allocator, writer, line.items);
                line.clearRetainingCapacity();
            } else if (byte != '\r') {
                try line.append(allocator, byte);
            }
        }
    }
    if (line.items.len > 0) try applyPeerLine(allocator, writer, line.items);
}

fn drainQueuedPeerLines(allocator: std.mem.Allocator, peer_queue: *WmPeerLineQueue, writer: anytype, tty_lock: *std.Thread.Mutex, redraw_requested: ?*std.atomic.Value(bool), max_items: usize) !bool {
    return drainQueuedPeerLinesWithTrace(allocator, peer_queue, writer, tty_lock, redraw_requested, max_items, .{}, null);
}

fn drainQueuedPeerLinesWithTrace(
    allocator: std.mem.Allocator,
    peer_queue: *WmPeerLineQueue,
    writer: anytype,
    tty_lock: *std.Thread.Mutex,
    redraw_requested: ?*std.atomic.Value(bool),
    max_items: usize,
    trace_settings: blocking_trace.Settings,
    logger: ?*Logger,
) !bool {
    var batch = try peer_queue.take(allocator, max_items);
    defer batch.deinit(allocator);
    defer for (batch.items) |entry| allocator.free(entry.line);

    if (batch.items.len == 0) return false;
    for (batch.items) |entry| {
        const start_ns = blocking_trace.start(trace_settings);
        try applyPeerLineLocked(allocator, writer, tty_lock, entry.session, redraw_requested, entry.line);
        if (blocking_trace.elapsedMaybe(start_ns)) |duration_ns| {
            traceWmBlocking(logger, trace_settings, "apply_peer_line_locked", duration_ns, entry.line.len);
        }
    }
    return true;
}

fn drainMainLoopPeerLinesWithTrace(allocator: std.mem.Allocator, peer_queue: *WmPeerLineQueue, writer: anytype, tty_lock: *std.Thread.Mutex, redraw_requested: ?*std.atomic.Value(bool), trace_settings: blocking_trace.Settings, logger: *Logger) !bool {
    const start_ns = blocking_trace.start(trace_settings);
    const drained = try drainQueuedPeerLinesWithTrace(allocator, peer_queue, writer, tty_lock, redraw_requested, 0, trace_settings, logger);
    if (blocking_trace.elapsedMaybe(start_ns)) |duration_ns| {
        traceWmBlocking(logger, trace_settings, "drain_peer_lines", duration_ns, 0);
    }
    return drained;
}

fn traceWmBlocking(logger: ?*Logger, settings: blocking_trace.Settings, comptime context: []const u8, duration_ns: i128, bytes: usize) void {
    if (!blocking_trace.shouldLog(settings.enabled, duration_ns, settings.threshold_ns)) return;
    if (logger) |log_file| {
        log_file.writeFmtScoped(.info, .wm, "blocking trace context={s} duration_us={d} bytes={d}", .{
            context,
            blocking_trace.micros(duration_ns),
            bytes,
        });
    }
}

fn applyPeerLine(allocator: std.mem.Allocator, writer: anytype, line: []const u8) !void {
    var message = attach_protocol.parsePeerMessage(allocator, line) catch return;
    defer message.deinit(allocator);
    switch (message) {
        .frame_batch => |batch| try terminal_batch_applier.applyFrameBatchCoalesced(allocator, writer, .{
            .deletes = batch.groups.deletes,
            .uploads = batch.groups.uploads,
            .placements = batch.groups.placements,
            .after = batch.groups.after,
        }),
        .detached, .presentation_status => {},
    }
}

fn applyPeerLineLocked(allocator: std.mem.Allocator, writer: anytype, tty_lock: *std.Thread.Mutex, session: ?*WmProducerSession, redraw_requested: ?*std.atomic.Value(bool), line: []const u8) !void {
    var message = attach_protocol.parsePeerMessage(allocator, line) catch return;
    defer message.deinit(allocator);
    switch (message) {
        .frame_batch => |batch| {
            tty_lock.lock();
            defer tty_lock.unlock();
            try terminal_batch_applier.applyFrameBatchCoalesced(allocator, writer, .{
                .deletes = batch.groups.deletes,
                .uploads = batch.groups.uploads,
                .placements = batch.groups.placements,
                .after = batch.groups.after,
            });
        },
        .presentation_status => |status| if (session) |producer| {
            tty_lock.lock();
            defer tty_lock.unlock();
            const next_status = presentationStatusFromPeer(status);
            if (!std.meta.eql(producer.presentation_status, next_status)) {
                producer.presentation_status = next_status;
                if (redraw_requested) |flag| flag.store(true, .seq_cst);
            }
        },
        .detached => {},
    }
}

fn presentationStatusFromPeer(status: attach_protocol.PresentationStatus) WmPresentationStatus {
    return .{
        .seen = true,
        .ready_to_show = status.ready_to_show,
        .source_px = status.source_px,
        .effective_rect_cells = status.effective_rect_cells,
    };
}

fn childTermExitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |code| @intCast(@min(code, 255)),
        .Signal, .Stopped, .Unknown => 1,
    };
}

const AttachOptions = struct {
    window_id: []const u8 = "main",
    rect_cells: render_batch_protocol.PresentationRectCells,
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?TerminalSize = null,
    occlusion_rects: []const render_batch_protocol.PresentationRectCells = &.{},
    clip_cells: ?render_batch_protocol.PresentationRectCells = null,
    image_ids: render_batch_protocol.IdRange = .{ .start = 100000, .end = 199999 },
    placement_ids: render_batch_protocol.IdRange = .{ .start = 200000, .end = 299999 },
    upload: render_batch_protocol.UploadPolicy,
};

fn writeInitialControl(writer: anytype, options: AttachOptions) !void {
    try writer.writeAll("{\"type\":\"hello\",\"protocol\":\"katzensteg.embed_jsonl\",\"version\":1}\n");
    try writer.writeAll("{\"type\":\"attach\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    try writer.writeAll(",\"rect_cells\":{");
    try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
    try writer.writeAll("},\"aspect\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
    if (options.z_base != 0) try writer.print(",\"z_base\":{d}", .{options.z_base});
    try writeTerminalGeometryFields(writer, options.terminal);
    try writeOcclusionRectsField(writer, options.occlusion_rects);
    try writeClipCellsField(writer, options.clip_cells);
    try writer.writeAll(",\"id_ranges\":{\"image\":[[");
    try writer.print("{d},{d}", .{ options.image_ids.start, options.image_ids.end });
    try writer.writeAll("]],\"placement\":[[");
    try writer.print("{d},{d}", .{ options.placement_ids.start, options.placement_ids.end });
    try writer.writeAll("]]},\"upload\":{\"profile\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.upload.profile));
    if (options.upload.path) |path| {
        try writer.writeAll(",\"path\":");
        try render_batch_protocol.writeJsonString(writer, path);
    }
    try writer.print(",\"high_water\":{d}", .{options.upload.high_water});
    try writer.writeAll("}}\n");
}

const ViewportOptions = struct {
    window_id: []const u8 = "main",
    rect_cells: render_batch_protocol.PresentationRectCells,
    aspect: render_batch_protocol.PresentationAspect = .fit,
    z_base: i32 = 0,
    terminal: ?TerminalSize = null,
    occlusion_rects: []const render_batch_protocol.PresentationRectCells = &.{},
    clip_cells: ?render_batch_protocol.PresentationRectCells = null,
};

fn writeViewportControl(writer: anytype, options: ViewportOptions) !void {
    try writer.writeAll("{\"type\":\"viewport\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    try writer.writeAll(",\"rect_cells\":{");
    try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
    try writer.writeAll("},\"aspect\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
    if (options.z_base != 0) try writer.print(",\"z_base\":{d}", .{options.z_base});
    try writeTerminalGeometryFields(writer, options.terminal);
    try writeOcclusionRectsField(writer, options.occlusion_rects);
    try writeClipCellsField(writer, options.clip_cells);
    try writer.writeAll("}\n");
}

fn writeTerminalGeometryFields(writer: anytype, terminal: ?TerminalSize) !void {
    const value = terminal orelse return;
    if (value.rows <= 0 or value.cols <= 0) return;
    try writer.print(",\"terminal_cells\":{{\"rows\":{d},\"cols\":{d}}}", .{ value.rows, value.cols });
    if (value.pixel_width > 0 and value.pixel_height > 0) {
        try writer.print(",\"terminal_px\":{{\"w\":{d},\"h\":{d}}}", .{ value.pixel_width, value.pixel_height });
    }
}

fn writeOcclusionRectsField(writer: anytype, occlusion_rects: []const render_batch_protocol.PresentationRectCells) !void {
    if (occlusion_rects.len == 0) return;
    try writer.writeAll(",\"occlusion_rects\":[");
    for (occlusion_rects, 0..) |rect, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.print("{{\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}}}", .{ rect.row, rect.col, rect.rows, rect.cols });
    }
    try writer.writeAll("]");
}

fn writeClipCellsField(writer: anytype, clip: ?render_batch_protocol.PresentationRectCells) !void {
    const rect = clip orelse return;
    try writer.print(",\"clip_cells\":{{\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}}}", .{ rect.row, rect.col, rect.rows, rect.cols });
}

/// Compute the clip rect to send to the producer for `rect` given the current
/// terminal viewport. Returns null when `rect` is fully inside the terminal —
/// the producer treats absent clip as "no clipping required". Returns the
/// visible intersection when partial. Returns a zero-sized rect when fully
/// off-screen, which the producer interprets as "emit no placements".
fn computeClipForRect(rect: render_batch_protocol.PresentationRectCells, terminal: TerminalSize) ?render_batch_protocol.PresentationRectCells {
    const rect_end_row = rect.row + rect.rows - 1;
    const rect_end_col = rect.col + rect.cols - 1;
    if (rect.row >= 1 and rect.col >= 1 and rect_end_row <= terminal.rows and rect_end_col <= terminal.cols) {
        return null;
    }
    const top = @max(rect.row, 1);
    const left = @max(rect.col, 1);
    const bottom = @min(rect_end_row, terminal.rows);
    const right = @min(rect_end_col, terminal.cols);
    if (bottom < top or right < left) {
        return render_batch_protocol.PresentationRectCells{ .row = 1, .col = 1, .rows = 0, .cols = 0 };
    }
    return render_batch_protocol.PresentationRectCells{
        .row = top,
        .col = left,
        .rows = bottom - top + 1,
        .cols = right - left + 1,
    };
}

fn tryWriteViewportControl(writer: anytype, options: ViewportOptions) bool {
    writeViewportControl(writer, options) catch return false;
    return true;
}

fn writeInputControl(writer: anytype, bytes: []const u8) !void {
    try writer.writeAll("{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":");
    try render_batch_protocol.writeJsonString(writer, bytes);
    try writer.writeAll("}\n");
}

fn tryWriteInputControl(writer: anytype, bytes: []const u8) bool {
    writeInputControl(writer, bytes) catch return false;
    return true;
}

fn writeShutdownControl(writer: anytype) !void {
    try writer.writeAll("{\"type\":\"shutdown\"}\n");
}

fn tryWriteShutdownControl(writer: anytype) bool {
    writeShutdownControl(writer) catch return false;
    return true;
}

const SessionIdRanges = struct {
    image: render_batch_protocol.IdRange,
    placement: render_batch_protocol.IdRange,
};

fn idRangesForSession(index: usize) SessionIdRanges {
    const base: u32 = 100000 + @as(u32, @intCast(index)) * 200000;
    return .{
        .image = .{ .start = base, .end = base + 99999 },
        .placement = .{ .start = base + 100000, .end = base + 199999 },
    };
}

fn zBaseForSlot(slot: usize) i32 {
    const max_z_slots: usize = 1000;
    const z_stride_per_slot: i32 = 1000;
    return @as(i32, @intCast(@min(slot, max_z_slots))) * z_stride_per_slot;
}

fn zBaseForSessionIndex(z_order: []const usize, session_index: usize) i32 {
    const slot = std.mem.indexOfScalar(usize, z_order, session_index) orelse 0;
    return zBaseForSlot(slot);
}

fn sendViewportZOrderForSessions(sessions: []WmProducerSession, z_order: []const usize, terminal: TerminalSize, aspect: render_batch_protocol.PresentationAspect, events: *ProtocolEventLog, logger: *Logger) !void {
    for (sessions, 0..) |*session, session_index| {
        if (!sessionIsVisible(session)) continue;
        var occlusion_scratch: [default_wm_session_capacity]render_batch_protocol.PresentationRectCells = undefined;
        const occlusion_rects = occlusionRectsForSession(sessions, z_order, session_index, occlusion_scratch[0..]);
        try sendViewportForSession(session, terminal, aspect, zBaseForSessionIndex(z_order, session_index), occlusion_rects, events, logger);
    }
}

fn occlusionRectsForSession(sessions: []const WmProducerSession, z_order: []const usize, session_index: usize, scratch: []render_batch_protocol.PresentationRectCells) []const render_batch_protocol.PresentationRectCells {
    const slot = std.mem.indexOfScalar(usize, z_order, session_index) orelse return scratch[0..0];
    var count: usize = 0;
    for (z_order[slot + 1 ..]) |higher_index| {
        if (higher_index >= sessions.len) continue;
        const higher = &sessions[higher_index];
        if (!sessionIsDrawable(higher)) continue;
        if (count >= scratch.len) break;
        scratch[count] = higher.window.outer.toPresentationRectCells();
        count += 1;
    }
    return scratch[0..count];
}

fn sendViewportForSession(session: *WmProducerSession, terminal: TerminalSize, aspect: render_batch_protocol.PresentationAspect, z_base: i32, occlusion_rects: []const render_batch_protocol.PresentationRectCells, events: *ProtocolEventLog, logger: *Logger) !void {
    if (!session.control_open or !sessionIsVisible(session)) return;
    const content = session.focusedContent();
    const content_rect = content.toPresentationRectCells();
    if (tryWriteViewportControl(session.child_stdin.?.deprecatedWriter(), .{
        .rect_cells = content_rect,
        .aspect = aspect,
        .z_base = z_base,
        .terminal = terminal,
        .occlusion_rects = occlusion_rects,
        .clip_cells = computeClipForRect(content_rect, terminal),
    })) {
        try events.record(.viewport_sent, session.profile_name);
        logger.writeFmtScoped(.info, .wm, "viewport sent profile={s} rect=({d},{d} {d}x{d}) z_base={d}", .{ session.profile_name, content.row, content.col, content.cols, content.rows, z_base });
    } else {
        logger.writeFmtScoped(.warn, .wm, "viewport control write failed profile={s}; producer control pipe is closed", .{session.profile_name});
        session.control_open = false;
    }
}

fn forwardInputToSession(session: *WmProducerSession, bytes: []const u8, events: *ProtocolEventLog, logger: *Logger) !void {
    if (!session.control_open or !sessionIsVisible(session)) return;
    if (tryWriteInputControl(session.child_stdin.?.deprecatedWriter(), bytes)) {
        try events.record(.input_sent, session.profile_name);
    } else {
        logger.writeFmtScoped(.warn, .wm, "input control write failed profile={s}; producer control pipe is closed", .{session.profile_name});
        session.control_open = false;
    }
}

fn shutdownSession(session: *WmProducerSession, events: *ProtocolEventLog, logger: *Logger) !void {
    if (session.state == .draining or session.state == .exited) return;
    session.state = .draining;
    if (session.control_open and session.child_stdin != null and !tryWriteShutdownControl(session.child_stdin.?.deprecatedWriter())) {
        logger.writeFmtScoped(.warn, .wm, "shutdown control write failed profile={s}; producer control pipe is closed", .{session.profile_name});
        session.control_open = false;
    } else if (session.control_open and session.child_stdin != null) {
        logger.writeFmtScoped(.info, .wm, "shutdown sent profile={s}", .{session.profile_name});
    } else {
        logger.writeFmtScoped(.info, .wm, "shutdown skipped profile={s}; producer control pipe is closed", .{session.profile_name});
    }
    session.control_open = false;
    try events.record(.shutdown_sent, session.profile_name);
    closeSessionControl(session);
}

fn closeSessionControl(session: *WmProducerSession) void {
    session.control_open = false;
    if (!session.stdin_closed) {
        if (session.child_stdin) |file| {
            file.close();
            session.child_stdin = null;
        }
        session.stdin_closed = true;
    }
}

fn selectUploadPolicy(allocator: std.mem.Allocator, tty: std.fs.File) !render_batch_protocol.UploadPolicy {
    const path = try upload_path_mod.makeUploadPath(allocator);
    errdefer allocator.free(path);
    {
        const probe_file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        defer probe_file.close();
        try probe_file.writeAll(&[_]u8{ 0, 0, 0, 255 });
    }
    const profile = forcedWmOutputProfile(allocator) orelse if (ts_kitty.capabilities.probe(allocator, tty, path)) |caps|
        mapKittyOutputProfile(ts_kitty.profile.choose(caps))
    else |_|
        .file_whole;
    return uploadPolicyForOutputProfile(path, profile);
}

fn forcedWmOutputProfile(allocator: std.mem.Allocator) ?config_mod.OutputProfile {
    const value = std.process.getEnvVarOwned(allocator, "KATZENSTEG_OUTPUT_PROFILE") catch return null;
    defer allocator.free(value);
    return config_mod.parseOutputProfile(value);
}

fn mapKittyOutputProfile(profile: ts_kitty.profile.OutputProfile) config_mod.OutputProfile {
    return switch (profile) {
        .direct_apc => .direct_apc,
        .file_whole => .file_whole,
        .file_offset_ring => .file_offset_ring,
    };
}

fn uploadPolicyForOutputProfile(path: []const u8, profile: config_mod.OutputProfile) render_batch_protocol.UploadPolicy {
    return switch (profile) {
        // The WM multiplexes producer batches through a shared JSONL host.
        // Keep raw APC out of that path even when a probe or override requests it.
        .direct_apc => .{ .profile = .file_whole, .path = path },
        .file_whole => .{ .profile = .file_whole, .path = path },
        .file_offset_ring => .{ .profile = .file_offset_ring, .path = path },
    };
}

fn deinitUploadPolicy(allocator: std.mem.Allocator, upload: *render_batch_protocol.UploadPolicy) void {
    if (upload.path) |path| {
        switch (upload.profile) {
            .file_whole => upload_path_mod.deleteRotatingFileWholeArtifacts(allocator, path),
            .file_offset_ring, .direct_apc => upload_path_mod.deleteBasePath(path),
        }
        allocator.free(path);
    }
    upload.path = null;
}

fn uploadPolicyForSession(allocator: std.mem.Allocator, tty: std.fs.File, session_index: usize) !render_batch_protocol.UploadPolicy {
    var upload = try selectUploadPolicy(allocator, tty);
    errdefer deinitUploadPolicy(allocator, &upload);
    if (upload.path) |path| {
        upload.path = try sessionUploadPath(allocator, path, session_index);
        upload_path_mod.deleteBasePath(path);
        allocator.free(path);
    }
    return upload;
}

fn sessionUploadPath(allocator: std.mem.Allocator, base_path: []const u8, session_index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.session-{d}", .{ base_path, session_index });
}

fn allSessionsDone(sessions: []const WmProducerSession) bool {
    for (sessions) |*session| {
        if (!session.wait_state.done.load(.seq_cst)) return false;
    }
    return true;
}

fn childTermSummary(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => |code| switch (code) {
            0 => "exited code=0",
            else => "exited nonzero",
        },
        .Signal => "signal",
        .Stopped => "stopped",
        .Unknown => "unknown",
    };
}

const ChildWaitState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    term: std.process.Child.Term = .{ .Unknown = 0 },
};

const InputAction = union(enum) {
    none,
    consume,
    start_launch,
    focus_next,
    close_focused,
    forward,
    quit,
    window: WindowAction,
    layout: LayoutAction,
    mouse_drag: Rect,
};

const InputRead = struct {
    action: InputAction,
    bytes: []const u8 = "",
    focus_changed: bool = false,
};

fn readInput(tty: *DirectTty, buf: []u8, mouse: *WmMouseInputState, outer: Rect, terminal: TerminalSize) InputRead {
    const n = std.posix.read(tty.file.handle, buf) catch return .{ .action = .none };
    if (n == 0) return .{ .action = .none };
    return readInputBytes(buf[0..n], mouse, outer, terminal);
}

fn readInputForSessionsLocked(tty_lock: *std.Thread.Mutex, tty: *DirectTty, buf: []u8, mouse: *WmMouseInputState, sessions: []const WmProducerSession, z_order: []usize, focused_index: *usize, terminal: TerminalSize) InputRead {
    const n = std.posix.read(tty.file.handle, buf) catch return .{ .action = .none };
    if (n == 0) return .{ .action = .none };
    tty_lock.lock();
    defer tty_lock.unlock();
    return readInputForSessionsBytes(buf[0..n], mouse, sessions, z_order, focused_index, terminal);
}

fn readInputForSessionsBytes(bytes: []u8, mouse: *WmMouseInputState, sessions: []const WmProducerSession, z_order: []usize, focused_index: *usize, terminal: TerminalSize) InputRead {
    const action = inputActionFromBytes(bytes);
    switch (action) {
        .quit, .focus_next, .start_launch => return .{ .action = action },
        .none => {},
        else => {},
    }
    if (sessions.len == 0) return .{ .action = .none };
    if (focused_index.* >= sessions.len) focused_index.* = 0;
    if (!sessionIsVisible(&sessions[focused_index.*])) {
        focused_index.* = nextVisibleSessionIndex(sessions, focused_index.*) orelse return .{ .action = .none };
    }
    if (action != .none) return .{ .action = action };
    var changed_focus = false;
    if (mouse.drag == null) {
        if (parseSgrMouseAt(bytes, 0)) |event| {
            if (event.pressed and (event.button & 3) == 0) {
                const cell = Cell{ .row = event.row, .col = event.col };
                if (hitSessionIndex(sessions, z_order, cell)) |hit_index| {
                    if (focused_index.* != hit_index) {
                        focused_index.* = hit_index;
                        bringWindowToFront(z_order, hit_index);
                        mouse.* = .{};
                        changed_focus = true;
                    }
                }
            }
        }
    }
    var input = readInputBytes(bytes, mouse, sessions[focused_index.*].window.outer, terminal);
    input.focus_changed = changed_focus;
    return input;
}

fn readInputBytes(bytes: []u8, mouse: *WmMouseInputState, outer: Rect, terminal: TerminalSize) InputRead {
    const action = inputActionFromBytes(bytes);
    if (action != .none) return .{ .action = action };
    const content = contentRectForOuter(outer);
    const mouse_input = mouse.readMouseInput(bytes, outer, content, terminal);
    if (mouse_input.action != .none) return mouse_input;
    const filtered = filterForwardedInputBytes(bytes, content);
    if (filtered.len > 0) return .{ .action = .forward, .bytes = filtered };
    return .{ .action = .none };
}

fn inputActionFromBytes(bytes: []const u8) InputAction {
    for (bytes) |byte| {
        switch (byte) {
            'q', 'Q' => return .quit,
            'n' => return .start_launch,
            '\t' => return .focus_next,
            else => {},
        }
    }
    for (bytes) |byte| {
        switch (byte) {
            'h' => return .{ .window = .move_left },
            'j' => return .{ .window = .move_down },
            'k' => return .{ .window = .move_up },
            'l' => return .{ .window = .move_right },
            'H' => return .{ .window = .resize_narrower },
            'J' => return .{ .window = .resize_shorter },
            'K' => return .{ .window = .resize_taller },
            'L' => return .{ .window = .resize_wider },
            'c' => return .{ .layout = .cascade },
            't' => return .{ .layout = .tile },
            else => {},
        }
    }
    return .none;
}

fn readLaunchPromptInput(tty: *DirectTty, buf: []u8, prompt: *std.ArrayList(u8), allocator: std.mem.Allocator) !LaunchPromptAction {
    const n = std.posix.read(tty.file.handle, buf) catch return .none;
    if (n == 0) return .none;
    return applyLaunchPromptBytes(buf[0..n], prompt, allocator);
}

fn applyLaunchPromptBytes(bytes: []const u8, prompt: *std.ArrayList(u8), allocator: std.mem.Allocator) !LaunchPromptAction {
    var changed = false;
    for (bytes) |byte| {
        switch (byte) {
            0x1b => return .cancel,
            '\r', '\n' => return .submit,
            0x7f, 0x08 => {
                if (prompt.items.len > 0) {
                    _ = prompt.pop();
                    changed = true;
                }
            },
            else => {
                if (isProfileNameByte(byte)) {
                    if (prompt.items.len < max_launch_prompt_len) {
                        try prompt.append(allocator, byte);
                        changed = true;
                    }
                }
            },
        }
    }
    return if (changed) .changed else .none;
}

fn isProfileNameByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => true,
        else => false,
    };
}

fn recordLaunchPrompt(events: *ProtocolEventLog, prompt: []const u8) !void {
    var scratch: [128]u8 = undefined;
    const detail = if (prompt.len == 0)
        "launch:"
    else
        try std.fmt.bufPrint(&scratch, "launch: {s}", .{prompt});
    try events.record(.launch_prompt, detail);
}

fn filterForwardedInputBytes(bytes: []u8, content: Rect) []const u8 {
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < bytes.len) {
        if (parseSgrMouseAt(bytes, read_index)) |mouse| {
            if (rectContainsCell(content, mouse.row, mouse.col)) {
                std.mem.copyForwards(u8, bytes[write_index .. write_index + mouse.len], bytes[read_index .. read_index + mouse.len]);
                write_index += mouse.len;
            }
            read_index += mouse.len;
            continue;
        }
        bytes[write_index] = bytes[read_index];
        write_index += 1;
        read_index += 1;
    }
    return bytes[0..write_index];
}

fn rectContainsCell(rect: Rect, row: i32, col: i32) bool {
    if (row < rect.row or col < rect.col) return false;
    if (row >= rect.row + rect.rows or col >= rect.col + rect.cols) return false;
    return true;
}

fn mouseHitTest(outer: Rect, cell: Cell) WmMouseHit {
    if (!rectContainsCell(outer, cell.row, cell.col)) return .desktop;
    if (outer.rows < 3 or outer.cols < 4) return .desktop;
    const right = outer.col + outer.cols - 1;
    const bottom = outer.row + outer.rows - 1;
    if (cell.row == bottom and cell.col == right) return .resize_bottom_right;
    if (cell.row == bottom and cell.col > outer.col and cell.col < right) return .resize_bottom;
    if (cell.col == right and cell.row > outer.row and cell.row < bottom) return .resize_right;
    if (rectContainsCell(contentRectForOuter(outer), cell.row, cell.col)) return .content;
    if (cell.row == outer.row + 1 and cell.col >= outer.col + 1 and cell.col <= outer.col + 2) return .close;
    if (cell.row == outer.row + 1 and cell.col > outer.col and cell.col < right) return .title;
    return .desktop;
}

const ParsedSgrMouse = struct {
    row: i32,
    col: i32,
    len: usize,
    button: i32,
    pressed: bool,
};

fn parseSgrMouseAt(bytes: []const u8, start: usize) ?ParsedSgrMouse {
    if (start + 3 > bytes.len) return null;
    if (!std.mem.eql(u8, bytes[start .. start + 3], "\x1b[<")) return null;
    var end: ?usize = null;
    var index: usize = start + 3;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == 'M' or bytes[index] == 'm') {
            end = index;
            break;
        }
    }
    const final = end orelse return null;
    var fields = std.mem.splitScalar(u8, bytes[start + 3 .. final], ';');
    const button = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const col = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const row = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    return .{ .row = row, .col = col, .len = final - start + 1, .button = button, .pressed = bytes[final] == 'M' };
}

fn redrawDesktopManyLocked(tty_lock: *std.Thread.Mutex, writer: anytype, terminal: TerminalSize, sessions: []const WmProducerSession, z_order: []const usize, focused_index: usize, events: *const ProtocolEventLog, redraw_state: *WmDesktopRedrawState) !void {
    tty_lock.lock();
    defer tty_lock.unlock();
    for (redraw_state.previous_chrome[0..redraw_state.previous_count]) |previous| {
        if (!chromeSnapshotStillCurrent(previous, sessions)) {
            try clearChrome(writer, previous.outer, terminal);
        }
    }
    for (z_order) |session_index| {
        if (session_index >= sessions.len) continue;
        const session = &sessions[session_index];
        if (!sessionIsDrawable(session)) continue;
        try renderChrome(writer, .{
            .outer = session.window.outer,
            .title = session.profile_name,
            .focused = session_index == focused_index,
            .terminal = terminal,
        });
    }
    if (visibleStatusSessionIndex(sessions, focused_index)) |status_index| {
        const focused = sessions[status_index];
        try renderStatusAndReturn(writer, terminal, focused.window, focused.upload.profile, focused.presentation_status, events);
    } else {
        try renderEmptyStatusAndReturn(writer, terminal, events);
    }
    redraw_state.capture(sessions, z_order);
}

fn chromeSnapshotStillCurrent(previous: WmChromeSnapshot, sessions: []const WmProducerSession) bool {
    if (previous.session_index >= sessions.len) return false;
    const session = &sessions[previous.session_index];
    return sessionIsDrawable(session) and std.meta.eql(session.window.outer, previous.outer);
}

fn clearChrome(writer: anytype, outer: Rect, terminal: TerminalSize) !void {
    if (outer.rows < 3 or outer.cols < 4) return;
    const bottom = outer.row + outer.rows - 1;
    try clearCellSpan(writer, outer.row, outer.col, outer.cols, terminal);
    try clearCellSpan(writer, outer.row + 1, outer.col, outer.cols, terminal);
    try clearCellSpan(writer, outer.row + 2, outer.col, outer.cols, terminal);
    try clearCellSpan(writer, bottom, outer.col, outer.cols, terminal);

    var row = outer.row + 3;
    while (row < bottom) : (row += 1) {
        try clearCellSpan(writer, row, outer.col, 1, terminal);
        try clearCellSpan(writer, row, outer.col + outer.cols - 1, 1, terminal);
    }
}

fn clearCellSpan(writer: anytype, row: i32, col: i32, cols: i32, terminal: TerminalSize) !void {
    if (row < 1 or row > terminal.rows or cols <= 0) return;
    const start_col = @max(1, col);
    if (start_col > terminal.cols) return;
    const requested_end = col + cols - 1;
    const end_col = @min(terminal.cols, requested_end);
    if (end_col < start_col) return;
    try moveCursor(writer, row, start_col);
    try writer.writeByteNTimes(' ', @intCast(end_col - start_col + 1));
}

fn visibleStatusSessionIndex(sessions: []const WmProducerSession, focused_index: usize) ?usize {
    if (sessions.len == 0) return null;
    const clamped = @min(focused_index, sessions.len - 1);
    if (sessionIsDrawable(&sessions[clamped])) return clamped;
    for (sessions, 0..) |*session, index| {
        if (sessionIsDrawable(session)) return index;
    }
    return null;
}

fn renderStatusAndReturn(writer: anytype, terminal: TerminalSize, window: WmWindowState, upload_profile: render_batch_protocol.UploadProfile, presentation_status: WmPresentationStatus, events: *const ProtocolEventLog) !void {
    try renderStatusBand(writer, .{
        .terminal = terminal,
        .window = window,
        .upload_profile = upload_profile,
        .presentation_status = presentation_status,
        .events = events,
    });
    const content = contentRectForOuter(window.outer);
    try moveCursor(writer, content.row, content.col);
}

fn renderEmptyStatusAndReturn(writer: anytype, terminal: TerminalSize, events: *const ProtocolEventLog) !void {
    if (terminal.rows < 1 or terminal.cols < 1) return;
    try moveCursor(writer, terminal.rows, 1);
    try writer.writeAll("\x1b[2K\x1b[7m");

    var remaining: usize = @intCast(terminal.cols);
    try writeStatusPart(writer, &remaining, " wm windows=0");
    if (events.last()) |event| {
        var scratch: [256]u8 = undefined;
        const event_prefix = try std.fmt.bufPrint(&scratch, " last={s} ", .{@tagName(event.kind)});
        try writeStatusPart(writer, &remaining, event_prefix);
        try writeStatusPart(writer, &remaining, event.detail);
    } else {
        try writeStatusPart(writer, &remaining, " last=none");
    }

    if (remaining > 0) try writer.writeByteNTimes(' ', remaining);
    try writer.writeAll("\x1b[0m");
    try moveCursor(writer, @max(1, terminal.rows - 1), 1);
}

pub fn contentRectForOuter(outer: Rect) Rect {
    return .{
        .row = outer.row + 3,
        .col = outer.col + 1,
        .rows = @max(0, outer.rows - 4),
        .cols = @max(0, outer.cols - 2),
    };
}

pub fn clampOuterRect(rect: Rect, terminal: TerminalSize) Rect {
    var out = rect;
    out.rows = std.math.clamp(out.rows, 1, @max(1, terminal.rows));
    out.cols = std.math.clamp(out.cols, 1, @max(1, terminal.cols));

    // Allow the window to extend past terminal edges, but keep at least one
    // visible row and one visible col so the user can still grab it.
    // Top-left must be ≤ terminal.{rows,cols}; bottom-right (row+rows-1,
    // col+cols-1) must be ≥ 1.
    const min_row = 2 - out.rows;
    const min_col = 2 - out.cols;
    out.row = std.math.clamp(out.row, min_row, terminal.rows);
    out.col = std.math.clamp(out.col, min_col, terminal.cols);
    return out;
}

test "wm window derives content rect inside text chrome" {
    const outer = Rect{ .row = 1, .col = 1, .rows = 20, .cols = 80 };
    const content = contentRectForOuter(outer);
    try std.testing.expectEqual(Rect{ .row = 4, .col = 2, .rows = 16, .cols = 78 }, content);
}

test "wm clampOuterRect allows partly-off-screen windows" {
    // Window dragged with its top-left above/left of the terminal viewport
    // should keep its negative row/col rather than getting snapped back inside.
    const partial = clampOuterRect(
        .{ .row = -3, .col = -2, .rows = 10, .cols = 20 },
        .{ .rows = 24, .cols = 80 },
    );
    try std.testing.expectEqual(@as(i32, -3), partial.row);
    try std.testing.expectEqual(@as(i32, -2), partial.col);
    try std.testing.expectEqual(@as(i32, 10), partial.rows);
    try std.testing.expectEqual(@as(i32, 20), partial.cols);

    // At least 1 row + 1 col must remain visible — pushing further off should
    // be clamped so the bottom-right edge stays at terminal row/col >= 1.
    const too_far = clampOuterRect(
        .{ .row = -9, .col = -19, .rows = 10, .cols = 20 },
        .{ .rows = 24, .cols = 80 },
    );
    try std.testing.expect(too_far.row + too_far.rows - 1 >= 1);
    try std.testing.expect(too_far.col + too_far.cols - 1 >= 1);

    // Symmetrically on the bottom-right: pushing the window past the bottom-right
    // edge should stop with at least 1 row + 1 col visible.
    const past_bottom = clampOuterRect(
        .{ .row = 100, .col = 100, .rows = 10, .cols = 20 },
        .{ .rows = 24, .cols = 80 },
    );
    try std.testing.expect(past_bottom.row <= 24);
    try std.testing.expect(past_bottom.col <= 80);
}

test "wm renderChrome clips writes to terminal bounds when window extends past edge" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    // Window with right edge past terminal cols=20. Without clipping, the top
    // border would have repeated horizontal chars beyond col 20 and the
    // terminal would wrap to the next row.
    try renderChrome(out.writer(std.testing.allocator), .{
        .outer = .{ .row = 1, .col = 1, .rows = 6, .cols = 40 },
        .title = "probe",
        .focused = true,
        .terminal = .{ .rows = 24, .cols = 20 },
    });

    // No moveCursor sequence with a column outside [1, 20] should appear.
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, idx, "\x1b[")) |start| {
        // Match \e[<row>;<col>H
        const remainder = out.items[start + 2 ..];
        const h_pos = std.mem.indexOfScalar(u8, remainder, 'H') orelse break;
        const semi_pos = std.mem.indexOfScalar(u8, remainder[0..h_pos], ';') orelse {
            idx = start + 2 + h_pos + 1;
            continue;
        };
        const col_str = remainder[semi_pos + 1 .. h_pos];
        const col = std.fmt.parseInt(i32, col_str, 10) catch {
            idx = start + 2 + h_pos + 1;
            continue;
        };
        try std.testing.expect(col >= 1 and col <= 20);
        idx = start + 2 + h_pos + 1;
    }
}

test "wm writeViewportControl emits clip_cells when rect partly off-screen" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const rect = render_batch_protocol.PresentationRectCells{ .row = -1, .col = 2, .rows = 10, .cols = 30 };
    const terminal = TerminalSize{ .rows = 24, .cols = 80 };
    try writeViewportControl(out.writer(std.testing.allocator), .{
        .rect_cells = rect,
        .aspect = .fit,
        .terminal = terminal,
        .clip_cells = computeClipForRect(rect, terminal),
    });

    // row=-1 with 10 rows in a 24-row terminal → visible rows are 1..8 (8 rows).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"clip_cells\":{\"row\":1,\"col\":2,\"rows\":8,\"cols\":30}") != null);
}

test "wm computes clip_cells for partly-off-screen rect" {
    const terminal = TerminalSize{ .rows = 24, .cols = 80 };

    // Fully on-screen → no clip needed.
    try std.testing.expectEqual(
        @as(?render_batch_protocol.PresentationRectCells, null),
        computeClipForRect(.{ .row = 2, .col = 2, .rows = 10, .cols = 30 }, terminal),
    );

    // Top partly off-screen (row = -1, height = 10 → visible rows = top.row=1, rows=8).
    try std.testing.expectEqual(
        @as(?render_batch_protocol.PresentationRectCells, .{ .row = 1, .col = 2, .rows = 8, .cols = 30 }),
        computeClipForRect(.{ .row = -1, .col = 2, .rows = 10, .cols = 30 }, terminal),
    );

    // Bottom partly off-screen.
    try std.testing.expectEqual(
        @as(?render_batch_protocol.PresentationRectCells, .{ .row = 20, .col = 2, .rows = 5, .cols = 30 }),
        computeClipForRect(.{ .row = 20, .col = 2, .rows = 10, .cols = 30 }, terminal),
    );

    // Fully off-screen → zero-sized clip (signal: nothing visible).
    const clip = computeClipForRect(.{ .row = -100, .col = 2, .rows = 5, .cols = 30 }, terminal).?;
    try std.testing.expect(clip.rows == 0 or clip.cols == 0);
}

test "wm content rect converts to presentation cells" {
    const content = Rect{ .row = 3, .col = 2, .rows = 16, .cols = 78 };
    const cells = content.toPresentationRectCells();
    try std.testing.expectEqual(@as(i32, 3), cells.row);
    try std.testing.expectEqual(@as(i32, 2), cells.col);
    try std.testing.expectEqual(@as(i32, 16), cells.rows);
    try std.testing.expectEqual(@as(i32, 78), cells.cols);
}

test "wm producer records bounded protocol events" {
    var log = try ProtocolEventLog.init(std.testing.allocator, 3);
    defer log.deinit();

    try log.record(.launch_started, "probe");
    try log.record(.attach_sent, "main");
    try log.record(.viewport_sent, "main");
    try log.record(.shutdown_sent, "session");

    try std.testing.expectEqual(@as(usize, 3), log.len());
    try std.testing.expectEqual(EventKind.attach_sent, log.at(0).?.kind);
    try std.testing.expectEqual(EventKind.shutdown_sent, log.last().?.kind);
}

test "wm window attachment state tracks detach and reattach" {
    var window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 });
    try std.testing.expect(!window.attached);

    window.markAttached();
    try std.testing.expect(window.attached);

    window.markDetached();
    try std.testing.expect(!window.attached);
}

test "wm chrome renders title and reserves content rect" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try renderChrome(out.writer(std.testing.allocator), .{
        .outer = .{ .row = 1, .col = 1, .rows = 6, .cols = 32 },
        .title = "probe",
        .focused = true,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "katzensteg wm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "┌─┬") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "│╳│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "├─┴") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "├") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "┤") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "┘") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[4;2H") != null);
}

test "wm status band renders host geometry and last event outside content" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    var log = try ProtocolEventLog.init(std.testing.allocator, 2);
    defer log.deinit();
    try log.record(.attach_sent, "main");

    const window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 });
    try renderStatusBand(out.writer(std.testing.allocator), .{
        .terminal = .{ .rows = 24, .cols = 100 },
        .window = window,
        .upload_profile = .file_whole,
        .events = &log,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[24;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "upload=file_whole") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "outer=1,1 80x20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "content=4,2 78x16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "last=attach_sent main") != null);
}

test "wm producer argv includes profile arguments" {
    const argv = try buildProducerArgv(std.testing.allocator, "katzensteg", "retroarch", &.{ "rom.sfc", "--fullscreen" });
    defer std.testing.allocator.free(argv);

    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("katzensteg", argv[0]);
    try std.testing.expectEqualStrings("--embed-jsonl", argv[1]);
    try std.testing.expectEqualStrings("retroarch", argv[2]);
    try std.testing.expectEqualStrings("rom.sfc", argv[3]);
    try std.testing.expectEqualStrings("--fullscreen", argv[4]);
}

test "wm status band renders producer presentation status" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();

    const window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 });
    try renderStatusBand(out.writer(std.testing.allocator), .{
        .terminal = .{ .rows = 24, .cols = 140 },
        .window = window,
        .upload_profile = .file_whole,
        .presentation_status = .{
            .seen = true,
            .ready_to_show = true,
            .source_px = .{ .w = 640, .h = 480 },
            .effective_rect_cells = .{ .row = 7, .col = 11, .rows = 15, .cols = 40 },
        },
        .events = &log,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "ready=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "src=640x480") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "eff=7,11 40x15") != null);
}

test "wm peer presentation status updates session cache" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var tty_lock = std.Thread.Mutex{};

    try applyPeerLineLocked(
        std.testing.allocator,
        out.writer(std.testing.allocator),
        &tty_lock,
        &session,
        null,
        "{\"type\":\"presentation_status\",\"window_id\":\"main\",\"ready_to_show\":true,\"source_px\":{\"w\":640,\"h\":480},\"effective_rect_cells\":{\"row\":7,\"col\":11,\"rows\":15,\"cols\":40}}",
    );

    try std.testing.expectEqualStrings("", out.items);
    try std.testing.expect(session.presentation_status.seen);
    try std.testing.expect(session.presentation_status.ready_to_show);
    try std.testing.expectEqual(render_batch_protocol.SourcePixels{ .w = 640, .h = 480 }, session.presentation_status.source_px.?);
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 7, .col = 11, .rows = 15, .cols = 40 }, session.presentation_status.effective_rect_cells.?);
}

test "wm peer presentation status only requests redraw on visible state changes" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var tty_lock = std.Thread.Mutex{};
    var redraw_requested = std.atomic.Value(bool).init(false);
    const line = "{\"type\":\"presentation_status\",\"window_id\":\"main\",\"ready_to_show\":true,\"source_px\":{\"w\":640,\"h\":480},\"effective_rect_cells\":{\"row\":7,\"col\":11,\"rows\":15,\"cols\":40}}";

    try applyPeerLineLocked(std.testing.allocator, out.writer(std.testing.allocator), &tty_lock, &session, &redraw_requested, line);
    try std.testing.expect(redraw_requested.swap(false, .seq_cst));

    try applyPeerLineLocked(std.testing.allocator, out.writer(std.testing.allocator), &tty_lock, &session, &redraw_requested, line);
    try std.testing.expect(!redraw_requested.load(.seq_cst));
}

test "wm peer stdout queue defers terminal writes until main loop drain" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };

    var queue = WmPeerLineQueue.init(std.testing.allocator);
    defer queue.deinit();

    const line = "{\"type\":\"frame_batch\",\"window_id\":\"main\",\"seq\":1,\"groups\":{\"deletes\":[\"D\"],\"uploads\":[\"U\"],\"placements\":[\"P\"],\"after\":[\"A\"]}}";
    try queue.enqueueCopy(&session, line);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", out.items);

    var tty_lock = std.Thread.Mutex{};
    var redraw_requested = std.atomic.Value(bool).init(false);
    try std.testing.expect(try drainQueuedPeerLines(std.testing.allocator, &queue, out.writer(std.testing.allocator), &tty_lock, &redraw_requested, 8));

    try std.testing.expectEqualStrings("DUPA", out.items);
    try std.testing.expect(!redraw_requested.load(.seq_cst));
}

test "wm main loop peer drain does not leave older queued frames behind input" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };

    var queue = WmPeerLineQueue.init(std.testing.allocator);
    defer queue.deinit();

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < 65) : (index += 1) {
        var line = std.ArrayList(u8).empty;
        defer line.deinit(std.testing.allocator);
        try line.writer(std.testing.allocator).print(
            "{{\"type\":\"frame_batch\",\"window_id\":\"main\",\"seq\":{d},\"groups\":{{\"deletes\":[\"D{d}\"],\"uploads\":[],\"placements\":[],\"after\":[]}}}}",
            .{ index + 1, index },
        );
        try queue.enqueueCopy(&session, line.items);
        try expected.writer(std.testing.allocator).print("D{d}", .{index});
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var tty_lock = std.Thread.Mutex{};
    var redraw_requested = std.atomic.Value(bool).init(false);

    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();

    try std.testing.expect(try drainMainLoopPeerLinesWithTrace(std.testing.allocator, &queue, out.writer(std.testing.allocator), &tty_lock, &redraw_requested, .{}, &logger));
    try std.testing.expectEqualStrings(expected.items, out.items);
    try std.testing.expect(!try drainMainLoopPeerLinesWithTrace(std.testing.allocator, &queue, out.writer(std.testing.allocator), &tty_lock, &redraw_requested, .{}, &logger));
}

test "wm peer stdout polling queues complete lines and retains partial lines" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };
    defer session.stdout_buffer.deinit(std.testing.allocator);

    var queue = WmPeerLineQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queuePeerStdoutBytes(std.testing.allocator, &session, &queue, "one\ntwo");

    var batch = try queue.take(std.testing.allocator, 0);
    defer batch.deinit(std.testing.allocator);
    defer for (batch.items) |entry| std.testing.allocator.free(entry.line);
    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqualStrings("one", batch.items[0].line);
    try std.testing.expectEqualStrings("two", session.stdout_buffer.items);
}

test "wm peer stdout chunk drain reads a bounded amount" {
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer std.posix.close(pipe[1]);

    const writer = std.fs.File{ .handle = pipe[1] };
    try writer.writeAll("one\ntwo\nthree\n");

    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
        .stdout_file = std.fs.File{ .handle = pipe[0] },
    };
    defer if (session.stdout_file) |file| file.close();
    defer session.stdout_buffer.deinit(std.testing.allocator);

    var queue = WmPeerLineQueue.init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(try drainSessionStdoutChunkWithLimit(std.testing.allocator, &session, &queue, 4));

    var batch = try queue.take(std.testing.allocator, 0);
    defer batch.deinit(std.testing.allocator);
    defer for (batch.items) |entry| std.testing.allocator.free(entry.line);

    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqualStrings("one", batch.items[0].line);

    try std.testing.expect(try drainSessionStdoutChunkWithLimit(std.testing.allocator, &session, &queue, 4));
    var next_batch = try queue.take(std.testing.allocator, 0);
    defer next_batch.deinit(std.testing.allocator);
    defer for (next_batch.items) |entry| std.testing.allocator.free(entry.line);

    try std.testing.expectEqual(@as(usize, 1), next_batch.items.len);
    try std.testing.expectEqualStrings("two", next_batch.items[0].line);
}

test "wm tty poll error does not mark tty ready" {
    var events = try WmEventLoop.init();
    defer events.deinit();
    events.tty_poll_armed = true;

    const action = onWmTtyReadable(&events, undefined, undefined, undefined, error.Unexpected);

    try std.testing.expectEqual(xev.CallbackAction.disarm, action);
    try std.testing.expect(!events.tty_ready);
    try std.testing.expect(!events.tty_poll_armed);
    try std.testing.expect(!events.tty_poll_supported);
}

test "wm producer stdout poll error does not mark stdout ready" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
        .stdout_poll_armed = true,
    };

    const action = onWmSessionStdoutReadable(&session, undefined, undefined, undefined, error.Unexpected);

    try std.testing.expectEqual(xev.CallbackAction.disarm, action);
    try std.testing.expect(!session.stdout_ready);
    try std.testing.expect(!session.stdout_poll_armed);
    try std.testing.expect(!session.stdout_poll_supported);
}

test "wm reconcile empty session list is stable" {
    var focused_index: usize = 0;
    var mouse = WmMouseInputState{};
    var log = try ProtocolEventLog.init(std.testing.allocator, 8);
    defer log.deinit();
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();

    const result = try reconcileExitedSessions(&.{}, &.{}, &focused_index, &mouse, &log, &logger);

    try std.testing.expect(!result.changed);
    try std.testing.expect(!result.focus_changed);
    try std.testing.expect(!result.z_order_changed);
    try std.testing.expectEqual(@as(usize, 0), focused_index);
}

fn enqueuePeerLineForQueueBoundTest(queue: *WmPeerLineQueue, done: *std.atomic.Value(bool)) void {
    queue.enqueueCopy(null, "two") catch {
        done.store(true, .seq_cst);
        return;
    };
    done.store(true, .seq_cst);
}

fn waitForBlockedQueueProducer(queue: *WmPeerLineQueue) !void {
    var timer = try std.time.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s) {
        queue.mutex.lock();
        const blocked = queue.blocked_enqueue_count > 0;
        queue.mutex.unlock();
        if (blocked) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "wm peer stdout queue wakes blocked producers when drained" {
    var queue = WmPeerLineQueue.initWithMaxEntries(std.testing.allocator, 1);
    defer queue.deinit();

    try queue.enqueueCopy(null, "one");

    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, enqueuePeerLineForQueueBoundTest, .{ &queue, &done });
    var thread_joined = false;
    defer if (!thread_joined) {
        queue.close();
        thread.join();
    };

    try waitForBlockedQueueProducer(&queue);
    try std.testing.expect(!done.load(.seq_cst));

    var batch = try queue.take(std.testing.allocator, 1);
    defer batch.deinit(std.testing.allocator);
    defer for (batch.items) |entry| std.testing.allocator.free(entry.line);
    try std.testing.expectEqual(@as(usize, 1), batch.items.len);
    try std.testing.expectEqualStrings("one", batch.items[0].line);

    thread.join();
    thread_joined = true;
    try std.testing.expect(done.load(.seq_cst));

    var remaining = try queue.take(std.testing.allocator, 0);
    defer remaining.deinit(std.testing.allocator);
    defer for (remaining.items) |entry| std.testing.allocator.free(entry.line);
    try std.testing.expectEqual(@as(usize, 1), remaining.items.len);
    try std.testing.expectEqualStrings("two", remaining.items[0].line);
}

test "wm queued presentation status still updates during drain" {
    var session = WmProducerSession{
        .profile_name = "test",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 20, .cols = 80 }),
        .upload = .{ .profile = .direct_apc },
        .child = undefined,
    };

    var queue = WmPeerLineQueue.init(std.testing.allocator);
    defer queue.deinit();

    const line = "{\"type\":\"presentation_status\",\"window_id\":\"main\",\"ready_to_show\":true,\"source_px\":{\"w\":640,\"h\":480},\"effective_rect_cells\":{\"row\":7,\"col\":11,\"rows\":15,\"cols\":40}}";
    try queue.enqueueCopy(&session, line);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var tty_lock = std.Thread.Mutex{};
    var redraw_requested = std.atomic.Value(bool).init(false);
    try std.testing.expect(try drainQueuedPeerLines(std.testing.allocator, &queue, out.writer(std.testing.allocator), &tty_lock, &redraw_requested, 8));

    try std.testing.expectEqualStrings("", out.items);
    try std.testing.expect(session.presentation_status.ready_to_show);
    try std.testing.expect(redraw_requested.load(.seq_cst));
}

test "wm resolves initial ready presentation to effective content rect" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "ready",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 22, .cols = 78 }),
            .upload = .{ .profile = .direct_apc },
            .presentation_status = .{
                .seen = true,
                .ready_to_show = true,
                .source_px = .{ .w = 640, .h = 480 },
                .effective_rect_cells = .{ .row = 6, .col = 10, .rows = 12, .cols = 40 },
            },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };

    try std.testing.expect(resolveInitialReadyPresentations(sessions[0..], .{ .rows = 24, .cols = 80, .pixel_width = 640, .pixel_height = 480 }));
    try std.testing.expect(sessions[0].initial_presentation_resolved);
    try std.testing.expectEqual(Rect{ .row = 3, .col = 9, .rows = 16, .cols = 42 }, sessions[0].window.outer);
    try std.testing.expect(!resolveInitialReadyPresentations(sessions[0..], .{ .rows = 24, .cols = 80, .pixel_width = 640, .pixel_height = 480 }));
}

test "wm desktop waits for presentation ready before drawing producer chrome" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "not-ready",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };
    const z_order = [_]usize{0};

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    var tty_lock = std.Thread.Mutex{};
    var redraw_state = WmDesktopRedrawState{};
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "not-ready") == null);

    sessions[0].presentation_status = .{ .seen = true, .ready_to_show = true, .source_px = .{ .w = 640, .h = 480 } };
    out.clearRetainingCapacity();
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "not-ready") != null);
}

test "wm desktop can render with no producer sessions" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    try log.record(.launch_prompt, "launch:");
    var tty_lock = std.Thread.Mutex{};
    const sessions = [_]WmProducerSession{};
    const z_order = [_]usize{};
    var redraw_state = WmDesktopRedrawState{};
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "windows=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "last=launch_prompt launch:") != null);
}

test "wm desktop redraw avoids full screen clear" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    try log.record(.attach_sent, "main");
    var tty_lock = std.Thread.Mutex{};
    const sessions = [_]WmProducerSession{};
    const z_order = [_]usize{};
    var redraw_state = WmDesktopRedrawState{};
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2K") != null);
}

test "wm desktop redraw does not clear unchanged window chrome" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "moved",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 8, .cols = 24 }),
            .upload = .{ .profile = .direct_apc },
            .presentation_status = .{ .seen = true, .ready_to_show = true },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
        .{
            .profile_name = "unchanged",
            .window = WmWindowState.init("main", .{ .row = 12, .col = 30, .rows = 8, .cols = 24 }),
            .upload = .{ .profile = .direct_apc },
            .presentation_status = .{ .seen = true, .ready_to_show = true },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };
    const z_order = [_]usize{ 0, 1 };
    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    var tty_lock = std.Thread.Mutex{};
    var redraw_state = WmDesktopRedrawState{};

    var initial = std.ArrayList(u8).empty;
    defer initial.deinit(std.testing.allocator);
    try redrawDesktopManyLocked(&tty_lock, initial.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);

    sessions[0].window.outer.row += 1;
    var moved = std.ArrayList(u8).empty;
    defer moved.deinit(std.testing.allocator);
    try redrawDesktopManyLocked(&tty_lock, moved.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);

    try std.testing.expect(std.mem.indexOf(u8, moved.items, "\x1b[12;30H                        ") == null);
}

test "wm initial control advertises file upload policy" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeInitialControl(out.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 16, .cols = 78 },
        .upload = .{ .profile = .file_whole, .path = "/tmp/katzensteg-wm-upload", .high_water = 4096 },
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"profile\":\"file_whole\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"/tmp/katzensteg-wm-upload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"profile\":\"direct_apc\"") == null);
}

test "wm attach and viewport controls advertise terminal geometry" {
    const terminal = TerminalSize{ .rows = 40, .cols = 160, .pixel_width = 1280, .pixel_height = 800 };

    var attach = std.ArrayList(u8).empty;
    defer attach.deinit(std.testing.allocator);
    try writeInitialControl(attach.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 20, .cols = 40 },
        .terminal = terminal,
        .upload = .{ .profile = .direct_apc },
    });
    try std.testing.expect(std.mem.indexOf(u8, attach.items, "\"terminal_cells\":{\"rows\":40,\"cols\":160}") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach.items, "\"terminal_px\":{\"w\":1280,\"h\":800}") != null);

    var viewport = std.ArrayList(u8).empty;
    defer viewport.deinit(std.testing.allocator);
    try writeViewportControl(viewport.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 20, .cols = 40 },
        .terminal = terminal,
    });
    try std.testing.expect(std.mem.indexOf(u8, viewport.items, "\"terminal_cells\":{\"rows\":40,\"cols\":160}") != null);
    try std.testing.expect(std.mem.indexOf(u8, viewport.items, "\"terminal_px\":{\"w\":1280,\"h\":800}") != null);
}

test "wm attach and viewport controls advertise occlusion rectangles" {
    const occlusions = [_]render_batch_protocol.PresentationRectCells{
        .{ .row = 1, .col = 1, .rows = 3, .cols = 20 },
        .{ .row = 8, .col = 30, .rows = 5, .cols = 12 },
    };

    var attach = std.ArrayList(u8).empty;
    defer attach.deinit(std.testing.allocator);
    try writeInitialControl(attach.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 20, .cols = 40 },
        .occlusion_rects = &occlusions,
        .upload = .{ .profile = .direct_apc },
    });
    try std.testing.expect(std.mem.indexOf(u8, attach.items, "\"occlusion_rects\":[{\"row\":1,\"col\":1,\"rows\":3,\"cols\":20},{\"row\":8,\"col\":30,\"rows\":5,\"cols\":12}]") != null);

    var viewport = std.ArrayList(u8).empty;
    defer viewport.deinit(std.testing.allocator);
    try writeViewportControl(viewport.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 20, .cols = 40 },
        .occlusion_rects = occlusions[0..1],
    });
    try std.testing.expect(std.mem.indexOf(u8, viewport.items, "\"occlusion_rects\":[{\"row\":1,\"col\":1,\"rows\":3,\"cols\":20}]") != null);
}

test "wm occlusion policy uses outer rects of higher running windows" {
    var sessions = [_]WmProducerSession{
        .{ .profile_name = "bottom", .window = WmWindowState.init("main", .{ .row = 4, .col = 4, .rows = 10, .cols = 30 }), .upload = .{ .profile = .direct_apc }, .child = std.process.Child.init(&.{"true"}, std.testing.allocator), .presentation_status = .{ .seen = true, .ready_to_show = true } },
        .{ .profile_name = "top", .window = WmWindowState.init("main", .{ .row = 2, .col = 6, .rows = 5, .cols = 12 }), .upload = .{ .profile = .direct_apc }, .child = std.process.Child.init(&.{"true"}, std.testing.allocator), .presentation_status = .{ .seen = true, .ready_to_show = true } },
    };
    sessions[0].state = .running;
    sessions[1].state = .running;
    var z_order = [_]usize{ 0, 1 };
    var scratch: [default_wm_session_capacity]render_batch_protocol.PresentationRectCells = undefined;

    const bottom_occlusions = occlusionRectsForSession(sessions[0..], z_order[0..], 0, scratch[0..]);
    try std.testing.expectEqual(@as(usize, 1), bottom_occlusions.len);
    try std.testing.expectEqual(render_batch_protocol.PresentationRectCells{ .row = 2, .col = 6, .rows = 5, .cols = 12 }, bottom_occlusions[0]);

    const top_occlusions = occlusionRectsForSession(sessions[0..], z_order[0..], 1, scratch[0..]);
    try std.testing.expectEqual(@as(usize, 0), top_occlusions.len);
}

test "wm occlusion policy ignores higher producers that are not drawable yet" {
    var sessions = [_]WmProducerSession{
        .{ .profile_name = "bottom", .window = WmWindowState.init("main", .{ .row = 4, .col = 4, .rows = 10, .cols = 30 }), .upload = .{ .profile = .direct_apc }, .child = std.process.Child.init(&.{"true"}, std.testing.allocator), .presentation_status = .{ .seen = true, .ready_to_show = true } },
        .{ .profile_name = "launching-top", .window = WmWindowState.init("main", .{ .row = 2, .col = 6, .rows = 5, .cols = 12 }), .upload = .{ .profile = .direct_apc }, .child = std.process.Child.init(&.{"true"}, std.testing.allocator) },
    };
    sessions[0].state = .running;
    sessions[1].state = .running;
    var z_order = [_]usize{ 0, 1 };
    var scratch: [default_wm_session_capacity]render_batch_protocol.PresentationRectCells = undefined;

    const bottom_occlusions = occlusionRectsForSession(sessions[0..], z_order[0..], 0, scratch[0..]);
    try std.testing.expectEqual(@as(usize, 0), bottom_occlusions.len);
}

test "wm upload policy honors file profile choices without direct apc" {
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_whole, uploadPolicyForOutputProfile("/tmp/wm-upload", .file_whole).profile);
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_offset_ring, uploadPolicyForOutputProfile("/tmp/wm-upload", .file_offset_ring).profile);
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_whole, uploadPolicyForOutputProfile("/tmp/wm-upload", .direct_apc).profile);
}

test "wm upload policy cleanup removes rotated file whole artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "upload.session-2" });
    const base_path_for_check = try std.testing.allocator.dupe(u8, path);
    defer std.testing.allocator.free(base_path_for_check);

    const first_rotated = try std.fmt.allocPrint(std.testing.allocator, "{s}.0", .{path});
    defer std.testing.allocator.free(first_rotated);
    const last_rotated = try std.fmt.allocPrint(std.testing.allocator, "{s}.255", .{path});
    defer std.testing.allocator.free(last_rotated);

    {
        const file = try std.fs.createFileAbsolute(path, .{});
        file.close();
    }
    {
        const file = try std.fs.createFileAbsolute(first_rotated, .{});
        file.close();
    }
    {
        const file = try std.fs.createFileAbsolute(last_rotated, .{});
        file.close();
    }

    var upload = render_batch_protocol.UploadPolicy{ .profile = .file_whole, .path = path };
    deinitUploadPolicy(std.testing.allocator, &upload);

    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(base_path_for_check, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(first_rotated, .{}));
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(last_rotated, .{}));
    try std.testing.expect(upload.path == null);
}

test "wm exec path renders chrome and applies fake peer frame batch" {
    const script_path = "/tmp/katzensteg-wm-fake-peer.sh";
    {
        const file = try std.fs.createFileAbsolute(script_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            "read _\n" ++
                "read _\n" ++
                "printf '%s\\n' '{\"type\":\"frame_batch\",\"window_id\":\"main\",\"seq\":1,\"groups\":{\"deletes\":[\"D\"],\"uploads\":[\"U\"],\"placements\":[\"P\"],\"after\":[\"A\"]}}'\n",
        );
    }
    defer std.fs.deleteFileAbsolute(script_path) catch {};

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const code = try runExecWithWriter(std.testing.allocator, &.{ "sh", script_path }, out.writer(std.testing.allocator), .{
        .title = "fake",
        .terminal = .{ .rows = 24, .cols = 80 },
        .upload = .{ .profile = .file_whole, .path = "/tmp/katzensteg-wm-test-upload" },
    });

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "katzensteg wm") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fake") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "DUPA") != null);
}

test "wm window actions move and resize within terminal bounds" {
    var window = WmWindowState.init("main", .{ .row = 2, .col = 2, .rows = 10, .cols = 30 });
    const terminal = TerminalSize{ .rows = 24, .cols = 80 };

    try std.testing.expect(applyWindowAction(&window, .move_right, terminal));
    try std.testing.expectEqual(Rect{ .row = 2, .col = 3, .rows = 10, .cols = 30 }, window.outer);

    try std.testing.expect(applyWindowAction(&window, .resize_wider, terminal));
    try std.testing.expectEqual(Rect{ .row = 2, .col = 3, .rows = 10, .cols = 32 }, window.outer);

    window.outer = .{ .row = 1, .col = 1, .rows = 6, .cols = 20 };
    try std.testing.expect(!applyWindowAction(&window, .resize_narrower, terminal));
    try std.testing.expect(!applyWindowAction(&window, .resize_shorter, terminal));
    try std.testing.expectEqual(Rect{ .row = 1, .col = 1, .rows = 6, .cols = 20 }, window.outer);
}

test "wm resize preserves producer aspect using terminal cell pixels" {
    var window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 14, .cols = 42 });
    const terminal = TerminalSize{ .rows = 40, .cols = 160, .pixel_width = 1280, .pixel_height = 800 };
    const status = WmPresentationStatus{
        .seen = true,
        .ready_to_show = true,
        .source_px = .{ .w = 640, .h = 480 },
    };

    try std.testing.expect(applyWindowActionWithPresentation(&window, .resize_wider, terminal, status));
    try std.testing.expectEqual(Rect{ .row = 1, .col = 1, .rows = 17, .cols = 44 }, window.outer);

    try std.testing.expect(applyWindowActionWithPresentation(&window, .resize_taller, terminal, status));
    try std.testing.expectEqual(Rect{ .row = 1, .col = 1, .rows = 18, .cols = 49 }, window.outer);
}

test "wm viewport control writes content rect" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeViewportControl(out.writer(std.testing.allocator), .{
        .window_id = "main",
        .rect_cells = .{ .row = 4, .col = 2, .rows = 18, .cols = 78 },
        .aspect = .fit,
    });

    try std.testing.expectEqualStrings(
        "{\"type\":\"viewport\",\"window_id\":\"main\",\"rect_cells\":{\"row\":4,\"col\":2,\"rows\":18,\"cols\":78},\"aspect\":\"fit\"}\n",
        out.items,
    );
}

test "wm attach and viewport controls can carry z base" {
    var attach = std.ArrayList(u8).empty;
    defer attach.deinit(std.testing.allocator);
    try writeInitialControl(attach.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 18, .cols = 78 },
        .z_base = 2000,
        .upload = .{ .profile = .direct_apc },
    });
    try std.testing.expect(std.mem.indexOf(u8, attach.items, "\"z_base\":2000") != null);

    var viewport = std.ArrayList(u8).empty;
    defer viewport.deinit(std.testing.allocator);
    try writeViewportControl(viewport.writer(std.testing.allocator), .{
        .rect_cells = .{ .row = 4, .col = 2, .rows = 18, .cols = 78 },
        .z_base = 3000,
    });
    try std.testing.expect(std.mem.indexOf(u8, viewport.items, "\"z_base\":3000") != null);
}

test "wm input control writes terminal bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try writeInputControl(out.writer(std.testing.allocator), "\x1b[<35;11;6M");

    try std.testing.expectEqualStrings(
        "{\"type\":\"input\",\"window_id\":\"main\",\"event\":\"terminal_bytes\",\"bytes\":\"\\u001b[<35;11;6M\"}\n",
        out.items,
    );
}

test "wm forwards mouse input only inside content rect" {
    const content = Rect{ .row = 4, .col = 2, .rows = 16, .cols = 78 };

    var inside = [_]u8{ 0x1b, '[', '<', '3', '5', ';', '2', ';', '4', 'M' };
    try std.testing.expectEqualStrings("\x1b[<35;2;4M", filterForwardedInputBytes(&inside, content));

    var outside_col = [_]u8{ 0x1b, '[', '<', '3', '5', ';', '1', ';', '4', 'M' };
    try std.testing.expectEqualStrings("", filterForwardedInputBytes(&outside_col, content));

    var outside_row = [_]u8{ 0x1b, '[', '<', '3', '5', ';', '2', ';', '3', 'M' };
    try std.testing.expectEqualStrings("", filterForwardedInputBytes(&outside_row, content));

    var key = [_]u8{'a'};
    try std.testing.expectEqualStrings("a", filterForwardedInputBytes(&key, content));
}

test "wm mouse filter preserves non-mouse bytes in coalesced terminal reads" {
    const content = Rect{ .row = 4, .col = 2, .rows = 16, .cols = 78 };

    var mixed = [_]u8{ 0x1b, '[', '<', '3', '5', ';', '1', ';', '4', 'M', 'a', 0x1b, '[', '<', '3', '5', ';', '2', ';', '4', 'M' };
    try std.testing.expectEqualStrings("a\x1b[<35;2;4M", filterForwardedInputBytes(&mixed, content));
}

const BrokenControlWriter = struct {
    pub fn writeAll(_: *BrokenControlWriter, _: []const u8) error{BrokenPipe}!void {
        return error.BrokenPipe;
    }

    pub fn writeByte(_: *BrokenControlWriter, _: u8) error{BrokenPipe}!void {
        return error.BrokenPipe;
    }

    pub fn print(_: *BrokenControlWriter, comptime _: []const u8, _: anytype) error{BrokenPipe}!void {
        return error.BrokenPipe;
    }
};

test "wm viewport control can be sent best-effort after producer exit" {
    var writer = BrokenControlWriter{};
    try std.testing.expect(!tryWriteViewportControl(&writer, .{
        .window_id = "main",
        .rect_cells = .{ .row = 4, .col = 2, .rows = 18, .cols = 78 },
        .aspect = .fit,
    }));
}

test "wm input parser prioritizes quit in coalesced input" {
    try std.testing.expectEqual(InputAction.quit, inputActionFromBytes("lq"));
    try std.testing.expectEqual(InputAction.start_launch, inputActionFromBytes("n"));
    try std.testing.expectEqual(InputAction{ .window = .move_right }, inputActionFromBytes("l"));
    try std.testing.expectEqual(InputAction.focus_next, inputActionFromBytes("\t"));
    try std.testing.expectEqual(InputAction{ .layout = .tile }, inputActionFromBytes("t"));
    try std.testing.expectEqual(InputAction{ .layout = .cascade }, inputActionFromBytes("c"));
}

test "wm launch prompt edits profile names" {
    var prompt = std.ArrayList(u8).empty;
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expectEqual(LaunchPromptAction.changed, try applyLaunchPromptBytes("sonic!", &prompt, std.testing.allocator));
    try std.testing.expectEqualStrings("sonic", prompt.items);

    try std.testing.expectEqual(LaunchPromptAction.changed, try applyLaunchPromptBytes(&.{0x7f}, &prompt, std.testing.allocator));
    try std.testing.expectEqualStrings("soni", prompt.items);

    try std.testing.expectEqual(LaunchPromptAction.cancel, try applyLaunchPromptBytes(&.{0x1b}, &prompt, std.testing.allocator));
    try std.testing.expectEqual(LaunchPromptAction.submit, try applyLaunchPromptBytes("\r", &prompt, std.testing.allocator));
}

test "wm mouse hit test separates title border and content" {
    const outer = Rect{ .row = 2, .col = 3, .rows = 12, .cols = 40 };

    try std.testing.expectEqual(WmMouseHit.close, mouseHitTest(outer, .{ .row = 3, .col = 4 }));
    try std.testing.expectEqual(WmMouseHit.close, mouseHitTest(outer, .{ .row = 3, .col = 5 }));
    try std.testing.expectEqual(WmMouseHit.title, mouseHitTest(outer, .{ .row = 3, .col = 6 }));
    try std.testing.expectEqual(WmMouseHit.title, mouseHitTest(outer, .{ .row = 3, .col = 10 }));
    try std.testing.expectEqual(WmMouseHit.resize_right, mouseHitTest(outer, .{ .row = 6, .col = 42 }));
    try std.testing.expectEqual(WmMouseHit.resize_bottom_right, mouseHitTest(outer, .{ .row = 13, .col = 42 }));
    try std.testing.expectEqual(WmMouseHit.content, mouseHitTest(outer, .{ .row = 5, .col = 10 }));
    try std.testing.expectEqual(WmMouseHit.desktop, mouseHitTest(outer, .{ .row = 20, .col = 10 }));
    try std.testing.expectEqual(WmMouseHit.desktop, mouseHitTest(.{ .row = 1, .col = 1, .rows = 3, .cols = 3 }, .{ .row = 2, .col = 2 }));
}

test "wm close hit consumes mouse and requests close" {
    var state = WmMouseInputState{};
    var close_down = [_]u8{ 0x1b, '[', '<', '0', ';', '5', ';', '3', 'M' };
    const outer = Rect{ .row = 2, .col = 3, .rows = 12, .cols = 40 };
    const content = contentRectForOuter(outer);

    try std.testing.expectEqual(InputAction.close_focused, state.readMouseInput(&close_down, outer, content, .{ .rows = 24, .cols = 80 }).action);
}

test "wm mouse drag moves from title bar cell delta" {
    var drag = WmMouseDrag.start(.title, .{ .row = 3, .col = 10 }, .{ .row = 2, .col = 3, .rows = 12, .cols = 40 });

    const next = drag.update(.{ .row = 5, .col = 14 }, .{ .rows = 24, .cols = 80 });

    try std.testing.expectEqual(Rect{ .row = 4, .col = 7, .rows = 12, .cols = 40 }, next);
}

test "wm mouse drag resizes from right and bottom borders" {
    var right = WmMouseDrag.start(.resize_right, .{ .row = 6, .col = 42 }, .{ .row = 2, .col = 3, .rows = 12, .cols = 40 });
    try std.testing.expectEqual(Rect{ .row = 2, .col = 3, .rows = 12, .cols = 45 }, right.update(.{ .row = 6, .col = 47 }, .{ .rows = 24, .cols = 80 }));

    var corner = WmMouseDrag.start(.resize_bottom_right, .{ .row = 13, .col = 42 }, .{ .row = 2, .col = 3, .rows = 12, .cols = 40 });
    try std.testing.expectEqual(Rect{ .row = 2, .col = 3, .rows = 15, .cols = 44 }, corner.update(.{ .row = 16, .col = 46 }, .{ .rows = 24, .cols = 80 }));
}

test "wm chrome drag consumes mouse packets until release" {
    var state = WmMouseInputState{};
    var title_down = [_]u8{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '3', 'M' };
    const outer = Rect{ .row = 2, .col = 3, .rows = 12, .cols = 40 };
    const content = contentRectForOuter(outer);

    try std.testing.expectEqual(InputAction{ .mouse_drag = Rect{ .row = 2, .col = 3, .rows = 12, .cols = 40 } }, state.readMouseInput(&title_down, outer, content, .{ .rows = 24, .cols = 80 }).action);

    var motion = [_]u8{ 0x1b, '[', '<', '3', '5', ';', '1', '2', ';', '5', 'M' };
    try std.testing.expectEqual(InputAction{ .mouse_drag = Rect{ .row = 4, .col = 5, .rows = 12, .cols = 40 } }, state.readMouseInput(&motion, outer, content, .{ .rows = 24, .cols = 80 }).action);

    var release = [_]u8{ 0x1b, '[', '<', '0', ';', '1', '2', ';', '5', 'm' };
    try std.testing.expectEqual(InputAction.consume, state.readMouseInput(&release, outer, content, .{ .rows = 24, .cols = 80 }).action);

    var content_click = [_]u8{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '5', 'M' };
    try std.testing.expectEqual(InputAction.forward, state.readMouseInput(&content_click, outer, content, .{ .rows = 24, .cols = 80 }).action);
}

test "wm cascade offsets new windows inside terminal bounds" {
    const terminal = TerminalSize{ .rows = 24, .cols = 80 };
    const first = initialOuterRect(terminal);
    const third = cascadedOuterRect(terminal, 2);

    try std.testing.expectEqual(first.row + 2, third.row);
    try std.testing.expectEqual(first.col + 4, third.col);
    try std.testing.expect(third.row + third.rows - 1 <= terminal.rows);
    try std.testing.expect(third.col + third.cols - 1 <= terminal.cols);
}

test "wm upload paths are distinct per producer session" {
    const first = try sessionUploadPath(std.testing.allocator, "/tmp/katzensteg-upload.rgba", 0);
    defer std.testing.allocator.free(first);
    const second = try sessionUploadPath(std.testing.allocator, "/tmp/katzensteg-upload.rgba", 1);
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.endsWith(u8, first, ".session-0"));
    try std.testing.expect(std.mem.endsWith(u8, second, ".session-1"));
}

test "wm z order hit test chooses frontmost window under mouse" {
    const windows = [_]WmWindowState{
        WmWindowState.init("back", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
        WmWindowState.init("front", .{ .row = 3, .col = 5, .rows = 12, .cols = 40 }),
    };
    var z_order = [_]usize{ 0, 1 };

    try std.testing.expectEqual(@as(?usize, 1), hitWindowIndex(windows[0..], z_order[0..], .{ .row = 5, .col = 10 }));
    try std.testing.expectEqual(@as(?usize, 0), hitWindowIndex(windows[0..], z_order[0..], .{ .row = 2, .col = 2 }));
}

test "wm mouse drag keeps original focused window when crossing another window" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "back",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
            .presentation_status = .{ .seen = true, .ready_to_show = true, .source_px = .{ .w = 640, .h = 480 } },
        },
        .{
            .profile_name = "front",
            .window = WmWindowState.init("main", .{ .row = 4, .col = 5, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
            .presentation_status = .{ .seen = true, .ready_to_show = true, .source_px = .{ .w = 640, .h = 480 } },
        },
    };
    var z_order = [_]usize{ 0, 1 };
    var focused_index: usize = 0;
    var mouse = WmMouseInputState{};
    var down = [_]u8{ 0x1b, '[', '<', '0', ';', '1', '0', ';', '2', 'M' };

    const start = readInputForSessionsBytes(down[0..], &mouse, sessions[0..], z_order[0..], &focused_index, .{ .rows = 24, .cols = 80 });
    try std.testing.expectEqual(@as(usize, 0), focused_index);
    try std.testing.expectEqual(InputAction{ .mouse_drag = sessions[0].window.outer }, start.action);

    var motion = [_]u8{ 0x1b, '[', '<', '3', '2', ';', '1', '0', ';', '5', 'M' };
    const moved = readInputForSessionsBytes(motion[0..], &mouse, sessions[0..], z_order[0..], &focused_index, .{ .rows = 24, .cols = 80 });
    try std.testing.expectEqual(@as(usize, 0), focused_index);
    try std.testing.expectEqual(InputAction{ .mouse_drag = Rect{ .row = 4, .col = 1, .rows = 12, .cols = 40 } }, moved.action);
}

test "wm closed producer sessions stop drawing and hit testing immediately" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "active",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
            .presentation_status = .{ .seen = true, .ready_to_show = true, .source_px = .{ .w = 640, .h = 480 } },
        },
        .{
            .profile_name = "closed",
            .window = WmWindowState.init("main", .{ .row = 3, .col = 5, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .draining,
            .control_open = false,
            .stdin_closed = true,
        },
    };
    const z_order = [_]usize{ 0, 1 };

    try std.testing.expectEqual(@as(?usize, 0), hitSessionIndex(sessions[0..], z_order[0..], .{ .row = 5, .col = 10 }));

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var log = try ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    var tty_lock = std.Thread.Mutex{};
    var redraw_state = WmDesktopRedrawState{};
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log, &redraw_state);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "active") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "closed") == null);
}

test "wm reconciles externally exited producer sessions" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "dead",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
            .stdin_closed = true,
        },
        .{
            .profile_name = "alive",
            .window = WmWindowState.init("main", .{ .row = 3, .col = 5, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
            .stdin_closed = true,
        },
    };
    sessions[0].wait_state.done.store(true, .seq_cst);
    var z_order = [_]usize{ 0, 1 };
    var focused_index: usize = 0;
    var mouse = WmMouseInputState{ .drag = WmMouseDrag.start(.title, .{ .row = 2, .col = 2 }, sessions[0].window.outer) };
    var log = try ProtocolEventLog.init(std.testing.allocator, 4);
    defer log.deinit();
    var logger = Logger.init(std.testing.allocator);
    defer logger.deinit();

    const result = try reconcileExitedSessions(sessions[0..], z_order[0..], &focused_index, &mouse, &log, &logger);

    try std.testing.expect(result.changed);
    try std.testing.expect(result.focus_changed);
    try std.testing.expectEqual(ProducerSessionState.exited, sessions[0].state);
    try std.testing.expectEqual(@as(usize, 1), focused_index);
    try std.testing.expectEqual(@as(?WmMouseDrag, null), mouse.drag);
    try std.testing.expectEqual(EventKind.process_exited, log.at(0).?.kind);
    try std.testing.expectEqual(EventKind.focus_changed, log.at(1).?.kind);
}

test "wm child exit polling marks finished child without wait thread" {
    var child = std.process.Child.init(&.{"/usr/bin/true"}, std.testing.allocator);
    try child.spawn();

    var session = WmProducerSession{
        .profile_name = "done",
        .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
        .upload = .{ .profile = .direct_apc },
        .child = child,
        .state = .running,
    };

    var timer = try std.time.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s and !session.wait_state.done.load(.seq_cst)) {
        _ = try pollSessionChildExit(&session);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expect(session.wait_state.done.load(.seq_cst));
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, session.wait_state.term);
}

test "wm z order compacts exited sessions behind visible sessions" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "visible-a",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
        .{
            .profile_name = "exited",
            .window = WmWindowState.init("main", .{ .row = 3, .col = 5, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .exited,
        },
        .{
            .profile_name = "visible-b",
            .window = WmWindowState.init("main", .{ .row = 5, .col = 9, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };
    var z_order = [_]usize{ 0, 1, 2 };

    try std.testing.expect(compactVisibleZOrder(sessions[0..], z_order[0..]));

    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, z_order[0..]);
}

test "wm tile layout arranges visible producers without overlap" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "one",
            .window = WmWindowState.init("main", .{ .row = 5, .col = 5, .rows = 8, .cols = 30 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
        .{
            .profile_name = "two",
            .window = WmWindowState.init("main", .{ .row = 7, .col = 9, .rows = 8, .cols = 30 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };

    try std.testing.expect(applyLayoutAction(sessions[0..], .tile, .{ .rows = 24, .cols = 80 }));

    try std.testing.expectEqual(Rect{ .row = 1, .col = 1, .rows = 23, .cols = 40 }, sessions[0].window.outer);
    try std.testing.expectEqual(Rect{ .row = 1, .col = 41, .rows = 23, .cols = 40 }, sessions[1].window.outer);
}

test "wm cascade layout skips non-visible producers" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "visible-a",
            .window = WmWindowState.init("main", .{ .row = 9, .col = 9, .rows = 8, .cols = 30 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
        .{
            .profile_name = "closed",
            .window = WmWindowState.init("main", .{ .row = 3, .col = 5, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .exited,
        },
        .{
            .profile_name = "visible-b",
            .window = WmWindowState.init("main", .{ .row = 11, .col = 13, .rows = 8, .cols = 30 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
        },
    };

    try std.testing.expect(applyLayoutAction(sessions[0..], .cascade, .{ .rows = 24, .cols = 80 }));

    try std.testing.expectEqual(Rect{ .row = 1, .col = 1, .rows = 22, .cols = 76 }, sessions[0].window.outer);
    try std.testing.expectEqual(Rect{ .row = 3, .col = 5, .rows = 12, .cols = 40 }, sessions[1].window.outer);
    try std.testing.expectEqual(Rect{ .row = 2, .col = 3, .rows = 22, .cols = 76 }, sessions[2].window.outer);
}

test "wm focus bring to front mutates z order without moving sessions" {
    var z_order = [_]usize{ 0, 1, 2 };

    bringWindowToFront(z_order[0..], 0);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, z_order[0..]);

    bringWindowToFront(z_order[0..], 2);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, z_order[0..]);
}

test "wm chrome marks focused window with terminal styling" {
    var active = std.ArrayList(u8).empty;
    defer active.deinit(std.testing.allocator);
    try renderChrome(active.writer(std.testing.allocator), .{
        .outer = .{ .row = 1, .col = 1, .rows = 8, .cols = 30 },
        .title = "active",
        .focused = true,
    });

    var inactive = std.ArrayList(u8).empty;
    defer inactive.deinit(std.testing.allocator);
    try renderChrome(inactive.writer(std.testing.allocator), .{
        .outer = .{ .row = 1, .col = 1, .rows = 8, .cols = 30 },
        .title = "inactive",
        .focused = false,
    });

    try std.testing.expect(std.mem.indexOf(u8, active.items, "\x1b[1;36m") != null);
    try std.testing.expect(std.mem.indexOf(u8, inactive.items, "\x1b[2m") != null);
}
