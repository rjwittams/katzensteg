const std = @import("std");
const system_io = @import("platform");
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const protocol = @import("protocol.zig");

pub const UploadMedium = enum {
    direct,
    shm,
    file_whole,
    file_offset,
};

const rotating_file_count = 256;

pub const Options = struct {
    upload_medium: UploadMedium = .direct,
    upload_file_path: ?[]const u8 = null,
    upload_file_high_water: u64 = 10 * 1024 * 1024,
    quiet: protocol.Quiet = .suppress_fail,
};

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
        node: types.SpriteNode,
    };

    const TextState = struct {
        row: i32,
        col: i32,
        len: usize,
    };

    const FileUploadState = struct {
        file: system_io.fs.File,
        path: []u8,
        high_water: u64,
        next_offset: u64,
        file_len: u64,
    };

    const RotatingFileUploadState = struct {
        paths: [rotating_file_count][]u8,
        file_lens: [rotating_file_count]u64,
        next_index: usize,
    };

    const UploadState = union(UploadMedium) {
        direct,
        shm: @import("shared_memory.zig").Pool,
        file_whole: RotatingFileUploadState,
        file_offset: FileUploadState,
    };

    allocator: std.mem.Allocator,
    file: system_io.fs.File,
    output: system_io.fs.File.Writer,
    sprites: std.AutoHashMap(u64, SpriteState),
    texts: std.AutoHashMap(u64, TextState),
    known_images: std.AutoHashMap(u32, void),
    retransmitted_images: std.AutoHashMap(u32, void),
    next_placement_id: u32,
    quiet: protocol.Quiet,
    upload: UploadState,

    pub fn init(allocator: std.mem.Allocator, file: system_io.fs.File) Backend {
        return initWithOptions(allocator, file, .{}) catch unreachable;
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, file: system_io.fs.File, options: Options) !Backend {
        const io = file.io;
        return .{
            .allocator = allocator,
            .file = file,
            .output = file.writerStreaming(&.{}),
            .sprites = std.AutoHashMap(u64, SpriteState).init(allocator),
            .texts = std.AutoHashMap(u64, TextState).init(allocator),
            .known_images = std.AutoHashMap(u32, void).init(allocator),
            .retransmitted_images = std.AutoHashMap(u32, void).init(allocator),
            .next_placement_id = 1,
            .quiet = options.quiet,
            .upload = try initUploadState(io, allocator, options),
        };
    }

    pub fn deinit(self: *Backend) void {
        const io = self.file.io;
        switch (self.upload) {
            .direct => {},
            .shm => |*pool| pool.deinit(),
            .file_whole => |*state| {
                for (&state.paths) |*path| {
                    system_io.fs.deleteFileAbsolute(io, path.*) catch {};
                    self.allocator.free(path.*);
                }
            },
            .file_offset => |*state| {
                state.file.close();
                system_io.fs.deleteFileAbsolute(io, state.path) catch {};
                self.allocator.free(state.path);
            },
        }
        self.sprites.deinit();
        self.texts.deinit();
        self.known_images.deinit();
        self.retransmitted_images.deinit();
    }

    fn writer(self: *Backend) *std.Io.Writer {
        return &self.output.interface;
    }

    pub fn registerRawImage(self: *Backend, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
        const io = self.file.io;
        if (self.known_images.contains(image_id)) {
            try self.retransmitted_images.put(image_id, {});
        }
        switch (self.upload) {
            .direct => try protocol.writeTransmitRgbaWithQuiet(self.writer(), self.quiet, image_id, rgba, w, h),
            .shm => |*pool| {
                const object = try pool.create(rgba, 0);
                // A failed write can be partial; keep its name until teardown.
                try protocol.writeTransmitRgbaShm(self.writer(), self.quiet, image_id, object.name(), w, h);
            },
            .file_whole => |*state| {
                const index = state.next_index;
                state.next_index = (state.next_index + 1) % state.paths.len;
                var file = try system_io.fs.createFileAbsolute(io, state.paths[index], .{ .read = true, .truncate = false });
                defer file.close();
                try file.pwriteAll(rgba, 0);
                const rgba_len_u64: u64 = @intCast(rgba.len);
                if (rgba_len_u64 > state.file_lens[index]) {
                    try file.setEndPos(rgba.len);
                    state.file_lens[index] = rgba_len_u64;
                }
                try file.sync();
                try protocol.writeTransmitRgbaFileWholeWithQuiet(self.writer(), self.quiet, image_id, state.paths[index], w, h);
            },
            .file_offset => |*state| {
                const region = try reserveFileRegion(state, rgba.len);
                try state.file.pwriteAll(rgba, region.offset);
                try state.file.sync();
                try protocol.writeTransmitRgbaFileRegionWithQuiet(self.writer(), self.quiet, image_id, state.path, region.offset, rgba.len, w, h);
            },
        }
        try self.known_images.put(image_id, {});
    }

    pub fn applySpriteOps(self: *Backend, sprite_ops: []const backend.SpriteOp) !void {
        var touched_keys = std.AutoHashMap(u64, void).init(self.allocator);
        defer touched_keys.deinit();

        for (sprite_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const placement_id = try self.allocatePlacementId();
                    try protocol.writePlaceWithQuiet(self.writer(), self.quiet, node.dest_rect.row, node.dest_rect.col, .{
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
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = placement_id, .node = node });
                    try touched_keys.put(key_int, {});
                },
                .update => {
                    const node = op.node orelse continue;
                    const image_id = @intFromEnum(node.image);
                    const old_state = self.sprites.get(key_int);
                    const placement_id = blk: {
                        if (old_state) |state| {
                            if (state.image_id != image_id) {
                                try protocol.writeDeleteExactPlacementWithQuiet(self.writer(), self.quiet, .{ .image_id = state.image_id, .placement_id = state.placement_id });
                                break :blk try self.allocatePlacementId();
                            }
                            break :blk state.placement_id;
                        }
                        break :blk try self.allocatePlacementId();
                    };
                    try protocol.writePlaceWithQuiet(self.writer(), self.quiet, node.dest_rect.row, node.dest_rect.col, .{
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
                    try self.sprites.put(key_int, .{ .image_id = image_id, .placement_id = placement_id, .node = node });
                    try touched_keys.put(key_int, {});
                },
                .remove => {
                    if (self.sprites.fetchRemove(key_int)) |entry| {
                        try protocol.writeDeleteExactPlacementWithQuiet(self.writer(), self.quiet, .{ .image_id = entry.value.image_id, .placement_id = entry.value.placement_id });
                    }
                },
            }
        }

        if (self.retransmitted_images.count() > 0) {
            var it = self.sprites.iterator();
            while (it.next()) |entry| {
                const key_int = entry.key_ptr.*;
                if (touched_keys.contains(key_int)) continue;
                const state = entry.value_ptr.*;
                if (!self.retransmitted_images.contains(state.image_id)) continue;
                const node = state.node;
                try protocol.writePlaceWithQuiet(self.writer(), self.quiet, node.dest_rect.row, node.dest_rect.col, .{
                    .image_id = state.image_id,
                    .placement_id = state.placement_id,
                    .cols = node.dest_rect.w,
                    .rows = node.dest_rect.h,
                    .src_x = node.source_rect.x,
                    .src_y = node.source_rect.y,
                    .src_w = node.source_rect.w,
                    .src_h = node.source_rect.h,
                    .z = node.z,
                });
            }
            self.retransmitted_images.clearRetainingCapacity();
        }
    }

    pub fn deleteImageData(self: *Backend, image_id: u32) !void {
        try protocol.writeDeleteImageWithQuiet(self.writer(), self.quiet, .free_data, image_id);
        _ = self.known_images.remove(image_id);
        _ = self.retransmitted_images.remove(image_id);
    }

    pub fn applyTextOps(self: *Backend, text_ops: []const backend.TextOp) !void {
        for (text_ops) |op| {
            const key_int = keyToInt(op.key);
            switch (op.tag) {
                .add, .update => {
                    const node = op.node orelse continue;
                    if (self.texts.get(key_int)) |old| {
                        if (old.len > 0 and (old.row != node.pos.row or old.col != node.pos.col or old.len > node.content.len)) {
                            try protocol.moveCursor(self.writer(), old.row, old.col);
                            // ECH clips at the margin after a resize; spaces could wrap
                            // and scroll the bottom row. Reset the old background too.
                            try self.writer().print("\x1b[0m\x1b[{d}X", .{old.len});
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
                        if (entry.value.len > 0) try self.writer().print("\x1b[0m\x1b[{d}X", .{entry.value.len});
                    }
                },
            }
        }
    }

    fn initUploadState(io: std.Io, allocator: std.mem.Allocator, options: Options) !UploadState {
        switch (options.upload_medium) {
            .direct => return .direct,
            .shm => return .{ .shm = .{ .allocator = allocator } },
            .file_whole, .file_offset => {
                const path = options.upload_file_path orelse return error.MissingUploadFilePath;
                return switch (options.upload_medium) {
                    .file_whole => .{ .file_whole = try initRotatingFileUploadState(io, allocator, path) },
                    .file_offset => .{ .file_offset = try initSingleFileUploadState(io, allocator, path, options.upload_file_high_water) },
                    else => unreachable,
                };
            },
        }
    }

    fn initRotatingFileUploadState(io: std.Io, allocator: std.mem.Allocator, base_path: []const u8) !RotatingFileUploadState {
        var paths: [rotating_file_count][]u8 = undefined;
        const file_lens: [rotating_file_count]u64 = [_]u64{0} ** rotating_file_count;
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                allocator.free(paths[i]);
            }
        }
        for (0..rotating_file_count) |i| {
            paths[i] = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, i });
            system_io.fs.deleteFileAbsolute(io, paths[i]) catch {};
            initialized += 1;
        }
        return .{
            .paths = paths,
            .file_lens = file_lens,
            .next_index = 0,
        };
    }

    fn initSingleFileUploadState(io: std.Io, allocator: std.mem.Allocator, path: []const u8, high_water: u64) !FileUploadState {
        const duped_path = try allocator.dupe(u8, path);
        errdefer allocator.free(duped_path);
        const upload_file = try system_io.fs.createFileAbsolute(io, duped_path, .{ .read = true, .truncate = false });
        errdefer upload_file.close();
        return .{
            .file = upload_file,
            .path = duped_path,
            .high_water = high_water,
            .next_offset = 0,
            .file_len = 0,
        };
    }

    fn reserveFileRegion(state: *FileUploadState, byte_len: usize) !struct { offset: u64 } {
        const need = @as(u64, @intCast(byte_len));
        if (need == 0) return .{ .offset = state.next_offset };

        const wrap_limit = @max(state.high_water, need);
        if (state.next_offset + need > wrap_limit) {
            state.next_offset = 0;
        }
        const offset = state.next_offset;
        state.next_offset = offset + need;
        if (state.next_offset > state.file_len) {
            state.file_len = state.next_offset;
            try state.file.setEndPos(state.file_len);
        }
        return .{ .offset = offset };
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
};

pub const KittyBackend = Backend;

test "moving and removing terminal text erase old cells without wrapping" {
    var tmp = system_io.fs.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("text", .{ .read = true });
    defer file.close();
    var output = Backend.init(std.testing.allocator, file);
    defer output.deinit();
    const key = types.NodeKey.text(1, 1);
    var node = types.TextNode{ .key = key, .pos = .{ .row = 24, .col = 1 }, .content = "old menu" };
    try output.applyTextOps(&.{.{ .tag = .add, .key = key, .node = node }});
    node.pos.row = 30;
    node.content = "new menu";
    try output.applyTextOps(&.{.{ .tag = .update, .key = key, .node = node }});
    try output.applyTextOps(&.{.{ .tag = .remove, .key = key, .node = null }});
    try file.seekTo(0);
    var buffer: [1024]u8 = undefined;
    const bytes = buffer[0..try file.readAll(&buffer)];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[24;1H\x1b[0m\x1b[8X\x1b[30;1H") != null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "\x1b[30;1H\x1b[0m\x1b[8X"));
    try std.testing.expectEqual(@as(usize, 0), output.texts.count());
}
