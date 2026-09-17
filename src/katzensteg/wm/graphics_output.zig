const std = @import("std");
const BatchGroupsView = @import("../terminal_batch_applier.zig").BatchGroupsView;

// Small writes reduce interference with another application's terminal output.
// They do not make concurrent terminal writers atomic.
pub fn apply(allocator: std.mem.Allocator, writer: anytype, image_id: u32, groups: BatchGroupsView) !void {
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    inline for (.{ groups.deletes, groups.uploads, groups.placements, groups.after }) |group| {
        for (group) |chunk| try frame.appendSlice(allocator, chunk);
    }
    var offset: usize = 0;
    // Validate the entire batch before emitting any of it.
    while (offset < frame.items.len) offset += try sequenceLength(frame.items[offset..], image_id);
    if (frame.items.len <= 512) {
        if (frame.items.len != 0) try writer.writeAll(frame.items);
    } else {
        offset = 0;
        while (offset < frame.items.len) {
            const n = try sequenceLength(frame.items[offset..], image_id);
            try writer.writeAll(frame.items[offset .. offset + n]);
            offset += n;
        }
    }
}

fn sequenceLength(bytes: []const u8, image_id: u32) !usize {
    if (!std.mem.startsWith(u8, bytes, "\x1b_G")) return error.NonGraphicsOutput;
    const end = std.mem.indexOf(u8, bytes, "\x1b\\") orelse return error.IncompleteGraphics;
    if (end + 2 > 512) return error.GraphicsCommandTooLarge;
    const separator = std.mem.indexOfScalar(u8, bytes[3..end], ';') orelse return error.InvalidGraphics;
    const header = bytes[3 .. 3 + separator];
    var fields = std.mem.splitScalar(u8, header, ',');
    var action: []const u8 = "";
    var transmission: []const u8 = "";
    var quiet = false;
    var own_id = false;
    var virtual = false;
    var delete_image = false;
    while (fields.next()) |field| {
        if (std.mem.startsWith(u8, field, "a=")) action = field[2..];
        if (std.mem.startsWith(u8, field, "t=")) transmission = field[2..];
        if (std.mem.eql(u8, field, "q=2")) quiet = true;
        if (std.mem.eql(u8, field, "U=1")) virtual = true;
        if (std.mem.eql(u8, field, "d=I")) delete_image = true;
        if (std.mem.startsWith(u8, field, "i=")) own_id = (try std.fmt.parseInt(u32, field[2..], 10)) == image_id;
    }
    if (!quiet or !own_id) return error.UnownedGraphics;
    if (std.mem.eql(u8, action, "t")) {
        if (!std.mem.eql(u8, transmission, "f") and !std.mem.eql(u8, transmission, "s")) return error.ExternalUploadRequired;
    } else if (std.mem.eql(u8, action, "p")) {
        if (!virtual) return error.VirtualPlacementRequired;
    } else if (std.mem.eql(u8, action, "d")) {
        if (!delete_image) return error.ImageDeleteRequired;
    } else return error.UnsupportedGraphics;
    return end + 2;
}

pub fn delete(writer: anytype, image_id: u32) !void {
    var bytes: [80]u8 = undefined;
    try writer.writeAll(try std.fmt.bufPrint(&bytes, "\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{image_id}));
}

test "graphics-only output coalesces small frames and rejects text and inline pixels" {
    const Recorder = struct {
        writes: usize = 0,
        fn writeAll(self: *@This(), _: []const u8) !void {
            self.writes += 1;
        }
    };
    var writer = Recorder{};
    try apply(std.testing.allocator, &writer, 77, .{
        .deletes = &.{},
        .uploads = &.{"\x1b_Ga=t,t=f,i=77,q=2;L3RtcC9m\x1b\\"},
        .placements = &.{"\x1b_Ga=p,U=1,i=77,c=2,r=2,q=2;\x1b\\"},
        .after = &.{},
    });
    try std.testing.expectEqual(@as(usize, 1), writer.writes);
    try std.testing.expectError(error.NonGraphicsOutput, sequenceLength("\x1b[2J", 77));
    try std.testing.expectError(error.ExternalUploadRequired, sequenceLength("\x1b_Ga=t,t=d,i=77,q=2;AAAA\x1b\\", 77));
    try std.testing.expectError(error.UnownedGraphics, sequenceLength("\x1b_Ga=d,d=I,i=78,q=2;\x1b\\", 77));
}

test "headless graphics accepts a bounded owned SHM upload and virtual placement" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try apply(std.testing.allocator, &output.writer, 77, .{
        .deletes = &.{},
        .uploads = &.{"\x1b_Ga=t,t=s,i=77,q=2,f=32,s=1,v=1;L2tzLXRlc3Q=\x1b\\"},
        .placements = &.{"\x1b_Ga=p,U=1,i=77,c=2,r=2,q=2;\x1b\\"},
        .after = &.{},
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "t=s") != null);
}
