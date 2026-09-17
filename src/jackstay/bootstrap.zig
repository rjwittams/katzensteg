//! Shared source setup only. Media and input retain independent owners afterward.
const input = @import("input.zig");
const media = @import("media.zig");
const c = input.c;

pub const Request = enum(u32) {
    observe = c.FT_BOOTSTRAP_INPUT_NONE,
    optional = c.FT_BOOTSTRAP_INPUT_OPTIONAL,
    required = c.FT_BOOTSTRAP_INPUT_REQUIRED,
};

pub const Connected = struct {
    client: ?input.Client,
    refusal: ?anyerror,
};

/// Bounded synchronous setup: call on a worker. Success returns the original
/// fd for media setup; after argument validation, failure consumes it as well.
pub fn connect(fd: *i32, request: Request) !Connected {
    try media.checkAbi();
    var handle: ?*c.ft_input_client = null;
    var status: c.ft_status = undefined;
    try input.check(c.ft_source_bootstrap_connect(fd, @intFromEnum(request), if (request == .observe) 0 else c.FT_INPUT_MODE_COOPERATIVE, &handle, &status));
    var refusal: ?anyerror = null;
    if (status != c.FT_STATUS_EMPTY) input.check(status) catch |err| {
        refusal = err;
    };
    return .{ .client = if (handle != null) .{ .handle = handle } else null, .refusal = refusal };
}

/// The host authorizes input separately from media, for this same source.
/// A returned server is a transport owner, not evidence of controller admission.
pub fn accept(fd: *i32, target: ?*input.Target) !?input.Server {
    try media.checkAbi();
    var handle: ?*c.ft_input_server = null;
    try input.check(c.ft_source_bootstrap_accept(fd, if (target) |t| t.handle else null, &handle));
    return if (handle != null) .{ .handle = handle } else null;
}

/// The publisher borrows this authority until its setup workers are joined.
/// The executor owns the target and continues pumping cleanup independently.
pub const Authority = struct {
    target: *input.Target,
    servers: *input.Servers,
};
