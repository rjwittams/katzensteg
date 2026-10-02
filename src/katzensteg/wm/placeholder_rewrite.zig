//! Stand-in for the kitty Unicode placeholder in a wrapped child's output.
//!
//! Some hosts refuse U+10EEEE in the text a plugin draws, because the host
//! draws placeholder images of its own. A plugin under the wrapper writes
//! U+10EEED instead and the relay turns it into the placeholder here. The two
//! differ in their last UTF-8 byte only, so the rewrite is in place, changes
//! no length and needs three bytes of state across reads. Nothing else in the
//! stream is interpreted.
const std = @import("std");

/// The codepoint a cooperating plugin writes, as the discovery record names it.
pub const standin_hex = "10EEED";

const prefix = [_]u8{ 0xf4, 0x8e, 0xbb };
const standin_last: u8 = 0xad;
const placeholder_last: u8 = 0xae;

pub const Rewrite = struct {
    matched: u2 = 0,

    pub fn apply(self: *Rewrite, bytes: []u8) void {
        for (bytes) |*byte| {
            if (self.matched == prefix.len) {
                if (byte.* == standin_last) byte.* = placeholder_last;
                self.matched = 0;
            }
            if (byte.* == prefix[self.matched]) {
                self.matched += 1;
            } else {
                self.matched = if (byte.* == prefix[0]) 1 else 0;
            }
        }
    }
};

test "stand-in becomes the placeholder and keeps its diacritics" {
    var rewrite: Rewrite = .{};
    var bytes = "a\u{10EEED}\u{305}\u{30D}b\u{10EEED}".*;
    rewrite.apply(&bytes);
    try std.testing.expectEqualStrings("a\u{10EEEE}\u{305}\u{30D}b\u{10EEEE}", &bytes);
}

test "rewrite survives every read split" {
    const source = "x\u{10EEED}\u{10EEED}y\u{10EEEC}\u{10EEED}";
    const expected = "x\u{10EEEE}\u{10EEEE}y\u{10EEEC}\u{10EEEE}";
    for (0..source.len + 1) |split| {
        var rewrite: Rewrite = .{};
        var bytes = source.*;
        rewrite.apply(bytes[0..split]);
        rewrite.apply(bytes[split..]);
        try std.testing.expectEqualStrings(expected, &bytes);
    }
}

test "neighbouring codepoints and a real placeholder pass unchanged" {
    var rewrite: Rewrite = .{};
    var bytes = "\u{10EEEE}\u{10EEEC}\u{10EE6D}\u{F4}\u{10FFFD}".*;
    const before = bytes;
    rewrite.apply(&bytes);
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}

test "a broken sequence does not carry a match into the next character" {
    var rewrite: Rewrite = .{};
    // The prefix, an unrelated byte, then a lone last byte: nothing matches.
    var bytes = [_]u8{ 0xf4, 0x8e, 0xbb, 'q', 0xad, 0xf4, 0xf4, 0x8e, 0xbb, 0xad };
    rewrite.apply(&bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xf4, 0x8e, 0xbb, 'q', 0xad, 0xf4, 0xf4, 0x8e, 0xbb, 0xae }, &bytes);
}
