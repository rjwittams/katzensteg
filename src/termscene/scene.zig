const std = @import("std");
const types = @import("types.zig");
const backend = @import("backend.zig");

pub const SceneError = error{
    DuplicateKey,
    InvalidImageHandle,
} || std.mem.Allocator.Error;

pub const SceneEngine = struct {
    allocator: std.mem.Allocator,
    current_sprites: std.ArrayList(types.SpriteNode),
    current_text: std.ArrayList(types.TextNode),
    previous_sprites: std.ArrayList(types.SpriteNode),
    previous_text: std.ArrayList(types.TextNode),
    sprite_ops: std.ArrayList(backend.SpriteOp),
    text_ops: std.ArrayList(backend.TextOp),
    stats: backend.FlushStats = .{},

    pub fn init(allocator: std.mem.Allocator) SceneEngine {
        return .{
            .allocator = allocator,
            .current_sprites = .empty,
            .current_text = .empty,
            .previous_sprites = .empty,
            .previous_text = .empty,
            .sprite_ops = .empty,
            .text_ops = .empty,
        };
    }

    pub fn deinit(self: *SceneEngine) void {
        freeTextItems(self.allocator, self.current_text.items);
        freeTextItems(self.allocator, self.previous_text.items);
        self.current_sprites.deinit(self.allocator);
        self.current_text.deinit(self.allocator);
        self.previous_sprites.deinit(self.allocator);
        self.previous_text.deinit(self.allocator);
        self.sprite_ops.deinit(self.allocator);
        self.text_ops.deinit(self.allocator);
    }

    pub fn beginScene(self: *SceneEngine) void {
        freeTextItems(self.allocator, self.current_text.items);
        self.current_sprites.clearRetainingCapacity();
        self.current_text.clearRetainingCapacity();
        self.sprite_ops.clearRetainingCapacity();
        self.text_ops.clearRetainingCapacity();
        self.stats = .{};
    }

    pub fn sprite(self: *SceneEngine, node: types.SpriteNode) SceneError!void {
        if (node.image == .invalid) return error.InvalidImageHandle;
        for (self.current_sprites.items) |existing| {
            if (keyEq(existing.key, node.key)) return error.DuplicateKey;
        }
        try self.current_sprites.append(self.allocator, node);
        self.stats.sprite_submitted += 1;
    }

    // Submitted text content is copied and owned by the engine. Callers may pass
    // stack-backed or temporary slices safely; the slice does not need to outlive
    // the call to `text()`.
    pub fn text(self: *SceneEngine, node: types.TextNode) SceneError!void {
        for (self.current_text.items) |existing| {
            if (keyEq(existing.key, node.key)) return error.DuplicateKey;
        }
        const owned = try self.allocator.dupe(u8, node.content);
        var stored = node;
        stored.content = owned;
        try self.current_text.append(self.allocator, stored);
        self.stats.text_submitted += 1;
    }

    // Diff ops produced here reference node values from the current/previous scene
    // buffers. They are valid until the next scene mutation (`beginScene`, `text`,
    // `sprite`, or `commit`). Backends must consume ops before the scene is mutated.
    pub fn diff(self: *SceneEngine) !void {
        self.sprite_ops.clearRetainingCapacity();
        self.text_ops.clearRetainingCapacity();

        for (self.current_sprites.items) |node| {
            const prev = findSprite(self.previous_sprites.items, node.key);
            if (prev) |old| {
                if (!types.eqlSprite(old, node)) {
                    try self.sprite_ops.append(self.allocator, .{ .tag = .update, .node = node, .key = node.key });
                    self.stats.sprite_updated += 1;
                }
            } else {
                try self.sprite_ops.append(self.allocator, .{ .tag = .add, .node = node, .key = node.key });
                self.stats.sprite_added += 1;
            }
        }

        for (self.previous_sprites.items) |node| {
            if (findSprite(self.current_sprites.items, node.key) == null) {
                try self.sprite_ops.append(self.allocator, .{ .tag = .remove, .node = null, .key = node.key });
                self.stats.sprite_removed += 1;
            }
        }

        for (self.current_text.items) |node| {
            const prev = findText(self.previous_text.items, node.key);
            if (prev) |old| {
                if (!types.eqlText(old, node)) {
                    try self.text_ops.append(self.allocator, .{ .tag = .update, .node = node, .key = node.key });
                    self.stats.text_updated += 1;
                }
            } else {
                try self.text_ops.append(self.allocator, .{ .tag = .add, .node = node, .key = node.key });
                self.stats.text_added += 1;
            }
        }

        for (self.previous_text.items) |node| {
            if (findText(self.current_text.items, node.key) == null) {
                try self.text_ops.append(self.allocator, .{ .tag = .remove, .node = null, .key = node.key });
                self.stats.text_removed += 1;
            }
        }
    }

    // Commit swaps the current scene into previous scene ownership. For text nodes,
    // owned content moves with the arrays; no text slices are duplicated here.
    pub fn commit(self: *SceneEngine) !void {
        freeTextItems(self.allocator, self.previous_text.items);

        const prev_sprites = self.previous_sprites;
        self.previous_sprites = self.current_sprites;
        self.current_sprites = prev_sprites;
        self.current_sprites.clearRetainingCapacity();

        const prev_text = self.previous_text;
        self.previous_text = self.current_text;
        self.current_text = prev_text;
        self.current_text.clearRetainingCapacity();
    }

    pub fn flushStats(self: *SceneEngine) backend.FlushStats {
        return self.stats;
    }

    fn findSprite(items: []const types.SpriteNode, key: types.NodeKey) ?types.SpriteNode {
        for (items) |item| {
            if (keyEq(item.key, key)) return item;
        }
        return null;
    }

    fn findText(items: []const types.TextNode, key: types.NodeKey) ?types.TextNode {
        for (items) |item| {
            if (keyEq(item.key, key)) return item;
        }
        return null;
    }

    fn keyEq(a: types.NodeKey, b: types.NodeKey) bool {
        return a.kind == b.kind and a.namespace == b.namespace and a.id == b.id;
    }

    fn freeTextItems(allocator: std.mem.Allocator, items: []const types.TextNode) void {
        for (items) |item| allocator.free(item.content);
    }
};
