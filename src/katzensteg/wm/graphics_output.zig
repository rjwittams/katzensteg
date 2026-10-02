const std = @import("std");
const BatchGroupsView = @import("../terminal_batch_applier.zig").BatchGroupsView;

// Small writes reduce interference with another application's terminal output.
// They do not make concurrent terminal writers atomic.
pub fn apply(allocator: std.mem.Allocator, writer: anytype, image_id: u32, groups: BatchGroupsView) !void {
    return applyAs(allocator, writer, image_id, image_id, groups);
}

/// As `apply`, for a batch a producer wrote under `image_id` that the terminal
/// is to receive under `terminal_id`. The producer keeps the id it attached
/// with; when the wrapped application owns the image on screen, the host
/// renames the batch on its way out.
pub fn applyAs(allocator: std.mem.Allocator, writer: anytype, image_id: u32, terminal_id: u32, groups: BatchGroupsView) !void {
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    inline for (.{ groups.deletes, groups.uploads, groups.placements, groups.after }) |group| {
        for (group) |chunk| try frame.appendSlice(allocator, chunk);
    }
    var offset: usize = 0;
    // Validate the entire batch before emitting any of it.
    while (offset < frame.items.len) offset += try sequenceLength(frame.items[offset..], image_id);
    if (terminal_id != image_id) {
        var renamed = std.ArrayList(u8).empty;
        errdefer renamed.deinit(allocator);
        offset = 0;
        while (offset < frame.items.len) {
            const n = try sequenceLength(frame.items[offset..], image_id);
            try appendRenamed(allocator, &renamed, frame.items[offset .. offset + n], terminal_id);
            offset += n;
        }
        frame.deinit(allocator);
        frame = renamed;
    }
    const image_id_out = terminal_id;
    if (frame.items.len <= 512) {
        if (frame.items.len != 0) try writer.writeAll(frame.items);
    } else {
        offset = 0;
        while (offset < frame.items.len) {
            const n = try sequenceLength(frame.items[offset..], image_id_out);
            try writer.writeAll(frame.items[offset .. offset + n]);
            offset += n;
        }
    }
}

// One validated command with its `i=` field replaced. Every command in a
// batch names the producer's id exactly once; `sequenceLength` checked that.
fn appendRenamed(allocator: std.mem.Allocator, out: *std.ArrayList(u8), sequence: []const u8, terminal_id: u32) !void {
    // `sequenceLength` refuses a command with no `;` (InvalidGraphics), and
    // `applyAs` validates the whole batch before renaming any of it.
    const separator = std.mem.indexOfScalar(u8, sequence, ';').?;
    try out.appendSlice(allocator, "\x1b_G");
    var fields = std.mem.splitScalar(u8, sequence[3..separator], ',');
    var first = true;
    while (fields.next()) |field| {
        if (!first) try out.append(allocator, ',');
        first = false;
        if (std.mem.startsWith(u8, field, "i=")) {
            var digits: [16]u8 = undefined;
            try out.appendSlice(allocator, try std.fmt.bufPrint(&digits, "i={d}", .{terminal_id}));
        } else try out.appendSlice(allocator, field);
    }
    try out.appendSlice(allocator, sequence[separator..]);
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

test "a batch is renamed to the terminal's image id, payload and other fields intact" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try applyAs(std.testing.allocator, &output.writer, 100003, 9939225, .{
        .deletes = &.{},
        .uploads = &.{"\x1b_Ga=t,t=f,i=100003,q=2,f=32,s=1,v=1;L3RtcC9m\x1b\\"},
        .placements = &.{"\x1b_Ga=p,U=1,i=100003,c=2,r=2,q=2;\x1b\\"},
        .after = &.{},
    });
    try std.testing.expectEqualStrings(
        "\x1b_Ga=t,t=f,i=9939225,q=2,f=32,s=1,v=1;L3RtcC9m\x1b\\" ++ "\x1b_Ga=p,U=1,i=9939225,c=2,r=2,q=2;\x1b\\",
        output.written(),
    );
    // A batch that does not carry the producer's id is still refused.
    try std.testing.expectError(error.UnownedGraphics, applyAs(std.testing.allocator, &output.writer, 100003, 9939225, .{
        .deletes = &.{},
        .uploads = &.{"\x1b_Ga=t,t=f,i=9939225,q=2;L3RtcC9m\x1b\\"},
        .placements = &.{},
        .after = &.{},
    }));
}
