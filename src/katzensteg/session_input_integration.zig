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
    // The complete marker never appears in command echo; only the INT trap
    // can produce it. Suppressing Ctrl-C must therefore time out.
    try shell_content.sendBytes("trap 'printf \"INT%s\\n\" ERRUPTED' INT; printf 'RUN_%s\\n' READY; sleep 30\r", false);
    try waitText(init.io, shell_content, "RUN_READY");
    try shell_content.sendBytes("\x03", false);
    try waitText(init.io, shell_content, "INTERRUPTED");
    // History belongs to cleat. Exercise the public WM Content API against
    // real PTY output: both wheel and key navigation expose earlier mirror
    // lines, and typing immediately after scrolling restores the live view.
    const history = try session.Content.create(init.gpa, provider, "stty -echo; i=1; while [ $i -le 20 ]; do printf 'HISTORY_%02d\\n' $i; i=$((i+1)); done; printf 'HISTORY_READY\\n'; read line; printf 'TYPED_%s\\n' \"$line\"; sleep 30", 40, 6, null, null);
    defer history.deinit();
    try waitText(init.io, history, "HISTORY_READY");
    const wheel = @import("cleat_input_adapter.zig").Pointer{ .button = 64, .pressed = true, .col = 0, .row = 0, .x = 0, .y = 0 };
    try history.sendPointer(wheel);
    try waitText(init.io, history, "HISTORY_14");
    if (!history.mirror.scrolled_back) return error.ExpectedScrollback;
    try history.sendBytes("\x1b[6;2~", false);
    try waitText(init.io, history, "HISTORY_READY");
    if (history.mirror.scrolled_back) return error.ExpectedBottom;
    try history.sendBytes("\x1b[5;2~", false);
    try waitText(init.io, history, "HISTORY_11");
    if (!history.mirror.scrolled_back) return error.ExpectedScrollback;
    try history.sendBytes("x", false);
    try waitText(init.io, history, "HISTORY_READY");
    if (history.mirror.scrolled_back) return error.ExpectedBottom;
    // No render pump between wheel and typing: snap-back must not depend on
    // the mirror having observed the viewport transition yet.
    try history.sendPointer(wheel);
    try history.sendBytes("y\r", false);
    try waitText(init.io, history, "TYPED_xy");
    if (history.mirror.scrolled_back) return error.ExpectedBottom;

    // A real raw-mode program enables SGR mouse tracking. The wheel must
    // arrive as program bytes, even with a modifier, without moving history.
    const mouse = try session.Content.create(init.gpa, provider, "python3 -c 'import os,tty; tty.setraw(0); os.write(1,b\"\\x1b[?1000h\\x1b[?1006hMOUSE_READY\"); data=os.read(0,64); os.write(1,b\"MOUSE_BYTES_\"+data.hex().encode()); import time; time.sleep(30)'", 80, 6, null, null);
    defer mouse.deinit();
    try waitText(init.io, mouse, "MOUSE_READY");
    if (mouse.mirror.modes.mouse_tracking == .none) return error.ExpectedMouseTracking;
    var modified_wheel = wheel;
    modified_wheel.button |= 8;
    try mouse.sendPointer(modified_wheel);
    try waitText(init.io, mouse, "MOUSE_BYTES_1b5b3c37323b313b314d");
    if (mouse.mirror.scrolled_back) return error.ExpectedBottom;

    // On the alternate screen Shift+PageUp belongs to the program.
    const alternate = try session.Content.create(init.gpa, provider, "python3 -c 'import os,tty; tty.setraw(0); os.write(1,b\"\\x1b[?1049hALT_READY\"); data=os.read(0,64); os.write(1,b\"ALT_BYTES_\"+data.hex().encode()); import time; time.sleep(30)'", 80, 6, null, null);
    defer alternate.deinit();
    try waitText(init.io, alternate, "ALT_READY");
    if (!alternate.mirror.modes.alternate_screen) return error.ExpectedAlternate;
    try alternate.sendBytes("\x1b[5;2~", false);
    try waitText(init.io, alternate, "ALT_BYTES_1b5b353b327e");
}
