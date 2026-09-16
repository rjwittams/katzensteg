//! Streaming insertion boundaries, not a screen model. Child bytes are forwarded
//! unchanged; incomplete strings and kitty uploads only defer host graphics.
const std = @import("std");

pub const Boundary = struct {
    state: enum { ground, escape, escape_intermediate, csi, string, string_escape } = .ground,
    string_kind: enum { osc, apc, other } = .other,
    utf8_left: u3 = 0,
    header: [256]u8 = undefined,
    header_len: usize = 0,
    header_overflow: bool = false,
    header_done: bool = false,
    kitty_chunks: bool = false,
    cleared: bool = false,

    pub fn safe(self: *const Boundary) bool {
        return self.state == .ground and self.utf8_left == 0 and !self.kitty_chunks;
    }
    pub fn feed(self: *Boundary, bytes: []const u8) void {
        for (bytes) |byte| self.next(byte);
    }
    fn collect(self: *Boundary, byte: u8) void {
        if (self.header_done) return;
        if (self.header_len == self.header.len) {
            self.header_overflow = true;
        } else {
            self.header[self.header_len] = byte;
            self.header_len += 1;
        }
    }
    fn start(self: *Boundary, state: @TypeOf(@as(Boundary, .{}).state)) void {
        self.state = state;
        self.header_len = 0;
        self.header_overflow = false;
        self.header_done = false;
    }
    fn endString(self: *Boundary) void {
        if (self.string_kind == .apc and self.header_len > 0 and self.header[0] == 'G') {
            // Unknown/oversized headers cannot establish a safe insertion point.
            if (self.header_overflow) {
                self.kitty_chunks = true;
            } else {
                var more = false;
                var fields = std.mem.splitScalar(u8, self.header[1..self.header_len], ',');
                while (fields.next()) |field| {
                    if (std.mem.eql(u8, field, "m=1")) more = true;
                }
                self.kitty_chunks = more;
            }
        }
        self.state = .ground;
    }
    fn next(self: *Boundary, byte: u8) void {
        if (self.utf8_left != 0) {
            if (byte & 0xc0 == 0x80) {
                self.utf8_left -= 1;
                return;
            }
            self.utf8_left = 0; // malformed UTF-8: process this byte normally
        }
        // UTF-8 continuation bytes are never 8-bit C1 introducers/terminators,
        // including in OSC titles and other string payloads.
        if (byte >= 0xc2 and byte <= 0xf4) {
            self.utf8_left = if (byte <= 0xdf) 1 else if (byte <= 0xef) 2 else 3;
        }
        // CAN/SUB cancel escape syntax, but do not finish a multi-APC upload.
        if (byte == 0x18 or byte == 0x1a) {
            self.state = .ground;
            return;
        }
        if (self.state == .string_escape) {
            if (byte == '\\') {
                self.endString();
                return;
            }
            // ESC ended the old string; this byte belongs to a new escape.
            self.state = .escape;
        }
        if (self.state == .string) {
            if (byte == 0x1b) self.state = .string_escape else if (byte == 0x9c or (byte == 7 and self.string_kind == .osc)) self.endString() else if (self.string_kind == .apc) {
                if (byte == ';') self.header_done = true else self.collect(byte);
            }
            return;
        }
        if (byte == 0x1b) {
            self.start(.escape);
            return;
        }
        // Raw C1 controls can also replace an unfinished CSI/escape.
        switch (byte) {
            0x9b => {
                self.start(.csi);
                return;
            },
            0x90, 0x98, 0x9d, 0x9e, 0x9f => {
                self.start(.string);
                self.string_kind = if (byte == 0x9d) .osc else if (byte == 0x9f) .apc else .other;
                return;
            },
            0x9c => {
                self.state = .ground;
                return;
            },
            else => {},
        }
        switch (self.state) {
            .ground => {},
            .escape => switch (byte) {
                '[' => self.start(.csi),
                ']', 'P', '_', '^', 'X' => {
                    self.start(.string);
                    self.string_kind = if (byte == ']') .osc else if (byte == '_') .apc else .other;
                },
                0x20...0x2f => self.state = .escape_intermediate,
                else => if (byte >= 0x30 and byte <= 0x7e) {
                    self.state = .ground;
                }, // C0 does not end the escape
            },
            .escape_intermediate => if (byte >= 0x30 and byte <= 0x7e) {
                self.state = .ground;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    const params = self.header[0..self.header_len];
                    if (byte == 'J' and !self.header_overflow and (std.mem.eql(u8, params, "2") or std.mem.eql(u8, params, "3"))) self.cleared = true;
                    self.state = .ground;
                } else if (byte >= 0x20 and byte <= 0x3f) self.collect(byte);
            },
            .string, .string_escape => unreachable,
        }
    }
};

test "boundaries survive every read split without treating C0 as CSI termination" {
    const units = [_][]const u8{ "\xf0\x9f\x90\x88", "\x1b[2;\x073H", "\x1b(B", "\x1b#8", "\x1b]title\x07", "\x1b]title ✜\x07", "\x1bPabc\x07def\x1b\\", "\x1b_Gm=0;AAA\x1b\\" };
    for (units) |unit| {
        var parser = Boundary{};
        for (unit, 0..) |byte, i| {
            parser.feed(&.{byte});
            try std.testing.expectEqual(i == unit.len - 1, parser.safe());
        }
    }
}

test "kitty upload owns graphics insertion across complete APC commands" {
    var parser = Boundary{};
    parser.feed("\x1b_Gm=1;AAAA\x1b\\text\x1b[2J");
    try std.testing.expect(!parser.safe());
    try std.testing.expect(parser.cleared);
    parser.feed("\x1b_Gm=1;BBBB\x1b\\");
    try std.testing.expect(!parser.safe());
    parser.feed("\x1b_Gm=0;CCCC\x1b\\");
    try std.testing.expect(parser.safe());
}

test "unbounded string payload uses bounded state and defers graphics" {
    var parser = Boundary{};
    parser.feed("\x1b_Gm=0;");
    for (0..10000) |_| parser.feed("AAAA");
    try std.testing.expect(!parser.safe());
    try std.testing.expect(parser.header_len < 256);
    parser.feed("\x1b\\");
    try std.testing.expect(parser.safe());
}

test "interrupted kitty final chunk cannot release upload ownership" {
    var parser = Boundary{};
    parser.feed("\x1b_Gm=1;AAAA\x1b\\\x1b_Gm=0;BBBB\x1b[31m");
    try std.testing.expect(!parser.safe());
    parser.feed("\x1b_Gm=0;CCCC\x1b\\");
    try std.testing.expect(parser.safe());
}

test "C1 strings can interrupt CSI and still defer injection" {
    var parser = Boundary{};
    parser.feed("\x1b[1;\x9dtitle");
    try std.testing.expect(!parser.safe());
    parser.feed("\x9c");
    try std.testing.expect(parser.safe());
}
