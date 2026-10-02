//! What a wrapped application's own kitty graphics commands mean to the host.
//!
//! An application that draws images itself (Claude Code's `Image`) picks the
//! image id and writes the placeholder cells. A plugin points such an image at
//! a session's claim file; the application then sends one file transmission
//! naming that path, and the id in it is the one the host should upload the
//! session's frames to. Later commands on that id say when to restore the
//! frame (the application sent its own pixels again) or let go (it deleted
//! the image). Pure classification: no state and no output here.
const std = @import("std");

/// Longest claim path taken. Host session directories are far shorter.
pub const max_path = 256;

pub const Event = union(enum) {
    none,
    /// A file transmission: `path` is what the application told the terminal to read.
    file: struct { id: u32, path: []const u8 },
    /// Pixels sent some other way, or a chunked transmission's first chunk.
    transmit: u32,
    /// The image, or its placements, were deleted by id.
    delete: u32,
    /// A delete that names no id: everything on screen may be gone.
    delete_all,
};

/// `header` is the control data after `G`; `payload` what followed the `;`
/// (possibly cut short, in which case a path is not trusted). `buffer` holds
/// the decoded path of a `file` event.
pub fn classify(header: []const u8, payload: []const u8, payload_truncated: bool, buffer: *[max_path]u8) Event {
    var action: u8 = 't';
    var medium: u8 = 'd';
    var delete: u8 = 'a';
    var id: u32 = 0;
    var fields = std.mem.splitScalar(u8, header, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') continue;
        const value = field[2..];
        switch (field[0]) {
            'a' => action = value[0],
            't' => medium = value[0],
            'd' => delete = value[0],
            'i' => id = std.fmt.parseInt(u32, value, 10) catch 0,
            else => {},
        }
    }
    switch (action) {
        't', 'T' => {
            // Continuation chunks carry no id; only a first command names one.
            if (id == 0) return .none;
            if (medium == 'f' and !payload_truncated) {
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(payload) catch return .{ .transmit = id };
                if (size == 0 or size > buffer.len) return .{ .transmit = id };
                decoder.decode(buffer[0..size], payload) catch return .{ .transmit = id };
                return .{ .file = .{ .id = id, .path = buffer[0..size] } };
            }
            return .{ .transmit = id };
        },
        'd' => return switch (delete) {
            'i', 'I' => if (id == 0) .none else .{ .delete = id },
            'a', 'A' => .delete_all,
            else => .none,
        },
        else => return .none,
    }
}

test "a file transmission yields its id and path" {
    var buffer: [max_path]u8 = undefined;
    var encoded: [128]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, "/tmp/katzensteg-wm-501/habc/s3/claim.rgba");
    const event = classify("a=T,U=1,q=2,f=32,s=1,v=1,i=9939225,c=40,r=10,t=f", payload, false, &buffer);
    try std.testing.expectEqual(@as(u32, 9939225), event.file.id);
    try std.testing.expectEqualStrings("/tmp/katzensteg-wm-501/habc/s3/claim.rgba", event.file.path);
}

test "direct pixels, continuation chunks and a cut payload are not claims" {
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqual(Event{ .transmit = 12 }, classify("a=T,U=1,q=2,f=32,s=96,v=48,i=12,c=40,r=10,m=1", "AAAA", false, &buffer));
    try std.testing.expectEqual(Event.none, classify("m=1,q=2", "AAAA", false, &buffer));
    try std.testing.expectEqual(Event{ .transmit = 12 }, classify("a=t,t=f,i=12", "L3RtcC94", true, &buffer));
    try std.testing.expectEqual(Event{ .transmit = 12 }, classify("a=t,t=f,i=12", "not base64!", false, &buffer));
    try std.testing.expectEqual(Event{ .transmit = 12 }, classify("a=t,t=s,i=12", "L2tzMQ==", false, &buffer));
}

test "deletes by id release, deletes without one restore, the rest is ignored" {
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqual(Event{ .delete = 7 }, classify("a=d,d=I,i=7,q=2", "", false, &buffer));
    try std.testing.expectEqual(Event{ .delete = 7 }, classify("a=d,d=i,i=7", "", false, &buffer));
    try std.testing.expectEqual(Event.delete_all, classify("a=d", "", false, &buffer));
    try std.testing.expectEqual(Event.delete_all, classify("a=d,d=A", "", false, &buffer));
    try std.testing.expectEqual(Event.none, classify("a=d,d=c", "", false, &buffer));
    try std.testing.expectEqual(Event.none, classify("a=q,i=31,s=1,v=1,t=d,f=24", "AAAA", false, &buffer));
    try std.testing.expectEqual(Event.none, classify("a=p,U=1,i=7,c=4,r=2", "", false, &buffer));
}
