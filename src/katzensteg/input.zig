const std = @import("std");
const system_io = @import("platform");
const presentation_layout = @import("presentation_layout.zig");
const render_batch_protocol = @import("render_batch_protocol.zig");
const native_key = @import("native_key.zig");
const terminal_keys = @import("terminal_keys.zig");

const command_binding = @import("command_key.zig");
const command_menu = @import("command_menu.zig");
pub const RoutingMode = enum { app, command };

pub const NativeKey = native_key.Key;

const max_pending_bytes = 256;
const max_local_presses = 64;
const keyboard_poll_hold_ns: i128 = 150 * std.time.ns_per_ms;

pub const sdl_num_scancodes = 512;
pub const sdl_event_key_down = 0x300;
pub const sdl_event_key_up = 0x301;
pub const sdl_event_text_input = 0x303;
pub const sdl_event_mouse_motion = 0x400;
pub const sdl_event_mouse_button_down = 0x401;
pub const sdl_event_mouse_button_up = 0x402;
pub const sdl_event_mouse_wheel = 0x403;

/// Size of one terminal cell in pixels, from the tty or the host's terminal
/// geometry. Pixel-resolution mouse reports map through it; without it
/// they cannot be placed and are dropped.
pub const CellPixels = struct {
    w: f32,
    h: f32,
};

pub const Target = struct {
    cols: i32 = 80,
    rows: i32 = 24,
    w: i32 = 640,
    h: i32 = 480,
    layout: presentation_layout.PresentationLayout = .{},
    source_px: ?render_batch_protocol.SourcePixels = null,
    cell_px: ?CellPixels = null,
    /// Coordinate of the first pixel in pixel reports: 1 for xterm's
    /// convention, 0 for kitty and Ghostty. The host sets it from the
    /// terminal identity.
    pixel_origin: i32 = 1,

    pub fn sameMapping(a: Target, b: Target) bool {
        if (a.cols != b.cols or a.rows != b.rows or a.w != b.w or a.h != b.h or a.layout.len != b.layout.len) return false;
        if (!std.meta.eql(a.cell_px, b.cell_px) or a.pixel_origin != b.pixel_origin) return false;
        for (a.layout.regions[0..a.layout.len], b.layout.regions[0..b.layout.len]) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }
};

/// A key as the SDL adapters project it. `native` is the source-neutral key
/// the binding was resolved from; presenters forward it without translating
/// SDL numbers back into names.
pub const KeyEvent = struct {
    keycode: i32,
    scancode: i32,
    mods: u16 = 0,
    repeat: bool = false,
    native: native_key.Key = .{},
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
    precise_x: ?f32 = null,
    precise_y: ?f32 = null,
    xrel: i32,
    yrel: i32,
    precise_xrel: ?f32 = null,
    precise_yrel: ?f32 = null,
    buttons: u32 = 0,
};

pub const MouseButtonEvent = struct {
    x: i32,
    y: i32,
    precise_x: ?f32 = null,
    precise_y: ?f32 = null,
    button: u8,
    pressed: bool,
    clicks: u8 = 1,
    buttons: u32 = 0,
};

pub const MouseWheelEvent = struct {
    x: i32,
    y: i32,
    precise_x: ?f32 = null,
    precise_y: ?f32 = null,
    mouse_x: i32,
    mouse_y: i32,
    precise_mouse_x: ?f32 = null,
    precise_mouse_y: ?f32 = null,
};

pub const MouseState = struct {
    x: i32,
    y: i32,
    precise_x: ?f32 = null,
    precise_y: ?f32 = null,
    xrel: i32 = 0,
    yrel: i32 = 0,
    precise_xrel: ?f32 = null,
    precise_yrel: ?f32 = null,
    buttons: u32,
};

pub const RelativeMouseBaseline = struct {
    x: i32 = 0,
    y: i32 = 0,
    precise_x: f32 = 0,
    precise_y: f32 = 0,

    pub fn snap(self: *RelativeMouseBaseline, current: MouseState) MouseState {
        const relative = MouseState{
            .x = current.x,
            .y = current.y,
            .xrel = current.x - self.x,
            .yrel = current.y - self.y,
            .precise_xrel = if (current.precise_x) |x| x - self.precise_x else null,
            .precise_yrel = if (current.precise_y) |y| y - self.precise_y else null,
            .buttons = current.buttons,
        };
        self.x = current.x;
        self.y = current.y;
        self.precise_x = current.precise_x orelse @floatFromInt(current.x);
        self.precise_y = current.precise_y orelse @floatFromInt(current.y);
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
    focus: bool,
    quit,
    key_down: KeyEvent,
    key_up: KeyEvent,
    text: TextEvent,
    // Borrowed until the source receives delivery completion. The adapter
    // chooses its text chunk size; the model has no SDL text-buffer limit.
    text_commit: []const u8,
    mouse_motion: MouseMotionEvent,
    mouse_button: MouseButtonEvent,
    mouse_wheel: MouseWheelEvent,
};

pub const TerminalInputParser = InputModel;

pub const InputModel = struct {
    const QueuedEvent = struct {
        event: InputEvent,
        controller: u64 = 0,
        ticket: u64 = 0,
        acknowledged: bool = false,
        mapping_generation: u64 = 0,
    };
    pub const DeliveryKind = enum { keyboard, pointer, text, scroll, cleanup };
    const Delivery = struct { ticket: u64, remaining: usize = 0, kind: DeliveryKind };
    pub const Press = struct { controller: u64, identity: u64, binding: KeyEvent };
    // Disabled until a local tty owner explicitly installs its binding.
    command_key: ?u8 = null,
    routing_mode: RoutingMode = .app,
    source_focused: bool = true,
    source_focus_owned: bool = false,
    command_hint: bool = false,
    command_pointer_action: ?command_menu.Action = null,
    consumed_terminal_buttons: u32 = 0,
    paste_active: bool = false,
    paste_drop: bool = false,
    quit_requested: bool = false,
    consumed_presses: [max_local_presses * 2]?NativeKey = @splat(null),
    remote_presses: [256]?Press = @splat(null),
    remote_controller: u64 = 0,
    remote_buttons: u32 = 0,
    native_keys: [sdl_num_scancodes]u8 = @splat(0),
    blocked_native_keys: [sdl_num_scancodes]bool = @splat(false),
    blocked_native_buttons: u32 = 0,
    native_buttons: u32 = 0,
    native_mouse_x: ?f32 = null,
    native_mouse_y: ?f32 = null,
    delivery: ?Delivery = null,
    next_ticket: u64 = 1,
    focus_generation: u64 = 0,
    overflow_generation: u64 = 0,
    mapping_generation: u64 = 0,
    queue_limit: ?usize = null,

    allocator: std.mem.Allocator,
    queue: std.ArrayList(QueuedEvent),
    pending: std.ArrayList(u8),
    target: Target = .{},
    last_mouse_x: i32 = 0,
    last_mouse_y: i32 = 0,
    precise_mouse_x: ?f32 = null,
    precise_mouse_y: ?f32 = null,
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
    // Local presses in flight. A down fixes the binding and press identity
    // that its repeats and release reuse, as the Jackstay contract requires.
    local_presses: [max_local_presses]?KeyEvent = @splat(null),
    next_press: u64 = 1,
    /// Kitty keyboard protocol flags the terminal reported in reply to the
    /// query the tty sends after pushing them. Zero until then, and on
    /// terminals without the protocol.
    keyboard_protocol_flags: u32 = 0,
    /// Units of SGR mouse reports, from the terminal's DECRQM reply to the
    /// tty's request for pixels. Cells until the terminal confirms.
    mouse_units: terminal_keys.MouseUnits = .cell,

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
        if (!Target.sameMapping(self.target, target)) self.mapping_generation +%= 1;
        self.target = .{
            .cols = @max(1, target.cols),
            .rows = @max(1, target.rows),
            .w = @max(1, target.w),
            .h = @max(1, target.h),
            .layout = target.layout,
            .source_px = target.source_px,
            .cell_px = target.cell_px,
            .pixel_origin = target.pixel_origin,
        };
    }

    /// Drop stale local work at a controller barrier. Remote executor tickets
    /// belong to a different owner and are never consumed here.
    pub fn discardLocalInput(self: *InputModel, pointer_only: bool) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const queued = self.queue.items[i];
            const pointer = switch (queued.event) {
                .mouse_motion, .mouse_button, .mouse_wheel => true,
                else => false,
            };
            if (queued.controller == 0 and (!pointer_only or pointer)) {
                _ = self.queue.orderedRemove(i);
            } else i += 1;
        }
        // Both scopes discard local pointer holds. Pointer-only cleanup keeps
        // keyboard state, but a drag from the old geometry must not survive.
        self.mouse_buttons = 0;
        if (!pointer_only) {
            self.pending.clearRetainingCapacity();
            self.keyboard_state = @splat(0);
            self.keyboard_deadline_ns = @splat(0);
            self.local_presses = @splat(null);
        }
    }

    pub fn discardStalePointerInput(self: *InputModel) void {
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const queued = self.queue.items[i];
            const pointer = switch (queued.event) {
                .mouse_motion, .mouse_button, .mouse_wheel => true,
                else => false,
            };
            if (queued.controller == 0 and pointer and queued.mapping_generation != self.mapping_generation) {
                _ = self.queue.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn feed(self: *TerminalInputParser, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            // Keep a split UTF-8/escape prefix even when the next read is large.
            // Only an overlong incomplete sequence is abandoned.
            if (self.pending.items.len == max_pending_bytes) self.pending.clearRetainingCapacity();
            const count = @min(rest.len, max_pending_bytes - self.pending.items.len);
            try self.pending.appendSlice(self.allocator, rest[0..count]);
            rest = rest[count..];
            self.parsePending() catch |err| {
                self.pending.clearRetainingCapacity();
                return err;
            };
        }
    }

    pub fn pendingCount(self: *const TerminalInputParser) usize {
        return self.queue.items.len;
    }

    pub fn noteNativePointer(self: *InputModel, x: f32, y: f32) void {
        self.last_mouse_x = @intFromFloat(x);
        self.last_mouse_y = @intFromFloat(y);
        self.precise_mouse_x = x;
        self.precise_mouse_y = y;
    }

    pub fn updateNativeMouse(self: *InputModel, x: f32, y: f32, buttons: u32) bool {
        const changed = self.native_mouse_x == null or self.native_mouse_x.? != x or
            self.native_mouse_y.? != y or buttons != self.native_buttons;
        self.native_mouse_x = x;
        self.native_mouse_y = y;
        self.native_buttons = buttons;
        if (changed) self.noteNativePointer(x, y);
        return changed;
    }

    pub fn mouseState(self: *const TerminalInputParser) MouseState {
        return .{
            .x = self.last_mouse_x,
            .y = self.last_mouse_y,
            .precise_x = self.precise_mouse_x,
            .precise_y = self.precise_mouse_y,
            .buttons = if (!self.applicationFocused()) 0 else self.mouse_buttons | self.remote_buttons | (self.native_buttons & ~self.blocked_native_buttons),
        };
    }

    pub fn takeMouseActivity(self: *TerminalInputParser) bool {
        const active = self.mouse_activity;
        self.mouse_activity = false;
        return active;
    }

    pub fn copyKeyboardState(self: *TerminalInputParser, out: []u8, now_ns: i128) void {
        if (!self.applicationFocused()) {
            @memset(out, 0);
            return;
        }
        self.expireKeyboardState(now_ns);
        const n = @min(out.len, self.keyboard_state.len);
        @memcpy(out[0..n], self.keyboard_state[0..n]);
        for (self.remote_presses) |entry| if (entry) |press| {
            const scan = press.binding.scancode;
            if (scan > 0 and scan < n) out[@intCast(scan)] = 1;
        };
    }

    fn append(self: *InputModel, event: InputEvent) !void {
        if (self.queue_limit) |limit| if (self.queue.items.len >= limit) {
            self.discardLocalInput(false);
            self.overflow_generation +%= 1;
            return error.Capacity;
        };
        try self.queue.append(self.allocator, .{ .event = event, .mapping_generation = self.mapping_generation });
    }

    pub fn peek(self: *const InputModel) ?InputEvent {
        return if (self.queue.items.len > 0) self.queue.items[0].event else null;
    }

    pub fn pop(self: *InputModel) ?InputEvent {
        return self.popForAdapter(std.math.maxInt(usize), 0, std.math.maxInt(u32));
    }

    pub fn popSdlRange(self: *InputModel, min_type: u32, max_type: u32) ?InputEvent {
        return self.popForAdapter(std.math.maxInt(usize), min_type, max_type);
    }

    // Called by an adapter that immediately projects the returned event. Text
    // remains borrowed until the source next pumps its completed work.
    pub fn popForAdapter(self: *InputModel, max_text_bytes: usize, min_type: u32, max_type: u32) ?InputEvent {
        return self.popForAdapterTypes(inputEventSdlType, max_text_bytes, min_type, max_type);
    }

    pub fn popForAdapterTypes(self: *InputModel, comptime eventType: fn (InputEvent) u32, max_text_bytes: usize, min_type: u32, max_type: u32) ?InputEvent {
        for (self.queue.items, 0..) |queued, idx| {
            const event_type = eventType(queued.event);
            if (event_type < min_type or event_type > max_type) continue;
            if (queued.event == .text_commit and queued.event.text_commit.len > max_text_bytes) {
                const text = queued.event.text_commit;
                var n = max_text_bytes;
                while (n > 0 and (text[n] & 0xc0) == 0x80) : (n -= 1) {}
                if (n == 0) return null;
                self.queue.items[idx].event.text_commit = text[n..];
                return .{ .text_commit = text[0..n] };
            }
            _ = self.queue.orderedRemove(idx);
            if (self.delivery) |*delivery| {
                if (queued.ticket == delivery.ticket and !queued.acknowledged and delivery.remaining > 0) delivery.remaining -= 1;
            }
            return queued.event;
        }
        return null;
    }

    pub fn beginDelivery(self: *InputModel, kind: DeliveryKind, count: usize) !void {
        if (self.delivery != null) return error.DeliveryInProgress;
        // Leave bounded room for releasing all held keys/buttons during cleanup.
        if (kind != .cleanup and self.queue.items.len + count > 768) {
            // State polling already delivered these transitions. Retain them for
            // mixed event/state readers until capacity is needed, then retire
            // only those acknowledged copies; never discard unobserved input.
            var retained: usize = 0;
            for (self.queue.items) |queued| {
                if (queued.acknowledged) continue;
                self.queue.items[retained] = queued;
                retained += 1;
            }
            self.queue.items.len = retained;
            if (retained + count > 768) return error.Capacity;
        }
        try self.queue.ensureUnusedCapacity(self.allocator, count);
        if (self.next_ticket == std.math.maxInt(u64)) return error.Capacity;
        self.delivery = .{ .ticket = self.next_ticket, .kind = kind };
        self.next_ticket += 1;
    }

    pub fn appendRemote(self: *InputModel, controller: u64, event: InputEvent) void {
        const delivery = &self.delivery.?;
        self.queue.appendAssumeCapacity(.{ .event = event, .controller = controller, .ticket = delivery.ticket });
        delivery.remaining += 1;
    }

    pub fn deliveryFinished(self: *const InputModel) bool {
        return if (self.delivery) |delivery| delivery.remaining == 0 else false;
    }

    pub fn finishDelivery(self: *InputModel) void {
        std.debug.assert(self.deliveryFinished());
        self.delivery = null;
    }

    // Observing a projected state settles only the transitions that it exposes.
    // Scroll/text cannot be acknowledged by querying buttons or keys.
    pub fn observeState(self: *InputModel, kind: DeliveryKind) void {
        if (self.delivery) |*delivery| {
            for (self.queue.items) |*queued| {
                const observed = switch (queued.event) {
                    .key_down, .key_up => kind == .keyboard,
                    .mouse_motion, .mouse_button => kind == .pointer,
                    else => false,
                };
                if (observed and queued.ticket == delivery.ticket and !queued.acknowledged) {
                    queued.acknowledged = true;
                    delivery.remaining -= 1;
                }
            }
        }
    }

    pub fn observeButtons(self: *InputModel) void {
        if (self.delivery) |*delivery| {
            for (self.queue.items) |*queued| {
                if (queued.event == .mouse_button and queued.ticket == delivery.ticket and !queued.acknowledged) {
                    queued.acknowledged = true;
                    delivery.remaining -= 1;
                }
            }
        }
    }

    pub fn observeModifiers(self: *InputModel) void {
        if (self.delivery) |*delivery| {
            for (self.queue.items) |*queued| {
                const scan = switch (queued.event) {
                    .key_down, .key_up => |key| key.scancode,
                    else => continue,
                };
                if (scan >= 224 and scan <= 231 and queued.ticket == delivery.ticket and !queued.acknowledged) {
                    queued.acknowledged = true;
                    delivery.remaining -= 1;
                }
            }
        }
    }

    pub fn discardControllerEvents(self: *InputModel, controller: u64, pointer_only: bool) void {
        var index: usize = 0;
        while (index < self.queue.items.len) {
            const queued = self.queue.items[index];
            const pointer = switch (queued.event) {
                .mouse_motion, .mouse_button, .mouse_wheel => true,
                else => false,
            };
            if (queued.controller == controller and (!pointer_only or pointer)) {
                _ = self.queue.orderedRemove(index);
            } else index += 1;
        }
    }

    pub fn pressSlot(self: *InputModel, controller: u64, identity: u64) ?*?Press {
        for (&self.remote_presses) |*slot| if (slot.*) |press| {
            if (press.controller == controller and press.identity == identity) return slot;
        };
        return null;
    }

    pub fn vacantPress(self: *InputModel) ?*?Press {
        for (&self.remote_presses) |*slot| if (slot.* == null) return slot;
        return null;
    }

    pub fn remoteScanHeld(self: *const InputModel, scan: i32) bool {
        for (self.remote_presses) |slot| if (slot) |press| {
            if (press.binding.scancode == scan) return true;
        };
        return false;
    }

    pub fn heldModifiers(self: *const InputModel) u16 {
        var result: u16 = 0;
        const scans = [_]i32{ 225, 229, 224, 228, 226, 230, 227, 231 };
        const bits = [_]u16{ 1, 2, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800 };
        for (scans, bits) |scan, bit| {
            if (self.remoteScanHeld(scan) or self.keyboard_state[@intCast(scan)] != 0) result |= bit;
        }
        return result;
    }

    pub fn keyHeldElsewhere(self: *const InputModel, scan: i32, controller: u64, identity: u64) bool {
        if (scan <= 0 or scan >= sdl_num_scancodes) return false;
        const index: usize = @intCast(scan);
        if (self.native_keys[index] != 0 or self.keyboard_state[index] != 0) return true;
        for (self.remote_presses) |slot| if (slot) |press| {
            if (press.binding.scancode == scan and (press.controller != controller or press.identity != identity)) return true;
        };
        return false;
    }

    /// The tty reader calls this when no more bytes followed an escape within
    /// the read timeout: a lone ESC is the Escape key, and ESC plus one byte
    /// that started no sequence is that key with Alt. Terminals speaking the
    /// kitty protocol never leave this ambiguity, since they encode both.
    pub fn flushStandaloneEscape(self: *TerminalInputParser) !void {
        if (self.pending.items.len == 1 and self.pending.items[0] == 0x1b) {
            try self.tapNamed("Escape");
            self.pending.clearRetainingCapacity();
            // If a partial mouse CSI was fragmented across reads, the tail
            // bytes could arrive after this flush — let the next parseOne
            // pass try to consume them as an orphan-mouse-tail cleanup.
            self.expect_orphan_mouse_tail = true;
            return;
        }
        if (self.pending.items.len == 2 and self.pending.items[0] == 0x1b and self.pending.items[1] == 'O') {
            // An SS3 key split across reads with the idle timeout in between
            // would be misread as Alt+O; that needs a link slower than the
            // timeout, and terminals speaking the kitty protocol never send
            // SS3 or a bare ESC prefix at all.
            try self.tapAltKey('O');
            self.pending.clearRetainingCapacity();
        }
    }

    pub fn keyboardReportsEvents(self: *const InputModel) bool {
        return self.keyboard_protocol_flags & 2 != 0;
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
        if (self.paste_active) {
            const end = "\x1b[201~";
            if (std.mem.startsWith(u8, bytes, end)) {
                self.paste_active = false;
                return end.len;
            }
            if (std.mem.startsWith(u8, end, bytes)) return 0;
            if (self.paste_drop) return 1;
            const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 1;
            if (bytes.len < len) return 0;
            _ = std.unicode.utf8Decode(bytes[0..len]) catch return len;
            // A paste is text, including newlines, never command keystrokes.
            try self.append(.{ .text = TextEvent.init(bytes[0..len]) });
            return len;
        }
        const first = bytes[0];
        if (first == 0x1b) {
            if (try self.parseEscape(bytes)) |consumed| {
                self.expect_orphan_mouse_tail = false;
                return consumed;
            }
            if (isIncompleteEscape(bytes)) return 0;
            if (bytes.len >= 2 and isAltPrefixedByte(bytes[1])) {
                // ESC followed by a key in the same read is the legacy Alt
                // encoding; a human Escape never arrives that close.
                try self.tapAltKey(bytes[1]);
                return 2;
            }
            try self.tapNamed("Escape");
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
            try self.tapNamed("Enter");
            return 1;
        }
        if (first == '\t') {
            try self.tapNamed("Tab");
            return 1;
        }
        if (first == 0x7f or first == 0x08) {
            try self.tapNamed("Backspace");
            return 1;
        }
        if (first >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(first) catch return 1;
            if (bytes.len < len) return 0;
            const code = std.unicode.utf8Decode(bytes[0..len]) catch return len;
            try self.tapCharacter(code, bytes[0..len], .{});
            return len;
        }
        if (first >= 0x20) {
            try self.tapCharacter(first, bytes[0..1], .{ .shift = std.ascii.isUpper(first) });
            return 1;
        }
        if (first >= 1 and first <= 26) {
            try self.tapCharacter('a' + first - 1, "", .{ .control = true });
        } else if (first == 0 or (first >= 0x1c and first <= 0x1f)) {
            try self.tapCharacter(first + 0x40, "", .{ .control = true });
        }
        return 1;
    }

    fn parseEscape(self: *TerminalInputParser, bytes: []const u8) !?usize {
        if (bytes.len < 2) return null;
        if (bytes[1] == 'O') {
            // SS3 keys from application cursor mode. Anything else after
            // ESC O is Alt+O followed by that byte.
            if (bytes.len < 3) return null;
            if (terminal_keys.decodeCsi("", bytes[2], self.keyboardReportsEvents())) |report| {
                try self.applyKeyReport(report);
                return 3;
            }
            return null;
        }
        if (bytes[1] != '[') return null;
        if (bytes.len < 3) return null;

        return try self.parseCsi(bytes, 2);
    }

    fn applyKeyReport(self: *TerminalInputParser, report: terminal_keys.Report) !void {
        switch (report) {
            .key => |decoded| try self.pressKey(decoded.key, decoded.text()),
            .protocol_flags => |flags| self.keyboard_protocol_flags = flags,
            .mouse_units => |units| self.mouse_units = units,
        }
    }

    fn tapAltKey(self: *TerminalInputParser, byte: u8) !void {
        if (byte >= 1 and byte <= 26) {
            try self.tapCharacter('a' + byte - 1, "", .{ .alt = true, .control = true });
        } else if (byte == '\r' or byte == '\n') {
            try self.pressKey(altNamed("Enter"), "");
        } else if (byte == '\t') {
            try self.pressKey(altNamed("Tab"), "");
        } else if (byte == 0x7f or byte == 0x08) {
            try self.pressKey(altNamed("Backspace"), "");
        } else {
            try self.tapCharacter(byte, "", .{ .alt = true, .shift = std.ascii.isUpper(byte) });
        }
    }

    fn altNamed(name: []const u8) native_key.Key {
        var key = native_key.Key.logical(name) catch unreachable;
        key.modifiers = .{ .alt = true };
        return key;
    }

    fn parseCsi(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        if (bytes.len <= start) return null;

        switch (bytes[start]) {
            'O' => {
                try self.setSourceFocus(false);
                return start + 1;
            },
            'I' => {
                try self.setSourceFocus(true);
                return start + 1;
            },
            '<' => return try self.parseSgrMouse(bytes, start),
            'M' => return try self.parseLegacyMouse(bytes, start),
            else => {},
        }

        if (std.ascii.isDigit(bytes[start])) {
            if (try self.parseUrxvtMouse(bytes, start)) |consumed| return consumed;
        }

        const final = csiFinalIndex(bytes, start) orelse return null;
        if (bytes[final] == '~' and std.mem.eql(u8, bytes[start..final], "200")) {
            self.paste_active = true;
            self.paste_drop = self.routing_mode == .command;
            return final + 1;
        }
        // Key reports in either the legacy or the kitty encoding; any other
        // control sequence is consumed without leaking into text.
        if (terminal_keys.decodeCsi(bytes[start..final], bytes[final], self.keyboardReportsEvents())) |report| {
            try self.applyKeyReport(report);
        }
        return final + 1;
    }

    fn parseLegacyMouse(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        if (bytes.len < start + 4) return null;
        const consumed = start + 4;
        const b = decodeLegacyMouseByte(bytes[start + 1]) orelse return consumed;
        const cell_x = decodeLegacyMouseByte(bytes[start + 2]) orelse return consumed;
        const cell_y = decodeLegacyMouseByte(bytes[start + 3]) orelse return consumed;
        const pressed = (b & 3) != 3;
        try self.emitMouseCode(b, cell_x, cell_y, pressed, .cell);
        return consumed;
    }

    fn parseUrxvtMouse(self: *TerminalInputParser, bytes: []const u8, start: usize) !?usize {
        const final = csiFinalIndex(bytes, start) orelse return null;
        if (bytes[final] != 'M') return null;
        var fields = std.mem.splitScalar(u8, bytes[start..final], ';');
        const b = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_x = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        const cell_y = std.fmt.parseInt(i32, fields.next() orelse return final + 1, 10) catch return final + 1;
        try self.emitMouseCode(b, cell_x, cell_y, true, .cell);
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
        try self.emitMouseCode(b, cell_x, cell_y, pressed, self.mouse_units);
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
            try self.emitMouseCode(b, cell_x, cell_y, true, self.mouse_units);
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
        try self.injectPointerAt(event, point.x, point.y);
    }

    pub fn injectSourcePointer(self: *TerminalInputParser, event: render_batch_protocol.SourcePointer) !void {
        // Image pixels and SDL window coordinates can differ on a scaled display.
        const source = self.target.source_px orelse render_batch_protocol.SourcePixels{ .w = self.target.w, .h = self.target.h };
        if (event.kind == .pointerup and (event.width != source.w or event.height != source.h)) {
            // A resize must not prevent a controller from releasing a held button.
            try self.injectPointerAt(.{ .kind = .pointerup, .row = 1, .col = 1, .button = event.button, .buttons = event.buttons }, self.last_mouse_x, self.last_mouse_y);
            return;
        }
        if (event.width != source.w or event.height != source.h) return error.StaleSourceSize;
        if (event.x < 0 or event.y < 0 or event.x >= source.w or event.y >= source.h) return error.InvalidSourcePoint;
        const x: i32 = @intCast(@divTrunc(@as(i64, event.x) * self.target.w, source.w));
        const y: i32 = @intCast(@divTrunc(@as(i64, event.y) * self.target.h, source.h));
        try self.injectPointerAt(.{ .kind = event.kind, .row = 1, .col = 1, .button = event.button, .buttons = event.buttons }, x, y);
    }

    fn injectPointerAt(self: *TerminalInputParser, event: render_batch_protocol.PointerEventPayload, x: i32, y: i32) !void {
        if (self.routing_mode == .command) return;
        switch (event.kind) {
            .wheel => {
                // Only line-mode deltas are normalised today. Pixel- and page-mode
                // wheel events would need scaling (e.g. pixel/100 → line) to avoid
                // emitting hundreds of wheel ticks per notch from a high-resolution
                // wheel. The only current host (pi-extension) always emits line mode;
                // when a producer needs pixel or page support we add the translation
                // here rather than letting wrong deltas through silently.
                if (event.delta_mode != .line) return;
                try self.append(.{ .mouse_wheel = .{
                    .x = roundWheelDelta(event.delta_x),
                    .y = -roundWheelDelta(event.delta_y),
                    .precise_x = if (event.delta_x != @trunc(event.delta_x)) @floatCast(std.math.clamp(event.delta_x, -1000, 1000)) else null,
                    .precise_y = if (event.delta_y != @trunc(event.delta_y)) @floatCast(-std.math.clamp(event.delta_y, -1000, 1000)) else null,
                    .mouse_x = x,
                    .mouse_y = y,
                } });
            },
            .pointermove => {
                const xrel = x - self.last_mouse_x;
                const yrel = y - self.last_mouse_y;
                self.mouse_buttons = event.buttons;
                try self.append(.{ .mouse_motion = .{
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
                try self.append(.{ .mouse_button = .{
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
        self.precise_mouse_x = null;
        self.precise_mouse_y = null;
        self.mouse_activity = true;
    }

    fn routeCommandMouse(self: *InputModel, b: i32, x: i32, y: i32, pressed: bool, units: terminal_keys.MouseUnits) !bool {
        const armed = self.routing_mode == .command;
        if (!armed and self.consumed_terminal_buttons == 0) return false;
        if ((b & (32 | 64)) != 0 or b == 4 or b == 5) return true;
        const button = b & 3;
        const mask = if (button == 3) self.consumed_terminal_buttons else sdlButtonMask(terminalButtonToSdl(@intCast(button)));
        var col = x;
        var row = y;
        if (units == .pixel) {
            const cell = self.target.cell_px orelse return true;
            if (cell.w <= 0 or cell.h <= 0) return true;
            col = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(@max(x - self.target.pixel_origin, 0))) / cell.w))) + 1;
            row = @as(i32, @intFromFloat(@floor(@as(f32, @floatFromInt(@max(y - self.target.pixel_origin, 0))) / cell.h))) + 1;
        }
        const hit = self.commandMenuSnapshot(@intCast(self.target.cols), @intCast(self.target.rows)).hit(col, row);
        if (pressed and button != 3) {
            self.consumed_terminal_buttons |= mask;
            if (armed and button == 0) self.command_pointer_action = hit;
        } else {
            self.consumed_terminal_buttons &= ~mask;
            const action = self.command_pointer_action;
            if (button == 0 or button == 3) {
                self.command_pointer_action = null;
                if (armed and action != null and action == hit) switch (action.?) {
                    .quit => try self.requestQuit(),
                    .cancel => try self.leaveCommandMode(),
                };
            }
        }
        return true;
    }

    fn emitMouseCode(self: *TerminalInputParser, b: i32, report_x: i32, report_y: i32, pressed: bool, units: terminal_keys.MouseUnits) !void {
        if (try self.routeCommandMouse(b, report_x, report_y, pressed, units)) return;
        if (!self.source_focused) return;
        const point = self.mapReportToSdl(report_x, report_y, units) orelse {
            // For now, terminal chrome/letterbox cells do not target SDL. Keep
            // button state and last mouse position unchanged until region
            // routing can synthesize enter/leave or chrome-owned events.
            return;
        };
        const x = point.x;
        const y = point.y;
        const xrel = x - self.last_mouse_x;
        const yrel = y - self.last_mouse_y;
        const precise_xrel: ?f32 = if (point.precise_x) |px| px - (self.precise_mouse_x orelse @as(f32, @floatFromInt(self.last_mouse_x))) else null;
        const precise_yrel: ?f32 = if (point.precise_y) |py| py - (self.precise_mouse_y orelse @as(f32, @floatFromInt(self.last_mouse_y))) else null;

        if ((b & 64) != 0 or b == 4 or b == 5) {
            try self.append(.{ .mouse_wheel = .{
                .x = 0,
                .y = if ((b & 1) == 0) 1 else -1,
                .mouse_x = x,
                .mouse_y = y,
                .precise_mouse_x = point.precise_x,
                .precise_mouse_y = point.precise_y,
            } });
        } else if ((b & 32) != 0) {
            try self.append(.{ .mouse_motion = .{
                .x = x,
                .y = y,
                .precise_x = point.precise_x,
                .precise_y = point.precise_y,
                .xrel = xrel,
                .yrel = yrel,
                .precise_xrel = precise_xrel,
                .precise_yrel = precise_yrel,
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
            try self.append(.{ .mouse_button = .{
                .x = x,
                .y = y,
                .precise_x = point.precise_x,
                .precise_y = point.precise_y,
                .button = button,
                .pressed = pressed,
                .buttons = self.mouse_buttons,
            } });
        }
        self.last_mouse_x = x;
        self.last_mouse_y = y;
        self.precise_mouse_x = point.precise_x;
        self.precise_mouse_y = point.precise_y;
        self.mouse_activity = true;
    }

    const MappedReport = struct { x: i32, y: i32, precise_x: ?f32 = null, precise_y: ?f32 = null };

    /// Place a mouse report in SDL coordinates. Cell reports map to a cell's
    /// origin; pixel reports become fractional cells first, so the same
    /// layout answers both and the sub-cell position survives.
    fn mapReportToSdl(self: *const TerminalInputParser, x: i32, y: i32, units: terminal_keys.MouseUnits) ?MappedReport {
        switch (units) {
            .cell => {
                const point = self.mapCellToSdl(x, y) orelse return null;
                return .{ .x = point.x, .y = point.y };
            },
            .pixel => {
                const cell = self.target.cell_px orelse return null;
                if (cell.w <= 0 or cell.h <= 0) return null;
                const col = @as(f32, @floatFromInt(@max(x - self.target.pixel_origin, 0))) / cell.w + 1;
                const row = @as(f32, @floatFromInt(@max(y - self.target.pixel_origin, 0))) / cell.h + 1;
                const point = self.mapFractionalCellToSdl(col, row) orelse return null;
                return .{ .x = @intFromFloat(@floor(point.x)), .y = @intFromFloat(@floor(point.y)), .precise_x = point.x, .precise_y = point.y };
            },
        }
    }

    fn mapFractionalCellToSdl(self: *const TerminalInputParser, col: f32, row: f32) ?presentation_layout.PrecisePoint {
        if (self.target.layout.len > 0) return self.target.layout.mapFractionalCellToSdl(col, row);
        const cols: f32 = @floatFromInt(self.target.cols);
        const rows: f32 = @floatFromInt(self.target.rows);
        const w: f32 = @floatFromInt(self.target.w);
        const h: f32 = @floatFromInt(self.target.h);
        return .{
            .x = std.math.clamp((std.math.clamp(col, 1, cols + 1) - 1) * w / cols, 0, w - 1),
            .y = std.math.clamp((std.math.clamp(row, 1, rows + 1) - 1) * h / rows, 0, h - 1),
        };
    }

    pub fn injectKey(self: *TerminalInputParser, event: render_batch_protocol.KeyInput) !void {
        if (!event.valid()) return error.InvalidKey;
        const converted = try event.toNative();
        try self.pressKey(converted.key, converted.text());
    }

    /// Every local key source enters here: terminal bytes, structured host
    /// keys and, later, kitty keyboard events. The key is bound once with the
    /// static US-layout tables (no SDL calls: this runs on reader threads and
    /// in presenter processes without SDL), receives a press identity, and is
    /// projected into the SDL-shaped queue. `text` is the key's text commit,
    /// which shortcut modifiers suppress.
    pub fn pressKey(self: *InputModel, key: native_key.Key, text: []const u8) !void {
        if (try self.routeKey(key)) return;
        if (!self.source_focused) return;

        const commits_text = text.len != 0 and !key.modifiers.suppressText();
        switch (key.action) {
            .tap => {
                var down = try bindStatic(key);
                down.native.press = try self.mintPress();
                down.native.action = .down;
                self.holdKeyForPolling(down);
                try self.append(.{ .key_down = down });
                if (commits_text) try self.append(.{ .text = TextEvent.init(text) });
                var up = down;
                up.native.action = .up;
                try self.append(.{ .key_up = up });
            },
            .down, .repeat => {
                // A second down for a held key is a repeat with the same press.
                const held = self.localPressSlot(&key);
                const slot = held orelse try self.beginLocalPress(key);
                var event = slot.*.?;
                event.repeat = held != null;
                event.native.action = if (held != null) .repeat else .down;
                event.native.modifiers = key.modifiers;
                event.mods = sdlModifiers(key.modifiers);
                self.setHeld(event.scancode, true);
                try self.append(.{ .key_down = event });
                if (commits_text) try self.append(.{ .text = TextEvent.init(text) });
            },
            .up => {
                var event: KeyEvent = undefined;
                if (self.localPressSlot(&key)) |slot| {
                    event = slot.*.?;
                    slot.* = null;
                } else {
                    // Its press was already released at a routing/focus barrier.
                    return;
                }
                event.repeat = false;
                event.native.action = .up;
                event.native.modifiers = key.modifiers;
                event.mods = sdlModifiers(key.modifiers);
                self.setHeld(event.scancode, false);
                try self.append(.{ .key_up = event });
            },
        }
    }

    /// Real-window input remains usable outside command mode, but a held
    /// physical press cannot reappear after the virtual focus-loss barrier.
    pub fn routeNativeKey(self: *InputModel, scan: i32, down: bool) bool {
        if ((self.command_key == null and !self.source_focus_owned) or scan <= 0 or scan >= sdl_num_scancodes) return false;
        const index: usize = @intCast(scan);
        self.native_keys[index] = @intFromBool(down);
        const blocked = self.blocked_native_keys[index] or !self.applicationFocused();
        self.blocked_native_keys[index] = down and blocked;
        return blocked;
    }

    pub fn nativeModifiers(self: *const InputModel, raw: u16) u16 {
        if (!self.applicationFocused()) return 0;
        var result = raw;
        for ([_]u16{ 0x40, 1, 0x100, 0x400, 0x80, 2, 0x200, 0x800 }, 224..) |mask, scan| {
            if (self.blocked_native_keys[scan]) result &= ~mask;
        }
        return result;
    }

    pub fn nativeMouseButtons(self: *InputModel, buttons: u32) u32 {
        self.native_buttons = buttons;
        self.blocked_native_buttons &= buttons;
        if (!self.applicationFocused()) self.blocked_native_buttons |= buttons;
        return buttons & ~self.blocked_native_buttons;
    }

    pub fn routeNativeButton(self: *InputModel, button: u8, down: bool) bool {
        if (button == 0 or button > 32) return !self.applicationFocused();
        const mask = sdlButtonMask(button);
        const blocked = !self.applicationFocused() or self.blocked_native_buttons & mask != 0;
        _ = self.nativeMouseButtons(if (down) self.native_buttons | mask else self.native_buttons & ~mask);
        return blocked;
    }

    fn consumePress(self: *InputModel, key: NativeKey) !void {
        if (key.action == .tap or key.action == .up) return;
        for (&self.consumed_presses) |*slot| if (slot.* == null) {
            slot.* = key;
            return;
        };
        return error.Capacity;
    }

    fn routeKey(self: *InputModel, key: NativeKey) !bool {
        for (&self.consumed_presses) |*slot| if (slot.*) |held| {
            if (held.sameKey(&key)) {
                if (key.action == .up) slot.* = null;
                return true;
            }
        };
        const attention = if (self.command_key) |binding| command_binding.matches(binding, key) else false;
        if (self.routing_mode == .app and !attention) return false;
        // Neither a repeat nor a release can arm or execute a command.
        if (key.action == .up or key.action == .repeat) return true;
        try self.consumePress(key);
        if (self.routing_mode == .app) {
            try self.enterCommandMode();
        } else switch (command_binding.decode(self.command_key.?, key, .direct)) {
            .literal => {
                try self.leaveCommandMode();
                var down = try bindStatic(key);
                down.native.press = try self.mintPress();
                down.native.action = .down;
                try self.append(.{ .key_down = down });
                var up = down;
                up.native.action = .up;
                try self.append(.{ .key_up = up });
            },
            .cancel => try self.leaveCommandMode(),
            .quit => try self.requestQuit(),
            else => self.command_hint = true,
        }
        return true;
    }

    pub fn commandMenuSnapshot(self: *const InputModel, cols: u16, rows: u16) command_menu.Snapshot {
        return .{ .active = self.routing_mode == .command, .hint = self.command_hint, .quitting = self.quit_requested, .binding = self.command_key orelse ']', .cols = cols, .rows = rows };
    }

    pub fn applicationFocused(self: *const InputModel) bool {
        return self.source_focused and self.routing_mode != .command;
    }

    fn setSourceFocus(self: *InputModel, focused: bool) !void {
        self.source_focus_owned = true;
        if (self.source_focused == focused) return;
        self.source_focused = focused;
        if (focused) {
            if (self.routing_mode != .command) try self.append(.{ .focus = true });
        } else try self.releaseLocalFocus();
    }

    fn enterCommandMode(self: *InputModel) !void {
        self.routing_mode = .command;
        self.command_hint = false;
        try self.releaseLocalFocus();
    }

    fn releaseLocalFocus(self: *InputModel) !void {
        // Keep the input decoder's pending bytes: the command may share a read
        // with its prefix. Retire queued app work before emitting cleanup.
        var i: usize = 0;
        while (i < self.queue.items.len) {
            if (self.queue.items[i].controller == 0) {
                _ = self.queue.orderedRemove(i);
            } else i += 1;
        }
        for (&self.local_presses) |*slot| if (slot.*) |held| {
            try self.consumePress(held.native);
            var up = held;
            up.native.action = .up;
            up.repeat = false;
            up.mods = 0;
            up.native.modifiers = .{};
            slot.* = null;
            try self.append(.{ .key_up = up });
        };
        for (self.native_keys, 0..) |held, scan| {
            if (held == 0) continue;
            self.blocked_native_keys[scan] = true;
            const name = native_key.domCode(@intCast(scan)) orelse continue;
            var up = try bindStatic(try NativeKey.physical(name));
            up.native.press = try self.mintPress();
            up.native.action = .up;
            try self.append(.{ .key_up = up });
        }
        self.keyboard_state = @splat(0);
        self.keyboard_deadline_ns = @splat(0);
        self.consumed_terminal_buttons |= self.mouse_buttons;
        self.command_pointer_action = null;
        const buttons = self.mouse_buttons | self.native_buttons;
        self.blocked_native_buttons |= self.native_buttons;
        self.mouse_buttons = 0;
        for (0..32) |bit| {
            if (buttons & (@as(u32, 1) << @intCast(bit)) != 0) try self.append(.{ .mouse_button = .{
                .x = self.last_mouse_x,
                .y = self.last_mouse_y,
                .button = @intCast(bit + 1),
                .pressed = false,
            } });
        }
        self.focus_generation +%= 1;
        try self.append(.{ .focus = false });
    }

    fn leaveCommandMode(self: *InputModel) !void {
        self.routing_mode = .app;
        self.command_hint = false;
        self.command_pointer_action = null;
        try self.append(.{ .focus = true });
    }

    pub fn requestQuit(self: *InputModel) !void {
        if (self.quit_requested) return;
        try self.append(.quit);
        self.quit_requested = true;
    }

    fn tapNamed(self: *TerminalInputParser, name: []const u8) !void {
        try self.pressKey(native_key.Key.logical(name) catch unreachable, "");
    }

    fn tapCharacter(self: *TerminalInputParser, codepoint: u21, text: []const u8, modifiers: native_key.Modifiers) !void {
        var key = native_key.Key.character(codepoint);
        key.modifiers = modifiers;
        try self.pressKey(key, text);
    }

    fn mintPress(self: *InputModel) !u64 {
        if (self.next_press == std.math.maxInt(u64)) return error.Capacity;
        defer self.next_press += 1;
        return self.next_press;
    }

    fn localPressSlot(self: *InputModel, key: *const native_key.Key) ?*?KeyEvent {
        for (&self.local_presses) |*slot| if (slot.*) |press| {
            if (press.native.sameKey(key)) return slot;
        };
        return null;
    }

    fn beginLocalPress(self: *InputModel, key: native_key.Key) !*?KeyEvent {
        for (&self.local_presses) |*slot| if (slot.* == null) {
            var event = try bindStatic(key);
            event.native.press = try self.mintPress();
            event.native.action = .down;
            slot.* = event;
            return slot;
        };
        return error.Capacity;
    }

    fn setHeld(self: *InputModel, scancode: i32, held: bool) void {
        if (scancode <= 0 or scancode >= sdl_num_scancodes) return;
        const index: usize = @intCast(scancode);
        self.keyboard_state[index] = @intFromBool(held);
        self.keyboard_deadline_ns[index] = if (held) std.math.maxInt(i128) else 0;
    }

    fn holdKeyForPolling(self: *TerminalInputParser, key: KeyEvent) void {
        if (key.scancode < 0) return;
        const idx: usize = @intCast(key.scancode);
        if (idx >= self.keyboard_state.len) return;
        self.keyboard_state[idx] = 1;
        self.keyboard_deadline_ns[idx] = system_io.time.nanoTimestamp() + keyboard_poll_hold_ns;
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

/// SDL modifier bits for native modifiers. Super and meta both project to the
/// GUI key; SDL has one notion of that key.
pub fn sdlModifiers(modifiers: native_key.Modifiers) u16 {
    var result: u16 = 0;
    if (modifiers.shift) result |= 0x0001;
    if (modifiers.control) result |= 0x0040;
    if (modifiers.alt) result |= 0x0100;
    if (modifiers.super or modifiers.meta) result |= 0x0400;
    if (modifiers.num_lock) result |= 0x1000;
    if (modifiers.caps_lock) result |= 0x2000;
    if (modifiers.alt_graph) result |= 0x4000;
    return result;
}

/// Bind a native key with the static US-layout tables. This is the binding
/// every source gets when no SDL keymap is available or safe to consult; the
/// SDL adapters refine it through `sdl_input_binding.bind`.
pub fn bindStatic(key: native_key.Key) !KeyEvent {
    var event = KeyEvent{ .keycode = 0, .scancode = 0, .mods = sdlModifiers(key.modifiers), .native = key };
    switch (key.kind) {
        .physical => {
            event.scancode = native_key.domUsage(key.name.slice()) orelse return error.Unsupported;
            event.keycode = staticKeycodeForUsage(event.scancode);
        },
        .logical => {
            event.keycode = try logicalKeycode(key.name.slice());
            event.scancode = if (!key.code.isEmpty())
                native_key.domUsage(key.code.slice()) orelse 0
            else if (key.codepoint()) |cp|
                (if (cp < 0x80) native_key.usLayoutUsage(@intCast(cp)) else 0)
            else
                native_key.domUsage(key.name.slice()) orelse 0;
        },
    }
    return event;
}

/// SDL keycode of a logical key: one character, or a DOM key name that means
/// the same at every layout. Positional DOM codes are physical only.
pub fn logicalKeycode(name: []const u8) !i32 {
    if ((std.unicode.utf8CountCodepoints(name) catch return error.Unsupported) == 1) {
        const cp = std.unicode.utf8Decode(name) catch return error.Unsupported;
        // SDL keycodes are unshifted: Shift+A is keycode 'a' with the modifier.
        if (cp < 0x80 and std.ascii.isUpper(@intCast(cp))) return std.ascii.toLower(@intCast(cp));
        return @intCast(cp);
    }
    const usage = native_key.domUsage(name) orelse return error.Unsupported;
    if (native_key.isPositionalName(name)) return error.Unsupported;
    return staticKeycodeForUsage(usage);
}

/// The keycode SDL gives a key position under the US layout.
fn staticKeycodeForUsage(usage: i32) i32 {
    if (usage >= 4 and usage <= 29) return 'a' + usage - 4;
    if (usage >= 30 and usage <= 38) return '1' + usage - 30;
    return switch (usage) {
        39 => '0',
        40 => 13,
        41 => 27,
        42 => 8,
        43 => 9,
        44 => 32,
        45 => '-',
        46 => '=',
        47 => '[',
        48 => ']',
        49 => '\\',
        51 => ';',
        52 => '\'',
        53 => '`',
        54 => ',',
        55 => '.',
        56 => '/',
        76 => 127,
        else => sdlKeycodeFromScancode(usage),
    };
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
    // Clamp before @intFromFloat to avoid a checked-cast panic on hostile or
    // misbehaving wire values (delta_x/delta_y are i32-rounded f64s parsed from
    // JSON; a value like 1e18 would otherwise abort the producer). Real wheels
    // emit ±1–5 ticks per notch; ±1000 is well above any plausible host input
    // and well below the i32 overflow range.
    const clamped = std.math.clamp(v, -1000.0, 1000.0);
    if (clamped >= 0) return @intFromFloat(clamped + 0.5);
    return @intFromFloat(clamped - 0.5);
}

fn decodeLegacyMouseByte(byte: u8) ?i32 {
    if (byte < 32) return null;
    return @as(i32, byte) - 32;
}

fn isIncompleteEscape(bytes: []const u8) bool {
    if (bytes.len == 1) return true;
    if (bytes[1] == 'O') return bytes.len == 2;
    if (bytes[1] != '[') return false;
    if (bytes.len == 2) return true;
    return isIncompleteCsi(bytes, 2);
}

/// Bytes the legacy Alt encoding prefixes with ESC. Another ESC starts its
/// own sequence and C1/UTF-8 lead bytes are not Alt-prefixed.
fn isAltPrefixedByte(byte: u8) bool {
    return byte < 0x80 and byte != 0x1b;
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

pub fn inputEventSdlType(event: InputEvent) u32 {
    return switch (event) {
        .focus => 0x200,
        .quit => 0x100,
        .key_down => sdl_event_key_down,
        .key_up => sdl_event_key_up,
        .text, .text_commit => sdl_event_text_input,
        .mouse_motion => sdl_event_mouse_motion,
        .mouse_button => |button| if (button.pressed) sdl_event_mouse_button_down else sdl_event_mouse_button_up,
        .mouse_wheel => sdl_event_mouse_wheel,
    };
}

fn expectKeyTransition(comptime tag: std.meta.Tag(InputEvent), keycode: i32, scancode: i32, mods: u16, event: InputEvent) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(event));
    const key = switch (event) {
        .key_down, .key_up => |key| key,
        else => unreachable,
    };
    try std.testing.expectEqual(keycode, key.keycode);
    try std.testing.expectEqual(scancode, key.scancode);
    try std.testing.expectEqual(mods, key.mods);
}

test "terminal input parser emits printable key text and key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    try std.testing.expectEqual(@as(usize, 3), parser.pendingCount());
    try expectKeyTransition(.key_down, 'a', 4, 0, parser.pop().?);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
    try expectKeyTransition(.key_up, 'a', 4, 0, parser.pop().?);
}

test "terminal input parser can pop events by SDL type range" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    try expectKeyTransition(.key_down, 'a', 4, 0, parser.popSdlRange(sdl_event_key_down, sdl_event_key_up).?);
    try expectKeyTransition(.key_up, 'a', 4, 0, parser.popSdlRange(sdl_event_key_down, sdl_event_key_up).?);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
}

test "terminal input parser exposes recent keys through polling state" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("a");

    var state = [_]u8{0} ** sdl_num_scancodes;
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 1), state[4]);

    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp() + keyboard_poll_hold_ns + 1);
    try std.testing.expectEqual(@as(u8, 0), state[4]);
}

test "terminal input parser emits arrow key transitions" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b[A");

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try expectKeyTransition(.key_down, sdlKeycodeFromScancode(82), 82, 0, parser.pop().?);
    try expectKeyTransition(.key_up, sdlKeycodeFromScancode(82), 82, 0, parser.pop().?);
}

test "terminal input parser emits c1 delete key" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x9b3~");

    try expectKeyTransition(.key_down, 0x7f, 76, 0, parser.pop().?);
    try expectKeyTransition(.key_up, 0x7f, 76, 0, parser.pop().?);
}

test "terminal input parser emits encoded escape without a tty flush" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b[27u");
    try expectKeyTransition(.key_down, 0x1b, 41, 0, parser.pop().?);
    try expectKeyTransition(.key_up, 0x1b, 41, 0, parser.pop().?);
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "terminal input parser flushes standalone escape" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("\x1b");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());

    try parser.flushStandaloneEscape();

    try std.testing.expectEqual(@as(usize, 2), parser.pendingCount());
    try expectKeyTransition(.key_down, 0x1b, 41, 0, parser.pop().?);
    try expectKeyTransition(.key_up, 0x1b, 41, 0, parser.pop().?);
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

test "injectPointer wheel clamps absurdly large deltas without panicking" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400 });

    try parser.injectPointer(.{
        .kind = .wheel,
        .row = 26,
        .col = 51,
        .button = -1,
        .buttons = 0,
        .delta_y = 1e18,
    });

    const event = parser.pop().?;
    // Clamp at ±1000 lines; delta_y sign is flipped to SDL convention, so a
    // huge positive deltaY → SDL y = -1000.
    try std.testing.expectEqual(@as(i32, -1000), event.mouse_wheel.y);
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

test "source pointer uses image pixels and shares mouse state with terminal input" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .w = 320, .h = 200, .cols = 20, .rows = 5 });
    try parser.injectSourcePointer(.{ .x = 247, .y = 123, .width = 320, .height = 200, .kind = .pointerdown, .button = 0, .buttons = 1 });
    const down = parser.pop().?.mouse_button;
    try std.testing.expectEqual(@as(i32, 247), down.x);
    try std.testing.expectEqual(@as(i32, 123), parser.mouseState().y);
    try std.testing.expectEqual(@as(u32, 1), parser.mouseState().buttons);
    parser.setTarget(.{ .w = 640, .h = 480 });
    try parser.injectSourcePointer(.{ .x = 247, .y = 123, .width = 320, .height = 200, .kind = .pointerup, .button = 0 });
    try std.testing.expect(!parser.pop().?.mouse_button.pressed);
    try std.testing.expectEqual(@as(u32, 0), parser.mouseState().buttons);
    try std.testing.expectError(error.StaleSourceSize, parser.injectSourcePointer(.{ .x = 1, .y = 1, .width = 320, .height = 200, .kind = .pointermove }));
}

test "source image pixels map into logical window input coordinates" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .w = 200, .h = 100, .source_px = .{ .w = 400, .h = 200 } });
    try parser.injectSourcePointer(.{ .x = 300, .y = 100, .width = 400, .height = 200, .kind = .pointermove });
    const event = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 150), event.x);
    try std.testing.expectEqual(@as(i32, 50), event.y);
    try std.testing.expectError(error.StaleSourceSize, parser.injectSourcePointer(.{ .x = 10, .y = 10, .width = 200, .height = 100, .kind = .pointermove }));
}

test "structured keys share tap events and polling state and support held keys" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.injectKey(.{ .key = "a", .shift = true });
    try std.testing.expectEqual(@as(u16, 1), parser.pop().?.key_down.mods);
    try std.testing.expectEqual(std.meta.Tag(InputEvent).text, std.meta.activeTag(parser.pop().?));
    try std.testing.expectEqual(std.meta.Tag(InputEvent).key_up, std.meta.activeTag(parser.pop().?));
    try parser.injectKey(.{ .key = "up", .action = .down, .ctrl = true });
    const down = parser.pop().?.key_down;
    try std.testing.expectEqual(@as(i32, 82), down.scancode);
    try std.testing.expectEqual(@as(u16, 0x40), down.mods);
    var state: [sdl_num_scancodes]u8 = undefined;
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp() + 10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u8, 1), state[82]);
    try parser.injectKey(.{ .key = "up", .action = .up });
    try std.testing.expectEqual(@as(i32, 82), parser.pop().?.key_up.scancode);
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 0), state[82]);
    try std.testing.expectError(error.InvalidKey, parser.injectKey(.{ .key = "not-a-key" }));
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
}

test "terminal UTF8 prefix survives a large following read" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    try model.feed("\xc3");
    try model.feed("\xa9" ++ "x" ** 300);
    try std.testing.expectEqual(@as(i32, 0xe9), model.pop().?.key_down.keycode);
    try std.testing.expectEqualStrings("é", model.pop().?.text.bytes());
}

test "native snapshots change canonical position only on native activity" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    try std.testing.expect(model.updateNativeMouse(0, 0, 0));
    try model.injectSourcePointer(.{ .x = 10, .y = 10, .width = 640, .height = 480, .kind = .pointermove });
    const remote = model.mouseState();
    try std.testing.expect(!model.updateNativeMouse(0, 0, 0));
    try std.testing.expectEqual(remote.x, model.mouseState().x);
    try std.testing.expect(model.updateNativeMouse(100.5, 120.25, 0));
    try std.testing.expectEqual(@as(i32, 100), model.mouseState().x);
    try std.testing.expectEqual(@as(?f32, 100.5), model.mouseState().precise_x);
}

test "remote delivery retires only acknowledged state copies when capacity is needed" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    // Unobserved local transitions must remain in their original order.
    try model.injectSourcePointer(.{ .x = 1, .y = 1, .width = 640, .height = 480, .kind = .pointerdown, .button = 0, .buttons = 1 });
    for (0..767) |_| {
        try model.beginDelivery(.keyboard, 1);
        model.appendRemote(1, .{ .key_up = .{ .scancode = 4, .keycode = 'a' } });
        model.observeState(.keyboard);
        try std.testing.expect(model.deliveryFinished());
        model.finishDelivery();
    }
    try std.testing.expectEqual(@as(usize, 768), model.pendingCount());
    try model.beginDelivery(.keyboard, 1);
    model.appendRemote(1, .{ .key_up = .{ .scancode = 225, .keycode = 0 } });
    try std.testing.expectEqual(@as(usize, 2), model.pendingCount());
    try std.testing.expect(model.pop().? == .mouse_button);
    try std.testing.expect(!model.deliveryFinished());
    try std.testing.expectEqual(@as(i32, 225), model.pop().?.key_up.scancode);
    try std.testing.expect(model.deliveryFinished());
    model.finishDelivery();
}

test "terminal keys carry native names and a shared press identity per tap" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.feed("A\x1b[A\x01");
    const shifted = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("A", shifted.native.name.slice());
    try std.testing.expectEqual(native_key.Kind.logical, shifted.native.kind);
    try std.testing.expect(shifted.native.modifiers.shift);
    try std.testing.expectEqual(@as(i32, 'a'), shifted.keycode);
    try std.testing.expectEqual(@as(i32, 4), shifted.scancode);
    try std.testing.expectEqual(@as(u16, 1), shifted.mods);
    try std.testing.expectEqualStrings("A", parser.pop().?.text.bytes());
    const released = parser.pop().?.key_up;
    try std.testing.expectEqual(shifted.native.press, released.native.press);
    try std.testing.expectEqual(native_key.Action.up, released.native.action);
    const arrow = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("ArrowUp", arrow.native.name.slice());
    try std.testing.expect(arrow.native.press > shifted.native.press);
    _ = parser.pop().?.key_up;
    const control = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("a", control.native.name.slice());
    try std.testing.expect(control.native.modifiers.control);
    try std.testing.expectEqual(@as(u16, 0x40), control.mods);
    try std.testing.expectEqual(std.meta.Tag(InputEvent).key_up, std.meta.activeTag(parser.pop().?));
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "native key presses keep the down binding and identity through repeat and release" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    var key = try native_key.Key.logical("Enter");
    key.action = .down;
    try parser.pressKey(key, "");
    const down = parser.pop().?.key_down;
    try std.testing.expectEqual(@as(i32, 13), down.keycode);
    try std.testing.expectEqual(@as(i32, 40), down.scancode);
    try std.testing.expect(!down.repeat);
    try std.testing.expect(down.native.press != 0);
    var state: [sdl_num_scancodes]u8 = undefined;
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp() + 10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u8, 1), state[40]);
    key.modifiers = .{ .control = true };
    try parser.pressKey(key, "");
    const repeated = parser.pop().?.key_down;
    try std.testing.expect(repeated.repeat);
    try std.testing.expectEqual(down.native.press, repeated.native.press);
    try std.testing.expectEqual(native_key.Action.repeat, repeated.native.action);
    try std.testing.expectEqual(@as(u16, 0x40), repeated.mods);
    key.action = .up;
    key.modifiers = .{};
    try parser.pressKey(key, "");
    const up = parser.pop().?.key_up;
    try std.testing.expectEqual(down.native.press, up.native.press);
    try std.testing.expectEqual(@as(i32, 40), up.scancode);
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 0), state[40]);
    // The next down of the same key is a new press.
    key.action = .down;
    try parser.pressKey(key, "");
    try std.testing.expect(parser.pop().?.key_down.native.press > up.native.press);
}

test "native key presses commit text unless a shortcut modifier is held" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    var key = native_key.Key.character('x');
    key.action = .down;
    try parser.pressKey(key, "x");
    _ = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("x", parser.pop().?.text.bytes());
    key.modifiers = .{ .alt = true };
    try parser.pressKey(key, "x");
    try std.testing.expect(parser.pop().?.key_down.repeat);
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "static binding follows the Jackstay key vocabulary" {
    const physical = try bindStatic(try native_key.Key.physical("KeyQ"));
    try std.testing.expectEqual(@as(i32, 20), physical.scancode);
    try std.testing.expectEqual(@as(i32, 'q'), physical.keycode);
    const minus = try bindStatic(try native_key.Key.physical("Minus"));
    try std.testing.expectEqual(@as(i32, '-'), minus.keycode);
    const f5 = try bindStatic(try native_key.Key.logical("F5"));
    try std.testing.expectEqual(@as(i32, 62), f5.scancode);
    try std.testing.expectEqual(sdlKeycodeFromScancode(62), f5.keycode);
    const symbol = try bindStatic(native_key.Key.character('!'));
    try std.testing.expectEqual(@as(i32, '!'), symbol.keycode);
    try std.testing.expectEqual(@as(i32, 0), symbol.scancode);
    var shifted = native_key.Key.character('Q');
    shifted.modifiers = .{ .shift = true, .caps_lock = true };
    const bound = try bindStatic(shifted);
    try std.testing.expectEqual(@as(i32, 'q'), bound.keycode);
    try std.testing.expectEqual(@as(u16, 0x2001), bound.mods);
    try std.testing.expectError(error.Unsupported, bindStatic(try native_key.Key.physical("Unknown")));
    try std.testing.expectError(error.Unsupported, logicalKeycode("KeyA"));
    try std.testing.expectError(error.Unsupported, logicalKeycode("ShiftLeft"));
    try std.testing.expectEqual(@as(i32, 27), try logicalKeycode("Escape"));
}

test "terminal parser decodes legacy modified keys, SS3 and Alt prefixes" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.feed("\x1b[1;5A\x1b[15~\x1bOD\x1bx\x1b[24;2~");
    const control_up = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("ArrowUp", control_up.native.name.slice());
    try std.testing.expectEqual(@as(u16, 0x40), control_up.mods);
    try std.testing.expectEqual(@as(i32, 82), control_up.scancode);
    _ = parser.pop().?.key_up;
    const f5 = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("F5", f5.native.name.slice());
    try std.testing.expectEqual(sdlKeycodeFromScancode(62), f5.keycode);
    _ = parser.pop().?.key_up;
    const ss3_left = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("ArrowLeft", ss3_left.native.name.slice());
    _ = parser.pop().?.key_up;
    const alt_x = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("x", alt_x.native.name.slice());
    try std.testing.expect(alt_x.native.modifiers.alt);
    try std.testing.expectEqual(@as(u16, 0x100), alt_x.mods);
    try std.testing.expectEqual(std.meta.Tag(InputEvent).key_up, std.meta.activeTag(parser.pop().?));
    const shift_f12 = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("F12", shift_f12.native.name.slice());
    try std.testing.expectEqual(@as(u16, 1), shift_f12.mods);
    _ = parser.pop().?.key_up;
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "terminal parser flushes ESC O as Alt+O and waits for an SS3 final" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    try parser.feed("\x1bO");
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
    try parser.flushStandaloneEscape();
    const alt_o = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("O", alt_o.native.name.slice());
    try std.testing.expect(alt_o.native.modifiers.alt and alt_o.native.modifiers.shift);
    _ = parser.pop().?.key_up;
    try parser.feed("\x1bOx");
    try std.testing.expectEqualStrings("O", parser.pop().?.key_down.native.name.slice());
    _ = parser.pop().?.key_up;
    try std.testing.expectEqualStrings("x", parser.pop().?.key_down.native.name.slice());
}

test "terminal parser turns kitty reports into held presses with positions and text" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    // Until the terminal confirms event reporting, a bare report is a tap.
    try parser.feed("\x1b[97u");
    try std.testing.expectEqual(@as(usize, 3), parser.pendingCount());
    while (parser.pop()) |_| {}
    try parser.feed("\x1b[?31u");
    try std.testing.expectEqual(@as(u32, 31), parser.keyboard_protocol_flags);
    try std.testing.expectEqual(@as(usize, 0), parser.pendingCount());
    // AZERTY 'a' at the US Q position: held, shifted mid-press, released.
    try parser.feed("\x1b[97::113;1;97u");
    const down = parser.pop().?.key_down;
    try std.testing.expectEqualStrings("a", down.native.name.slice());
    try std.testing.expectEqualStrings("KeyQ", down.native.code.slice());
    try std.testing.expectEqual(@as(i32, 20), down.scancode);
    try std.testing.expectEqual(@as(i32, 'a'), down.keycode);
    try std.testing.expectEqualStrings("a", parser.pop().?.text.bytes());
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
    var state: [sdl_num_scancodes]u8 = undefined;
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp() + std.time.ns_per_s);
    try std.testing.expectEqual(@as(u8, 1), state[20]);
    try parser.feed("\x1b[97:65:113;2:2;65u");
    const repeat = parser.pop().?.key_down;
    try std.testing.expect(repeat.repeat);
    try std.testing.expectEqual(down.native.press, repeat.native.press);
    // The repeat keeps the binding and name its down established; the
    // shifted character arrives as text.
    try std.testing.expectEqualStrings("a", repeat.native.name.slice());
    try std.testing.expect(repeat.native.modifiers.shift);
    try std.testing.expectEqual(@as(u16, 1), repeat.mods);
    try std.testing.expectEqualStrings("A", parser.pop().?.text.bytes());
    try parser.feed("\x1b[97::113;1:3u");
    const up = parser.pop().?.key_up;
    try std.testing.expectEqual(down.native.press, up.native.press);
    try std.testing.expectEqual(@as(i32, 20), up.scancode);
    parser.copyKeyboardState(&state, system_io.time.nanoTimestamp());
    try std.testing.expectEqual(@as(u8, 0), state[20]);
    // Modifier keys are physical positions with real transitions.
    try parser.feed("\x1b[57441;2u\x1b[57441;1:3u");
    const shift_down = parser.pop().?.key_down;
    try std.testing.expectEqual(@as(i32, 225), shift_down.scancode);
    try std.testing.expectEqual(sdlKeycodeFromScancode(225), shift_down.keycode);
    try std.testing.expectEqual(@as(i32, 225), parser.pop().?.key_up.scancode);
    // Escape is unambiguous and unknown functional keys are dropped.
    try parser.feed("\x1b[27u\x1b[57428u\x1b[27;1:3u");
    try std.testing.expectEqualStrings("Escape", parser.pop().?.key_down.native.name.slice());
    try std.testing.expectEqualStrings("Escape", parser.pop().?.key_up.native.name.slice());
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "terminal input parser maps pixel mouse reports with sub-cell precision" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    var layout = presentation_layout.PresentationLayout{};
    layout.setSingleSdlRegion(.{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    });
    parser.setTarget(.{ .cols = 100, .rows = 40, .w = 320, .h = 240, .layout = layout, .cell_px = .{ .w = 10, .h = 20 } });
    const generation = parser.mapping_generation;
    // Cells until the terminal confirms pixels.
    try parser.feed("\x1b[<35;11;6M");
    try std.testing.expectEqual(InputEvent{ .mouse_motion = .{ .x = 0, .y = 0, .xrel = 0, .yrel = 0, .buttons = 0 } }, parser.pop().?);
    try parser.feed("\x1b[?1016;1$y");
    try std.testing.expectEqual(terminal_keys.MouseUnits.pixel, parser.mouse_units);
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
    // Pixel 101,101 is the first pixel of cell 11,6.
    try parser.feed("\x1b[<35;101;101M");
    const origin = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 0), origin.x);
    try std.testing.expectEqual(@as(f32, 0), origin.precise_x.?);
    try parser.feed("\x1b[<0;505;401M");
    const press = parser.pop().?.mouse_button;
    try std.testing.expectEqual(@as(i32, 161), press.x);
    try std.testing.expectEqual(@as(i32, 120), press.y);
    try std.testing.expect(@abs(press.precise_x.? - 161.6) < 0.01);
    try std.testing.expectEqual(@as(f32, 120), press.precise_y.?);
    try std.testing.expect(press.pressed);
    try parser.feed("\x1b[<32;515;401M");
    const drag = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 165), drag.x);
    try std.testing.expectEqual(@as(i32, 4), drag.xrel);
    try std.testing.expect(@abs(drag.precise_xrel.? - 4.0) < 0.01);
    try std.testing.expectEqual(@as(u32, 1), drag.buttons);
    const state = parser.mouseState();
    try std.testing.expect(@abs(state.precise_x.? - 165.6) < 0.01);
    // Outside the layout nothing targets SDL; legacy encodings stay cells.
    try parser.feed("\x1b[<35;5;5M");
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
    try parser.feed("\x1b[<64;505;401M");
    const wheel = parser.pop().?.mouse_wheel;
    try std.testing.expectEqual(@as(i32, 161), wheel.mouse_x);
    try std.testing.expect(wheel.precise_mouse_x != null);
    // A changed cell size is a new mapping.
    parser.setTarget(.{ .cols = 100, .rows = 40, .w = 320, .h = 240, .layout = layout, .cell_px = .{ .w = 8, .h = 16 } });
    try std.testing.expect(parser.mapping_generation != generation);
    // Without a cell size pixel reports cannot be placed.
    parser.setTarget(.{ .cols = 100, .rows = 40, .w = 320, .h = 240, .layout = layout });
    try parser.feed("\x1b[<35;505;401M");
    try std.testing.expectEqual(@as(?InputEvent, null), parser.pop());
}

test "terminal input parser maps pixel reports without a layout" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400, .cell_px = .{ .w = 10, .h = 20 } });
    try parser.feed("\x1b[?1016;1$y\x1b[<35;251;301M");
    const motion = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 200), motion.x);
    try std.testing.expectEqual(@as(i32, 120), motion.y);
    try parser.feed("\x1b[<35;5000;5000M");
    const clamped = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 799), clamped.x);
    try std.testing.expectEqual(@as(i32, 399), clamped.y);
}

test "terminal input parser honours a zero-based pixel origin" {
    var parser = TerminalInputParser.init(std.testing.allocator);
    defer parser.deinit();
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400, .cell_px = .{ .w = 10, .h = 20 }, .pixel_origin = 0 });
    try parser.feed("\x1b[?1016;1$y\x1b[<35;250;300M");
    const motion = parser.pop().?.mouse_motion;
    try std.testing.expectEqual(@as(i32, 200), motion.x);
    try std.testing.expectEqual(@as(i32, 120), motion.y);
    try parser.feed("\x1b[<35;0;0M");
    try std.testing.expectEqual(@as(i32, 0), parser.pop().?.mouse_motion.x);
    const before = parser.mapping_generation;
    parser.setTarget(.{ .cols = 100, .rows = 50, .w = 800, .h = 400, .cell_px = .{ .w = 10, .h = 20 }, .pixel_origin = 1 });
    try std.testing.expect(parser.mapping_generation != before);
}

test "command prefix releases held input and cancels without leaking repeats" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    model.command_key = ']';
    try model.feed("\x1b[?31u\x1b[119;1:1u\x1b[<0;2;2M");
    while (model.pop() != null) {}
    try model.feed("\x1b[93;5:1u");
    try std.testing.expectEqual(RoutingMode.command, model.routing_mode);
    try std.testing.expectEqual(@as(i32, 26), model.pop().?.key_up.scancode);
    try std.testing.expect(!model.pop().?.mouse_button.pressed);
    try std.testing.expect(!model.pop().?.focus);
    try std.testing.expect(model.pop() == null);
    var state: [sdl_num_scancodes]u8 = undefined;
    model.copyKeyboardState(&state, 0);
    try std.testing.expectEqual(@as(u8, 0), state[26]);
    try std.testing.expectEqual(@as(u32, 0), model.mouseState().buttons);
    try model.feed("\x1b[27;1:1u");
    try std.testing.expectEqual(RoutingMode.app, model.routing_mode);
    try std.testing.expect(model.pop().?.focus);
    try model.feed("\x1b[119;1:2u\x1b[93;5:2u\x1b[27;1:2u\x1b[119;1:3u\x1b[93;5:3u\x1b[27;1:3u");
    try std.testing.expect(model.pop() == null);
    try model.feed("\x1b[119;1:1u");
    try std.testing.expectEqual(@as(i32, 26), model.pop().?.key_down.scancode);
}

test "command doubled prefix is one literal tap in legacy and kitty encodings" {
    for ([_][]const u8{ "\x1d\x1d", "\x1b[?31u\x1b[93;5:1u\x1b[93;5:3u\x1b[93;5:1u" }) |bytes| {
        var model = InputModel.init(std.testing.allocator);
        defer model.deinit();
        model.command_key = ']';
        try model.feed(bytes);
        try std.testing.expect(!model.pop().?.focus);
        try std.testing.expect(model.pop().?.focus);
        const down = model.pop().?.key_down;
        const up = model.pop().?.key_up;
        try std.testing.expectEqual(@as(i32, ']'), down.keycode);
        try std.testing.expectEqual(@as(u16, 0x40), down.mods);
        try std.testing.expectEqual(down.native.press, up.native.press);
        try model.feed("\x1b[93;5:2u\x1b[93;5:3u");
        try std.testing.expect(model.pop() == null);
    }
}

test "command paste cannot cancel or quit even across read boundaries" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    model.command_key = ']';
    try model.feed("\x1d");
    _ = model.pop();
    for ("\x1b[200~\x1b\x1dq\x1b[201~") |byte| try model.feed(&.{byte});
    try std.testing.expectEqual(RoutingMode.command, model.routing_mode);
    try std.testing.expect(!model.quit_requested);
    try std.testing.expect(!model.command_hint);
    try model.feed("x\x1b[<0;3;3M");
    try std.testing.expect(model.command_hint);
    try std.testing.expect(model.pop() == null);
    try model.feed("q");
    try std.testing.expect(model.quit_requested);
    try std.testing.expectEqual(std.meta.Tag(InputEvent).quit, std.meta.activeTag(model.pop().?));
    try model.feed("q");
    try std.testing.expect(model.pop() == null);
}

test "command routing blocks native held keys until their physical release" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    model.command_key = ']';
    try std.testing.expect(!model.routeNativeKey(26, true));
    try model.feed("\x1d");
    try std.testing.expectEqual(@as(i32, 26), model.pop().?.key_up.scancode);
    _ = model.pop();
    try model.feed("\x1b[27u");
    _ = model.pop();
    try std.testing.expect(model.routeNativeKey(26, true));
    try std.testing.expect(model.routeNativeKey(26, false));
    try std.testing.expect(!model.routeNativeKey(26, true));
}

test "command binding uses base layout and disabled models forward the prefix" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    try model.feed("\x1dq");
    try std.testing.expectEqual(@as(i32, ']'), model.pop().?.key_down.keycode);
    while (model.pop() != null) {}
    model.command_key = ']';
    // Logical layout key differs, but its reported base position is BracketRight.
    try model.feed("\x1b[?31u\x1b[229::93;5:1u");
    try std.testing.expectEqual(RoutingMode.command, model.routing_mode);
    try std.testing.expect(!model.pop().?.focus);
    // Releasing with a changed logical name still retires the consumed press.
    try model.feed("\x1b[93::93;1:3u\x1b[27;1:1u");
    try std.testing.expect(model.pop().?.focus);
    try model.feed("\x1b[93;7:1u"); // Alt+Ctrl is not the configured prefix.
    try std.testing.expectEqual(RoutingMode.app, model.routing_mode);
    try std.testing.expectEqual(@as(i32, ']'), model.pop().?.key_down.keycode);
}

test "command menu clicks require matching release and consume pointer gestures" {
    var model = InputModel.init(std.testing.allocator);
    defer model.deinit();
    model.command_key = ']';
    try model.feed("\x1d");
    _ = model.pop();
    try model.feed("\x1b[<0;13;24M");
    try std.testing.expectEqual(RoutingMode.command, model.routing_mode);
    try model.feed("\x1b[<0;13;23m");
    try std.testing.expectEqual(RoutingMode.command, model.routing_mode);
    try model.feed("\x1b[<0;13;24M\x1b[<0;13;24m");
    try std.testing.expectEqual(RoutingMode.app, model.routing_mode);
    try std.testing.expect(model.pop().?.focus);
    try std.testing.expect(model.pop() == null);
    try model.feed("\x1d\x1b[<0;3;24M\x1b[27u\x1b[<0;3;24m");
    try std.testing.expect(!model.pop().?.focus);
    try std.testing.expect(model.pop().?.focus);
    try std.testing.expect(model.pop() == null);
    try std.testing.expect(!model.quit_requested);
    // Pixel reports use the terminal's pixel origin and cell size, not game pixels.
    model.mouse_units = .pixel;
    model.target.pixel_origin = 0;
    model.target.cell_px = .{ .w = 10, .h = 20 };
    try model.feed("\x1d\x1b[<0;25;470M\x1b[<0;25;470m");
    try std.testing.expect(!model.pop().?.focus);
    try std.testing.expectEqual(std.meta.Tag(InputEvent).quit, std.meta.activeTag(model.pop().?));
    try std.testing.expect(model.pop() == null);
}
