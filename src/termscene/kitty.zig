const std = @import("std");
const types = @import("types.zig");
const backend = @import("backend.zig");

pub const KittyBackend = struct {
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

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) KittyBackend {
        return .{
            .allocator = allocator,
            .file = file,
            .sprites = std.AutoHashMap(u64, SpriteState).init(allocator),
            .texts = std.AutoHashMap(u64, TextState).init(allocator),
            .next_placement_id = 1,
        };
    }

    pub fn deinit(self: *KittyBackend) void {
        self.sprites.deinit();
        self.texts.deinit();
    }

    fn writer(self: *KittyBackend) std.fs.File.DeprecatedWriter {
        return self.file.deprecatedWriter();
    }

    pub fn registerRawImage(self: *KittyBackend, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        var prefix_buf: [128]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=t,f=32,s={d},v={d},i={d}", .{ w, h, image_id });
        try chunkedApc(self.writer(), prefix, rgba);
    }

    pub fn applySpriteOps(self: *KittyBackend, sprite_ops: []const backend.SpriteOp) !void {
        for (sprite_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const placement_id = try self.allocatePlacementId();
                    try moveCursor(self.writer(), node.dest_rect.row, node.dest_rect.col);
                    try self.writer().print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{
                        image_id,
                        placement_id,
                        node.dest_rect.w,
                        node.dest_rect.h,
                        node.source_rect.x,
                        node.source_rect.y,
                        node.source_rect.w,
                        node.source_rect.h,
                        node.z,
                    });
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = placement_id });
                },
                .update => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const state = self.sprites.get(key_int) orelse blk: {
                        const placement_id = try self.allocatePlacementId();
                        break :blk SpriteState{ .image_id = image_id, .placement_id = placement_id };
                    };
                    try moveCursor(self.writer(), node.dest_rect.row, node.dest_rect.col);
                    try self.writer().print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{
                        image_id,
                        state.placement_id,
                        node.dest_rect.w,
                        node.dest_rect.h,
                        node.source_rect.x,
                        node.source_rect.y,
                        node.source_rect.w,
                        node.source_rect.h,
                        node.z,
                    });
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = state.placement_id });
                },
                .remove => {
                    if (self.sprites.fetchRemove(key_int)) |entry| {
                        try self.writer().print("\x1b_Gq=2,a=d,d=i,i={d},p={d};\x1b\\", .{ entry.value.image_id, entry.value.placement_id });
                    }
                },
            }
        }
    }

    pub fn applyTextOps(self: *KittyBackend, text_ops: []const backend.TextOp) !void {
        for (text_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add, .update => {
                    const node = op.node orelse continue;
                    if (self.texts.get(key_int)) |old| {
                        if (old.row == node.pos.row and old.col == node.pos.col and old.len > node.content.len) {
                            try moveCursor(self.writer(), old.row, old.col);
                            try writeSpaces(self.writer(), old.len);
                        }
                    }
                    try moveCursor(self.writer(), node.pos.row, node.pos.col);
                    if (node.style.bg) |bg| {
                        try self.writer().print("\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{s}\x1b[0m", .{ node.style.fg.r, node.style.fg.g, node.style.fg.b, bg.r, bg.g, bg.b, node.content });
                    } else {
                        try self.writer().print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{ node.style.fg.r, node.style.fg.g, node.style.fg.b, node.content });
                    }
                    try self.texts.put(key_int, .{ .row = node.pos.row, .col = node.pos.col, .len = node.content.len });
                },
                .remove => {
                    if (self.texts.fetchRemove(key_int)) |entry| {
                        try moveCursor(self.writer(), entry.value.row, entry.value.col);
                        try writeSpaces(self.writer(), entry.value.len);
                    }
                },
            }
        }
    }

    fn chunkedApc(out: std.fs.File.DeprecatedWriter, prefix: []const u8, payload: []const u8) !void {
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
                try out.writeAll("\x1b_G");
                try out.writeAll(prefix);
                try out.print(",m={c};", .{more});
            } else {
                try out.print("\x1b_Gm={c};", .{more});
            }
            try out.writeAll(b64[offset..end]);
            try out.writeAll("\x1b\\");
            offset = end;
        }
    }

    fn moveCursor(out: std.fs.File.DeprecatedWriter, row: i32, col: i32) !void {
        try out.print("\x1b[{d};{d}H", .{ row, col });
    }

    fn keyToInt(key: types.NodeKey) u64 {
        return (@as(u64, key.kind) << 56) | (@as(u64, key.namespace) << 32) | key.id;
    }

    fn allocatePlacementId(self: *KittyBackend) !u32 {
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
