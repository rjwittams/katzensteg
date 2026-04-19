const std = @import("std");

const board_w: i32 = 10;
const board_h: i32 = 20;
const fps: f32 = 30.0;
const gravity_base: f32 = 0.75;
const lock_delay: f32 = 0.45;

const cell_cols: i32 = 2;
const cell_rows: i32 = 1;
const board_cols: i32 = board_w * cell_cols;
const board_rows: i32 = board_h * cell_rows;
const scene_cols: i32 = 42;
const scene_rows: i32 = 28;

const CellRect = struct {
    col: i32,
    row: i32,
    w: i32,
    h: i32,

    fn inset(self: CellRect, dx: i32, dy: i32) CellRect {
        return .{ .col = self.col + dx, .row = self.row + dy, .w = self.w - dx * 2, .h = self.h - dy * 2 };
    }

    fn move(self: CellRect, dx: i32, dy: i32) CellRect {
        return .{ .col = self.col + dx, .row = self.row + dy, .w = self.w, .h = self.h };
    }
};

const Layout = struct {
    title: CellRect,
    board: CellRect,
    board_panel: CellRect,
    next_panel: CellRect,
    hold_panel: CellRect,
    hud_panel: CellRect,
    instructions_panel: CellRect,

    fn init() Layout {
        const top_strip_h = 1;
        const board = CellRect{ .col = 4, .row = 3, .w = board_cols, .h = board_rows };
        const board_panel = CellRect{ .col = board.col - 1, .row = board.row - 1, .w = board.w + 2, .h = board.h + 2 };
        const side_col = board_panel.col + board_panel.w + 2;
        const next_panel = CellRect{ .col = side_col, .row = board_panel.row, .w = 12, .h = 6 };
        const hold_panel = CellRect{ .col = side_col, .row = next_panel.row + next_panel.h + 1, .w = 12, .h = 6 };
        const hud_panel = CellRect{ .col = side_col, .row = hold_panel.row + hold_panel.h + 1, .w = 12, .h = 5 };
        const instructions_panel = CellRect{ .col = board_panel.col, .row = board_panel.row + board_panel.h + 1, .w = scene_cols - board_panel.col + 1, .h = scene_rows - (board_panel.row + board_panel.h + 1) + 1 };
        return .{
            .title = .{ .col = board_panel.col, .row = 1, .w = scene_cols - board_panel.col + 1, .h = top_strip_h },
            .board = board,
            .board_panel = board_panel,
            .next_panel = next_panel,
            .hold_panel = hold_panel,
            .hud_panel = hud_panel,
            .instructions_panel = instructions_panel,
        };
    }
};

const layout = Layout.init();

fn panelInner(panel: CellRect) CellRect {
    return panel.inset(1, 1);
}

fn previewOrigin(piece: PieceKind, panel: CellRect) Point {
    const inner = panelInner(panel);
    const shape = Game.cells(piece, 0);
    var min_x: i32 = 99;
    var min_y: i32 = 99;
    var max_x: i32 = -99;
    var max_y: i32 = -99;
    for (shape) |cell| {
        min_x = @min(min_x, cell.x);
        min_y = @min(min_y, cell.y);
        max_x = @max(max_x, cell.x);
        max_y = @max(max_y, cell.y);
    }
    const piece_w_cols = (max_x - min_x + 1) * cell_cols;
    const piece_h_rows = max_y - min_y + 1;
    const origin_col = inner.col + @divTrunc(inner.w - piece_w_cols, 2) - min_x * cell_cols;
    const origin_row = inner.row + @divTrunc(inner.h - piece_h_rows, 2) - min_y;
    return .{ .x = origin_col, .y = origin_row };
}

const board_col: i32 = layout.board.col;
const board_row: i32 = layout.board.row;
const board_right_col: i32 = board_col + board_cols - 1;
const board_bottom_row: i32 = board_row + board_rows - 1;
const preview_col: i32 = layout.next_panel.col + 1;
const next_row: i32 = layout.next_panel.row + 2;
const hold_row: i32 = layout.hold_panel.row + 2;
const hud_row: i32 = layout.hud_panel.row + 1;

const bg_w: i32 = 840;
const bg_h: i32 = 560;
const tile_px: i32 = 32;
const row_strip_w: i32 = tile_px * 10;
const atlas_w: i32 = row_strip_w * 4;
const atlas_h: i32 = tile_px * 6;

const image_bg: u32 = 1001;
const image_atlas: u32 = 1002;
const proof_image_bg: u32 = 2001;
const proof_image_atlas: u32 = 2002;
const probe_image_a: u32 = 3001;
const probe_image_b: u32 = 3002;
const probe_image_c: u32 = 3003;

const placement_bg: u32 = 1;
const placement_board_base_start: u32 = 1000;
const placement_board_overlay_start: u32 = 2000;
const placement_active_base_start: u32 = 3000;
const placement_active_overlay_start: u32 = 3010;
const placement_ghost_start: u32 = 3020;
const placement_next_start: u32 = 3030;
const placement_hold_start: u32 = 3040;
const placement_sweep_start: u32 = 3100;
const placement_tint: u32 = 3200;

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

const Point = struct { x: i32, y: i32 };

const PieceKind = enum(u8) { I, O, T, S, Z, J, L };

const ActivePiece = struct {
    kind: PieceKind,
    x: i32,
    y: i32,
    rot: u8,
};

const InputState = struct {
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

const SharedInput = struct {
    mutex: std.Thread.Mutex = .{},
    state: InputState = .{},
    stop: bool = false,
};

const Game = struct {
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

    fn cells(kind: PieceKind, rot: u8) [4]Point {
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

    fn kindIndex(kind: PieceKind) u8 {
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

    fn move(self: *Game, dx: i32, dy: i32) bool {
        var moved = self.current;
        moved.x += dx;
        moved.y += dy;
        if (self.canPlace(moved)) {
            self.current = moved;
            return true;
        }
        return false;
    }

    fn rotate(self: *Game, dir: i32) void {
        var rotated = self.current;
        rotated.rot = @intCast(@mod(@as(i32, rotated.rot) + dir, 4));
        const kicks = [_]Point{
            .{ .x = 0, .y = 0 }, .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = -1 }, .{ .x = -2, .y = 0 }, .{ .x = 2, .y = 0 },
        };
        for (kicks) |kick| {
            var attempt = rotated;
            attempt.x += kick.x;
            attempt.y += kick.y;
            if (self.canPlace(attempt)) {
                self.current = attempt;
                self.lock_timer = 0;
                return;
            }
        }
    }

    fn ghostY(self: *Game) i32 {
        var ghost = self.current;
        while (self.canPlace(.{ .kind = ghost.kind, .x = ghost.x, .y = ghost.y + 1, .rot = ghost.rot })) ghost.y += 1;
        return ghost.y;
    }

    fn lockPiece(self: *Game) void {
        const shape = cells(self.current.kind, self.current.rot);
        for (shape) |cell| {
            const x = self.current.x + cell.x;
            const y = self.current.y + cell.y;
            if (y < 0) {
                self.game_over = true;
                self.show_help = false;
                return;
            }
            self.board[@intCast(y)][@intCast(x)] = kindIndex(self.current.kind);
        }

        self.clear_fx_count = 0;
        self.clear_fx_rows = .{ -1, -1, -1, -1 };

        var cleared: u32 = 0;
        var y: i32 = board_h - 1;
        while (y >= 0) : (y -= 1) {
            var full = true;
            for (self.board[@intCast(y)]) |value| {
                if (value == 0) {
                    full = false;
                    break;
                }
            }
            if (full) {
                if (self.clear_fx_count < self.clear_fx_rows.len) {
                    self.clear_fx_rows[self.clear_fx_count] = y;
                    self.clear_fx_count += 1;
                }
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
            self.score += @as(u32, switch (cleared) {
                1 => 100,
                2 => 300,
                3 => 500,
                else => 800,
            }) * self.level;
        }

        self.current = self.makePiece(self.next);
        self.next = self.randomKind();
        self.hold_used = false;
        self.lock_timer = 0;
        self.fall_timer = 0;
        if (!self.canPlace(self.current)) {
            self.game_over = true;
            self.show_help = false;
        }
    }

    fn holdSwap(self: *Game) void {
        if (self.hold_used or self.game_over) return;
        const current_kind = self.current.kind;
        if (self.hold) |held| {
            self.current = self.makePiece(held);
            self.hold = current_kind;
        } else {
            self.hold = current_kind;
            self.current = self.makePiece(self.next);
            self.next = self.randomKind();
        }
        self.hold_used = true;
        if (!self.canPlace(self.current)) {
            self.game_over = true;
            self.show_help = false;
        }
    }

    fn hardDrop(self: *Game) void {
        var dist: u32 = 0;
        while (self.move(0, 1)) dist += 1;
        self.score += dist * 2;
        self.lockPiece();
    }

    pub fn update(self: *Game, dt: f32, input: InputState) void {
        if (input.restart) {
            self.reset();
            return;
        }
        if (input.help) self.show_help = !self.show_help;
        if (input.pause) {
            self.paused = !self.paused;
            self.show_help = false;
        }
        if (self.clear_fx_timer > 0) self.clear_fx_timer = @max(0, self.clear_fx_timer - dt);
        if (self.game_over or self.paused) return;

        if (input.left) _ = self.move(-1, 0);
        if (input.right) _ = self.move(1, 0);
        if (input.rotate_cw) self.rotate(1);
        if (input.rotate_ccw) self.rotate(-1);
        if (input.hold) self.holdSwap();
        if (input.hard_drop) {
            self.hardDrop();
            return;
        }

        const gravity = gravity_base / @as(f32, @floatFromInt(self.level));
        const step = if (input.soft_drop) 0.04 else gravity;
        self.fall_timer += dt;
        while (self.fall_timer >= step) {
            self.fall_timer -= step;
            if (!self.move(0, 1)) {
                self.lock_timer += step;
                if (self.lock_timer >= lock_delay) {
                    self.lockPiece();
                    break;
                }
            } else {
                self.lock_timer = 0;
                if (input.soft_drop) self.score += 1;
            }
        }

        if (!self.canPlace(.{ .kind = self.current.kind, .x = self.current.x, .y = self.current.y + 1, .rot = self.current.rot })) {
            self.lock_timer += dt * 0.35;
            if (self.lock_timer >= lock_delay) self.lockPiece();
        } else {
            self.lock_timer = 0;
        }
    }
};

fn pieceColor(index: u8) Color {
    return switch (index) {
        1 => .{ .r = 0, .g = 238, .b = 255 },
        2 => .{ .r = 255, .g = 220, .b = 90 },
        3 => .{ .r = 190, .g = 100, .b = 255 },
        4 => .{ .r = 120, .g = 255, .b = 130 },
        5 => .{ .r = 255, .g = 90, .b = 120 },
        6 => .{ .r = 100, .g = 170, .b = 255 },
        7 => .{ .r = 255, .g = 150, .b = 70 },
        else => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
}

const Atlas = struct {
    block: [8]Rect,
    glow: [3]Rect,
    ghost: [2]Rect,
    sweep: [4]Rect,
    tint: Rect,
};

const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas: Atlas,
    prev_board: [board_h][board_w]u8 = [_][board_w]u8{[_]u8{255} ** board_w} ** board_h,
    prev_next: ?PieceKind = null,
    prev_hold: ?PieceKind = null,
    prev_score: u32 = 0xffffffff,
    prev_lines: u32 = 0xffffffff,
    prev_level: u32 = 0xffffffff,
    prev_game_over: bool = false,
    prev_hold_used: bool = false,
    board_drawn: bool = false,

    pub fn init(allocator: std.mem.Allocator, writer: anytype) !Renderer {
        const bg = try allocator.alloc(u8, @as(usize, @intCast(bg_w * bg_h * 4)));
        defer allocator.free(bg);
        const atlas_buf = try allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4)));
        defer allocator.free(atlas_buf);

        try ansiClear(writer);

        buildBackground(bg, bg_w, bg_h);
        const atlas = buildAtlas(atlas_buf, atlas_w, atlas_h);
        try kittyUpload(writer, image_bg, bg, bg_w, bg_h);
        try kittyUpload(writer, image_atlas, atlas_buf, atlas_w, atlas_h);
        try placeBackground(writer);
        try drawStaticHud(writer);

        return .{
            .allocator = allocator,
            .atlas = atlas,
        };
    }

    pub fn render(self: *Renderer, writer: anytype, game: *Game, t: f32) !void {
        _ = self.allocator;
        try self.drawBoardDiff(writer, game);
        try self.drawGhost(writer, game, t);
        try self.drawActive(writer, game, t);
        const next_origin = previewOrigin(game.next, layout.next_panel);
        try self.drawPreview(writer, game.next, placement_next_start, next_origin.x, next_origin.y, false);
        if (game.hold) |held| {
            const hold_origin = previewOrigin(held, layout.hold_panel);
            try self.drawPreview(writer, held, placement_hold_start, hold_origin.x, hold_origin.y, game.hold_used);
        } else {
            try self.drawPreview(writer, game.hold, placement_hold_start, preview_col, hold_row, game.hold_used);
        }
        try self.drawSweep(writer, game, t);
        try self.drawDangerTint(writer, game, t);
        try self.drawHud(writer, game, t);
    }

    fn drawBoardDiff(self: *Renderer, writer: anytype, game: *Game) !void {
        var y: i32 = 0;
        while (y < board_h) : (y += 1) {
            var x: i32 = 0;
            while (x < board_w) : (x += 1) {
                const now = game.board[@intCast(y)][@intCast(x)];
                const prev = self.prev_board[@intCast(y)][@intCast(x)];
                if (!self.board_drawn or now != prev) {
                    const pid = placement_board_base_start + @as(u32, @intCast(y * board_w + x));
                    const overlay_pid = placement_board_overlay_start + @as(u32, @intCast(y * board_w + x));
                    if (now == 0) {
                        try kittyDeletePlacement(writer, image_atlas, pid);
                        try kittyDeletePlacement(writer, image_atlas, overlay_pid);
                    } else {
                        try placeTile(writer, image_atlas, pid, board_col + x * cell_cols, board_row + y, cell_cols, cell_rows, self.atlas.block[now], 5);
                        try placeTile(writer, image_atlas, overlay_pid, board_col + x * cell_cols, board_row + y, cell_cols, cell_rows, self.atlas.glow[@intCast(@mod(x + y, 3))], 6);
                    }
                    self.prev_board[@intCast(y)][@intCast(x)] = now;
                }
            }
        }
        self.board_drawn = true;
    }

    fn drawGhost(self: *Renderer, writer: anytype, game: *Game, t: f32) !void {
        const frame: usize = @intCast(@mod(@as(i32, @intFromFloat(t * 4.0)), 2));
        const gy = game.ghostY();
        const shape = Game.cells(game.current.kind, game.current.rot);
        for (shape, 0..) |cell, i| {
            const px = game.current.x + cell.x;
            const py = gy + cell.y;
            const pid = placement_ghost_start + @as(u32, @intCast(i));
            if (py < 0) {
                try kittyDeletePlacement(writer, image_atlas, pid);
                continue;
            }
            try placeTile(writer, image_atlas, pid, board_col + px * cell_cols, board_row + py, cell_cols, cell_rows, self.atlas.ghost[frame], 7);
        }
    }

    fn drawActive(self: *Renderer, writer: anytype, game: *Game, t: f32) !void {
        const base = self.atlas.block[Game.kindIndex(game.current.kind)];
        const glow_frame: usize = @intCast(@mod(@as(i32, @intFromFloat(t * 7.0)), 3));
        const shape = Game.cells(game.current.kind, game.current.rot);
        for (shape, 0..) |cell, i| {
            const px = game.current.x + cell.x;
            const py = game.current.y + cell.y;
            const pid = placement_active_base_start + @as(u32, @intCast(i));
            const overlay_pid = placement_active_overlay_start + @as(u32, @intCast(i));
            if (py < 0) {
                try kittyDeletePlacement(writer, image_atlas, pid);
                try kittyDeletePlacement(writer, image_atlas, overlay_pid);
                continue;
            }
            try placeTile(writer, image_atlas, pid, board_col + px * cell_cols, board_row + py, cell_cols, cell_rows, base, 8);
            try placeTile(writer, image_atlas, overlay_pid, board_col + px * cell_cols, board_row + py, cell_cols, cell_rows, self.atlas.glow[glow_frame], 9);
        }
    }

    fn drawPreview(self: *Renderer, writer: anytype, piece_opt: anytype, start_pid: u32, col: i32, row: i32, dimmed: bool) !void {
        if (@TypeOf(piece_opt) == PieceKind) {
            try self.drawPreviewPiece(writer, piece_opt, start_pid, col, row, dimmed);
        } else if (piece_opt) |piece| {
            try self.drawPreviewPiece(writer, piece, start_pid, col, row, dimmed);
        } else {
            var i: usize = 0;
            while (i < 4) : (i += 1) try kittyDeletePlacement(writer, image_atlas, start_pid + @as(u32, @intCast(i)));
        }
    }

    fn drawPreviewPiece(self: *Renderer, writer: anytype, piece: PieceKind, start_pid: u32, col: i32, row: i32, dimmed: bool) !void {
        const base = if (dimmed) self.atlas.ghost[0] else self.atlas.block[Game.kindIndex(piece)];
        const shape = Game.cells(piece, 0);
        for (shape, 0..) |cell, i| {
            try placeTile(writer, image_atlas, start_pid + @as(u32, @intCast(i)), col + cell.x * cell_cols, row + cell.y, cell_cols, cell_rows, base, 8);
        }
    }

    fn drawSweep(self: *Renderer, writer: anytype, game: *Game, _: f32) !void {
        if (game.clear_fx_timer <= 0 or game.clear_fx_count == 0) {
            var row_i: usize = 0;
            while (row_i < 4) : (row_i += 1) try kittyDeletePlacement(writer, image_atlas, placement_sweep_start + @as(u32, @intCast(row_i)));
            return;
        }
        const phase = 1.0 - (game.clear_fx_timer / 0.32);
        const frame: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(phase * 4.0)), 0, 3));
        var i: usize = 0;
        while (i < game.clear_fx_count) : (i += 1) {
            const row = game.clear_fx_rows[i];
            try placeTile(writer, image_atlas, placement_sweep_start + @as(u32, @intCast(i)), board_col, board_row + row, board_cols, cell_rows, self.atlas.sweep[frame], 20);
        }
        while (i < 4) : (i += 1) try kittyDeletePlacement(writer, image_atlas, placement_sweep_start + @as(u32, @intCast(i)));
    }

    fn drawDangerTint(self: *Renderer, writer: anytype, game: *Game, t: f32) !void {
        var highest: i32 = board_h;
        var y: i32 = 0;
        while (y < board_h) : (y += 1) {
            var x: i32 = 0;
            while (x < board_w) : (x += 1) {
                if (game.board[@intCast(y)][@intCast(x)] != 0) {
                    highest = @min(highest, y);
                    break;
                }
            }
        }
        if (highest > 4) {
            try kittyDeletePlacement(writer, image_atlas, placement_tint);
            return;
        }
        const pulse = 0.35 + 0.35 * (0.5 + 0.5 * @sin(t * 6.0));
        const tint_rect = if (pulse > 0.55) self.atlas.glow[2] else self.atlas.tint;
        try placeTile(writer, image_atlas, placement_tint, board_col, board_row, board_cols, board_rows, tint_rect, 15);
    }

    fn drawHud(self: *Renderer, writer: anytype, game: *Game, t: f32) !void {
        const next_label_col = layout.next_panel.col + 1;
        const hold_label_col = layout.hold_panel.col + 1;
        const hud_col = layout.hud_panel.col + 1;
        const info_col = layout.instructions_panel.col + 1;
        const info_width: usize = @intCast(layout.instructions_panel.w - 2);
        if (self.prev_next != game.next or self.prev_hold != game.hold or self.prev_score != game.score or self.prev_lines != game.lines or self.prev_level != game.level or self.prev_game_over != game.game_over or self.prev_hold_used != game.hold_used or game.paused) {
            try moveCursor(writer, layout.next_panel.row + 1, next_label_col);
            try writer.writeAll("\x1b[38;2;255;180;120mNEXT\x1b[0m");
            try moveCursor(writer, layout.hold_panel.row + 1, hold_label_col);
            try writer.writeAll("\x1b[38;2;220;170;255mHOLD\x1b[0m");

            try moveCursor(writer, hud_row, hud_col);
            try writer.print("\x1b[38;2;190;255;240mSCR\x1b[0m {d:<6}", .{game.score});
            try moveCursor(writer, hud_row + 1, hud_col);
            try writer.print("\x1b[38;2;190;255;240mLIN\x1b[0m {d:<6}", .{game.lines});
            try moveCursor(writer, hud_row + 2, hud_col);
            try writer.print("\x1b[38;2;190;255;240mLVL\x1b[0m {d:<6}", .{game.level});

            try moveCursor(writer, layout.hold_panel.row + layout.hold_panel.h - 1, hold_label_col);
            if (game.hold_used) {
                try writer.writeAll("\x1b[38;2;255;170;220mHOLD SPENT\x1b[0m  ");
            } else if (game.paused) {
                try writer.writeAll("\x1b[38;2;255;220;120mPAUSED\x1b[0m      ");
            } else {
                try writer.writeAll("\x1b[38;2;120;255;190mHOLD READY\x1b[0m  ");
            }

            self.prev_next = game.next;
            self.prev_hold = game.hold;
            self.prev_score = game.score;
            self.prev_lines = game.lines;
            self.prev_level = game.level;
            self.prev_hold_used = game.hold_used;
        }

        const pulse = 0.5 + 0.5 * @sin(t * 5.0);
        const marquee = if (game.paused) "TTYTRIS  [PAUSED]  PRESS P TO RESUME  R TO RESET  Q TO QUIT" else "TTYTRIS  KITTY SPRITES + ALPHA OVERLAYS  FLASHY. PERSISTENT. NO FULL-FRAME BLITS.";
        const title_width = layout.title.w;
        const span = @max(@as(i32, @intCast(marquee.len)) - title_width, 0);
        const phase = 0.5 + 0.5 * @sin(t * 0.9);
        const offset: usize = @intCast(@min(span, @as(i32, @intFromFloat(phase * @as(f32, @floatFromInt(span))))));
        const visible_width: usize = @intCast(title_width);
        const end = @min(offset + visible_width, marquee.len);
        var line_buf: [96]u8 = [_]u8{' '} ** 96;
        const slice = marquee[offset..end];
        @memcpy(line_buf[0..slice.len], slice);
        try moveCursor(writer, layout.title.row, layout.title.col);
        try writer.print("\x1b[38;2;{d};{d};255m{s}\x1b[0m", .{ 100 + @as(i32, @intFromFloat(pulse * 80.0)), 180 + @as(i32, @intFromFloat(pulse * 60.0)), line_buf[0..visible_width] });

        var blank: [96]u8 = [_]u8{' '} ** 96;
        if (game.show_help) {
            try moveCursor(writer, layout.instructions_panel.row + 1, info_col);
            try writer.print("\x1b[38;2;130;150;190m{s}\x1b[0m", .{blank[0..info_width]});
            const help1 = "MOVE: LEFT/RIGHT   ROT: UP/X CW";
            const help2 = "ROT CCW: Z   DROP: DOWN / SPACE";
            const help3 = "HOLD: C   PAUSE: P   RESET: R   QUIT: Q";
            var h1: [96]u8 = [_]u8{' '} ** 96;
            var h2: [96]u8 = [_]u8{' '} ** 96;
            var h3: [96]u8 = [_]u8{' '} ** 96;
            const s1 = help1[0..@min(help1.len, info_width)];
            const s2 = help2[0..@min(help2.len, info_width)];
            const s3 = help3[0..@min(help3.len, info_width)];
            @memcpy(h1[0..s1.len], s1);
            @memcpy(h2[0..s2.len], s2);
            @memcpy(h3[0..s3.len], s3);
            try moveCursor(writer, layout.instructions_panel.row + 2, info_col);
            try writer.print("\x1b[38;2;200;220;255m{s}\x1b[0m", .{h1[0..info_width]});
            try moveCursor(writer, layout.instructions_panel.row + 3, info_col);
            try writer.print("\x1b[38;2;200;220;255m{s}\x1b[0m", .{h2[0..info_width]});
            try moveCursor(writer, layout.instructions_panel.row + 4, info_col);
            try writer.print("\x1b[38;2;200;220;255m{s}\x1b[0m", .{h3[0..info_width]});
        } else {
            const status_text = if (game.game_over)
                "GAME OVER — PRESS R TO RESTART"
            else if (game.paused)
                "PAUSED — PRESS P TO RESUME"
            else
                "STATUS OK — PRESS ? FOR HELP";
            var status_buf: [96]u8 = [_]u8{' '} ** 96;
            const status_slice = status_text[0..@min(status_text.len, info_width)];
            @memcpy(status_buf[0..status_slice.len], status_slice);
            try moveCursor(writer, layout.instructions_panel.row + 1, info_col);
            if (game.game_over) {
                try writer.print("\x1b[48;2;90;20;40m\x1b[38;2;255;235;240m{s}\x1b[0m", .{status_buf[0..info_width]});
            } else if (game.paused) {
                try writer.print("\x1b[48;2;30;40;90m\x1b[38;2;230;240;255m{s}\x1b[0m", .{status_buf[0..info_width]});
            } else {
                try writer.print("\x1b[38;2;160;210;255m{s}\x1b[0m", .{status_buf[0..info_width]});
            }
            try moveCursor(writer, layout.instructions_panel.row + 2, info_col);
            try writer.print("\x1b[38;2;130;150;190m{s}\x1b[0m", .{blank[0..info_width]});
            try moveCursor(writer, layout.instructions_panel.row + 3, info_col);
            try writer.print("\x1b[38;2;130;150;190m{s}\x1b[0m", .{blank[0..info_width]});
            try moveCursor(writer, layout.instructions_panel.row + 4, info_col);
            try writer.print("\x1b[38;2;130;150;190m{s}\x1b[0m", .{blank[0..info_width]});
        }
        self.prev_game_over = game.game_over;
    }
};

fn buildBackground(buf: []u8, w: i32, h: i32) void {
    clearRgba(buf, .{ .r = 4, .g = 6, .b = 16, .a = 255 });
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        const wave = 0.5 + 0.5 * @sin(@as(f32, @floatFromInt(y)) * 0.03);
        const c = Color{
            .r = @intFromFloat(5.0 + wave * 10.0),
            .g = @intFromFloat(8.0 + wave * 18.0),
            .b = @intFromFloat(20.0 + wave * 35.0),
            .a = 255,
        };
        fillRect(buf, w, h, 0, y, w, 1, c);
    }

    var i: i32 = 0;
    while (i < 80) : (i += 1) {
        const x = @mod(i * 97, w - 4);
        const sy = @mod(i * 53, h - 4);
        fillRect(buf, w, h, x, sy, 2, 2, .{ .r = 180, .g = 220, .b = 255, .a = 70 });
    }

    const cellw = @divTrunc(bg_w, scene_cols);
    const cellh = @divTrunc(bg_h, scene_rows);

    const board_panel_px = layout.board_panel;
    const next_panel_px = layout.next_panel;
    const hold_panel_px = layout.hold_panel;
    const hud_panel_px = layout.hud_panel;
    drawPanel(buf, w, h, (board_panel_px.col - 1) * cellw, (board_panel_px.row - 1) * cellh, board_panel_px.w * cellw, board_panel_px.h * cellh, .{ .r = 40, .g = 180, .b = 255, .a = 255 });
    drawPanel(buf, w, h, (next_panel_px.col - 1) * cellw, (next_panel_px.row - 1) * cellh, next_panel_px.w * cellw, next_panel_px.h * cellh, .{ .r = 255, .g = 140, .b = 80, .a = 255 });
    drawPanel(buf, w, h, (hold_panel_px.col - 1) * cellw, (hold_panel_px.row - 1) * cellh, hold_panel_px.w * cellw, hold_panel_px.h * cellh, .{ .r = 180, .g = 100, .b = 255, .a = 255 });
    drawPanel(buf, w, h, (hud_panel_px.col - 1) * cellw, (hud_panel_px.row - 1) * cellh, hud_panel_px.w * cellw, hud_panel_px.h * cellh, .{ .r = 0, .g = 220, .b = 190, .a = 255 });
    drawPanel(buf, w, h, (layout.instructions_panel.col - 1) * cellw, (layout.instructions_panel.row - 1) * cellh, layout.instructions_panel.w * cellw, layout.instructions_panel.h * cellh, .{ .r = 120, .g = 160, .b = 255, .a = 255 });

    var gy: i32 = 0;
    while (gy < board_h) : (gy += 1) {
        var gx: i32 = 0;
        while (gx < board_w) : (gx += 1) {
            const c = if (@mod(gx + gy, 2) == 0) Color{ .r = 10, .g = 16, .b = 30, .a = 255 } else Color{ .r = 12, .g = 20, .b = 36, .a = 255 };
            fillRect(buf, w, h, (layout.board.col - 1) * cellw + gx * cell_cols * cellw, (layout.board.row - 1) * cellh + gy * cellh, cell_cols * cellw, cellh, c);
        }
    }
}

fn buildAtlas(buf: []u8, w: i32, h: i32) Atlas {
    clearRgba(buf, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    var atlas = Atlas{
        .block = undefined,
        .glow = undefined,
        .ghost = undefined,
        .sweep = undefined,
        .tint = .{ .x = 8 * tile_px, .y = 2 * tile_px, .w = tile_px, .h = tile_px },
    };

    atlas.block[0] = .{ .x = 0, .y = 0, .w = tile_px, .h = tile_px };
    var i: u8 = 1;
    while (i <= 7) : (i += 1) {
        const idx = i - 1;
        const rect = Rect{ .x = @as(i32, idx) * tile_px, .y = 0, .w = tile_px, .h = tile_px };
        atlas.block[i] = rect;
        drawBlockTile(buf, w, h, rect.x, rect.y, tile_px, pieceColor(i));
    }

    atlas.ghost[0] = .{ .x = 0, .y = tile_px, .w = tile_px, .h = tile_px };
    atlas.ghost[1] = .{ .x = tile_px, .y = tile_px, .w = tile_px, .h = tile_px };
    drawGhostTile(buf, w, h, atlas.ghost[0].x, atlas.ghost[0].y, tile_px, 90);
    drawGhostTile(buf, w, h, atlas.ghost[1].x, atlas.ghost[1].y, tile_px, 130);

    atlas.glow[0] = .{ .x = 2 * tile_px, .y = tile_px, .w = tile_px, .h = tile_px };
    atlas.glow[1] = .{ .x = 3 * tile_px, .y = tile_px, .w = tile_px, .h = tile_px };
    atlas.glow[2] = .{ .x = 4 * tile_px, .y = tile_px, .w = tile_px, .h = tile_px };
    drawGlowTile(buf, w, h, atlas.glow[0].x, atlas.glow[0].y, tile_px, .{ .r = 120, .g = 220, .b = 255, .a = 255 }, 60);
    drawGlowTile(buf, w, h, atlas.glow[1].x, atlas.glow[1].y, tile_px, .{ .r = 180, .g = 240, .b = 255, .a = 255 }, 90);
    drawGlowTile(buf, w, h, atlas.glow[2].x, atlas.glow[2].y, tile_px, .{ .r = 255, .g = 70, .b = 110, .a = 255 }, 70);

    var s: i32 = 0;
    while (s < 4) : (s += 1) {
        atlas.sweep[@intCast(s)] = .{ .x = s * row_strip_w, .y = 3 * tile_px, .w = row_strip_w, .h = tile_px };
        drawSweepTile(buf, w, h, atlas.sweep[@intCast(s)].x, atlas.sweep[@intCast(s)].y, row_strip_w, tile_px, s);
    }

    fillRect(buf, w, h, atlas.tint.x, atlas.tint.y, atlas.tint.w, atlas.tint.h, .{ .r = 255, .g = 30, .b = 70, .a = 46 });
    return atlas;
}

fn drawBlockTile(buf: []u8, w: i32, h: i32, x: i32, y: i32, size: i32, color: Color) void {
    glowRect(buf, w, h, x + 2, y + 2, size - 4, size - 4, color, 8, 0.35);
    fillRect(buf, w, h, x + 3, y + 3, size - 6, size - 6, .{ .r = @intCast(@min(color.r / 2 + 30, 255)), .g = @intCast(@min(color.g / 2 + 30, 255)), .b = @intCast(@min(color.b / 2 + 30, 255)), .a = 255 });
    fillRect(buf, w, h, x + 5, y + 5, size - 10, size - 10, color);
    fillRect(buf, w, h, x + 6, y + 6, size - 12, @divTrunc(size - 12, 3), .{ .r = 255, .g = 255, .b = 255, .a = 80 });
    strokeRect(buf, w, h, x + 3, y + 3, size - 6, size - 6, 1, .{ .r = 255, .g = 255, .b = 255, .a = 90 });
}

fn drawGhostTile(buf: []u8, w: i32, h: i32, x: i32, y: i32, size: i32, alpha: u8) void {
    glowRect(buf, w, h, x + 4, y + 4, size - 8, size - 8, .{ .r = 120, .g = 220, .b = 255, .a = alpha }, 7, 0.25);
    fillRect(buf, w, h, x + 5, y + 5, size - 10, size - 10, .{ .r = 100, .g = 170, .b = 220, .a = alpha / 2 });
    strokeRect(buf, w, h, x + 5, y + 5, size - 10, size - 10, 2, .{ .r = 220, .g = 250, .b = 255, .a = alpha });
}

fn drawGlowTile(buf: []u8, w: i32, h: i32, x: i32, y: i32, size: i32, color: Color, alpha: u8) void {
    var yy: i32 = 0;
    while (yy < size) : (yy += 1) {
        var xx: i32 = 0;
        while (xx < size) : (xx += 1) {
            const dx = @as(f32, @floatFromInt(xx - @divTrunc(size, 2)));
            const dy = @as(f32, @floatFromInt(yy - @divTrunc(size, 2)));
            const dist = @sqrt(dx * dx + dy * dy);
            const a = std.math.clamp(1.0 - dist / (@as(f32, @floatFromInt(size)) * 0.62), 0, 1);
            if (a > 0) blendPixel(buf, w, h, x + xx, y + yy, .{ .r = color.r, .g = color.g, .b = color.b, .a = @intFromFloat(@as(f32, @floatFromInt(alpha)) * a) });
        }
    }
}

fn drawSweepTile(buf: []u8, w: i32, h: i32, x: i32, y: i32, rw: i32, rh: i32, frame: i32) void {
    var xx: i32 = 0;
    while (xx < rw) : (xx += 1) {
        const nx = @as(f32, @floatFromInt(xx)) / @as(f32, @floatFromInt(rw));
        const center = (@as(f32, @floatFromInt(frame)) + 0.6) / 4.6;
        const d = @abs(nx - center);
        const a = std.math.clamp(1.0 - d * 4.0, 0, 1);
        const c = Color{ .r = 255, .g = 240, .b = 190, .a = @intFromFloat(190.0 * a) };
        fillRect(buf, w, h, x + xx, y + 4, 1, rh - 8, c);
    }
}

fn clearRgba(buf: []u8, color: Color) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        buf[i] = color.r;
        buf[i + 1] = color.g;
        buf[i + 2] = color.b;
        buf[i + 3] = color.a;
    }
}

fn pixelIndex(w: i32, x: i32, y: i32) usize {
    return @as(usize, @intCast((y * w + x) * 4));
}

fn blendPixel(buf: []u8, w: i32, h: i32, x: i32, y: i32, color: Color) void {
    if (x < 0 or y < 0 or x >= w or y >= h or color.a == 0) return;
    const idx = pixelIndex(w, x, y);
    const src_a = @as(f32, @floatFromInt(color.a)) / 255.0;
    const dst_a = @as(f32, @floatFromInt(buf[idx + 3])) / 255.0;
    const out_a = src_a + dst_a * (1.0 - src_a);
    if (out_a <= 0) {
        buf[idx] = 0;
        buf[idx + 1] = 0;
        buf[idx + 2] = 0;
        buf[idx + 3] = 0;
        return;
    }
    const src_r = @as(f32, @floatFromInt(color.r));
    const src_g = @as(f32, @floatFromInt(color.g));
    const src_b = @as(f32, @floatFromInt(color.b));
    const dst_r = @as(f32, @floatFromInt(buf[idx]));
    const dst_g = @as(f32, @floatFromInt(buf[idx + 1]));
    const dst_b = @as(f32, @floatFromInt(buf[idx + 2]));
    const out_r = (src_r * src_a + dst_r * dst_a * (1.0 - src_a)) / out_a;
    const out_g = (src_g * src_a + dst_g * dst_a * (1.0 - src_a)) / out_a;
    const out_b = (src_b * src_a + dst_b * dst_a * (1.0 - src_a)) / out_a;
    buf[idx] = @intFromFloat(std.math.clamp(out_r, 0, 255));
    buf[idx + 1] = @intFromFloat(std.math.clamp(out_g, 0, 255));
    buf[idx + 2] = @intFromFloat(std.math.clamp(out_b, 0, 255));
    buf[idx + 3] = @intFromFloat(out_a * 255.0);
}

fn fillRect(buf: []u8, w: i32, h: i32, x0: i32, y0: i32, rw: i32, rh: i32, color: Color) void {
    var y = y0;
    while (y < y0 + rh) : (y += 1) {
        var x = x0;
        while (x < x0 + rw) : (x += 1) blendPixel(buf, w, h, x, y, color);
    }
}

fn strokeRect(buf: []u8, w: i32, h: i32, x0: i32, y0: i32, rw: i32, rh: i32, t: i32, color: Color) void {
    fillRect(buf, w, h, x0, y0, rw, t, color);
    fillRect(buf, w, h, x0, y0 + rh - t, rw, t, color);
    fillRect(buf, w, h, x0, y0, t, rh, color);
    fillRect(buf, w, h, x0 + rw - t, y0, t, rh, color);
}

fn glowRect(buf: []u8, w: i32, h: i32, x0: i32, y0: i32, rw: i32, rh: i32, color: Color, radius: i32, strength: f32) void {
    var y = y0 - radius;
    while (y < y0 + rh + radius) : (y += 1) {
        var x = x0 - radius;
        while (x < x0 + rw + radius) : (x += 1) {
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (x < x0) dx = @floatFromInt(x0 - x) else if (x >= x0 + rw) dx = @floatFromInt(x - (x0 + rw - 1));
            if (y < y0) dy = @floatFromInt(y0 - y) else if (y >= y0 + rh) dy = @floatFromInt(y - (y0 + rh - 1));
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist <= @as(f32, @floatFromInt(radius))) {
                const a = (1.0 - dist / @as(f32, @floatFromInt(radius))) * strength;
                blendPixel(buf, w, h, x, y, .{ .r = color.r, .g = color.g, .b = color.b, .a = @intFromFloat(@as(f32, @floatFromInt(color.a)) * a) });
            }
        }
    }
}

fn drawPanel(buf: []u8, w: i32, h: i32, x: i32, y: i32, rw: i32, rh: i32, accent: Color) void {
    fillRect(buf, w, h, x, y, rw, rh, .{ .r = 10, .g = 16, .b = 30, .a = 230 });
    glowRect(buf, w, h, x, y, rw, rh, accent, 18, 0.24);
    strokeRect(buf, w, h, x, y, rw, rh, 2, .{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 180 });
}

fn chunkedApc(writer: anytype, prefix: []const u8, payload: []const u8) !void {
    const enc_len = std.base64.standard.Encoder.calcSize(payload.len);
    const b64 = try std.heap.page_allocator.alloc(u8, enc_len);
    defer std.heap.page_allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, payload);

    var offset: usize = 0;
    const chunk: usize = 3072;
    while (offset < b64.len) {
        const end = @min(offset + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        if (offset == 0) {
            try writer.writeAll("\x1b_G");
            try writer.writeAll(prefix);
            try writer.print(",m={c};", .{more});
            try writer.writeAll(b64[offset..end]);
            try writer.writeAll("\x1b\\");
        } else {
            try writer.print("\x1b_Gm={c};", .{more});
            try writer.writeAll(b64[offset..end]);
            try writer.writeAll("\x1b\\");
        }
        offset = end;
    }
}

fn storeRaw(writer: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=t,f=32,s={d},v={d},i={d}", .{ w, h, image_id });
    try chunkedApc(writer, prefix, rgba);
}

fn placeBackground(writer: anytype) !void {
    try moveCursor(writer, 1, 1);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},z=-10;\x1b\\", .{ image_bg, placement_bg, scene_cols, scene_rows });
}

fn placeTile(writer: anytype, image_id: u32, placement_id: u32, col: i32, row: i32, cols: i32, rows: i32, src: Rect, z: i32) !void {
    try moveCursor(writer, row, col);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{ image_id, placement_id, cols, rows, src.x, src.y, src.w, src.h, z });
}

fn kittyUpload(writer: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    try storeRaw(writer, image_id, rgba, w, h);
}

fn kittyDeletePlacement(writer: anytype, image_id: u32, placement_id: u32) !void {
    try writer.print("\x1b_Gq=2,a=d,d=i,i={d},p={d};\x1b\\", .{ image_id, placement_id });
}

fn kittyDeleteImage(writer: anytype, image_id: u32) !void {
    try writer.print("\x1b_Ga=d,q=1,d=I,i={d};\x1b\\", .{ image_id });
}

fn kittyDeleteAll(writer: anytype) !void {
    try writer.writeAll("\x1b_Gq=2,a=d,d=A;\x1b\\");
}

fn moveCursor(writer: anytype, row: i32, col: i32) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

fn ansiClear(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

fn drawStaticHud(writer: anytype) !void {
    try moveCursor(writer, scene_rows, 1);
    try writer.writeAll("\x1b[0m");
}

fn readProbeReplies(allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var reader = std.fs.File.stdin().deprecatedReader();
    const start = std.time.milliTimestamp();
    var buf: [256]u8 = undefined;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try list.appendSlice(allocator, buf[0..n]);
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn detectGraphicsSupport(allocator: std.mem.Allocator, writer: anytype) !bool {
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    const reply = try readProbeReplies(allocator, 300);
    defer allocator.free(reply);
    return std.mem.indexOf(u8, reply, "_Gi=31;OK") != null;
}

fn inputThread(shared: *SharedInput) void {
    var stdin = std.fs.File.stdin().deprecatedReader();
    var buf: [16]u8 = undefined;
    while (true) {
        shared.mutex.lock();
        const should_stop = shared.stop;
        shared.mutex.unlock();
        if (should_stop) break;

        const count = stdin.read(&buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            }
            break;
        };
        if (count == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        shared.mutex.lock();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ch = buf[i];
            switch (ch) {
                'q', 'Q' => shared.state.quit = true,
                'r', 'R' => shared.state.restart = true,
                'z', 'Z' => shared.state.rotate_ccw = true,
                'x', 'X', '\r' => shared.state.rotate_cw = true,
                'c', 'C' => shared.state.hold = true,
                'p', 'P' => shared.state.pause = true,
                '?' => shared.state.help = true,
                ' ' => shared.state.hard_drop = true,
                else => if (ch == 0x1b and i + 2 < count and buf[i + 1] == '[') {
                    switch (buf[i + 2]) {
                        'A' => shared.state.rotate_cw = true,
                        'B' => shared.state.soft_drop = true,
                        'C' => shared.state.right = true,
                        'D' => shared.state.left = true,
                        else => {},
                    }
                    i += 2;
                },
            }
        }
        shared.mutex.unlock();
    }
}

fn makeProbeGradient(allocator: std.mem.Allocator, w: i32, h: i32, a_bias: u8) ![]u8 {
    const buf = try allocator.alloc(u8, @as(usize, @intCast(w * h * 4)));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx: usize = @intCast((y * w + x) * 4);
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w - 1, 1)));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h - 1, 1)));
            buf[idx] = @intFromFloat(255.0 * fx);
            buf[idx + 1] = @intFromFloat(255.0 * fy);
            buf[idx + 2] = @intFromFloat(255.0 * (1.0 - fx));
            const checker = if (@mod(@divTrunc(x, 8) + @divTrunc(y, 8), 2) == 0) a_bias else 255;
            buf[idx + 3] = checker;
        }
    }
    return buf;
}

fn placeStored(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32) !void {
    try moveCursor(writer, y, x);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d};\x1b\\", .{ image_id, placement_id, cols, rows });
}

fn placeStoredCrop(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32, src_x: i32, src_y: i32, src_w: i32, src_h: i32) !void {
    try moveCursor(writer, y, x);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d};\x1b\\", .{ image_id, placement_id, cols, rows, src_x, src_y, src_w, src_h });
}

fn displayImmediateRaw(writer: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32, x: i32, y: i32, cols: i32, rows: i32) !void {
    try moveCursor(writer, y, x);
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=T,C=1,f=32,s={d},v={d},i={d},c={d},r={d}", .{ w, h, image_id, cols, rows });
    try chunkedApc(writer, prefix, rgba);
}

fn makeSimpleGradient(allocator: std.mem.Allocator, w: i32, h: i32, alpha_bias: u8) ![]u8 {
    const buf = try allocator.alloc(u8, @as(usize, @intCast(w * h * 4)));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx: usize = @intCast((y * w + x) * 4);
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w - 1, 1)));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h - 1, 1)));
            buf[idx] = @intFromFloat(255.0 * fx);
            buf[idx + 1] = @intFromFloat(255.0 * fy);
            buf[idx + 2] = @intFromFloat(255.0 * (1.0 - fx));
            buf[idx + 3] = if (@mod(@divTrunc(x, 16) + @divTrunc(y, 16), 2) == 0) alpha_bias else 255;
        }
    }
    return buf;
}

fn runProbeCloneScene(allocator: std.mem.Allocator, writer: anytype) !void {
    const img1 = try makeProbeGradient(allocator, 64, 32, 110);
    defer allocator.free(img1);
    const img2 = try makeProbeGradient(allocator, 64, 32, 180);
    defer allocator.free(img2);
    const atlas = try makeProbeGradient(allocator, 96, 64, 220);
    defer allocator.free(atlas);

    try ansiClear(writer);
    try moveCursor(writer, 1, 1);
    try writer.writeAll("ttytris probe clone\r\n");
    try writer.writeAll("A: immediate raw a=T   B: stored raw a=t + a=p   C: cropped stored placement\r\n");
    try writer.writeAll("same scene as probe.zig, inside main.zig\r\n\r\n");

    try moveCursor(writer, 5, 3);
    try writer.writeAll("A");
    try moveCursor(writer, 5, 24);
    try writer.writeAll("B");
    try moveCursor(writer, 5, 45);
    try writer.writeAll("C");
    try moveCursor(writer, 15, 24);
    try writer.writeAll("D");

    try displayImmediateRaw(writer, probe_image_a, img1, 64, 32, 3, 6, 14, 7);
    try storeRaw(writer, probe_image_b, img2, 64, 32);
    try placeStored(writer, probe_image_b, 1, 24, 6, 14, 7);
    try storeRaw(writer, probe_image_c, atlas, 96, 64);
    try placeStoredCrop(writer, probe_image_c, 1, 45, 6, 14, 7, 0, 0, 48, 32);
    try placeStored(writer, probe_image_c, 2, 24, 16, 14, 7);
}

fn makeProofGame() Game {
    var game = Game.init(123456789);
    game.board = [_][board_w]u8{[_]u8{0} ** board_w} ** board_h;
    var y: i32 = 12;
    while (y < board_h) : (y += 1) {
        var x: i32 = 0;
        while (x < board_w) : (x += 1) {
            if (!((y == 14 and x == 4) or (y == 17 and x == 7) or (y == 19 and (x == 3 or x == 8)))) {
                game.board[@intCast(y)][@intCast(x)] = @as(u8, @intCast(@mod(x + y, 7) + 1));
            }
        }
    }
    game.current = .{ .kind = .T, .x = 3, .y = 6, .rot = 0 };
    game.next = .L;
    game.hold = .I;
    game.hold_used = false;
    game.score = 42420;
    game.lines = 37;
    game.level = 4;
    game.clear_fx_rows = .{ 15, -1, -1, -1 };
    game.clear_fx_count = 1;
    game.clear_fx_timer = 0.22;
    return game;
}

fn uploadRealBackground(allocator: std.mem.Allocator, writer: anytype) !void {
    const bg = try allocator.alloc(u8, @as(usize, @intCast(bg_w * bg_h * 4)));
    defer allocator.free(bg);
    buildBackground(bg, bg_w, bg_h);
    try storeRaw(writer, image_bg, bg, bg_w, bg_h);
}

fn uploadRealAtlas(allocator: std.mem.Allocator, writer: anytype) !Atlas {
    const atlas_buf = try allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4)));
    defer allocator.free(atlas_buf);
    const atlas = buildAtlas(atlas_buf, atlas_w, atlas_h);
    try storeRaw(writer, image_atlas, atlas_buf, atlas_w, atlas_h);
    return atlas;
}

fn runProofStep(allocator: std.mem.Allocator, writer: anytype, step: usize) !void {
    try kittyDeleteAll(writer);
    try ansiClear(writer);

    if (step == 0) {
        try runProbeCloneScene(allocator, writer);
        return;
    }

    if (step == 1) {
        try runProbeCloneScene(allocator, writer);
        _ = try Renderer.init(allocator, writer);
        try moveCursor(writer, 20, 1);
        try writer.writeAll("STEP 1: probe clone, then Renderer.init() — did init wipe/break it?");
        try moveCursor(writer, 21, 1);
        try writer.writeAll("Enter next, b back, q quit");
        return;
    }

    if (step == 2) {
        _ = try Renderer.init(allocator, writer);
        try runProbeCloneScene(allocator, writer);
        try moveCursor(writer, 20, 1);
        try writer.writeAll("STEP 2: Renderer.init(), then probe clone again");
        try moveCursor(writer, 21, 1);
        try writer.writeAll("If this fails, init poisoned later graphics commands");
        return;
    }

    if (step == 3) {
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 3: upload real background only");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("Enter next, b back, q quit");
        try uploadRealBackground(allocator, writer);
        return;
    }

    if (step == 4) {
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 4: place real background");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("Enter next, b back, q quit");
        try uploadRealBackground(allocator, writer);
        try placeBackground(writer);
        return;
    }

    if (step == 5) {
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 5: upload real atlas only");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("Enter next, b back, q quit");
        _ = try uploadRealAtlas(allocator, writer);
        return;
    }

    if (step == 6) {
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 6: hardcoded atlas crop vs renderer.atlas.block[1]");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("Enter next, b back, q quit");
        const atlas = try uploadRealAtlas(allocator, writer);
        const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
        const rect = atlas.block[1];
        try moveCursor(writer, 3, 1);
        try writer.print("hard=({d},{d},{d},{d}) atlas.block[1]=({d},{d},{d},{d})", .{ hard.x, hard.y, hard.w, hard.h, rect.x, rect.y, rect.w, rect.h });
        try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        try placeTile(writer, image_atlas, 9101, board_col + 6, board_row + 2, cell_cols, cell_rows, rect, 8);
        return;
    }

    if (step == 7) {
        const renderer = try Renderer.init(allocator, writer);
        _ = renderer;
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 7: Renderer.init(), then hardcoded atlas crop");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("Does init make image_atlas unusable?");
        const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
        try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        return;
    }

    if (step == 8) {
        _ = try Renderer.init(allocator, writer);
        try moveCursor(writer, 1, 1);
        try writer.writeAll("STEP 8: Renderer.init(), then re-store atlas, then hardcoded crop");
        try moveCursor(writer, 2, 1);
        try writer.writeAll("If this works, init's atlas upload/path is the culprit");
        _ = try uploadRealAtlas(allocator, writer);
        const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
        try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        return;
    }

    var renderer = try Renderer.init(allocator, writer);
    var game = makeProofGame();

    try moveCursor(writer, 1, 1);
    switch (step) {
        9 => try writer.writeAll("STEP 9: bg upload -> atlas upload -> hardcoded atlas crop"),
        10 => try writer.writeAll("STEP 10: bg upload -> place bg -> atlas upload -> hardcoded atlas crop"),
        11 => try writer.writeAll("STEP 11: bg upload -> atlas upload -> place bg -> hardcoded atlas crop"),
        12 => try writer.writeAll("STEP 12: ghost + glow overlay"),
        13 => try writer.writeAll("STEP 13: sweep + tint overlays"),
        14 => try writer.writeAll("STEP 14: board diff render"),
        15 => try writer.writeAll("STEP 15: active + ghost + preview"),
        16 => try writer.writeAll("STEP 16: HUD"),
        17 => try writer.writeAll("STEP 17: full renderer.render sample frame"),
        18 => try writer.writeAll("STEP 18: hardDrop() then render()"),
        else => try writer.writeAll("STEP 19: hardDrop() twice with render()"),
    }
    try moveCursor(writer, 2, 1);
    try writer.writeAll("Enter next, b back, q quit");

    switch (step) {
        3 => {
            const bg = try allocator.alloc(u8, @as(usize, @intCast(bg_w * bg_h * 4)));
            defer allocator.free(bg);
            buildBackground(bg, bg_w, bg_h);
            try storeRaw(writer, image_bg, bg, bg_w, bg_h);
        },
        4 => {
            const bg = try allocator.alloc(u8, @as(usize, @intCast(bg_w * bg_h * 4)));
            defer allocator.free(bg);
            buildBackground(bg, bg_w, bg_h);
            try storeRaw(writer, image_bg, bg, bg_w, bg_h);
            try placeBackground(writer);
        },
        5 => {
            const atlas_buf = try allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4)));
            defer allocator.free(atlas_buf);
            _ = buildAtlas(atlas_buf, atlas_w, atlas_h);
            try storeRaw(writer, image_atlas, atlas_buf, atlas_w, atlas_h);
        },
        6 => {
            const atlas_buf = try allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4)));
            defer allocator.free(atlas_buf);
            const atlas = buildAtlas(atlas_buf, atlas_w, atlas_h);
            try storeRaw(writer, image_atlas, atlas_buf, atlas_w, atlas_h);
            const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
            const rect = atlas.block[1];
            try moveCursor(writer, 3, 1);
            try writer.print("hard=({d},{d},{d},{d}) atlas.block[1]=({d},{d},{d},{d})", .{ hard.x, hard.y, hard.w, hard.h, rect.x, rect.y, rect.w, rect.h });
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
            try placeTile(writer, image_atlas, 9101, board_col + 6, board_row + 2, cell_cols, cell_rows, rect, 8);
        },
        7 => {
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, renderer.atlas.block[1], 8);
            try placeTile(writer, image_atlas, 9110, board_col + 2, board_row + 4, cell_cols, cell_rows, renderer.atlas.ghost[1], 7);
            try placeTile(writer, image_atlas, 9111, board_col + 4, board_row + 4, cell_cols, cell_rows, renderer.atlas.glow[1], 9);
        },
        8 => {
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, renderer.atlas.block[1], 8);
            try placeTile(writer, image_atlas, 9112, board_col, board_row + 8, board_cols, cell_rows, renderer.atlas.sweep[2], 20);
            try placeTile(writer, image_atlas, 9113, board_col, board_row + 10, board_cols, board_rows, renderer.atlas.tint, 15);
        },
        9 => {
            try uploadRealBackground(allocator, writer);
            _ = try uploadRealAtlas(allocator, writer);
            const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        },
        10 => {
            try uploadRealBackground(allocator, writer);
            try placeBackground(writer);
            _ = try uploadRealAtlas(allocator, writer);
            const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        },
        11 => {
            try uploadRealBackground(allocator, writer);
            _ = try uploadRealAtlas(allocator, writer);
            try placeBackground(writer);
            const hard = Rect{ .x = 0, .y = 0, .w = 32, .h = 32 };
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, hard, 8);
        },
        12 => {
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, renderer.atlas.block[1], 8);
            try placeTile(writer, image_atlas, 9110, board_col + 2, board_row + 4, cell_cols, cell_rows, renderer.atlas.ghost[1], 7);
            try placeTile(writer, image_atlas, 9111, board_col + 4, board_row + 4, cell_cols, cell_rows, renderer.atlas.glow[1], 9);
        },
        13 => {
            try placeTile(writer, image_atlas, 9100, board_col + 2, board_row + 2, cell_cols, cell_rows, renderer.atlas.block[1], 8);
            try placeTile(writer, image_atlas, 9112, board_col, board_row + 8, board_cols, cell_rows, renderer.atlas.sweep[2], 20);
            try placeTile(writer, image_atlas, 9113, board_col, board_row + 10, board_cols, board_rows, renderer.atlas.tint, 15);
        },
        14 => {
            try renderer.drawBoardDiff(writer, &game);
        },
        15 => {
            try renderer.drawBoardDiff(writer, &game);
            try renderer.drawGhost(writer, &game, 0.4);
            try renderer.drawActive(writer, &game, 0.4);
            const next_origin = previewOrigin(game.next, layout.next_panel);
            try renderer.drawPreview(writer, game.next, placement_next_start, next_origin.x, next_origin.y, false);
            if (game.hold) |held| {
                const hold_origin = previewOrigin(held, layout.hold_panel);
                try renderer.drawPreview(writer, held, placement_hold_start, hold_origin.x, hold_origin.y, false);
            }
        },
        16 => {
            try renderer.drawBoardDiff(writer, &game);
            try renderer.drawGhost(writer, &game, 0.4);
            try renderer.drawActive(writer, &game, 0.4);
            const next_origin = previewOrigin(game.next, layout.next_panel);
            try renderer.drawPreview(writer, game.next, placement_next_start, next_origin.x, next_origin.y, false);
            if (game.hold) |held| {
                const hold_origin = previewOrigin(held, layout.hold_panel);
                try renderer.drawPreview(writer, held, placement_hold_start, hold_origin.x, hold_origin.y, false);
            }
            try renderer.drawHud(writer, &game, 0.4);
        },
        17 => {
            try renderer.render(writer, &game, 0.4);
        },
        18 => {
            game.hardDrop();
            try renderer.render(writer, &game, 0.4);
        },
        else => {
            game.hardDrop();
            try renderer.render(writer, &game, 0.4);
            game.hardDrop();
            try renderer.render(writer, &game, 0.4);
        },
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const proof_mode = args.len > 1 and std.mem.eql(u8, args[1], "--proof");
    const simple_proof_mode = args.len > 1 and std.mem.eql(u8, args[1], "--proof-simple");

    var writer = std.fs.File.stdout().deprecatedWriter();
    const stdin_fd = std.fs.File.stdin().handle;

    const original_termios = try std.posix.tcgetattr(stdin_fd);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    if (!(proof_mode or simple_proof_mode)) {
        if (!try detectGraphicsSupport(allocator, writer)) {
            std.debug.print("ttytris: kitty graphics protocol not detected in this terminal session. Run `zig build probe` to see what works.\n", .{});
            return;
        }
    }

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer {
        kittyDeleteAll(writer) catch {};
        writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
    }

    if (proof_mode or simple_proof_mode) {
        var step: usize = if (simple_proof_mode) 0 else 0;
        try runProofStep(allocator, writer, step);
        var reader = std.fs.File.stdin().deprecatedReader();
        var buf: [16]u8 = undefined;
        while (true) {
            const n = reader.read(&buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n > 0) {
                for (buf[0..n]) |ch| switch (ch) {
                    'q', 'Q' => return,
                    '\r', '\n' => {
                        if (step < 19) step += 1;
                        try runProofStep(allocator, writer, step);
                    },
                    'b', 'B' => {
                        if (step > 0) step -= 1;
                        try runProofStep(allocator, writer, step);
                    },
                    else => {},
                };
            }
            std.Thread.sleep(16 * std.time.ns_per_ms);
        }
        return;
    }

    var renderer = try Renderer.init(allocator, writer);

    var shared = SharedInput{};
    var thread = try std.Thread.spawn(.{}, inputThread, .{&shared});
    defer {
        shared.mutex.lock();
        shared.stop = true;
        shared.mutex.unlock();
        thread.join();
    }

    var game = Game.init(@intCast(std.time.nanoTimestamp()));
    var timer = try std.time.Timer.start();
    var elapsed_t: f32 = 0;

    while (true) {
        const dt_ns = timer.lap();
        const dt = @min(@as(f32, @floatFromInt(dt_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s)), 0.05);
        elapsed_t += dt;

        shared.mutex.lock();
        const input = shared.state;
        shared.state = .{};
        shared.mutex.unlock();
        if (input.quit) break;

        game.update(dt, input);
        try renderer.render(writer, &game, elapsed_t);

        std.Thread.sleep(@as(u64, @intFromFloat((1.0 / fps) * @as(f32, @floatFromInt(std.time.ns_per_s)))));
    }
}
