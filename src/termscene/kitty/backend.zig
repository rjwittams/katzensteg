const std = @import("std");
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const protocol = @import("protocol.zig");

pub const Backend = struct {
    // Backend-local retained state used to make remove/update operations correct.
    // Scene diffs are keyed by logical node keys, but kitty remove operations need
    // the exact placement id and image id originally used, and terminal text
    // removal needs the prior text position/length to blank old content.
    //
    // Placement ids are allocated by the backend and retained per logical sprite
    // key. This keeps placement-id management correct by construction: clients only
    // provide stable logical keys, while the backend owns kitty-specific placement
    // identity.
    const SpriteState = struct {
        image_id: u32,
        placement_id: u32,
    };

    const TextState = struct {
        row: i32,
        col: i32,
        len: usize,
    };

    allocator: std.mem.Allocator,
    file: std.fs.File,
    sprites: std.AutoHashMap(u64, SpriteState),
    texts: std.AutoHashMap(u64, TextState),
    next_placement_id: u32,

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) Backend {
        return .{
            .allocator = allocator,
            .file = file,
            .sprites = std.AutoHashMap(u64, SpriteState).init(allocator),
            .texts = std.AutoHashMap(u64, TextState).init(allocator),
            .next_placement_id = 1,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.sprites.deinit();
        self.texts.deinit();
    }

    fn writer(self: *Backend) std.fs.File.DeprecatedWriter {
        return self.file.deprecatedWriter();
    }

    pub fn registerRawImage(self: *Backend, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        try protocol.writeTransmitRgba(self.writer(), image_id, rgba, w, h);
    }

    pub fn applySpriteOps(self: *Backend, sprite_ops: []const backend.SpriteOp) !void {
        for (sprite_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const placement_id = try self.allocatePlacementId();
                    try protocol.writePlace(self.writer(), node.dest_rect.row, node.dest_rect.col, .{
                        .image_id = image_id,
                        .placement_id = placement_id,
                        .cols = node.dest_rect.w,
                        .rows = node.dest_rect.h,
                        .src_x = node.source_rect.x,
                        .src_y = node.source_rect.y,
                        .src_w = node.source_rect.w,
                        .src_h = node.source_rect.h,
                        .z = node.z,
                    });
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = placement_id });
                },
                .update => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const old_state = self.sprites.get(key_int);
                    const placement_id = blk: {
                        if (old_state) |state| {
                            if (state.image_id != image_id) {
                                try protocol.writeDeleteExactPlacement(self.writer(), .{ .image_id = state.image_id, .placement_id = state.placement_id });
                                break :blk try self.allocatePlacementId();
                            }
                            break :blk state.placement_id;
                        }
                        break :blk try self.allocatePlacementId();
                    };
                    try protocol.writePlace(self.writer(), node.dest_rect.row, node.dest_rect.col, .{
                        .image_id = image_id,
                        .placement_id = placement_id,
                        .cols = node.dest_rect.w,
                        .rows = node.dest_rect.h,
                        .src_x = node.source_rect.x,
                        .src_y = node.source_rect.y,
                        .src_w = node.source_rect.w,
                        .src_h = node.source_rect.h,
                        .z = node.z,
                    });
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = placement_id });
                },
                .remove => {
                    if (self.sprites.fetchRemove(key_int)) |entry| {
                        try protocol.writeDeleteExactPlacement(self.writer(), .{ .image_id = entry.value.image_id, .placement_id = entry.value.placement_id });
                    }
                },
            }
        }
    }

    pub fn applyTextOps(self: *Backend, text_ops: []const backend.TextOp) !void {
        for (text_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add, .update => {
                    const node = op.node orelse continue;
                    if (self.texts.get(key_int)) |old| {
                        if (old.row == node.pos.row and old.col == node.pos.col and old.len > node.content.len) {
                            try protocol.moveCursor(self.writer(), old.row, old.col);
                            try writeSpaces(self.writer(), old.len);
                        }
                    }
                    try protocol.moveCursor(self.writer(), node.pos.row, node.pos.col);
                    if (node.style.bg) |bg| {
                        try self.writer().print("\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{s}\x1b[0m", .{ node.style.fg.r, node.style.fg.g, node.style.fg.b, bg.r, bg.g, bg.b, node.content });
                    } else {
                        try self.writer().print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ node.style.fg.r, node.style.fg.g, node.style.fg.b, node.content });
                    }
                    try self.texts.put(key_int, .{ .row = node.pos.row, .col = node.pos.col, .len = node.content.len });
                },
                .remove => {
                    if (self.texts.fetchRemove(key_int)) |entry| {
                        try protocol.moveCursor(self.writer(), entry.value.row, entry.value.col);
                        try writeSpaces(self.writer(), entry.value.len);
                    }
                },
            }
        }
    }

    fn keyToInt(key: types.NodeKey) u64 {
        return (@as(u64, key.kind) << 56) | (@as(u64, key.namespace) << 32) | key.id;
    }

    fn allocatePlacementId(self: *Backend) !u32 {
        const id = self.next_placement_id;
        if (id == 0) return error.OutOfPlacementIds;
        self.next_placement_id +%= 1;
        if (self.next_placement_id == 0) self.next_placement_id = 1;
        return id;
    }

    fn writeSpaces(out: std.fs.File.DeprecatedWriter, count: usize) !void {
        var buf: [128]u8 = [_]u8{' '} ** 128;
        var remaining = count;
        while (remaining > 0) {
            const n = @min(remaining, buf.len);
            try out.writeAll(buf[0..n]);
            remaining -= n;
        }
    }
};

pub const KittyBackend = Backend;
