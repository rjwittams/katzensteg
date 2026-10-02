//! PROTOTYPE — throwaway (rjwittams/katzensteg#97). Turns the terminal bytes
//! the WM would forward to a producer into the structured events cleat takes.
//! Crude: mouse reports and paste brackets are dropped.
const std = @import("std");
const terminal_keys = @import("../terminal_keys.zig");
const proto_cells = @import("proto_cells");

pub fn forward(bytes: []const u8, reports_events: bool) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        if (byte == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
            var final = i + 2;
            while (final < bytes.len and !(bytes[final] >= 0x40 and bytes[final] <= 0x7e)) final += 1;
            if (final >= bytes.len) return;
            defer i = final + 1;
            const params = bytes[i + 2 .. final];
            if (params.len > 0 and params[0] == '<') continue;
            const report = terminal_keys.decodeCsi(params, bytes[final], reports_events) orelse continue;
            if (report != .key) continue;
            const decoded = report.key;
            proto_cells.key(decoded.key.name.slice(), @as(u32, @bitCast(decoded.key.modifiers)), switch (decoded.key.action) {
                .down, .tap => .down,
                .repeat => .repeat,
                .up => .up,
            }, decoded.text());
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            proto_cells.raw(bytes[i .. i + 1]);
            i += 1;
            continue;
        }
        var end = i;
        while (end < bytes.len and bytes[end] >= 0x20 and bytes[end] != 0x7f) end += 1;
        proto_cells.typed(bytes[i..end]);
        i = end;
    }
}
