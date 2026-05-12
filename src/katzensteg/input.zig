const std = @import("std");
const presentation_layout = @import("presentation_layout.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");

const max_pending_bytes = 256;
const keyboard_poll_hold_ns: i128 = 150 * std.time.ns_per_ms;

pub const sdl_num_scancodes = 512;
pub const sdl_event_key_down = 0x300;
pub const sdl_event_key_up = 0x301;
pub const sdl_event_text_input = 0x303;
pub const sdl_event_mouse_motion = 0x400;
pub const sdl_event_mouse_button_down = 0x401;
pub const sdl_event_mouse_button_up = 0x402;
pub const sdl_event_mouse_wheel = 0x403;

pub const Target = struct {
    cols: i32 = 80,
    rows: i32 = 24,
    w: i32 = 640,
    h: i32 = 480,
    layout: presentation_layout.PresentationLayout = .{},
};

pub const KeyEvent = struct {
    keycode: i32,
    scancode: i32,
    mods: u16 = 0,
};

pub const TextEvent = struct {
    buf: [32]u8 = [_]u8{0} ** 32,

    pub fn init(bytes_in: []const u8) TextEvent {
        var event = TextEvent{};
        const n = @min(bytes_in.len, event.buf.len - 1);
        @memcpy(event.buf[0..n], bytes_in[0..n]);
        return event;
    }

    pub fn bytes(self: *const TextEvent) []const u8 {
        return std.mem.sliceTo(&self.buf, 0);
    }
};

pub const MouseMotionEvent = struct {
    x: i32,
    y: i32,
    xrel: i32,
    yrel: i32,
    buttons: u32 = 0,
};

pub const MouseButtonEvent = struct {
    x: i32,
    y: i32,
    button: u8,
    pressed: bool,
    clicks: u8 = 1,
    buttons: u32 = 0,
};

pub const MouseWheelEvent = struct {
    x: i32,
    y: i32,
    mouse_x: i32,
    mouse_y: i32,
};

pub const MouseState = struct {
    x: i32,
    y: i32,
    xrel: i32 = 0,
    yrel: i32 = 0,
    buttons: u32,
};

pub const RelativeMouseBaseline = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn snap(self: *RelativeMouseBaseline, current: MouseState) MouseState {
        const relative = MouseState{
            .x = current.x,
            .y = current.y,
            .xrel = current.x - self.x,
            .yrel = current.y - self.y,
            .buttons = current.buttons,
        };
        self.x = current.x;
        self.y = current.y;
        return relative;
    }
};

pub const MouseOwner = enum {
    terminal,
    real_window,
};

pub const MouseOwnership = struct {
    owner: MouseOwner = .terminal,

    pub fn claimTerminal(self: *MouseOwnership) void {
        self.owner = .terminal;
    }

    pub fn claimRealWindow(self: *MouseOwnership) void {
        self.owner = .real_window;
    }

    pub fn terminalOwns(self: MouseOwnership) bool {
        return self.owner == .terminal;
    }
};

pub const InputEvent = union(enum) {
    key_down: KeyEvent,
    key_up: KeyEvent,
    text: TextEvent,
    mouse_motion: MouseMotionEvent,
    mouse_button: MouseButtonEvent,
    mouse_wheel: MouseWheelEvent,
};

pub const TerminalInputParser = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(InputEvent),
    pending: std.ArrayList(u8),
    target: Target = .{},
    last_mouse_x: i32 = 0,
    last_mouse_y: i32 = 0,
    mouse_buttons: u32 = 0,
    mouse_activity: bool = false,
    // Set after an ESC/CSI sequence is consumed without producing a valid
    // event. Causes the next parseOne call to look for an orphan-mouse-tail
    // (e.g. residual `4;47;44M` bytes left after a partial mouse CSI).
    // Cleared after that one lookup, so arbitrary printable input that happens
    // to look like a mouse tail isn't silently captured.
    expect_orphan_mouse_tail: bool = false,
    keyboard_state: [sdl_num_scancodes]u8 = [_]u8{0} ** sdl_num_scancodes,
    keyboard_deadline_ns: [sdl_num_scancodes]i128 = [_]i128{0} ** sdl_num_scancodes,

    pub fn init(allocator: std.mem.Allocator) TerminalInputParser {
        return .{
            .allocator = allocator,
            .queue = .empty,
            .pending = .empty,
        };
    }

    pub fn deinit(self: *TerminalInputParser) void {
        self.queue.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    pub fn setTarget(self: *TerminalInputParser, target: Target) void {
        self.target = .{
            .cols = @max(1, target.cols),
            .rows = @max(1, target.rows),
            .w = @max(1, target.w),
            .h = @max(1, target.h),
            .layout = target.layout,
        };
    }

    pub fn feed(self: *TerminalInputParser, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.pending.items.len + bytes.len > max_pending_bytes) self.pending.clearRetainingCapacity();
        try self.pending.appendSlice(self.allocator, bytes);
        try self.parsePending();
    }

    pub fn pendingCount(self: *const TerminalInputParser) usize {
        return self.queue.items.len;
    }

    pub fn mouseState(self: *const TerminalInputParser) MouseState {
        return .{
            .x = self.last_mouse_x,
            .y = self.last_mouse_y,
            .buttons = self.mouse_buttons,
        };
    }

    pub fn takeMouseActivity(self: *TerminalInputParser) bool {
        const active = self.mouse_activity;
        self.mouse_activity = false;
        return active;
    }

    pub fn copyKeyboardState(self: *TerminalInputParser, out: []u8, now_ns: i128) void {
        self.expireKeyboardState(now_ns);
        const n = @min(out.len, self.keyboard_state.len);
        @memcpy(out[0..n], self.keyboard_state[0..n]);
    }

    pub fn pop(self: *TerminalInputParser) ?InputEvent {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    pub fn popSdlRange(self: *TerminalInputParser, min_type: u32, max_type: u32) ?InputEvent {
        for (self.queue.items, 0..) |event, idx| {
            const event_type = inputEventSdlType(event);
            if (event_type >= min_type and event_type <= max_type) return self.queue.orderedRemove(idx);
        }
        return null;
    }

    pub fn flushStandaloneEscape(self: *TerminalInputParser) !void {
        if (self.pending.items.len == 1 and self.pending.items[0] == 0x1b) {
            try self.emitKey(.{ .keycode = 0x1b, .scancode = 41 });
            self.pending.clearRetainingCapacity();
            // If a partial mouse CSI was fragmented across reads, the tail
            // bytes could arrive after this flush — let the next parseOne
            // pass try to consume them as an orphan-mouse-tail cleanup.
            self.expect_orphan_mouse_tail = true;
        }
    }

    fn parsePending(self: *TerminalInputParser) !void {
        while (self.pending.items.len > 0) {
            const consumed = try self.parseOne(self.pending.items);
            if (consumed == 0) break;
            std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - consumed], self.pending.items[consumed..]);
            self.pending.items.len -= consumed;
        }
    }

    fn parseOne(self: *TerminalInputParser, bytes: []const u8) !usize {
        const first = bytes[0];
        if (first == 0x1b) {
            if (try self.parseEscape(bytes)) |consumed| {
                self.expect_orphan_mouse_tail = false;
                return consumed;
            }
            if (isIncompleteEscape(bytes)) return 0;
            try self.emitKey(.{ .keycode = 0x1b, .scancode = 41 });
            self.expect_orphan_mouse_tail = true;
            return 1;
        }
        if (first == 0x9b) {
            if (try self.parseCsi(bytes, 1)) |consumed| {
                self.expect_orphan_mouse_tail = false;
                return consumed;
            }
            if (isIncompleteCsi(bytes, 1)) return 0;
            self.expect_orphan_mouse_tail = true;
            return 1;
        }
        if (self.expect_orphan_mouse_tail) {
            self.expect_orphan_mouse_tail = false;
            if (try self.parseOrphanMouseTail(bytes)) |consumed| return consumed;
        }
        if (first == '\r' or first == '\n') {
            try self.emitKey(.{ .keycode = '\r', .scancode = 40 });
            return 1;
        }
        if (first == '\t') {
            try self.emitKey(.{ .keycode = '\t', .scancode = 43 });
            return 1;
        }
        if (first == 0x7f or first == 0x08) {
            try self.emitKey(.{ .keycode = 0x08, .scancode = 42 });
            return 1;
        }
        if (first >= 0x20) {
            const key = asciiKey(first);
            try self.emitTextAndKey(bytes[0..1], key);
            return 1;
        }
        return 1;
    }

    fn parseEscape(self: *TerminalInputParser, bytes: []const u8) !?usize {
        if (bytes.len < 2) return null;
        if (bytes[1] != '[') return null;
        if (bytes.len < 3) return null;

        return try self.parseCsi(bytes, 2);
    }

    fn parseCsi(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        if (bytes.len <= start) return null;

        switch (bytes[start]) {
            'A' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82 });
                return start + 1;
            },
            'B' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(81), .scancode = 81 });
                return start + 1;
            },
            'C' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(79), .scancode = 79 });
                return start + 1;
            },
            'D' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(80), .scancode = 80 });
                return start + 1;
            },
            'H' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(74), .scancode = 74 });
                return start + 1;
            },
            'F' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(77), .scancode = 77 });
                return start + 1;
            },
            '<' => return try self.parseSgrMouse(bytes, start),
            'M' => return try self.parseLegacyMouse(bytes, start),
            else => {},
        }

        if (std.ascii.isDigit(bytes[start])) {
            if (try self.parseUrxvtMouse(bytes, start)) |consumed| return consumed;
        }

        if (bytes[start] == '3' and bytes.len > start + 1 and bytes[start + 1] == '~') {
            try self.emitKey(.{ .keycode = 0x7f, .scancode = 76 });
            return start + 2;
        }
        if (csiFinalIndex(bytes, start)) |final| return final + 1;
        return null;
    }

    fn parseLegacyMouse(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        if (bytes.len < start + 4) return null;
        const consumed = start + 4;
        const b = decodeLegacyMouseByte(bytes[start + 1]) orelse return consumed;
        const cell_x = decodeLegacyMouseByte(bytes[start + 2]) orelse return consumed;
        const cell_y = decodeLegacyMouseByte(bytes[start + 3]) orelse return consumed;
        const pressed = (b & 3) != 3;
        try self.emitMouseCode(b, cell_x, cell_y, pressed);
        return consumed;
    }

    fn parseUrxvtMouse(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        const final = csiFinalIndex(bytes, start) orelse return null;
        if (bytes[final] != 'M') return null;
        var fields = std.mem.splitScalar(u8, bytes[start..final], ';');
        const b = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_x = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_y = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        try self.emitMouseCode(b, cell_x, cell_y, true);
        return final + 1;
    }

    fn parseSgrMouse(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        var end: ?usize = null;
        var i: usize = start + 1;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 'M' or bytes[i] == 'm') {
                end = i;
                break;
            }
        }
        const final = end orelse return null;
        var fields = std.mem.splitScalar(u8, bytes[start + 1 .. final], ';');
        const b = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_x = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_y = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const pressed = bytes[final] == 'M';
        try self.emitMouseCode(b, cell_x, cell_y, pressed);
        return final + 1;
    }

    fn parseOrphanMouseTail(self: *TerminalInputParser, bytes: []const u8) !?usize {
        if (bytes.len == 0) return null;
        if (bytes[0] == ';') {
            if (orphanTailFinalIndex(bytes)) |final| return final + 1;
            return null;
        }
        if (!std.ascii.isDigit(bytes[0])) return null;
        const final = orphanTailFinalIndex(bytes) orelse return null;
        var fields = std.mem.splitScalar(u8, bytes[0..final], ';');
        const b = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
        const cell_x = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
        const cell_y = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
        if (fields.next() != null) return null;
        if (b == 4 or b == 5 or (b & 64) != 0) {
            try self.emitMouseCode(b, cell_x, cell_y, true);
            return final + 1;
        }
        return null;
    }

    // Inject a structured pointer event (delivered over embed-jsonl by a host
    // that already has parsed input — e.g. the pi-extension getting events from
    // pi-tui). Bypasses the SGR parser entirely; produces the same InputEvent
    // variants as emitMouseCode so downstream code is identical.
    //
    // Convention note: the wire format uses DOM/pi-tui sign for deltas
    // (deltaY positive = scroll down, deltaX positive = scroll right). SDL's
    // mouse_wheel.y is opposite (positive = away from user = up), so deltaY is
    // negated when translating. deltaX maps directly.
    pub fn injectPointer(self: *TerminalInputParser, event: render_batch_protocol.PointerEventPayload) !void {
        const point = self.mapCellToSdl(event.col, event.row) orelse return;
        const x = point.x;
        const y = point.y;

        switch (event.kind) {
            .wheel => {
                // Only line-mode deltas are normalised today. Pixel- and page-mode
                // wheel events would need scaling (e.g. pixel/100 → line) to avoid
                // emitting hundreds of wheel ticks per notch from a high-resolution
                // wheel. The only current host (pi-extension) always emits line mode;
                // when a producer needs pixel or page support we add the translation
                // here rather than letting wrong deltas through silently.
                if (event.delta_mode != .line) return;
                try self.queue.append(self.allocator, .{ .mouse_wheel = .{
                    .x = roundWheelDelta(event.delta_x),
                    .y = -roundWheelDelta(event.delta_y),
                    .mouse_x = x,
                    .mouse_y = y,
                } });
            },
            .pointermove => {
                const xrel = x - self.last_mouse_x;
                const yrel = y - self.last_mouse_y;
                self.mouse_buttons = event.buttons;
                try self.queue.append(self.allocator, .{ .mouse_motion = .{
                    .x = x,
                    .y = y,
                    .xrel = xrel,
                    .yrel = yrel,
                    .buttons = self.mouse_buttons,
                } });
            },
            .pointerdown, .pointerup => {
                // event.button is i32 from the wire. The lower bound rejects -1
                // ("no button" sentinel used for motion/wheel). The upper bound
                // prevents @intCast panicking on out-of-range values; any value
                // beyond the known pointer indices is rejected outright rather
                // than mapped to a default button.
                if (event.button < 0 or event.button > 255) return;
                const sdl_button = sdlButtonFromPointerIndex(@intCast(event.button));
                self.mouse_buttons = event.buttons;
                try self.queue.append(self.allocator, .{ .mouse_button = .{
                    .x = x,
                    .y = y,
                    .button = sdl_button,
                    .pressed = event.kind == .pointerdown,
                    .buttons = self.mouse_buttons,
                } });
            },
        }
        self.last_mouse_x = x;
        self.last_mouse_y = y;
        self.mouse_activity = true;
    }

    fn emitMouseCode(self: *TerminalInputParser, b: i32, cell_x: i32, cell_y: i32, pressed: bool) !void {
        const point = self.mapCellToSdl(cell_x, cell_y) orelse {
            // For now, terminal chrome/letterbox cells do not target SDL. Keep
            // button state and last mouse position unchanged until region
            // routing can synthesize enter/leave or chrome-owned events.
            return;
        };
        const x = point.x;
        const y = point.y;
        const xrel = x - self.last_mouse_x;
        const yrel = y - self.last_mouse_y;

        if ((b & 64) != 0 or b == 4 or b == 5) {
            try self.queue.append(self.allocator, .{ .mouse_wheel = .{
                .x = 0,
                .y = if ((b & 1) == 0) 1 else -1,
                .mouse_x = x,
                .mouse_y = y,
            } });
        } else if ((b & 32) != 0) {
            try self.queue.append(self.allocator, .{ .mouse_motion = .{
                .x = x,
                .y = y,
                .xrel = xrel,
                .yrel = yrel,
                .buttons = self.mouse_buttons,
            } });
        } else {
            const button = terminalButtonToSdl(@intCast(b & 3));
            if (pressed) {
                self.mouse_buttons |= sdlButtonMask(button);
            } else if ((b & 3) == 3) {
                self.mouse_buttons = 0;
            } else {
                self.mouse_buttons &= ~sdlButtonMask(button);
            }
            try self.queue.append(self.allocator, .{ .mouse_button = .{
                .x = x,
                .y = y,
                .button = button,
                .pressed = pressed,
                .buttons = self.mouse_buttons,
            } });
        }
        self.last_mouse_x = x;
        self.last_mouse_y = y;
        self.mouse_activity = true;
    }

    fn emitTextAndKey(self: *TerminalInputParser, bytes: []const u8, key: KeyEvent) !void {
        self.holdKeyForPolling(key);
        try self.queue.append(self.allocator, .{ .key_down = key });
        try self.queue.append(self.allocator, .{ .text = TextEvent.init(bytes) });
        try self.queue.append(self.allocator, .{ .key_up = key });
    }

    fn emitKey(self: *TerminalInputParser, key: KeyEvent) !void {
        self.holdKeyForPolling(key);
        try self.queue.append(self.allocator, .{ .key_down = key });
        try self.queue.append(self.allocator, .{ .key_up = key });
    }

    fn holdKeyForPolling(self: *TerminalInputParser, key: KeyEvent) void {
        if (key.scancode < 0) return;
        const idx: usize = @intCast(key.scancode);
        if (idx >= self.keyboard_state.len) return;
        self.keyboard_state[idx] = 1;
        self.keyboard_deadline_ns[idx] = std.time.nanoTimestamp() + keyboard_poll_hold_ns;
    }

    fn expireKeyboardState(self: *TerminalInputParser, now_ns: i128) void {
        for (&self.keyboard_state, self.keyboard_deadline_ns) |*state, deadline| {
            if (state.* != 0 and deadline <= now_ns) state.* = 0;
        }
    }

    fn mapCellX(self: *const TerminalInputParser, cell_x: i32) i32 {
        return @divTrunc((std.math.clamp(cell_x, 1, self.target.cols) - 1) * self.target.w, self.target.cols);
    }

    fn mapCellY(self: *const TerminalInputParser, cell_y: i32) i32 {
        return @divTrunc((std.math.clamp(cell_y, 1, self.target.rows) - 1) * self.target.h, self.target.rows);
    }

    fn mapCellToSdl(self: *const TerminalInputParser, cell_x: i32, cell_y: i32) ?presentation_layout.Point {
        if (self.target.layout.len > 0) return self.target.layout.mapCellToSdl(cell_x, cell_y);
        return .{
            .x = self.mapCellX(cell_x),
            .y = self.mapCellY(cell_y),
        };
    }
};

pub fn sdlKeycodeFromScancode(scancode: i32) i32 {
    return scancode | (1 << 30);
}

fn sdlButtonMask(button: u8) u32 {
    return @as(u32, 1) << @intCast(button - 1);
}

fn terminalButtonToSdl(button: u2) u8 {
    return switch (button) {
        0 => 1,
        1 => 2,
        2 => 3,
        else => 1,
    };
}

// Map a pointer-event button index (0=left, 1=middle, 2=right, 3=back, 4=forward)
// to SDL's mouse button enum (1=left, 2=middle, 3=right, 4=X1, 5=X2).
fn sdlButtonFromPointerIndex(button: u8) u8 {
    return switch (button) {
        0 => 1,
        1 => 2,
        2 => 3,
        3 => 4,
        4 => 5,
        else => 1,
    };
}

fn roundWheelDelta(v: f64) i32 {
    if (v >= 0) return @intFromFloat(v + 0.5);
    return @intFromFloat(v - 0.5);
}

fn decodeLegacyMouseByte(byte: u8) ?i32 {
    if (byte < 32) return null;
    return @as(i32, byte) - 32;
}

fn isIncompleteEscape(bytes: []const u8) bool {
    if (bytes.len == 1) return true;
    if (bytes[1] != '[') return false;
    if (bytes.len == 2) return true;
    return isIncompleteCsi(bytes, 2);
}

fn isIncompleteCsi(bytes: []const u8, start: usize) bool {
    if (bytes.len <= start) return true;
    if (bytes[start] == 'M') return bytes.len < start + 4;
    return csiFinalIndex(bytes, start) == null;
}

fn csiFinalIndex(bytes: []const u8, start: usize) ?usize {
    if (bytes.len <= start) return null;
    var i: usize = start;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] >= 0x40 and bytes[i] <= 0x7e) return i;
    }
    return null;
}

fn orphanTailFinalIndex(bytes: []const u8) ?usize {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b == 'M' or b == 'm') return i;
        if (!(std.ascii.isDigit(b) or b == ';')) return null;
    }
    return null;
}

fn asciiKey(byte: u8) KeyEvent {
    if (byte >= 'a' and byte <= 'z') {
        return .{ .keycode = byte, .scancode = 4 + byte - 'a' };
    }
    if (byte >= 'A' and byte <= 'Z') {
        return .{ .keycode = std.ascii.toLower(byte), .scancode = 4 + std.ascii.toLower(byte) - 'a', .mods = 0x0003 };
    }
    if (byte >= '1' and byte <= '9') {
        return .{ .keycode = byte, .scancode = 30 + byte - '1' };
    }
    if (byte == '0') return .{ .keycode = byte, .scancode = 39 };
    return switch (byte) {
        ' ' => .{ .keycode = byte, .scancode = 44 },
        '-' => .{ .keycode = byte, .scancode = 45 },
        '=' => .{ .keycode = byte, .scancode = 46 },
        '[' => .{ .keycode = byte, .scancode = 47 },
        ']' => .{ .keycode = byte, .scancode = 48 },
        '\\' => .{ .keycode = byte, .scancode = 49 },
        ';' => .{ .keycode = byte, .scancode = 51 },
        '\'' => .{ .keycode = byte, .scancode = 52 },
        '`' => .{ .keycode = byte, .scancode = 53 },
        ',' => .{ .keycode = byte, .scancode = 54 },
        '.' => .{ .keycode = byte, .scancode = 55 },
        '/' => .{ .keycode = byte, .scancode = 56 },
        else => .{ .keycode = byte, .scancode = 0 },
    };
}

fn inputEventSdlType(event: InputEvent) u32 {
    return switch (event) {
        .key_down => sdl_event_key_down,
        .key_up => sdl_event_key_up,
        .text => sdl_event_text_input,
        .mouse_motion => sdl_event_mouse_motion,
        .mouse_button => |button| if (button.pressed) sdl_event_mouse_button_down else sdl_event_mouse_button_up,
        .mouse_wheel => sdl_event_mouse_wheel,
    };
}

test "terminal input parser emits printable key text and key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    try std.testing.expectEqual(@as(usize, 3), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.pop().?);
}

test "terminal input parser can pop events by SDL type range" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.popSdlRange(sdl_event_key_down, sdl_event_key_up).?);
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.popSdlRange(sdl_event_key_down, sdl_event_key_up).?);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
}

test "terminal input parser exposes recent keys through polling state" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    var state = [_]u8{0} ** sdl_num_scancodes;
    parser.copyKeyboardState(&state, std.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 1), state[4]);

    parser.copyKeyboardState(&state, std.time.nanoTimestamp() + keyboard_poll_hold_ns + 1);
    try std.testing.expectEqual(@as(u8, 0), state[4]);
}

test "terminal input parser emits arrow key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b[A");

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82, .mods = 0 } }, parser.pop().?);
}

test "terminal input parser emits c1 delete key" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x9b3~");

    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = 0x7f, .scancode = 76, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = 0x7f, .scancode = 76, .mods = 0 } }, parser.pop().?);
}

test "terminal input parser flushes standalone escape" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());

    try parser.flushStandaloneEscape();

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = 0x1b, .scancode = 41, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = 0x1b, .scancode = 41, .mods = 0 } }, parser.pop().?);
}

test "terminal input parser emits SGR mouse motion in SDL coordinates" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b[<35;51;26M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_motion = .{ .x = 400, .y = 200, .xrel = 400, .yrel = 200, .buttons = 0 } }, parser.pop().?);
}

test "terminal input parser emits legacy mouse wheel without text leakage" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b[M`S:");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 400, .mouse_y = 200 } }, parser.pop().?);
}

test "terminal input parser emits urxvt mouse wheel without text leakage" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b[64;51;26M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 400, .mouse_y = 200 } }, parser.pop().?);
}

test "terminal input parser emits c1 csi mouse wheel without text leakage" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x9b64;9;39M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 64, .mouse_y = 304 } }, parser.pop().?);
}

test "terminal input parser drops unknown CSI controls without text leakage" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b[?1006h\x9b?1006l");

    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
}

test "terminal input parser emits c1 sgr wheel buttons without text leakage" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x9b<4;56;48M\x9b<5;56;48M");

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 440, .mouse_y = 376 } }, parser.pop().?);
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = -1, .mouse_x = 440, .mouse_y = 376 } }, parser.pop().?);
}

test "terminal input parser preserves split c1 sgr mouse wheel sequence" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x9b<4;56;");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());

    try parser.feed("48M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 440, .mouse_y = 376 } }, parser.pop().?);
}

test "terminal input parser consumes orphan mouse tail only after an unparseable CSI" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    // Simulate a fragmented mouse CSI: the lone ESC is flushed, which sets
    // the orphan-tail flag; the next feed delivers the tail and is parsed as
    // a wheel event.
    try parser.feed("\x1b");
    try parser.flushStandaloneEscape();
    // Drain the synthesized ESC key (down+up) the flush emits.
    _ = parser.pop();
    _ = parser.pop();

    try parser.feed("4;47;44M");
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 368, .mouse_y = 344 } }, parser.pop().?);
}

test "terminal input parser treats stray mouse-shaped bytes as text without preceding CSI" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    // No preceding ESC/CSI: literal "4;47;44M" the user types must not get
    // silently rewritten as a wheel event.
    try parser.feed("4;47;44M");

    // First emitted event should be the '4' text/key, not a mouse_wheel.
    const first = parser.pop().?;
    switch (first) {
        .mouse_wheel => try std.testing.expect(false),
        else => {},
    }
}

test "terminal input parser preserves split escape sgr mouse wheel sequence" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());

    try parser.feed("[<4;56;48M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 440, .mouse_y = 376 } }, parser.pop().?);
}

test "terminal input parser preserves split SGR mouse wheel sequence" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b[<64;");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());

    try parser.feed("51;26M");

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 400, .mouse_y = 200 } }, parser.pop().?);
}

test "terminal input parser maps mouse through presentation layout" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    var layout = presentation_layout.PresentationLayout{};
    layout.setSingleSdlRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    });
    parser.setTarget(.{ .cols = 100, .rows = 40, .w = 320, .h = 240, .layout = layout });

    try parser.feed("\x1b[<35;11;6M");
    try std.testing.expectEqual(InputEvent{ .mouse_motion = .{ .x = 0, .y = 0, .xrel = 0, .yrel = 0, .buttons = 0 } }, parser.pop().?);

    try parser.feed("\x1b[<35;50;20M");
    try std.testing.expectEqual(InputEvent{ .mouse_motion = .{ .x = 156, .y = 112, .xrel = 156, .yrel = 112, .buttons = 0 } }, parser.pop().?);
}

test "terminal input parser suppresses mouse outside presentation layout" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    var layout = presentation_layout.PresentationLayout{};
    layout.setSingleSdlRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    });
    parser.setTarget(.{ .cols = 100, .rows = 40, .w = 320, .h = 240, .layout = layout });

    try parser.feed("\x1b[<35;5;20M");

    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
    try std.testing.expectEqual(@as(i32, 0), parser.mouseState().x);
    try std.testing.expectEqual(@as(i32, 0), parser.mouseState().y);
    try std.testing.expectEqual(@as(u32, 0), parser.mouseState().buttons);
}

test "terminal input parser tracks mouse button state for polling" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.feed("\x1b[<0;51;26M");
    try std.testing.expectEqual(@as(u32, 1), parser.mouseState().buttons);
    try std.testing.expectEqual(@as(i32, 400), parser.mouseState().x);
    try std.testing.expectEqual(@as(i32, 200), parser.mouseState().y);

    try parser.feed("\x1b[<0;51;26m");
    try std.testing.expectEqual(@as(u32, 0), parser.mouseState().buttons);
}

test "relative mouse baseline snaps to current position after polling" {
    var baseline = RelativeMouseBaseline{};

    const first = baseline.snap(.{ .x = 80, .y = 80, .buttons = 1 });
    try std.testing.expectEqual(@as(i32, 80), first.x);
    try std.testing.expectEqual(@as(i32, 80), first.y);
    try std.testing.expectEqual(@as(i32, 80), first.xrel);
    try std.testing.expectEqual(@as(i32, 80), first.yrel);
    try std.testing.expectEqual(@as(u32, 1), first.buttons);

    const second = baseline.snap(.{ .x = 160, .y = 120, .buttons = 1 });
    try std.testing.expectEqual(@as(i32, 160), second.x);
    try std.testing.expectEqual(@as(i32, 120), second.y);
    try std.testing.expectEqual(@as(i32, 80), second.xrel);
    try std.testing.expectEqual(@as(i32, 40), second.yrel);

    const third = baseline.snap(.{ .x = 160, .y = 120, .buttons = 0 });
    try std.testing.expectEqual(@as(i32, 0), third.xrel);
    try std.testing.expectEqual(@as(i32, 0), third.yrel);
    try std.testing.expectEqual(@as(u32, 0), third.buttons);
}

test "mouse ownership switches between terminal and real window" {
    var ownership = MouseOwnership{};
    try std.testing.expect(ownership.terminalOwns());

    ownership.claimRealWindow();
    try std.testing.expect(!ownership.terminalOwns());

    ownership.claimTerminal();
    try std.testing.expect(ownership.terminalOwns());
}

test "terminal input parser reports mouse activity once" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try std.testing.expect(!parser.takeMouseActivity());

    try parser.feed("\x1b[<35;11;11M");

    try std.testing.expect(parser.takeMouseActivity());
    try std.testing.expect(!parser.takeMouseActivity());
}

test "injectPointer pointerdown emits SDL mouse_button with mapped index" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.injectPointer(.{
        .kind = .pointerdown,
        .row = 26,
        .col = 51,
        .button = 0,
        .buttons = 1,
    });

    try std.testing.expectEqual(@as(usize, 1), parser.pendingCount());
    try std.testing.expectEqual(
        InputEvent{ .mouse_button = .{ .x = 400, .y = 200, .button = 1, .pressed = true, .buttons = 1 } },
        parser.pop().?,
    );
}

test "injectPointer pointerup with right button (index 2) emits SDL button 3 release" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.injectPointer(.{
        .kind = .pointerup,
        .row = 26,
        .col = 51,
        .button = 2,
        .buttons = 0,
    });

    const event = parser.pop().?;
    try std.testing.expectEqual(@as(u8, 3), event.mouse_button.button);
    try std.testing.expectEqual(false, event.mouse_button.pressed);
    try std.testing.expectEqual(@as(u32, 0), event.mouse_button.buttons);
}

test "injectPointer pointerdown rejects out-of-range button without panicking" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.injectPointer(.{
        .kind = .pointerdown,
        .row = 1,
        .col = 1,
        .button = -1,
        .buttons = 0,
    });
    try parser.injectPointer(.{
        .kind = .pointerdown,
        .row = 1,
        .col = 1,
        .button = 256,
        .buttons = 0,
    });

    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
}

test "injectPointer pointermove emits SDL mouse_motion with xrel/yrel from last position" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    // First move parks the cursor at cell (2,2) → SDL (8, 8) with the 8-pixel
    // cell stride implied by the target. Then move to cell (51,26) → SDL
    // (400, 200). xrel/yrel are the deltas: 400-8=392, 200-8=192.
    try parser.injectPointer(.{
        .kind = .pointermove,
        .row = 2,
        .col = 2,
        .button = -1,
        .buttons = 0,
    });
    _ = parser.pop();

    try parser.injectPointer(.{
        .kind = .pointermove,
        .row = 26,
        .col = 51,
        .button = -1,
        .buttons = 1,
    });

    const event = parser.pop().?;
    try std.testing.expectEqual(@as(i32, 400), event.mouse_motion.x);
    try std.testing.expectEqual(@as(i32, 200), event.mouse_motion.y);
    try std.testing.expectEqual(@as(i32, 392), event.mouse_motion.xrel);
    try std.testing.expectEqual(@as(i32, 192), event.mouse_motion.yrel);
    try std.testing.expectEqual(@as(u32, 1), event.mouse_motion.buttons);
}

test "injectPointer wheel flips delta_y sign to SDL convention" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    // DOM/pi-tui: positive deltaY = scroll down. SDL: positive y = scroll up.
    try parser.injectPointer(.{
        .kind = .wheel,
        .row = 26,
        .col = 51,
        .button = -1,
        .buttons = 0,
        .delta_y = 1,
    });

    try std.testing.expectEqual(
        InputEvent{ .mouse_wheel = .{ .x = 0, .y = -1, .mouse_x = 400, .mouse_y = 200 } },
        parser.pop().?,
    );

    // Negative deltaY (scroll up in DOM) → positive SDL y.
    try parser.injectPointer(.{
        .kind = .wheel,
        .row = 26,
        .col = 51,
        .button = -1,
        .buttons = 0,
        .delta_y = -1,
    });

    try std.testing.expectEqual(
        InputEvent{ .mouse_wheel = .{ .x = 0, .y = 1, .mouse_x = 400, .mouse_y = 200 } },
        parser.pop().?,
    );
}

test "injectPointer wheel drops non-line delta_mode events" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.injectPointer(.{
        .kind = .wheel,
        .row = 1,
        .col = 1,
        .button = -1,
        .buttons = 0,
        .delta_y = 120,
        .delta_mode = .pixel,
    });
    try parser.injectPointer(.{
        .kind = .wheel,
        .row = 1,
        .col = 1,
        .button = -1,
        .buttons = 0,
        .delta_y = 1,
        .delta_mode = .page,
    });

    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
}
