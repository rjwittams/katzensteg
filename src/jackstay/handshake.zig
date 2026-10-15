//! Track handshake v3. Media and input retain independent owners afterward.
const std = @import("std");
const input = @import("input.zig");
const media = @import("media.zig");
const c = media.c;

const video_track: u64 = 1;
const input_track: u64 = 2;

pub const Request = enum { observe, optional, required };

pub const Connected = struct {
    /// Media setup consumes this; close releases it otherwise.
    local: media.Local,
    host_time: bool,
    client: ?input.Client,
    refusal: ?anyerror,

    pub fn close(self: *Connected) void {
        c.ft_local_connection_destroy(&self.local);
    }
};

/// Bounded synchronous setup: call on a worker. Consumes fd after argument
/// validation. Selects video, plus input unless observing.
pub fn connect(fd: *i32, request: Request) !Connected {
    try media.checkAbi();
    var local = try media.adopt(fd);
    defer c.ft_local_connection_destroy(&local);
    var offer: ?*c.ft_handshake_offer = null;
    try input.check(c.ft_handshake_connect_local(&local, &offer));
    defer c.ft_handshake_offer_destroy(&offer);
    var label: [*c]const u8 = null;
    var clock: u32 = undefined;
    var tracks: [*c]const c.ft_track_offer = null;
    var count: usize = 0;
    try input.check(c.ft_handshake_offer_describe(offer, &label, &clock, &tracks, &count));
    var selections: [2]c.ft_track_selection = undefined;
    var selected: usize = 0;
    var video = false;
    var input_offered = false;
    for (tracks[0..count]) |track| {
        const kind = std.mem.span(track.kind);
        if (!video and std.mem.eql(u8, kind, c.FT_TRACK_KIND_VIDEO)) {
            video = true;
            selections[selected] = .{ .id = track.id, .required = 1, .write = 0 };
            selected += 1;
        } else if (request != .observe and !input_offered and std.mem.eql(u8, kind, c.FT_TRACK_KIND_INPUT)) {
            input_offered = true;
            selections[selected] = .{ .id = track.id, .required = @intFromBool(request == .required), .write = 1 };
            selected += 1;
        }
    }
    if (!video) return error.VideoNotOffered;
    if (request == .required and !input_offered) return error.InputNotOffered;
    var admissions: [2]c.ft_track_admission = undefined;
    var connected = Connected{ .local = null, .host_time = clock == c.FT_CLOCK_DOMAIN_HOST_TIME, .client = null, .refusal = if (request != .observe and !input_offered) error.InputNotOffered else null };
    var handle: ?*c.ft_input_client = null;
    // The C contract writes input status on every successful return.
    var status: c.ft_status = undefined;
    var affordances: ?*c.ft_affordances_host = null;
    try input.check(c.ft_handshake_select(&offer, &selections, selected, if (input_offered) c.FT_INPUT_MODE_COOPERATIVE else 0, &admissions, &connected.local, &handle, &status, &affordances));
    for (admissions[0..selected]) |admission| if (admission.result != c.FT_TRACK_ADMITTED) {
        connected.refusal = error.InputRefused;
    };
    if (status != c.FT_STATUS_EMPTY) input.check(status) catch |err| {
        connected.refusal = err;
    };
    if (handle != null) connected.client = .{ .handle = handle };
    return connected;
}

pub const Accepted = struct {
    /// Serve CPU setup on this when video was admitted; close it otherwise.
    local: media.Local,
    video: bool,
    input: ?input.Server,

    pub fn close(self: *Accepted) void {
        c.ft_local_connection_destroy(&self.local);
    }
};

/// Offers video, and input only with a target, in host time. A returned server
/// is a transport owner, not evidence of controller admission.
pub fn accept(fd: *i32, label: [*:0]const u8, target: ?*input.Target) !Accepted {
    try media.checkAbi();
    var accepted = Accepted{ .local = try media.adopt(fd), .video = false, .input = null };
    errdefer accepted.close();
    const tracks = [_]c.ft_track_offer{
        std.mem.zeroInit(c.ft_track_offer, .{ .id = video_track, .kind = c.FT_TRACK_KIND_VIDEO, .label = "video", .direction = c.FT_TRACK_FROM_SOURCE }),
        std.mem.zeroInit(c.ft_track_offer, .{ .id = input_track, .kind = c.FT_TRACK_KIND_INPUT, .label = "input", .direction = c.FT_TRACK_TO_SOURCE }),
    };
    var admissions: [tracks.len]c.ft_track_admission = undefined;
    var count: usize = 0;
    var server: ?*c.ft_input_server = null;
    var affordances: ?*c.ft_affordances_producer = null;
    try input.check(c.ft_handshake_accept_local(&accepted.local, label, c.FT_CLOCK_DOMAIN_HOST_TIME, &tracks, if (target != null) 2 else 1, if (target) |t| t.handle else null, &admissions, &count, &server, &affordances));
    for (admissions[0..count]) |admission| {
        if (admission.id == video_track and admission.result == c.FT_TRACK_ADMITTED) accepted.video = true;
    }
    if (server != null) accepted.input = .{ .handle = server };
    return accepted;
}

/// The publisher borrows this authority until its setup workers are joined.
/// The executor owns the target and continues pumping cleanup independently.
pub const Authority = struct {
    target: *input.Target,
    servers: *input.Servers,
};
