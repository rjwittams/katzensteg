const std = @import("std");
const core = @import("core_types.zig");
const commands = @import("core_commands.zig");
const inspect_model = @import("inspect_model.zig");
const runtime_mod = @import("runtime.zig");

const Command = commands.Command;
const CoreHandle = core.CoreHandle;
const ExternalFramebufferFormat = @import("frame_builder.zig").ExternalFramebufferFormat;

pub fn onRenderPresentCore(rt: *runtime_mod.Runtime, renderer: CoreHandle, start_ns: i128) void {
    rt.frame_builder.onRenderPresent(&rt.logger, &rt.tty.?, &rt.engine.?, &rt.backend.?, renderer, rt.bg_only, rt.cursor_state.snapshot(), rt.debug_protocol_replies, rt.image_gc);
    rt.notePresentationLayout(rt.frame_builder.presentationLayoutForRenderer(&rt.tty.?, renderer));
    const duration = std.time.nanoTimestamp() - start_ns;
    rt.notePresentDuration(duration);
    const summary = rt.frame_builder.inspectSummary();
    const whiskers_frame: inspect_model.FrameRecord = .{
        .id = 0,
        .ts_ns = std.time.nanoTimestamp(),
        .present_ns = duration,
        .queue_depth = rt.currentQueueDepth(),
        .skipped_presents = rt.skipped_presents,
        .render_strategy = summary.render_strategy,
        .strategy_short = summary.strategy_short,
        .copies = summary.copies,
        .fills = summary.fills,
        .lines = summary.lines,
        .uploads = summary.uploads,
        .placements = summary.placements,
        .bytes_uploaded = summary.bytes_uploaded,
        .fallback_texture_key = summary.fallback_texture_key,
        .fallback_reason = summary.fallback_reason,
        .image_id = summary.image_id,
        .placement_id = summary.placement_id,
    };
    if (rt.whiskers_client) |*client| {
        rt.inspect_resources.clearRetainingCapacity();
        rt.frame_builder.appendSnapshotResources(rt.allocator, &rt.inspect_resources) catch return;
        rt.inspect_resource_records.clearRetainingCapacity();
        for (rt.inspect_resources.items) |res| {
            rt.inspect_resource_records.append(rt.allocator, .{
                .kind = switch (res.kind) {
                    .texture => .texture,
                    .image => .image,
                    .placement => .placement,
                },
                .texture_key = res.texture_key,
                .placement_id = res.placement_id,
                .alias = inspect_model.makeAlias(if (res.texture_key != 0) res.texture_key else res.image_id),
                .w = res.w,
                .h = res.h,
                .format = res.format,
                .blend_mode = res.blend_mode,
                .update_count = res.update_count,
                .image_id = res.image_id,
            }) catch {};
        }
        client.notePresent(whiskers_frame, rt.inspect_resource_records.items);
    }
}

pub fn onExternalFramebufferPresent(rt: *runtime_mod.Runtime, width: i32, height: i32, format: ExternalFramebufferFormat, pixels: []const u8) void {
    rt.presentExternalFramebuffer(width, height, format, pixels);
}

pub fn handleCommand(rt: *runtime_mod.Runtime, cmd: Command) void {
    switch (cmd) {
        .create_window => |c| rt.frame_builder.onCreateWindow(c.window, c.w, c.h),
        .create_renderer => |c| rt.frame_builder.onCreateRenderer(c.window, c.renderer),
        .destroy_renderer => |c| rt.frame_builder.onDestroyRenderer(c.renderer),
        .create_texture => |c| rt.frame_builder.onCreateTexture(c.texture, c.format, c.w, c.h),
        .destroy_texture => |c| rt.frame_builder.onDestroyTexture(c.texture),
        .update_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onUpdateTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.pixels) |buf| @ptrCast(buf.ptr) else null, c.pitch);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onUpdateTextureBatch(&rt.logger, c.texture, if (rect) |*r| r else null, if (c.pixels) |buf| @ptrCast(buf.ptr) else null, c.pitch);
            }
        },
        .update_yuv_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onUpdateYuvTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uplane) |buf| @ptrCast(buf.ptr) else null, c.upitch, if (c.vplane) |buf| @ptrCast(buf.ptr) else null, c.vpitch);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onUpdateYuvTextureBatch(&rt.logger, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uplane) |buf| @ptrCast(buf.ptr) else null, c.upitch, if (c.vplane) |buf| @ptrCast(buf.ptr) else null, c.vpitch);
            }
        },
        .update_nv_texture => |c| {
            var rect = c.rect;
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onUpdateNvTexture(&rt.logger, &rt.backend.?, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uvplane) |buf| @ptrCast(buf.ptr) else null, c.uvpitch);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onUpdateNvTextureBatch(&rt.logger, c.texture, if (rect) |*r| r else null, if (c.yplane) |buf| @ptrCast(buf.ptr) else null, c.ypitch, if (c.uvplane) |buf| @ptrCast(buf.ptr) else null, c.uvpitch);
            }
        },
        .lock_texture => |c| {
            var rect = c.rect;
            rt.frame_builder.onLockTexture(&rt.logger, c.texture, if (rect) |*r| r else null, c.pixels, c.pitch);
        },
        .unlock_texture => |c| {
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onUnlockTexture(&rt.logger, &rt.backend.?, c.texture);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onUnlockTextureBatch(&rt.logger, c.texture);
            }
        },
        .set_texture_color_mod => |c| {
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onSetTextureColorMod(&rt.logger, &rt.backend.?, c.texture, c.r, c.g, c.b);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onSetTextureColorModBatch(c.texture, c.r, c.g, c.b);
            }
        },
        .set_texture_alpha_mod => |c| {
            if (rt.active and rt.backend != null) {
                rt.frame_builder.onSetTextureAlphaMod(&rt.logger, &rt.backend.?, c.texture, c.a);
            } else if (rt.active and rt.batch_sink != null) {
                rt.frame_builder.onSetTextureAlphaModBatch(c.texture, c.a);
            }
        },
        .set_texture_blend_mode => |c| rt.frame_builder.onSetTextureBlendMode(&rt.logger, c.texture, c.blend_mode),
        .set_render_draw_color => |c| rt.frame_builder.onSetRenderDrawColor(c.renderer, c.r, c.g, c.b, c.a),
        .render_clear => |c| rt.frame_builder.onRenderClear(c.renderer),
        .render_copy => |c| {
            var src = c.src;
            var dst = c.dst;
            rt.frame_builder.onRenderCopy(&rt.logger, c.renderer, c.texture, if (src) |*r| r else null, if (dst) |*r| r else null);
        },
        .render_copy_ex => |c| {
            var src = c.src;
            var dst = c.dst;
            var center = c.center;
            rt.frame_builder.onRenderCopyEx(&rt.logger, c.renderer, c.texture, if (src) |*r| r else null, if (dst) |*r| r else null, c.angle, if (center) |*p| p else null, c.flip);
        },
        .render_fill_rect => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderFillRect(c.renderer, if (rect) |*r| r else null);
        },
        .render_draw_point => |c| rt.frame_builder.onRenderDrawPoint(c.renderer, c.x, c.y),
        .render_draw_line => |c| rt.frame_builder.onRenderDrawLine(&rt.logger, c.renderer, c.x1, c.y1, c.x2, c.y2),
        .render_set_viewport => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderSetViewport(c.renderer, if (rect) |*r| r else null);
        },
        .render_set_clip_rect => |c| {
            var rect = c.rect;
            rt.frame_builder.onRenderSetClipRect(c.renderer, if (rect) |*r| r else null);
        },
        .render_present => |c| {
            if (rt.batch_sink != null) {
                rt.renderBatchPresent(c.renderer);
                return;
            }
            if (rt.active and rt.tty != null and rt.engine != null and rt.backend != null and rt.shouldPresent()) {
                if (!rt.terminalRenderingEnabled()) {
                    rt.notePresentationLayout(.{});
                    return;
                }
                onRenderPresentCore(rt, c.renderer, std.time.nanoTimestamp());
            }
        },
        .external_framebuffer_present => |c| if (c.pixels) |buf| onExternalFramebufferPresent(rt, c.width, c.height, c.format, buf),
        .create_color_cursor => |c| if (c.rgba) |rgba| rt.cursor_state.createColorCursor(c.cursor, c.width, c.height, c.hot_x, c.hot_y, rgba),
        .set_cursor => |c| rt.cursor_state.setCursor(c.cursor),
        .show_cursor => |c| rt.cursor_state.showCursor(c.visible),
        .free_cursor => |c| rt.cursor_state.freeCursor(c.cursor),
        .set_cursor_position => |c| rt.cursor_state.setPosition(if (c.position) |p| .{ .x = p.x, .y = p.y } else null),
    }
}
