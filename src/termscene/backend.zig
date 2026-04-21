const types = @import("types.zig");

pub const SpriteOpTag = enum {
    add,
    update,
    remove,
};

pub const TextOpTag = enum {
    add,
    update,
    remove,
};

pub const SpriteOp = struct {
    tag: SpriteOpTag,
    node: ?types.SpriteNode,
    key: types.NodeKey,
};

pub const TextOp = struct {
    tag: TextOpTag,
    node: ?types.TextNode,
    key: types.NodeKey,
};

pub const FlushStats = struct {
    sprite_submitted: usize = 0,
    text_submitted: usize = 0,
    sprite_added: usize = 0,
    sprite_updated: usize = 0,
    sprite_removed: usize = 0,
    text_added: usize = 0,
    text_updated: usize = 0,
    text_removed: usize = 0,
};
