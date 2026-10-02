//! A producer's frame as a reference a client can hand to an application that
//! draws the image itself, instead of the host writing it to the terminal.
//!
//! In placeholder presentation each frame is one external upload: a file path
//! or a shared-memory name, with the pixel size in the command. This reads
//! that reference out of the producer's upload command. No pixels are touched.
const std = @import("std");

pub const max_name = 256;

pub const Medium = enum { file, shm };

pub const FrameRef = struct {
    medium: Medium,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    width: u32,
    height: u32,

    pub fn name(self: *const FrameRef) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The reference in one kitty upload command (`ESC _ G ... ; payload ESC \`),
/// or null when it is not a whole-image RGBA upload from a file or
/// shared-memory object: such a command cannot be handed on by name.
pub fn parseUpload(command: []const u8) ?FrameRef {
    if (!std.mem.startsWith(u8, command, "\x1b_G") or !std.mem.endsWith(u8, command, "\x1b\\")) return null;
    const body = command[3 .. command.len - 2];
    const separator = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    var action: u8 = 't';
    var medium: ?Medium = null;
    var format: u32 = 32;
    var width: u32 = 0;
    var height: u32 = 0;
    var data_size: ?u64 = null;
    var offset: u64 = 0;
    var fields = std.mem.splitScalar(u8, body[0..separator], ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') continue;
        const value = field[2..];
        switch (field[0]) {
            'a' => action = value[0],
            't' => medium = switch (value[0]) {
                'f' => .file,
                's' => .shm,
                else => return null,
            },
            'f' => format = std.fmt.parseInt(u32, value, 10) catch return null,
            's' => width = std.fmt.parseInt(u32, value, 10) catch return null,
            'v' => height = std.fmt.parseInt(u32, value, 10) catch return null,
            'S' => data_size = std.fmt.parseInt(u64, value, 10) catch return null,
            'O' => offset = std.fmt.parseInt(u64, value, 10) catch return null,
            else => {},
        }
    }
    if (action != 't' or format != 32 or width == 0 or height == 0) return null;
    // A region of a larger file is not a whole image under one name. A size
    // that is exactly the image (shared memory states it) changes nothing.
    if (offset != 0) return null;
    if (data_size) |bytes| if (bytes != @as(u64, width) * height * 4) return null;
    var frame = FrameRef{ .medium = medium orelse return null, .width = width, .height = height };
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(body[separator + 1 ..]) catch return null;
    if (size == 0 or size > frame.name_buf.len) return null;
    decoder.decode(frame.name_buf[0..size], body[separator + 1 ..]) catch return null;
    frame.name_len = size;
    return frame;
}

test "a whole-file or shared-memory RGBA upload yields its name and size" {
    const file = parseUpload("\x1b_Gq=2,a=t,t=f,f=32,s=640,v=480,i=100002;L3RtcC9rL3MyL2ZyYW1lLnJnYmEuMw==\x1b\\").?;
    try std.testing.expectEqual(Medium.file, file.medium);
    try std.testing.expectEqualStrings("/tmp/k/s2/frame.rgba.3", file.name());
    try std.testing.expectEqual(@as(u32, 640), file.width);
    try std.testing.expectEqual(@as(u32, 480), file.height);
    const shm = parseUpload("\x1b_Gq=2,a=t,t=s,f=32,s=640,v=480,i=77,S=1228800;L2tzLXRlc3Q=\x1b\\").?;
    try std.testing.expectEqual(Medium.shm, shm.medium);
    try std.testing.expectEqualStrings("/ks-test", shm.name());
}

test "placements, inline pixels, file regions and malformed commands are not frames" {
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=p,U=1,i=77,c=2,r=2,q=2;\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=d,f=32,s=1,v=1,i=77;AAAA\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=32,s=4,v=4,S=64,O=128,i=77;L3RtcC9m\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=32,s=4,v=4,S=32,i=77;L3RtcC9m\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=24,s=4,v=4,i=77;L3RtcC9m\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=32,i=77;L3RtcC9m\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=32,s=4,v=4,i=77;not base64!\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b_Ga=t,t=f,f=32,s=4,v=4,i=77;\x1b\\"));
    try std.testing.expectEqual(@as(?FrameRef, null), parseUpload("\x1b[2J"));
}
