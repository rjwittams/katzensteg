const std = @import("std");

pub const board_w: i32 = 10;
pub const board_h: i32 = 20;
pub const fps: f32 = 30.0;
pub const gravity_base: f32 = 0.75;
pub const lock_delay: f32 = 0.45;

pub const Point = struct { x: i32, y: i32 };

pub const PieceKind = enum(u8) { I, O, T, S, Z, J, L };

pub const ActivePiece = struct {
    kind: PieceKind,
    x: i32,
    y: i32,
    rot: u8,
};

pub const InputState = struct {
    left: bool = false,
    right: bool = false,
    soft_drop: bool = false,
    rotate_cw: bool = false,
    rotate_ccw: bool = false,
    hard_drop: bool = false,
    hold: bool = false,
    pause: bool = false,
    help: bool = false,
    quit: bool = false,
    restart: bool = false,
};

pub const SharedInput = struct {
    mutex: std.Thread.Mutex = .{},
    state: InputState = .{},
    stop: bool = false,
};

pub const Game = struct {
    board: [board_h][board_w]u8 = [_][board_w]u8{[_]u8{0} ** board_w} ** board_h,
    current: ActivePiece,
    next: PieceKind,
    hold: ?PieceKind = null,
    hold_used: bool = false,
    prng: std.Random.DefaultPrng,
    fall_timer: f32 = 0,
    lock_timer: f32 = 0,
    score: u32 = 0,
    lines: u32 = 0,
    level: u32 = 1,
    game_over: bool = false,
    paused: bool = false,
    show_help: bool = false,
    clear_fx_timer: f32 = 0,
    clear_fx_rows: [4]i32 = .{ -1, -1, -1, -1 },
    clear_fx_count: usize = 0,

    pub fn init(seed: u64) Game {
        var game = Game{
            .current = .{ .kind = .T, .x = 3, .y = 0, .rot = 0 },
            .next = .I,
            .prng = std.Random.DefaultPrng.init(seed),
        };
        game.current = game.makePiece(game.randomKind());
        game.next = game.randomKind();
        return game;
    }

    pub fn reset(self: *Game) void {
        self.board = [_][board_w]u8{[_]u8{0} ** board_w} ** board_h;
        self.current = self.makePiece(self.randomKind());
        self.next = self.randomKind();
        self.hold = null;
        self.hold_used = false;
        self.fall_timer = 0;
        self.lock_timer = 0;
        self.score = 0;
        self.lines = 0;
        self.level = 1;
        self.game_over = false;
        self.paused = false;
        self.show_help = false;
        self.clear_fx_timer = 0;
        self.clear_fx_rows = .{ -1, -1, -1, -1 };
        self.clear_fx_count = 0;
    }

    fn randomKind(self: *Game) PieceKind {
        return @enumFromInt(self.prng.random().uintLessThan(u8, 7));
    }

    fn makePiece(_: *Game, kind: PieceKind) ActivePiece {
        return .{ .kind = kind, .x = 3, .y = 0, .rot = 0 };
    }

    pub fn cells(kind: PieceKind, rot: u8) [4]Point {
        const r = rot % 4;
        return switch (kind) {
            .I => switch (r) {
                0 => .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 } },
                1 => .{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 } },
                2 => .{ .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 } },
                else => .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 } },
            },
            .O => .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
            .T => switch (r) {
                0 => .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
                1 => .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
                2 => .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
                else => .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
            },
            .S => switch (r) {
                0, 2 => .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } },
                else => .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 } },
            },
            .Z => switch (r) {
                0, 2 => .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
                else => .{ .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
            },
            .J => switch (r) {
                0 => .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
                1 => .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
                2 => .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 } },
                else => .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 } },
            },
            .L => switch (r) {
                0 => .{ .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
                1 => .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 } },
                2 => .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 0, .y = 2 } },
                else => .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
            },
        };
    }

    pub fn kindIndex(kind: PieceKind) u8 {
        return @intFromEnum(kind) + 1;
    }

    fn canPlace(self: *Game, piece: ActivePiece) bool {
        const shape = cells(piece.kind, piece.rot);
        for (shape) |cell| {
            const x = piece.x + cell.x;
            const y = piece.y + cell.y;
            if (x < 0 or x >= board_w or y >= board_h) return false;
            if (y >= 0 and self.board[@intCast(y)][@intCast(x)] != 0) return false;
        }
        return true;
    }

    fn move(self: *Game, dx: i32, dy: i32) bool { var moved = self.current; moved.x += dx; moved.y += dy; if (self.canPlace(moved)) { self.current = moved; return true; } return false; }
    fn rotate(self: *Game, dir: i32) void { var rotated = self.current; rotated.rot = @intCast(@mod(@as(i32, rotated.rot) + dir, 4)); const kicks = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = -1 }, .{ .x = -2, .y = 0 }, .{ .x = 2, .y = 0 }, }; for (kicks) |kick| { var attempt = rotated; attempt.x += kick.x; attempt.y += kick.y; if (self.canPlace(attempt)) { self.current = attempt; self.lock_timer = 0; return; } } }
    pub fn ghostY(self: *Game) i32 { var ghost = self.current; while (self.canPlace(.{ .kind = ghost.kind, .x = ghost.x, .y = ghost.y + 1, .rot = ghost.rot })) ghost.y += 1; return ghost.y; }

    fn lockPiece(self: *Game) void {
        const shape = cells(self.current.kind, self.current.rot);
        for (shape) |cell| {
            const x = self.current.x + cell.x;
            const y = self.current.y + cell.y;
            if (y < 0) { self.game_over = true; self.show_help = false; return; }
            self.board[@intCast(y)][@intCast(x)] = kindIndex(self.current.kind);
        }
        self.clear_fx_count = 0;
        self.clear_fx_rows = .{ -1, -1, -1, -1 };
        var cleared: u32 = 0;
        var y: i32 = board_h - 1;
        while (y >= 0) : (y -= 1) {
            var full = true;
            for (self.board[@intCast(y)]) |value| if (value == 0) { full = false; break; };
            if (full) {
                if (self.clear_fx_count < self.clear_fx_rows.len) { self.clear_fx_rows[self.clear_fx_count] = y; self.clear_fx_count += 1; }
                cleared += 1;
                var yy: i32 = y;
                while (yy > 0) : (yy -= 1) self.board[@intCast(yy)] = self.board[@intCast(yy - 1)];
                self.board[0] = [_]u8{0} ** board_w;
                y += 1;
            }
        }
        if (cleared > 0) {
            self.clear_fx_timer = 0.32;
            self.lines += cleared;
            self.level = @divTrunc(self.lines, 10) + 1;
            self.score += @as(u32, switch (cleared) { 1 => 100, 2 => 300, 3 => 500, else => 800, }) * self.level;
        }
        self.current = self.makePiece(self.next);
        self.next = self.randomKind();
        self.hold_used = false;
        self.lock_timer = 0;
        self.fall_timer = 0;
        if (!self.canPlace(self.current)) { self.game_over = true; self.show_help = false; }
    }

    fn holdSwap(self: *Game) void {
        if (self.hold_used or self.game_over) return;
        const current_kind = self.current.kind;
        if (self.hold) |held| { self.current = self.makePiece(held); self.hold = current_kind; } else { self.hold = current_kind; self.current = self.makePiece(self.next); self.next = self.randomKind(); }
        self.hold_used = true;
        if (!self.canPlace(self.current)) { self.game_over = true; self.show_help = false; }
    }

    pub fn hardDrop(self: *Game) void { var dist: u32 = 0; while (self.move(0, 1)) dist += 1; self.score += dist * 2; self.lockPiece(); }

    pub fn update(self: *Game, dt: f32, input: InputState) void {
        if (input.restart) { self.reset(); return; }
        if (input.help) self.show_help = !self.show_help;
        if (input.pause) { self.paused = !self.paused; self.show_help = false; }
        if (self.clear_fx_timer > 0) self.clear_fx_timer = @max(0, self.clear_fx_timer - dt);
        if (self.game_over or self.paused) return;
        if (input.left) _ = self.move(-1, 0);
        if (input.right) _ = self.move(1, 0);
        if (input.rotate_cw) self.rotate(1);
        if (input.rotate_ccw) self.rotate(-1);
        if (input.hold) self.holdSwap();
        if (input.hard_drop) { self.hardDrop(); return; }
        const gravity = gravity_base / @as(f32, @floatFromInt(self.level));
        const step = if (input.soft_drop) 0.04 else gravity;
        self.fall_timer += dt;
        while (self.fall_timer >= step) {
            self.fall_timer -= step;
            if (!self.move(0, 1)) { self.lock_timer += step; if (self.lock_timer >= lock_delay) { self.lockPiece(); break; } }
            else { self.lock_timer = 0; if (input.soft_drop) self.score += 1; }
        }
        if (!self.canPlace(.{ .kind = self.current.kind, .x = self.current.x, .y = self.current.y + 1, .rot = self.current.rot })) {
            self.lock_timer += dt * 0.35; if (self.lock_timer >= lock_delay) self.lockPiece();
        } else self.lock_timer = 0;
    }
};
