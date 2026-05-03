const core = @import("core_types.zig");
const frame_builder = @import("frame_builder.zig");

const CoreHandle = core.CoreHandle;
const CoreRect = core.CoreRect;
const CorePoint = core.CorePoint;
const ExternalFramebufferFormat = frame_builder.ExternalFramebufferFormat;

pub const Command = union(enum) {
    create_window: struct { window: CoreHandle, w: i32, h: i32 },
    window_size: struct { window: CoreHandle, w: i32, h: i32 },
    create_renderer: struct { window: CoreHandle, renderer: CoreHandle },
    destroy_renderer: struct { renderer: CoreHandle },
    create_texture: struct { texture: CoreHandle, format: core.PixelFormat, w: i32, h: i32 },
    destroy_texture: struct { texture: CoreHandle },
    update_texture: struct { texture: CoreHandle, rect: ?CoreRect, pixels: ?[]u8, pitch: i32 },
    update_yuv_texture: struct { texture: CoreHandle, rect: ?CoreRect, yplane: ?[]u8, ypitch: i32, uplane: ?[]u8, upitch: i32, vplane: ?[]u8, vpitch: i32 },
    update_nv_texture: struct { texture: CoreHandle, rect: ?CoreRect, yplane: ?[]u8, ypitch: i32, uvplane: ?[]u8, uvpitch: i32 },
    lock_texture: struct { texture: CoreHandle, rect: ?CoreRect, pixels: ?*anyopaque, pitch: i32 },
    unlock_texture: struct { texture: CoreHandle },
    set_texture_color_mod: struct { texture: CoreHandle, r: u8, g: u8, b: u8 },
    set_texture_alpha_mod: struct { texture: CoreHandle, a: u8 },
    set_texture_blend_mode: struct { texture: CoreHandle, blend_mode: core.BlendMode },
    set_render_draw_color: struct { renderer: CoreHandle, r: u8, g: u8, b: u8, a: u8 },
    render_clear: struct { renderer: CoreHandle },
    render_copy: struct { renderer: CoreHandle, texture: CoreHandle, src: ?CoreRect, dst: ?CoreRect },
    render_copy_ex: struct { renderer: CoreHandle, texture: CoreHandle, src: ?CoreRect, dst: ?CoreRect, angle: f64, center: ?CorePoint, flip: c_int },
    render_fill_rect: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_draw_point: struct { renderer: CoreHandle, x: i32, y: i32 },
    render_draw_line: struct { renderer: CoreHandle, x1: i32, y1: i32, x2: i32, y2: i32 },
    render_set_viewport: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_set_clip_rect: struct { renderer: CoreHandle, rect: ?CoreRect },
    render_present: struct { renderer: CoreHandle },
    external_framebuffer_present: struct { width: i32, height: i32, format: ExternalFramebufferFormat, pixels: ?[]u8 },
    create_color_cursor: struct { cursor: CoreHandle, width: i32, height: i32, hot_x: i32, hot_y: i32, rgba: ?[]u8 },
    set_cursor: struct { cursor: CoreHandle },
    show_cursor: struct { visible: bool },
    free_cursor: struct { cursor: CoreHandle },
    set_cursor_position: struct { position: ?CorePoint },
};
