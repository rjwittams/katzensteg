const std = @import("std");

const ProbeResult = struct {
    kitty_graphics: bool,
    raw_reply: []u8,
};

fn writeApc(writer: anytype, control: []const u8, payload_b64: []const u8) !void {
    try writer.writeAll("\x1b_G");
    try writer.writeAll(control);
    try writer.writeAll(";");
    try writer.writeAll(payload_b64);
    try writer.writeAll("\x1b\\");
}

fn chunkedApc(writer: anytype, prefix: []const u8, payload: []const u8) !void {
    const enc_len = std.base64.standard.Encoder.calcSize(payload.len);
    const b64 = try std.heap.page_allocator.alloc(u8, enc_len);
    defer std.heap.page_allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, payload);

    var offset: usize = 0;
    const chunk: usize = 3072;
    while (offset < b64.len) {
        const end = @min(offset + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        if (offset == 0) {
            try writeApcPrefix(writer, prefix, more, b64[offset..end]);
        } else {
            try writer.print("\x1b_Gm={c};", .{more});
            try writer.writeAll(b64[offset..end]);
            try writer.writeAll("\x1b\\");
        }
        offset = end;
    }
}

fn writeApcPrefix(writer: anytype, prefix: []const u8, more: u8, payload_b64: []const u8) !void {
    try writer.writeAll("\x1b_G");
    try writer.writeAll(prefix);
    try writer.print(",m={c};", .{more});
    try writer.writeAll(payload_b64);
    try writer.writeAll("\x1b\\");
}

fn goto(writer: anytype, x: i32, y: i32) !void {
    try writer.print("\x1b[{d};{d}H", .{ y, x });
}

fn makeGradient(allocator: std.mem.Allocator, w: i32, h: i32, a_bias: u8) ![]u8 {
    const buf = try allocator.alloc(u8, @as(usize, @intCast(w * h * 4)));
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const idx: usize = @intCast((y * w + x) * 4);
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(@max(w - 1, 1)));
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(@max(h - 1, 1)));
            buf[idx] = @intFromFloat(255.0 * fx);
            buf[idx + 1] = @intFromFloat(255.0 * fy);
            buf[idx + 2] = @intFromFloat(255.0 * (1.0 - fx));
            const checker = if (@mod(@divTrunc(x, 8) + @divTrunc(y, 8), 2) == 0) a_bias else 255;
            buf[idx + 3] = checker;
        }
    }
    return buf;
}

fn readReplies(allocator: std.mem.Allocator, timeout_ms: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    var reader = std.fs.File.stdin().deprecatedReader();
    const start = std.time.milliTimestamp();
    var buf: [512]u8 = undefined;
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n > 0) {
            try list.appendSlice(allocator, buf[0..n]);
        } else {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn probeSupport(allocator: std.mem.Allocator, writer: anytype) !ProbeResult {
    try writer.writeAll("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    try writer.writeAll("\x1b[16t\x1b[5n");
    const reply = try readReplies(allocator, 700);
    return .{
        .kitty_graphics = std.mem.indexOf(u8, reply, "_Gi=31;OK") != null,
        .raw_reply = reply,
    };
}

fn deleteAll(writer: anytype) !void {
    try writer.writeAll("\x1b_Ga=d,q=2,d=A;\x1b\\");
}

fn storeRaw(writer: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32) !void {
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=t,f=32,s={d},v={d},i={d}", .{ w, h, image_id });
    try chunkedApc(writer, prefix, rgba);
}

fn placeStored(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32) !void {
    try goto(writer, x, y);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d};\x1b\\", .{ image_id, placement_id, cols, rows });
}

fn placeStoredZ(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32, z: i32) !void {
    try goto(writer, x, y);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},z={d};\x1b\\", .{ image_id, placement_id, cols, rows, z });
}

fn placeStoredCrop(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32, src_x: i32, src_y: i32, src_w: i32, src_h: i32) !void {
    try goto(writer, x, y);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d};\x1b\\", .{ image_id, placement_id, cols, rows, src_x, src_y, src_w, src_h });
}

fn placeStoredCropZ(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32, src_x: i32, src_y: i32, src_w: i32, src_h: i32, z: i32) !void {
    try goto(writer, x, y);
    try writer.print("\x1b_Gq=2,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{ image_id, placement_id, cols, rows, src_x, src_y, src_w, src_h, z });
}

fn deletePlacement(writer: anytype, image_id: u32, placement_id: u32) !void {
    try writer.print("\x1b_Gq=2,a=d,d=i,i={d},p={d};\x1b\\", .{ image_id, placement_id });
}

fn placeStoredCropQuiet(writer: anytype, image_id: u32, placement_id: u32, x: i32, y: i32, cols: i32, rows: i32, src_x: i32, src_y: i32, src_w: i32, src_h: i32, z: i32) !void {
    try goto(writer, x, y);
    try writer.print("\x1b_Gq=1,a=p,C=1,i={d},p={d},c={d},r={d},x={d},y={d},w={d},h={d},z={d};\x1b\\", .{ image_id, placement_id, cols, rows, src_x, src_y, src_w, src_h, z });
}

fn displayStoredRaw(writer: anytype, image_id: u32, placement_id: u32, rgba: []const u8, w: i32, h: i32, x: i32, y: i32, cols: i32, rows: i32) !void {
    try storeRaw(writer, image_id, rgba, w, h);
    try placeStored(writer, image_id, placement_id, x, y, cols, rows);
}

fn displayImmediateRaw(writer: anytype, image_id: u32, rgba: []const u8, w: i32, h: i32, x: i32, y: i32, cols: i32, rows: i32) !void {
    try goto(writer, x, y);
    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "q=2,a=T,C=1,f=32,s={d},v={d},i={d},c={d},r={d}", .{ w, h, image_id, cols, rows });
    try chunkedApc(writer, prefix, rgba);
}

fn drawGrid(writer: anytype, image_id: u32, shifted: bool) !void {
    var row: i32 = 0;
    while (row < 4) : (row += 1) {
        var col: i32 = 0;
        while (col < 6) : (col += 1) {
            const pid_base: u32 = @intCast(3000 + row * 10 + col);
            const pid_overlay: u32 = @intCast(4000 + row * 10 + col);
            const x = 3 + col * 3 + @as(i32, if (shifted and @mod(row, 2) == 0) 1 else 0);
            const y = 26 + row;
            const src_x = @mod(col * 13, 64);
            const src_y = @mod(row * 11, 32);
            try placeStoredCropZ(writer, image_id, pid_base, x, y, 2, 1, src_x, src_y, 24, 24, 5);
            try placeStoredCropZ(writer, image_id, pid_overlay, x, y, 2, 1, 32, 32, 32, 32, 6);
        }
    }
}

fn largeStoreTest(allocator: std.mem.Allocator, writer: anytype) !void {
    const big_bg = try makeGradient(allocator, 840, 560, 255);
    defer allocator.free(big_bg);
    const big_atlas = try makeGradient(allocator, 1280, 192, 220);
    defer allocator.free(big_atlas);

    try storeRaw(writer, 104, big_bg, 840, 560);
    try storeRaw(writer, 105, big_atlas, 1280, 192);
    try placeStoredZ(writer, 104, 9000, 1, 1, 42, 28, -10);
    try placeStoredCropZ(writer, 105, 9001, 52, 6, 20, 6, 160, 32, 320, 32, 10);
    try placeStoredCropZ(writer, 105, 9002, 52, 14, 20, 6, 512, 64, 32, 32, 12);
}

fn stress(writer: anytype, image_id: u32) !void {
    var frame: i32 = 0;
    while (frame < 180) : (frame += 1) {
        var row: i32 = 0;
        while (row < 10) : (row += 1) {
            var col: i32 = 0;
            while (col < 10) : (col += 1) {
                const pid: u32 = @intCast(8000 + row * 16 + col);
                const x = 70 + col * 2 + @as(i32, if (@mod(frame + row, 6) == 0) 1 else 0);
                const y = 6 + row;
                const src_x = @mod(col * 7 + frame * 3, 64);
                const src_y = @mod(row * 5 + frame * 2, 32);
                const z: i32 = if (@mod(row + col, 2) == 0) 4 else 5;
                try placeStoredCropQuiet(writer, image_id, pid, x, y, 2, 1, src_x, src_y, 24, 24, z);
            }
        }
        std.Thread.sleep(33 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var writer = std.fs.File.stdout().deprecatedWriter();
    const stdin_fd = std.fs.File.stdin().handle;
    const original_termios = try std.posix.tcgetattr(stdin_fd);
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch {};
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);

    try writer.writeAll("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l");
    defer writer.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    const probe = try probeSupport(allocator, writer);
    defer allocator.free(probe.raw_reply);

    try goto(writer, 1, 1);
    try writer.writeAll("ttytris probe\r\n");
    try writer.print("kitty graphics query: {s}\r\n", .{if (probe.kitty_graphics) "OK" else "NO"});
    try writer.writeAll("A immediate   B store+place   C cropped   D replace same placement id\r\n");
    try writer.writeAll("E negative-z bg   F many cropped+overlay placements   G wide strip   H board tint\r\n");
    try writer.writeAll("q quit  d delete all  m move D  x delete one F tile  v retile F grid  s stress  l large\r\n\r\n");

    const img1 = try makeGradient(allocator, 64, 32, 110);
    defer allocator.free(img1);
    const img2 = try makeGradient(allocator, 64, 32, 180);
    defer allocator.free(img2);
    const atlas = try makeGradient(allocator, 96, 64, 220);
    defer allocator.free(atlas);

    try goto(writer, 5, 3);
    try writer.writeAll("A");
    try goto(writer, 5, 24);
    try writer.writeAll("B");
    try goto(writer, 5, 45);
    try writer.writeAll("C");
    try goto(writer, 15, 24);
    try writer.writeAll("D");
    try goto(writer, 15, 3);
    try writer.writeAll("E");
    try goto(writer, 24, 3);
    try writer.writeAll("F");
    try goto(writer, 15, 45);
    try writer.writeAll("G");
    try goto(writer, 24, 45);
    try writer.writeAll("H");

    try displayImmediateRaw(writer, 101, img1, 64, 32, 3, 6, 14, 7);
    try displayStoredRaw(writer, 102, 1, img2, 64, 32, 24, 6, 14, 7);
    try storeRaw(writer, 103, atlas, 96, 64);
    try placeStoredCrop(writer, 103, 1, 45, 6, 14, 7, 0, 0, 48, 32);
    try placeStored(writer, 103, 2, 24, 16, 14, 7);
    try placeStoredZ(writer, 103, 5000, 1, 14, 24, 7, -10);
    try drawGrid(writer, 103, false);
    try placeStoredCropZ(writer, 103, 6000, 45, 16, 20, 2, 0, 24, 96, 16, 20);
    try placeStoredCropZ(writer, 103, 7000, 45, 25, 20, 4, 32, 32, 32, 32, 15);

    var moved = false;
    var shifted = false;
    var reader = std.fs.File.stdin().deprecatedReader();
    var buf: [16]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (n == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }
        for (buf[0..n]) |ch| switch (ch) {
            'q', 'Q' => return,
            'd', 'D' => try deleteAll(writer),
            'm', 'M' => {
                moved = !moved;
                try placeStored(writer, 103, 2, if (moved) 40 else 24, 16, 14, 7);
            },
            'x', 'X' => {
                try deletePlacement(writer, 103, 3002);
                try deletePlacement(writer, 103, 4002);
            },
            'v', 'V' => {
                shifted = !shifted;
                try drawGrid(writer, 103, shifted);
            },
            's', 'S' => {
                try stress(writer, 103);
            },
            'l', 'L' => {
                try largeStoreTest(allocator, writer);
            },
            else => {},
        };
    }
}
