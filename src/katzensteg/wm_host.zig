const std = @import("std");
const render_batch_protocol = @import("render_batch_protocol.zig");
const attach_protocol = @import("attach_protocol.zig");
const terminal_batch_applier = @import("terminal_batch_applier.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;
const Logger = @import("log.zig").Logger;
const config_mod = @import("config.zig");
const upload_path_mod = @import("upload_path.zig");
const ts_kitty = @import("termscene").kitty;

pub const TerminalSize = struct {
    rows: i32,
    cols: i32,
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

    pub fn init(allocator: std.mem.Allocator, capacity: usize) ProtocolEventLog {
        const events = allocator.alloc(ProtocolEvent, capacity) catch unreachable;
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

pub const WmDesktopState = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(WmWindowState),
    focused_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) WmDesktopState {
        return .{ .allocator = allocator, .windows = .empty };
    }

    pub fn deinit(self: *WmDesktopState) void {
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addWindow(self: *WmDesktopState, window_id: []const u8, outer: Rect) !void {
        try self.windows.append(self.allocator, WmWindowState.init(window_id, outer));
        if (self.windows.items.len == 1) self.focused_index = 0;
    }

    pub fn focusedWindow(self: *WmDesktopState) ?*WmWindowState {
        if (self.windows.items.len == 0) return null;
        if (self.focused_index >= self.windows.items.len) self.focused_index = 0;
        return &self.windows.items[self.focused_index];
    }

    pub fn focusNext(self: *WmDesktopState) void {
        if (self.windows.items.len == 0) return;
        self.focused_index = (self.focused_index + 1) % self.windows.items.len;
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
};

pub const StatusBandOptions = struct {
    terminal: TerminalSize,
    window: WmWindowState,
    upload_profile: render_batch_protocol.UploadProfile,
    events: *const ProtocolEventLog,
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
    window.outer = clampOuterRect(next, terminal);
    return !std.meta.eql(previous, window.outer);
}

pub fn runProfile(allocator: std.mem.Allocator, profile_name: []const u8) !u8 {
    return runProfiles(allocator, &.{profile_name});
}

pub fn runProfiles(allocator: std.mem.Allocator, profile_names: []const []const u8) !u8 {
    return runMultiProfile(allocator, profile_names);
}

const WmProducerSession = struct {
    profile_name: []const u8,
    window: WmWindowState,
    upload: render_batch_protocol.UploadPolicy,
    child: std.process.Child,
    child_stdin: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,
    stdout_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,
    wait_state: ChildWaitState = .{},
    state: ProducerSessionState = .launching,
    control_open: bool = true,
    stdin_closed: bool = false,

    fn focusedContent(self: WmProducerSession) Rect {
        return contentRectForOuter(self.window.outer);
    }
};

fn runMultiProfile(allocator: std.mem.Allocator, profile_names: []const []const u8) !u8 {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    var tty = try DirectTty.init();
    defer tty.deinit();

    var logger = Logger.init(allocator);
    defer logger.deinit();
    var event_log = ProtocolEventLog.init(allocator, 16);
    defer event_log.deinit();
    var tty_lock = std.Thread.Mutex{};

    const terminal = TerminalSize{ .rows = tty.rows, .cols = tty.cols };
    const session_capacity = @max(profile_names.len, default_wm_session_capacity);
    var sessions = try allocator.alloc(WmProducerSession, session_capacity);
    defer allocator.free(sessions);
    var z_order = try allocator.alloc(usize, session_capacity);
    defer allocator.free(z_order);
    var initialized: usize = 0;
    defer {
        for (sessions[0..initialized]) |*session| {
            closeSessionControl(session);
            if (session.stdout_file) |file| file.close();
            if (session.wait_thread) |thread| thread.join();
            if (session.stdout_thread) |thread| thread.join();
            deinitUploadPolicy(allocator, &session.upload);
            allocator.free(session.profile_name);
        }
    }

    try tty.enableInputCapture();
    for (profile_names, 0..) |profile_name, i| {
        z_order[i] = i;
        sessions[i] = try launchProducerSession(allocator, exe, tty.file, terminal, profile_name, i, &event_log);
        initialized += 1;
        sessions[i].wait_thread = try std.Thread.spawn(.{}, waitChildThread, .{ &sessions[i].child, &sessions[i].wait_state });
    }

    var focused_index: usize = 0;
    const writer = tty.file.deprecatedWriter();
    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
    for (sessions[0..initialized]) |*session| {
        try startSessionStdoutThread(allocator, session, tty.file, &tty_lock);
    }
    logger.writeFmtScoped(.info, .wm, "multi-profile launch count={d}", .{initialized});

    var shutdown_sent = false;
    const keep_alive_when_empty = profile_names.len == 0;
    var input_buf: [256]u8 = undefined;
    var mouse_state = WmMouseInputState{};
    var launch_prompt = std.ArrayList(u8).empty;
    defer launch_prompt.deinit(allocator);
    var prompt_active = false;
    while (!shutdown_sent and (keep_alive_when_empty or !allSessionsDone(sessions[0..initialized]))) {
        const lifecycle = try reconcileExitedSessions(sessions[0..initialized], z_order[0..initialized], &focused_index, &mouse_state, &event_log, &logger);
        if (lifecycle.changed) {
            if (lifecycle.focus_changed or lifecycle.z_order_changed) try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
            try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
        }
        if (prompt_active) {
            const prompt = try readLaunchPromptInput(&tty, &input_buf, &launch_prompt, allocator);
            switch (prompt) {
                .none => {},
                .changed => {
                    try recordLaunchPrompt(&event_log, launch_prompt.items);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                },
                .cancel => {
                    prompt_active = false;
                    launch_prompt.clearRetainingCapacity();
                    try event_log.record(.launch_prompt, "cancelled");
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
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
                        sessions[new_index] = try launchProducerSession(allocator, exe, tty.file, terminal, launch_prompt.items, new_index, &event_log);
                        initialized += 1;
                        sessions[new_index].wait_thread = try std.Thread.spawn(.{}, waitChildThread, .{ &sessions[new_index].child, &sessions[new_index].wait_state });
                        focused_index = new_index;
                        bringWindowToFront(z_order[0..initialized], focused_index);
                        mouse_state = .{};
                        try startSessionStdoutThread(allocator, &sessions[new_index], tty.file, &tty_lock);
                        try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
                    }
                    launch_prompt.clearRetainingCapacity();
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                },
            }
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        }
        if (!shutdown_sent) {
            const input = readInputForSessions(&tty, &input_buf, &mouse_state, sessions[0..initialized], z_order[0..initialized], &focused_index, terminal);
            if (input.focus_changed) {
                try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
                try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
            }
            switch (input.action) {
                .none, .consume => {},
                .start_launch => {
                    prompt_active = true;
                    launch_prompt.clearRetainingCapacity();
                    try recordLaunchPrompt(&event_log, launch_prompt.items);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                },
                .focus_next => {
                    if (nextVisibleSessionIndex(sessions[0..initialized], focused_index)) |next_index| {
                        focused_index = next_index;
                        bringWindowToFront(z_order[0..initialized], focused_index);
                        mouse_state = .{};
                        try event_log.record(.focus_changed, sessions[focused_index].profile_name);
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
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
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
                    }
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                },
                .forward => {
                    if (initialized == 0) continue;
                    try forwardInputToSession(&sessions[focused_index], input.bytes, &event_log, &logger);
                },
                .quit => {
                    shutdown_sent = true;
                    for (sessions[0..initialized]) |*session| try shutdownSession(session, &event_log, &logger);
                    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                },
                .window => |action| {
                    if (initialized == 0) continue;
                    const focused = &sessions[focused_index];
                    if (applyWindowAction(&focused.window, action, terminal)) {
                        try sendViewportForSession(focused, .fit, zBaseForSessionIndex(z_order[0..initialized], focused_index), &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                    }
                },
                .layout => |action| {
                    if (applyLayoutAction(sessions[0..initialized], action, terminal)) {
                        mouse_state = .{};
                        try sendViewportZOrderForSessions(sessions[0..initialized], z_order[0..initialized], .fit, &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                    }
                },
                .mouse_drag => |outer| {
                    if (initialized == 0) continue;
                    const focused = &sessions[focused_index];
                    if (!std.meta.eql(focused.window.outer, outer)) {
                        focused.window.outer = outer;
                        try sendViewportForSession(focused, .fit, zBaseForSessionIndex(z_order[0..initialized], focused_index), &event_log, &logger);
                        try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
                    }
                },
            }
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    for (sessions[0..initialized]) |*session| {
        closeSessionControl(session);
    }
    for (sessions[0..initialized]) |*session| {
        if (session.wait_thread) |thread| {
            thread.join();
            session.wait_thread = null;
        }
        const already_recorded_exit = session.state == .exited;
        session.state = .exited;
        if (session.stdout_thread) |thread| {
            thread.join();
            session.stdout_thread = null;
        }
        if (!already_recorded_exit) try event_log.record(.process_exited, session.profile_name);
    }
    try redrawDesktopManyLocked(&tty_lock, writer, terminal, sessions[0..initialized], z_order[0..initialized], focused_index, &event_log);
    if (shutdown_sent) return 0;
    for (sessions[0..initialized]) |*session| {
        const code = childTermExitCode(session.wait_state.term);
        if (code != 0) return code;
    }
    return 0;
}

fn launchProducerSession(allocator: std.mem.Allocator, exe: []const u8, tty_file: std.fs.File, terminal: TerminalSize, profile_name: []const u8, session_index: usize, events: *ProtocolEventLog) !WmProducerSession {
    var upload = try uploadPolicyForSession(allocator, tty_file, session_index);
    errdefer deinitUploadPolicy(allocator, &upload);

    const owned_profile_name = try allocator.dupe(u8, profile_name);
    errdefer allocator.free(owned_profile_name);

    var child = std.process.Child.init(&.{ exe, "--embed-jsonl", owned_profile_name }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
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
    try writeInitialControl(session.child_stdin.?.deprecatedWriter(), .{
        .rect_cells = session.focusedContent().toPresentationRectCells(),
        .aspect = .fit,
        .z_base = zBaseForSlot(session_index),
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

fn startSessionStdoutThread(allocator: std.mem.Allocator, session: *WmProducerSession, tty_file: std.fs.File, tty_lock: *std.Thread.Mutex) !void {
    if (session.stdout_thread != null) return;
    const stdout_file = session.stdout_file orelse return;
    session.stdout_file = null;
    session.stdout_thread = try std.Thread.spawn(.{}, applyPeerStdoutThread, .{ThreadApplyArgs{
        .allocator = allocator,
        .stdout_file = stdout_file,
        .tty_file = tty_file,
        .tty_lock = tty_lock,
    }});
}

pub fn runExecWithWriter(allocator: std.mem.Allocator, argv: []const []const u8, writer: anytype, options: RunExecOptions) !u8 {
    if (argv.len == 0) return 64;

    const outer = initialOuterRect(options.terminal);
    try renderChrome(writer, .{ .outer = outer, .title = options.title, .focused = true });

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    if (child.stdin) |stdin_file| {
        child.stdin = null;
        try writeInitialControl(stdin_file.deprecatedWriter(), .{
            .rect_cells = contentRectForOuter(outer).toPresentationRectCells(),
            .aspect = options.aspect,
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
        if (session_index < sessions.len and sessionIsVisible(&sessions[session_index]) and rectContainsCell(sessions[session_index].window.outer, cell.row, cell.col)) return session_index;
    }
    return null;
}

fn sessionIsVisible(session: *const WmProducerSession) bool {
    return session.state == .running and !session.wait_state.done.load(.seq_cst);
}

const LifecycleReconcileResult = struct {
    changed: bool = false,
    focus_changed: bool = false,
    z_order_changed: bool = false,
};

fn reconcileExitedSessions(sessions: []WmProducerSession, z_order: []usize, focused_index: *usize, mouse: *WmMouseInputState, events: *ProtocolEventLog, logger: *Logger) !LifecycleReconcileResult {
    var result = LifecycleReconcileResult{};
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
    try moveCursor(writer, options.outer.row, options.outer.col);
    try writer.writeAll(text_box.top_left);
    if (horizontal_len > 1) {
        try writer.writeAll(text_box.horizontal);
        try writer.writeAll(text_box.tee_down);
        try writeRepeated(writer, text_box.horizontal, horizontal_len - 2);
    } else {
        try writeRepeated(writer, text_box.horizontal, horizontal_len);
    }
    try writer.writeAll(text_box.top_right);

    try moveCursor(writer, options.outer.row + 1, options.outer.col);
    try writer.writeAll(text_box.vertical);
    try writer.writeAll("╳");
    try writer.writeAll(text_box.vertical);
    try writer.writeAll(" ");
    const label_prefix = if (options.focused) "*katzensteg wm " else " katzensteg wm ";
    const title_space: usize = @intCast(@max(0, options.outer.cols - 2));
    var written: usize = @min(3, title_space);
    written += try writeTruncated(writer, label_prefix, title_space -| written);
    written += try writeTruncated(writer, options.title, title_space -| written);
    if (written < title_space) try writer.writeByteNTimes(' ', title_space - written);
    try writer.writeAll(text_box.vertical);

    try moveCursor(writer, options.outer.row + 2, options.outer.col);
    try writer.writeAll(text_box.tee_left);
    if (horizontal_len > 1) {
        try writer.writeAll(text_box.horizontal);
        try writer.writeAll(text_box.tee_up);
        try writeRepeated(writer, text_box.horizontal, horizontal_len - 2);
    } else {
        try writeRepeated(writer, text_box.horizontal, horizontal_len);
    }
    try writer.writeAll(text_box.tee_right);

    var row = options.outer.row + 3;
    while (row < options.outer.row + options.outer.rows - 1) : (row += 1) {
        try moveCursor(writer, row, options.outer.col);
        try writer.writeAll(text_box.vertical);
        try moveCursor(writer, row, options.outer.col + options.outer.cols - 1);
        try writer.writeAll(text_box.vertical);
    }

    try moveCursor(writer, options.outer.row + options.outer.rows - 1, options.outer.col);
    try writer.writeAll(text_box.bottom_left);
    try writeRepeated(writer, text_box.horizontal, horizontal_len);
    try writer.writeAll(text_box.bottom_right);

    const content = contentRectForOuter(options.outer);
    try moveCursor(writer, content.row, content.col);
}

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

fn applyPeerStdoutLocked(allocator: std.mem.Allocator, stdout_file: std.fs.File, writer: anytype, tty_lock: *std.Thread.Mutex) !void {
    defer stdout_file.close();
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stdout_file.read(&buf);
        if (n == 0) break;
        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                try applyPeerLineLocked(allocator, writer, tty_lock, line.items);
                line.clearRetainingCapacity();
            } else if (byte != '\r') {
                try line.append(allocator, byte);
            }
        }
    }
    if (line.items.len > 0) try applyPeerLineLocked(allocator, writer, tty_lock, line.items);
}

fn applyPeerLine(allocator: std.mem.Allocator, writer: anytype, line: []const u8) !void {
    var batch = attach_protocol.parseFrameBatch(allocator, line) catch return;
    defer batch.deinit(allocator);
    try terminal_batch_applier.applyFrameBatch(writer, .{
        .deletes = batch.groups.deletes,
        .uploads = batch.groups.uploads,
        .placements = batch.groups.placements,
        .after = batch.groups.after,
    });
}

fn applyPeerLineLocked(allocator: std.mem.Allocator, writer: anytype, tty_lock: *std.Thread.Mutex, line: []const u8) !void {
    var batch = attach_protocol.parseFrameBatch(allocator, line) catch return;
    defer batch.deinit(allocator);
    tty_lock.lock();
    defer tty_lock.unlock();
    try terminal_batch_applier.applyFrameBatch(writer, .{
        .deletes = batch.groups.deletes,
        .uploads = batch.groups.uploads,
        .placements = batch.groups.placements,
        .after = batch.groups.after,
    });
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
};

fn writeViewportControl(writer: anytype, options: ViewportOptions) !void {
    try writer.writeAll("{\"type\":\"viewport\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    try writer.writeAll(",\"rect_cells\":{");
    try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
    try writer.writeAll("},\"aspect\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
    if (options.z_base != 0) try writer.print(",\"z_base\":{d}", .{options.z_base});
    try writer.writeAll("}\n");
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
    return @as(i32, @intCast(@min(slot, @as(usize, 1000)))) * 1000;
}

fn zBaseForSessionIndex(z_order: []const usize, session_index: usize) i32 {
    const slot = std.mem.indexOfScalar(usize, z_order, session_index) orelse 0;
    return zBaseForSlot(slot);
}

fn sendViewportZOrderForSessions(sessions: []WmProducerSession, z_order: []const usize, aspect: render_batch_protocol.PresentationAspect, events: *ProtocolEventLog, logger: *Logger) !void {
    for (sessions, 0..) |*session, session_index| {
        if (!sessionIsVisible(session)) continue;
        try sendViewportForSession(session, aspect, zBaseForSessionIndex(z_order, session_index), events, logger);
    }
}

fn sendViewportForSession(session: *WmProducerSession, aspect: render_batch_protocol.PresentationAspect, z_base: i32, events: *ProtocolEventLog, logger: *Logger) !void {
    if (!session.control_open or !sessionIsVisible(session)) return;
    const content = session.focusedContent();
    if (tryWriteViewportControl(session.child_stdin.?.deprecatedWriter(), .{
        .rect_cells = content.toPresentationRectCells(),
        .aspect = aspect,
        .z_base = z_base,
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
        .direct_apc => .{ .profile = .file_whole, .path = path },
        .file_whole => .{ .profile = .file_whole, .path = path },
        .file_offset_ring => .{ .profile = .file_offset_ring, .path = path },
    };
}

fn deinitUploadPolicy(allocator: std.mem.Allocator, upload: *render_batch_protocol.UploadPolicy) void {
    if (upload.path) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
        allocator.free(path);
    }
    upload.path = null;
}

fn uploadPolicyForSession(allocator: std.mem.Allocator, tty: std.fs.File, session_index: usize) !render_batch_protocol.UploadPolicy {
    var upload = try selectUploadPolicy(allocator, tty);
    errdefer deinitUploadPolicy(allocator, &upload);
    if (upload.path) |path| {
        upload.path = try sessionUploadPath(allocator, path, session_index);
        allocator.free(path);
    }
    return upload;
}

fn sessionUploadPath(allocator: std.mem.Allocator, base_path: []const u8, session_index: usize) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.session-{d}", .{ base_path, session_index });
}

fn runInteractiveExec(allocator: std.mem.Allocator, argv: []const []const u8, tty: *DirectTty, options: RunExecOptions) !u8 {
    if (argv.len == 0) return 64;

    var logger = Logger.init(allocator);
    defer logger.deinit();
    var event_log = ProtocolEventLog.init(allocator, 16);
    defer event_log.deinit();
    var tty_lock = std.Thread.Mutex{};

    var window = WmWindowState.init("main", initialOuterRect(options.terminal));
    const writer = tty.file.deprecatedWriter();
    try tty.enableInputCapture();
    {
        tty_lock.lock();
        defer tty_lock.unlock();
        try renderChrome(writer, .{ .outer = window.outer, .title = options.title, .focused = true });
    }
    try event_log.record(.launch_started, options.title);
    try renderStatusAndReturnLocked(&tty_lock, writer, options.terminal, window, options.upload.profile, &event_log);
    logger.writeFmtScoped(.info, .wm, "launch title={s} terminal={d}x{d}", .{ options.title, options.terminal.cols, options.terminal.rows });

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var child_stdin = child.stdin.?;
    child.stdin = null;
    try writeInitialControl(child_stdin.deprecatedWriter(), .{
        .rect_cells = contentRectForOuter(window.outer).toPresentationRectCells(),
        .aspect = options.aspect,
        .upload = options.upload,
    });
    window.markAttached();
    try event_log.record(.attach_sent, window.window_id);
    try renderStatusAndReturnLocked(&tty_lock, writer, options.terminal, window, options.upload.profile, &event_log);
    logger.writeFmtScoped(.info, .wm, "attach window={s} rect=({d},{d} {d}x{d})", .{ window.window_id, contentRectForOuter(window.outer).row, contentRectForOuter(window.outer).col, contentRectForOuter(window.outer).cols, contentRectForOuter(window.outer).rows });

    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stdout_thread = try std.Thread.spawn(.{}, applyPeerStdoutThread, .{ThreadApplyArgs{
        .allocator = allocator,
        .stdout_file = stdout_file,
        .tty_file = tty.file,
        .tty_lock = &tty_lock,
    }});

    var wait_state = ChildWaitState{};
    const wait_thread = try std.Thread.spawn(.{}, waitChildThread, .{ &child, &wait_state });

    var shutdown_sent = false;
    var stdin_closed = false;
    var control_open = true;
    var input_buf: [256]u8 = undefined;
    var mouse_state = WmMouseInputState{};
    while (!wait_state.done.load(.seq_cst)) {
        if (!shutdown_sent) {
            const input = readInput(tty, &input_buf, &mouse_state, window.outer, options.terminal);
            switch (input.action) {
                .none => {},
                .consume => {},
                .start_launch => {},
                .focus_next => {},
                .forward => {
                    if (control_open) {
                        if (tryWriteInputControl(child_stdin.deprecatedWriter(), input.bytes)) {
                            try event_log.record(.input_sent, window.window_id);
                        } else {
                            logger.writeScoped(.warn, .wm, "input control write failed; producer control pipe is closed");
                            control_open = false;
                        }
                    }
                },
                .quit, .close_focused => {
                    if (control_open and !tryWriteShutdownControl(child_stdin.deprecatedWriter())) {
                        logger.writeScoped(.warn, .wm, "shutdown control write failed; producer control pipe is closed");
                        control_open = false;
                    } else {
                        logger.writeScoped(.info, .wm, "shutdown sent");
                    }
                    try event_log.record(.shutdown_sent, window.window_id);
                    try renderStatusAndReturnLocked(&tty_lock, writer, options.terminal, window, options.upload.profile, &event_log);
                    child_stdin.close();
                    stdin_closed = true;
                    shutdown_sent = true;
                },
                .window => |action| {
                    if (applyWindowAction(&window, action, options.terminal)) {
                        const content = contentRectForOuter(window.outer);
                        if (control_open) {
                            if (tryWriteViewportControl(child_stdin.deprecatedWriter(), .{
                                .rect_cells = content.toPresentationRectCells(),
                                .aspect = options.aspect,
                            })) {
                                try event_log.record(.viewport_sent, window.window_id);
                                logger.writeFmtScoped(.info, .wm, "viewport sent rect=({d},{d} {d}x{d})", .{ content.row, content.col, content.cols, content.rows });
                            } else {
                                logger.writeScoped(.warn, .wm, "viewport control write failed; producer control pipe is closed");
                                control_open = false;
                            }
                        }
                        try redrawDesktopLocked(&tty_lock, writer, options.terminal, window, options.title, options.upload.profile, &event_log);
                    }
                },
                .layout => {},
                .mouse_drag => |outer| {
                    if (!std.meta.eql(window.outer, outer)) {
                        window.outer = outer;
                        const content = contentRectForOuter(window.outer);
                        if (control_open) {
                            if (tryWriteViewportControl(child_stdin.deprecatedWriter(), .{
                                .rect_cells = content.toPresentationRectCells(),
                                .aspect = options.aspect,
                            })) {
                                try event_log.record(.viewport_sent, window.window_id);
                                logger.writeFmtScoped(.info, .wm, "viewport sent rect=({d},{d} {d}x{d})", .{ content.row, content.col, content.cols, content.rows });
                            } else {
                                logger.writeScoped(.warn, .wm, "viewport control write failed; producer control pipe is closed");
                                control_open = false;
                            }
                        }
                        try redrawDesktopLocked(&tty_lock, writer, options.terminal, window, options.title, options.upload.profile, &event_log);
                    }
                },
            }
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    if (!stdin_closed) child_stdin.close();
    wait_thread.join();
    stdout_thread.join();
    logger.writeFmtScoped(.info, .wm, "producer exited {s}", .{childTermSummary(wait_state.term)});
    try event_log.record(.process_exited, childTermSummary(wait_state.term));
    try renderStatusAndReturnLocked(&tty_lock, writer, options.terminal, window, options.upload.profile, &event_log);
    if (shutdown_sent) return 0;
    return childTermExitCode(wait_state.term);
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

const ThreadApplyArgs = struct {
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    tty_file: std.fs.File,
    tty_lock: *std.Thread.Mutex,
};

fn applyPeerStdoutThread(args: ThreadApplyArgs) void {
    applyPeerStdoutLocked(args.allocator, args.stdout_file, args.tty_file.deprecatedWriter(), args.tty_lock) catch {};
}

const ChildWaitState = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    term: std.process.Child.Term = .{ .Unknown = 0 },
};

fn waitChildThread(child: *std.process.Child, state: *ChildWaitState) void {
    state.term = child.wait() catch .{ .Unknown = 0 };
    state.done.store(true, .seq_cst);
}

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

fn readInputForSessions(tty: *DirectTty, buf: []u8, mouse: *WmMouseInputState, sessions: []const WmProducerSession, z_order: []usize, focused_index: *usize, terminal: TerminalSize) InputRead {
    const n = std.posix.read(tty.file.handle, buf) catch return .{ .action = .none };
    if (n == 0) return .{ .action = .none };
    const bytes = buf[0..n];
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

fn redrawDesktop(writer: anytype, terminal: TerminalSize, window: WmWindowState, title: []const u8, upload_profile: render_batch_protocol.UploadProfile, events: *const ProtocolEventLog) !void {
    try writer.writeAll("\x1b[2J");
    try renderChrome(writer, .{ .outer = window.outer, .title = title, .focused = true });
    try renderStatusAndReturn(writer, terminal, window, upload_profile, events);
}

fn redrawDesktopLocked(tty_lock: *std.Thread.Mutex, writer: anytype, terminal: TerminalSize, window: WmWindowState, title: []const u8, upload_profile: render_batch_protocol.UploadProfile, events: *const ProtocolEventLog) !void {
    tty_lock.lock();
    defer tty_lock.unlock();
    try redrawDesktop(writer, terminal, window, title, upload_profile, events);
}

fn redrawDesktopManyLocked(tty_lock: *std.Thread.Mutex, writer: anytype, terminal: TerminalSize, sessions: []const WmProducerSession, z_order: []const usize, focused_index: usize, events: *const ProtocolEventLog) !void {
    tty_lock.lock();
    defer tty_lock.unlock();
    try writer.writeAll("\x1b[2J");
    for (z_order) |session_index| {
        if (session_index >= sessions.len) continue;
        const session = &sessions[session_index];
        if (!sessionIsVisible(session)) continue;
        try renderChrome(writer, .{
            .outer = session.window.outer,
            .title = session.profile_name,
            .focused = session_index == focused_index,
        });
    }
    if (visibleStatusSessionIndex(sessions, focused_index)) |status_index| {
        const focused = sessions[status_index];
        try renderStatusAndReturn(writer, terminal, focused.window, focused.upload.profile, events);
    } else {
        try renderEmptyStatusAndReturn(writer, terminal, events);
    }
}

fn visibleStatusSessionIndex(sessions: []const WmProducerSession, focused_index: usize) ?usize {
    if (sessions.len == 0) return null;
    const clamped = @min(focused_index, sessions.len - 1);
    if (sessionIsVisible(&sessions[clamped])) return clamped;
    for (sessions, 0..) |*session, index| {
        if (sessionIsVisible(session)) return index;
    }
    return null;
}

fn renderStatusAndReturn(writer: anytype, terminal: TerminalSize, window: WmWindowState, upload_profile: render_batch_protocol.UploadProfile, events: *const ProtocolEventLog) !void {
    try renderStatusBand(writer, .{
        .terminal = terminal,
        .window = window,
        .upload_profile = upload_profile,
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

fn renderStatusAndReturnLocked(tty_lock: *std.Thread.Mutex, writer: anytype, terminal: TerminalSize, window: WmWindowState, upload_profile: render_batch_protocol.UploadProfile, events: *const ProtocolEventLog) !void {
    tty_lock.lock();
    defer tty_lock.unlock();
    try renderStatusAndReturn(writer, terminal, window, upload_profile, events);
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
    out.row = @max(1, out.row);
    out.col = @max(1, out.col);

    const max_row = @max(1, terminal.rows - out.rows + 1);
    const max_col = @max(1, terminal.cols - out.cols + 1);
    out.row = @min(out.row, max_row);
    out.col = @min(out.col, max_col);
    return out;
}

test "wm window derives content rect inside text chrome" {
    const outer = Rect{ .row = 1, .col = 1, .rows = 20, .cols = 80 };
    const content = contentRectForOuter(outer);
    try std.testing.expectEqual(Rect{ .row = 4, .col = 2, .rows = 16, .cols = 78 }, content);
}

test "wm window clamps outer rect to terminal" {
    const clamped = clampOuterRect(
        .{ .row = 20, .col = 75, .rows = 10, .cols = 20 },
        .{ .rows = 24, .cols = 80 },
    );
    try std.testing.expect(clamped.row >= 1);
    try std.testing.expect(clamped.col >= 1);
    try std.testing.expect(clamped.row + clamped.rows - 1 <= 24);
    try std.testing.expect(clamped.col + clamped.cols - 1 <= 80);
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
    var log = ProtocolEventLog.init(std.testing.allocator, 3);
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

    var log = ProtocolEventLog.init(std.testing.allocator, 2);
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

test "wm desktop can render with no producer sessions" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var log = ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    try log.record(.launch_prompt, "launch:");
    var tty_lock = std.Thread.Mutex{};
    const sessions = [_]WmProducerSession{};
    const z_order = [_]usize{};

    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "windows=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "last=launch_prompt launch:") != null);
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

test "wm upload policy honors file profile choices without direct apc" {
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_whole, uploadPolicyForOutputProfile("/tmp/wm-upload", .file_whole).profile);
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_offset_ring, uploadPolicyForOutputProfile("/tmp/wm-upload", .file_offset_ring).profile);
    try std.testing.expectEqual(render_batch_protocol.UploadProfile.file_whole, uploadPolicyForOutputProfile("/tmp/wm-upload", .direct_apc).profile);
}

test "wm exec path renders chrome and applies fake peer frame batch" {
    const script_path = "/tmp/katzensteg-wm-fake-peer.py";
    {
        const file = try std.fs.createFileAbsolute(script_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            "import sys\n" ++
                "sys.stdin.readline()\n" ++
                "sys.stdin.readline()\n" ++
                "sys.stdout.write('{\"type\":\"frame_batch\",\"window_id\":\"main\",\"seq\":1,\"groups\":{\"deletes\":[\"D\"],\"uploads\":[\"U\"],\"placements\":[\"P\"],\"after\":[\"A\"]}}\\n')\n" ++
                "sys.stdout.flush()\n",
        );
    }
    defer std.fs.deleteFileAbsolute(script_path) catch {};

    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const code = try runExecWithWriter(std.testing.allocator, &.{ "python3", script_path }, out.writer(std.testing.allocator), .{
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

test "wm desktop tracks multiple windows and focused index" {
    var desktop = WmDesktopState.init(std.testing.allocator);
    defer desktop.deinit();

    try desktop.addWindow("one", .{ .row = 1, .col = 1, .rows = 10, .cols = 30 });
    try desktop.addWindow("two", .{ .row = 3, .col = 5, .rows = 10, .cols = 30 });

    try std.testing.expectEqual(@as(usize, 2), desktop.windows.items.len);
    try std.testing.expectEqualStrings("one", desktop.focusedWindow().?.window_id);
    desktop.focusNext();
    try std.testing.expectEqualStrings("two", desktop.focusedWindow().?.window_id);
    desktop.focusNext();
    try std.testing.expectEqualStrings("one", desktop.focusedWindow().?.window_id);
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
    const z_order = [_]usize{ 0, 1 };

    try std.testing.expectEqual(@as(?usize, 1), hitWindowIndex(windows[0..], z_order[0..], .{ .row = 5, .col = 10 }));
    try std.testing.expectEqual(@as(?usize, 0), hitWindowIndex(windows[0..], z_order[0..], .{ .row = 2, .col = 2 }));
}

test "wm closed producer sessions stop drawing and hit testing immediately" {
    var sessions = [_]WmProducerSession{
        .{
            .profile_name = "active",
            .window = WmWindowState.init("main", .{ .row = 1, .col = 1, .rows = 12, .cols = 40 }),
            .upload = .{ .profile = .direct_apc },
            .child = std.process.Child.init(&.{"true"}, std.testing.allocator),
            .state = .running,
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
    var log = ProtocolEventLog.init(std.testing.allocator, 1);
    defer log.deinit();
    var tty_lock = std.Thread.Mutex{};
    try redrawDesktopManyLocked(&tty_lock, out.writer(std.testing.allocator), .{ .rows = 24, .cols = 80 }, sessions[0..], z_order[0..], 0, &log);

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
    var log = ProtocolEventLog.init(std.testing.allocator, 4);
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
