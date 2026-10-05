//! Real daemon regression: input received before the role grant must be retained.
const std = @import("std");
const cleat = @import("cleat");
const session = @import("wm/session.zig");
const c = cleat.c;

fn waitText(io: std.Io, content: *session.Content, needle: []const u8) !void {
    for (0..500) |_| {
        _ = try content.pump();
        for (0..content.mirror.size.rows) |row| {
            var text = std.Io.Writer.Allocating.init(content.allocator);
            defer text.deinit();
            for (content.mirror.row(row)) |cell| try text.writer.writeAll(cell.text);
            if (std.mem.indexOf(u8, text.written(), needle) != null) return;
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.RenderTimeout;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    const provider = (try cleat.Provider.open(init.gpa, init.io, args[1], args[2], cleat.pin)).provider;
    defer provider.close();
    var desc = std.mem.zeroes(c.cleat_session_desc);
    const command = "stty -echo; printf BUFFER_READY; read line; printf 'BUFFER_EFFECT_%s' \"$line\"; sleep 30";
    desc.command = command.ptr;
    desc.command_len = command.len;
    desc.cols = 80;
    desc.rows = 24;
    desc.role = c.CLEAT_ROLE_CONTROLLER;
    const created = try provider.create(desc);
    defer created.destroy();
    const id = try init.gpa.dupe(u8, try created.id());
    defer init.gpa.free(id);
    const attached = try session.Content.attach(init.gpa, provider, id, 80, 24);
    defer attached.deinit();
    // Before any pump, borrowed WM tokens must survive the async control grant.
    // Mix keys, paste, and focus changes to check retained event ordering.
    try attached.focus(true);
    var byte = [_]u8{'w'};
    try attached.sendBytes(&byte, false);
    byte[0] = 'z';
    // The grant may land between two tokens before the owner's render pump.
    // Later input must drain earlier queued input first, preserving `wx`.
    for (0..500) |_| {
        _ = c.cleat_session_poll(attached.session.?.handle);
        if (c.cleat_session_role(attached.session.?.handle) == c.CLEAT_ROLE_CONTROLLER) break;
        try init.io.sleep(.fromMilliseconds(1), .awake);
    }
    try attached.sendBytes("\x1b[200~", false);
    try attached.sendBytes("x", false);
    try attached.sendBytes("\x1b[201~", false);
    try attached.focus(false);
    try attached.focus(true);
    try attached.sendBytes("\r", false);
    // Echo is disabled, so this proves the queued command reached the program.
    try waitText(init.io, attached, "BUFFER_EFFECT_wx");

    // Exercise the exact command/paste/interrupt scenario without the WM's
    // io_uring dependency, using the same Content API and real daemon mirror.
    const shell_command = "exec /bin/sh";
    desc.command = shell_command.ptr;
    desc.command_len = shell_command.len;
    const shell = try provider.create(desc);
    defer shell.destroy();
    const shell_id = try init.gpa.dupe(u8, try shell.id());
    defer init.gpa.free(shell_id);
    const shell_content = try session.Content.attach(init.gpa, provider, shell_id, 80, 24);
    defer shell_content.deinit();
    try shell_content.focus(true);
    for ("printf 'INPUT_%s\\n' OK\r") |value| try shell_content.sendBytes(&.{value}, false);
    try waitText(init.io, shell_content, "INPUT_OK");
    try shell_content.sendBytes("\x1b[200~", false);
    try shell_content.sendBytes("printf 'PASTE_%s\\n' OK", false);
    try shell_content.sendBytes("\x1b[201~", false);
    try shell_content.sendBytes("\r", false);
    try waitText(init.io, shell_content, "PASTE_OK");
    try shell_content.sendBytes("trap 'echo INTERRUPTED' INT; printf 'RUN_%s\\n' READY; sleep 30\r", false);
    try waitText(init.io, shell_content, "RUN_READY");
    try shell_content.sendBytes("\x03", false);
    try waitText(init.io, shell_content, "INTERRUPTED");
}
