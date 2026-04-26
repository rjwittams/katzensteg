const std = @import("std");
const sdl = @import("katzensteg_sdl");
const presentation_layout = @import("presentation_layout.zig");

const max_pending_bytes = 256;

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

    pub fn pop(self: *TerminalInputParser) ?InputEvent {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    pub fn flushStandaloneEscape(self: *TerminalInputParser) !void {
        if (self.pending.items.len == 1 and self.pending.items[0] == 0x1b) {
            try self.emitKey(.{ .keycode = 0x1b, .scancode = 41 });
            self.pending.clearRetainingCapacity();
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
            if (try self.parseEscape(bytes)) |consumed| return consumed;
            if (bytes.len == 1) return 0;
            try self.emitKey(.{ .keycode = 0x1b, .scancode = 41 });
            return 1;
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

        switch (bytes[2]) {
            'A' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82 });
                return 3;
            },
            'B' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(81), .scancode = 81 });
                return 3;
            },
            'C' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(79), .scancode = 79 });
                return 3;
            },
            'D' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(80), .scancode = 80 });
                return 3;
            },
            'H' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(74), .scancode = 74 });
                return 3;
            },
            'F' => {
                try self.emitKey(.{ .keycode = sdlKeycodeFromScancode(77), .scancode = 77 });
                return 3;
            },
            '<' => return try self.parseSgrMouse(bytes),
            else => {},
        }

        if (std.mem.startsWith(u8, bytes, "\x1b[3~")) {
            try self.emitKey(.{ .keycode = 0x7f, .scancode = 76 });
            return 4;
        }
        return null;
    }

    fn parseSgrMouse(self: *TerminalInputParser, bytes: []const u8) !?usize {
        var end: ?usize = null;
        var i: usize = 3;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 'M' or bytes[i] == 'm') {
                end = i;
                break;
            }
        }
        const final = end orelse return null;
        var fields = std.mem.splitScalar(u8, bytes[3..final], ';');
        const b = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_x = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_y = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const pressed = bytes[final] == 'M';
        const point = self.mapCellToSdl(cell_x, cell_y) orelse {
            // For now, terminal chrome/letterbox cells do not target SDL. Keep
            // button state and last mouse position unchanged until region
            // routing can synthesize enter/leave or chrome-owned events.
            return final + 1;
        };
        const x = point.x;
        const y = point.y;
        const xrel = x - self.last_mouse_x;
        const yrel = y - self.last_mouse_y;

        if ((b & 64) != 0) {
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
        return final + 1;
    }

    fn emitTextAndKey(self: *TerminalInputParser, bytes: []const u8, key: KeyEvent) !void {
        try self.queue.append(self.allocator, .{ .key_down = key });
        try self.queue.append(self.allocator, .{ .text = TextEvent.init(bytes) });
        try self.queue.append(self.allocator, .{ .key_up = key });
    }

    fn emitKey(self: *TerminalInputParser, key: KeyEvent) !void {
        try self.queue.append(self.allocator, .{ .key_down = key });
        try self.queue.append(self.allocator, .{ .key_up = key });
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

test "terminal input parser emits printable key text and key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    try std.testing.expectEqual(@as(usize, 3), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = 'a', .scancode = 4, .mods = 0 } }, parser.pop().?);
}

test "terminal input parser emits arrow key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b[A");

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try std.testing.expectEqual(InputEvent{ .key_down = .{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82, .mods = 0 } }, parser.pop().?);
    try std.testing.expectEqual(InputEvent{ .key_up = .{ .keycode = sdlKeycodeFromScancode(82), .scancode = 82, .mods = 0 } }, parser.pop().?);
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
