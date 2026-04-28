const std = @import("std");
const core = @import("core_types.zig");
const termscene = @import("termscene");

const ts_types = termscene.types;

pub const AssetPublication = union(enum) {
    new_asset: struct {
        asset_id: u64,
        width: i32,
        height: i32,
        rgba: []u8,
        owns_rgba: bool = true,
    },

    pub fn deinit(self: *AssetPublication, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .new_asset => |*asset| if (asset.owns_rgba) allocator.free(asset.rgba),
        }
        self.* = undefined;
    }
};

pub const SceneSprite = struct {
    asset_id: u64,
    source_rect: core.CoreRect,
    dest_rect: ts_types.CellRect,
    z: i32,
};

pub const SolidSprite = struct {
    color: [4]u8,
    dest_rect: ts_types.CellRect,
    z: i32,
};

pub const SceneJob = struct {
    had_clear: bool,
    clear_color: [4]u8,
    publications: []AssetPublication,
    sprites: []SceneSprite,
    solids: []SolidSprite,

    pub fn deinit(self: *SceneJob, allocator: std.mem.Allocator) void {
        for (self.publications) |*publication| publication.deinit(allocator);
        allocator.free(self.publications);
        allocator.free(self.sprites);
        allocator.free(self.solids);
        self.* = undefined;
    }
};

pub const FramebufferJob = struct {
    width: i32,
    height: i32,
    rgba: []u8,
    owns_rgba: bool = true,

    pub fn deinit(self: *FramebufferJob, allocator: std.mem.Allocator) void {
        if (self.owns_rgba) allocator.free(self.rgba);
        self.* = undefined;
    }
};

pub const PresentJob = union(enum) {
    scene: SceneJob,
    framebuffer: FramebufferJob,

    pub fn deinit(self: *PresentJob, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .scene => |*job| job.deinit(allocator),
            .framebuffer => |*job| job.deinit(allocator),
        }
    }
};

test "framebuffer job can borrow rgba without freeing it" {
    const rgba = try std.testing.allocator.alloc(u8, 4);
    defer std.testing.allocator.free(rgba);

    var job = FramebufferJob{
        .width = 1,
        .height = 1,
        .rgba = rgba,
        .owns_rgba = false,
    };
    job.deinit(std.testing.allocator);
}
