//! Byte/state integration scenario, invoked only with a private runtime root.
const std = @import("std");
const cleat = @import("cleat");
const c = cleat.c;
const Content = @import("wm_session").Content;

fn appendCells(cells: [*c]const c.cleat_render_cell, count: usize, bytes: []u8, len: *usize) void {
    if (count == 0) return;
    for (cells[0..count]) |cell| {
        if (cell.grapheme_count == 0) continue;
        for (cell.graphemes[0..cell.grapheme_count]) |cp| {
            if (cp < 128 and len.* < bytes.len) {
                bytes[len.*] = @intCast(cp);
                len.* += 1;
            }
        }
    }
}
fn contains(update: c.cleat_render_update, needle: []const u8) bool {
    var bytes: [8192]u8 = undefined;
    var len: usize = 0;
    if (update.op_count == 0) return false;
    for (update.ops[0..update.op_count]) |op| {
        appendCells(op.cells, op.cell_count, &bytes, &len);
        if (op.row_desc_count == 0) continue;
        for (op.rows[0..op.row_desc_count]) |row| appendCells(row.cells, row.cell_count, &bytes, &len);
    }
    return std.mem.indexOf(u8, bytes[0..len], needle) != null;
}
fn waitText(io: std.Io, session: cleat.Session, needle: []const u8, full: bool) !void {
    for (0..500) |_| {
        if (session.pull()) |value| {
            var update = value;
            defer session.release(&update);
            if (full and update.op_count > 0) try std.testing.expect(contains(update, needle));
            if (contains(update, needle)) {
                if (full) {
                    // Attach's first render contains the complete visible grid.
                    try std.testing.expectEqual(@as(c_uint, c.CLEAT_DIRTY_FULL), update.dirty);
                    try std.testing.expect(update.op_count > 0);
                    try std.testing.expectEqual(c.CLEAT_RENDER_OP_FULL_VISIBLE_REPLACE, update.ops[0].kind);
                }
                return;
            }
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.RenderTimeout;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    if (args.len != 3) return error.Usage;
    // A wrong pin must refuse opening and preserve both actual versions.
    var wrong = cleat.pin;
    wrong.protocol += 1;
    const mismatch = (try cleat.Provider.open(init.gpa, init.io, args[1], args[2], wrong)).mismatch;
    try std.testing.expectEqualDeep(cleat.pin, mismatch.actual);
    try std.testing.expectEqualDeep(wrong, mismatch.expected);
    wrong = cleat.pin;
    wrong.abi += 1;
    try std.testing.expectEqualDeep(cleat.pin, (try cleat.Provider.open(init.gpa, init.io, args[1], args[2], wrong)).mismatch.actual);
    const provider = (try cleat.Provider.open(init.gpa, init.io, args[1], args[2], cleat.pin)).provider;
    defer provider.close();
    const command = "stty -echo; printf CLEAT_READY; read answer; printf 'CLEAT_EFFECT_%s' \"$answer\"; sleep 30";
    // Exercise the WM's descriptor construction, including cleat-allocated id
    // and optional outer default colours, through the real provider.
    const content = try Content.create(init.gpa, provider, command, 80, 24, .{ 171, 205, 239 }, .{ 18, 52, 86 });
    defer content.deinit();
    const created = content.session.?;
    try waitText(init.io, created, "CLEAT_READY", false);
    const id = try init.gpa.dupe(u8, try created.id());
    defer init.gpa.free(id);
    // Unknown ids return a handle synchronously but are refused asynchronously.
    // The WM adapter must distinguish this from an established program exit.
    const missing = try Content.attach(init.gpa, provider, "unknown-session", 80, 24);
    defer missing.deinit();
    for (0..500) |_| {
        _ = try missing.pump();
        if (missing.ended()) break;
        try init.io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(missing.ended());
    try std.testing.expect(!missing.established);
    const confirmed = try Content.attach(init.gpa, provider, id, 80, 24);
    defer confirmed.deinit();
    for (0..500) |_| {
        _ = try confirmed.pump();
        if (confirmed.established) break;
        try init.io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(confirmed.established);
    try std.testing.expect(!confirmed.ended());
    // A quickly exiting program is an accepted session's normal exit, not an
    // opening refusal, even if the owner misses the streaming interval.
    const quick = try Content.create(init.gpa, provider, "true", 80, 24, null, null);
    defer quick.deinit();
    for (0..500) |_| {
        _ = try quick.pump();
        if (quick.ended()) break;
        try init.io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(quick.ended());
    try std.testing.expect(quick.established);

    const attached = try provider.attach(id, 80, 24);
    defer attached.destroy();
    // The attached client receives printed text in its initial full update.
    try waitText(init.io, attached, "CLEAT_READY", true);
    var event = std.mem.zeroes(c.cleat_input_event);
    event.kind = c.CLEAT_INPUT_KEY;
    event.key_action = c.CLEAT_KEY_ACTION_PRESS;
    event.key_kind = c.CLEAT_KEY_UNICODE_SCALAR;
    event.key_code = 'k';
    try attached.sendInput(event);
    event.key_kind = c.CLEAT_KEY_NAMED;
    event.key_code = c.CLEAT_KEY_ENTER;
    try attached.sendInput(event);
    // Echo is disabled: this text proves the program consumed the key.
    try waitText(init.io, attached, "CLEAT_EFFECT_k", false);
    try attached.resize(79, 23);
    var geometry = std.mem.zeroes(c.cleat_terminal_geometry);
    geometry.cell_width_px = 9;
    geometry.cell_height_px = 17;
    geometry.content_width_px = 79 * 9;
    geometry.content_height_px = 23 * 17;
    try attached.reportGeometry(geometry);
    // Resize and geometry reach the daemon and appear in render state.
    for (0..500) |_| {
        if (attached.pull()) |value| {
            var update = value;
            defer attached.release(&update);
            if (update.cols == 79 and update.rows == 23 and update.geometry.cell_width_px == 9 and update.geometry.cell_height_px == 17) return;
        }
        try init.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.GeometryTimeout;
}
