const std = @import("std");

pub const ImageHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const NodeKind = enum {
    sprite,
    text,
};

pub const NodeKey = packed struct(u64) {
    kind: u8,
    namespace: u24,
    id: u32,

    pub fn sprite(namespace: u24, id: u32) NodeKey {
        return .{ .kind = 1, .namespace = namespace, .id = id };
    }

    pub fn text(namespace: u24, id: u32) NodeKey {
        return .{ .kind = 2, .namespace = namespace, .id = id };
    }

    pub fn nodeKind(self: NodeKey) NodeKind {
        return if (self.kind == 1) .sprite else .text;
    }
};

pub const SourceRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const CellPoint = struct {
    col: i32,
    row: i32,
};

pub const CellRect = struct {
    col: i32,
    row: i32,
    w: i32,
    h: i32,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const TextMode = enum {
    auto,
    terminal,
    sprite_font,
};

pub const TextStyle = struct {
    fg: Color = .{ .r = 255, .g = 255, .b = 255 },
    bg: ?Color = null,
};

pub const SpriteNode = struct {
    key: NodeKey,
    image: ImageHandle,
    source_rect: SourceRect,
    dest_rect: CellRect,
    z: i32 = 0,
    visible: bool = true,
};

pub const TextNode = struct {
    key: NodeKey,
    pos: CellPoint,
    content: []const u8,
    z: i32 = 0,
    visible: bool = true,
    mode: TextMode = .auto,
    style: TextStyle = .{},
};

pub fn eqlSprite(a: SpriteNode, b: SpriteNode) bool {
    return std.meta.eql(a, b);
}

pub fn eqlText(a: TextNode, b: TextNode) bool {
    return a.key.id == b.key.id and a.key.kind == b.key.kind and a.key.namespace == b.key.namespace and
        a.pos.col == b.pos.col and a.pos.row == b.pos.row and a.z == b.z and a.visible == b.visible and
        a.mode == b.mode and std.meta.eql(a.style, b.style) and std.mem.eql(u8, a.content, b.content);
}
