const std = @import("std");
const render_batch_protocol = @import("render_batch_protocol.zig");
const attach_protocol = @import("attach_protocol.zig");
const terminal_batch_applier = @import("terminal_batch_applier.zig");
const DirectTty = @import("direct_tty.zig").DirectTty;
const Logger = @import("log.zig").Logger;
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
    attach_sent,
    viewport_sent,
    input_sent,
    detach_sent,
    detached_received,
    shutdown_sent,
    process_exited,
    parse_error,
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

const text_box = struct {
    const top_left = "┌";
    const top_right = "┐";
    const bottom_left = "└";
    const bottom_right = "┘";
    const tee_left = "├";
    const tee_right = "┤";
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
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    var tty = try DirectTty.init();
    defer tty.deinit();
    var upload = try selectUploadPolicy(allocator, tty.file);
    defer deinitUploadPolicy(allocator, &upload);

    return runInteractiveExec(allocator, &.{ exe, "--embed-jsonl", profile_name }, &tty, .{
        .title = profile_name,
        .terminal = .{ .rows = tty.rows, .cols = tty.cols },
        .upload = upload,
    });
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

pub fn renderChrome(writer: anytype, options: ChromeOptions) !void {
    if (options.outer.rows < 3 or options.outer.cols < 4) return;

    const horizontal_len: usize = @intCast(@max(0, options.outer.cols - 2));
    try moveCursor(writer, options.outer.row, options.outer.col);
    try writer.writeAll(text_box.top_left);
    try writeRepeated(writer, text_box.horizontal, horizontal_len);
    try writer.writeAll(text_box.top_right);

    try moveCursor(writer, options.outer.row + 1, options.outer.col);
    try writer.writeAll(text_box.vertical);
    const label_prefix = " katzensteg wm: ";
    const title_space: usize = @intCast(@max(0, options.outer.cols - 2));
    var written: usize = 0;
    written += try writeTruncated(writer, label_prefix, title_space -| written);
    written += try writeTruncated(writer, options.title, title_space -| written);
    if (written < title_space) try writer.writeByteNTimes(' ', title_space - written);
    try writer.writeAll(text_box.vertical);

    try moveCursor(writer, options.outer.row + 2, options.outer.col);
    try writer.writeAll(text_box.tee_left);
    try writeRepeated(writer, text_box.horizontal, horizontal_len);
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
};

fn writeViewportControl(writer: anytype, options: ViewportOptions) !void {
    try writer.writeAll("{\"type\":\"viewport\",\"window_id\":");
    try render_batch_protocol.writeJsonString(writer, options.window_id);
    try writer.writeAll(",\"rect_cells\":{");
    try writer.print("\"row\":{d},\"col\":{d},\"rows\":{d},\"cols\":{d}", .{ options.rect_cells.row, options.rect_cells.col, options.rect_cells.rows, options.rect_cells.cols });
    try writer.writeAll("},\"aspect\":");
    try render_batch_protocol.writeJsonString(writer, @tagName(options.aspect));
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

fn selectUploadPolicy(allocator: std.mem.Allocator, tty: std.fs.File) !render_batch_protocol.UploadPolicy {
    const path = try upload_path_mod.makeUploadPath(allocator);
    errdefer allocator.free(path);
    {
        const probe_file = try std.fs.createFileAbsolute(path, .{ .read = true, .truncate = true });
        defer probe_file.close();
        try probe_file.writeAll(&[_]u8{ 0, 0, 0, 255 });
    }
    const profile = if (ts_kitty.capabilities.probe(allocator, tty, path)) |caps|
        ts_kitty.profile.choose(caps)
    else |_|
        .file_whole;
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
    while (!wait_state.done.load(.seq_cst)) {
        if (!shutdown_sent) {
            const input = readInput(tty, &input_buf, contentRectForOuter(window.outer));
            switch (input.action) {
                .none => {},
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
                .quit => {
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
    forward,
    quit,
    window: WindowAction,
};

const InputRead = struct {
    action: InputAction,
    bytes: []const u8 = "",
};

fn readInput(tty: *DirectTty, buf: []u8, content: Rect) InputRead {
    const n = std.posix.read(tty.file.handle, buf) catch return .{ .action = .none };
    if (n == 0) return .{ .action = .none };
    const bytes = buf[0..n];
    const action = inputActionFromBytes(bytes);
    if (action != .none) return .{ .action = action };
    const filtered = filterForwardedInputBytes(bytes, content);
    if (filtered.len > 0) return .{ .action = .forward, .bytes = filtered };
    return .{ .action = .none };
}

fn inputActionFromBytes(bytes: []const u8) InputAction {
    for (bytes) |byte| {
        switch (byte) {
            'q', 'Q' => return .quit,
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
            else => {},
        }
    }
    return .none;
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

const ParsedSgrMouse = struct {
    row: i32,
    col: i32,
    len: usize,
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
    _ = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const col = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const row = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    return .{ .row = row, .col = col, .len = final - start + 1 };
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
        .outer = .{ .row = 1, .col = 1, .rows = 6, .cols = 24 },
        .title = "probe",
        .focused = true,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.items, "probe") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "katzensteg wm") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "katzensteg wm: fake") != null);
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
    try std.testing.expectEqual(InputAction{ .window = .move_right }, inputActionFromBytes("l"));
}
