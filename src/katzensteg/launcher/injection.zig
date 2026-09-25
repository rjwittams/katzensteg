//! How the launcher gets Katzensteg's SDL adapter into the target process.
//!
//! - `preload`: the dynamic loader loads the adapter before the application
//!   (`LD_PRELOAD` on Linux, `DYLD_INSERT_LIBRARIES` on macOS); the adapter
//!   exports SDL's symbols and finds the real ones with dlsym.
//! - `dynapi`: SDL's dynamic API loads the adapter on its first call
//!   (`SDL_DYNAMIC_API` for SDL2, `SDL3_DYNAMIC_API` for SDL3); the adapter
//!   fills SDL's jump table from the loading SDL and substitutes wrappers.
//!   Nothing is injected into the process, so it is the Windows mechanism.
//!
//! A profile selects one with `injection`; `auto` (the default) is `dynapi`
//! on Windows and `preload` on Linux and macOS. `KATZENSTEG_INJECTION`
//! overrides the profile for one launch.
const std = @import("std");
const builtin = @import("builtin");

pub const Injection = enum {
    auto,
    preload,
    dynapi,

    pub fn parse(value: []const u8) ?Injection {
        return std.meta.stringToEnum(Injection, value);
    }
};

pub const Mechanism = enum { preload, dynapi };

pub const Os = enum {
    linux,
    macos,
    windows,
    other,

    pub fn current() Os {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .other,
        };
    }
};

pub const SdlApi = enum {
    sdl2,
    sdl3,

    pub fn parse(value: []const u8) ?SdlApi {
        return std.meta.stringToEnum(SdlApi, value);
    }
};

/// The adapter libraries a profile offers, already selected for the
/// platform. Either may be missing where it is not built.
pub const SdlAdapter = struct {
    api: SdlApi,
    preload: ?[]const u8 = null,
    dynapi: ?[]const u8 = null,
};

pub fn mechanismFor(requested: Injection, os: Os) Mechanism {
    return switch (requested) {
        .preload => .preload,
        .dynapi => .dynapi,
        .auto => if (os == .windows) .dynapi else .preload,
    };
}

pub const Setting = struct {
    mechanism: Mechanism,
    name: []const u8,
    /// The profile's library path, before `{repo}`/`$HOME` expansion.
    library: []const u8,
};

pub const ResolveError = error{
    /// Windows has no preload mechanism; the loader is not asked to inject.
    PreloadUnavailable,
    /// The profile offers no library for the selected mechanism here.
    NoAdapterLibrary,
};

/// The environment variable that loads `adapter` with `requested` on `os`.
pub fn resolve(adapter: SdlAdapter, requested: Injection, os: Os) ResolveError!Setting {
    const mechanism = mechanismFor(requested, os);
    return switch (mechanism) {
        .preload => .{
            .mechanism = .preload,
            .name = switch (os) {
                .linux, .other => "LD_PRELOAD",
                .macos => "DYLD_INSERT_LIBRARIES",
                .windows => return error.PreloadUnavailable,
            },
            .library = adapter.preload orelse return error.NoAdapterLibrary,
        },
        .dynapi => .{
            .mechanism = .dynapi,
            .name = switch (adapter.api) {
                .sdl2 => "SDL_DYNAMIC_API",
                .sdl3 => "SDL3_DYNAMIC_API",
            },
            .library = adapter.dynapi orelse return error.NoAdapterLibrary,
        },
    };
}

const sdl2_adapter = SdlAdapter{ .api = .sdl2, .preload = "{repo}/libks.so", .dynapi = "{repo}/ks-dynapi" };

test "auto keeps preload on Linux and macOS and selects the dynamic API on Windows" {
    try std.testing.expectEqual(Mechanism.preload, mechanismFor(.auto, .linux));
    try std.testing.expectEqual(Mechanism.preload, mechanismFor(.auto, .macos));
    try std.testing.expectEqual(Mechanism.dynapi, mechanismFor(.auto, .windows));
    try std.testing.expectEqual(Mechanism.dynapi, mechanismFor(.dynapi, .linux));
    try std.testing.expectEqual(Mechanism.preload, mechanismFor(.preload, .windows));
}

test "preload uses the platform loader variable" {
    const linux = try resolve(sdl2_adapter, .auto, .linux);
    try std.testing.expectEqualStrings("LD_PRELOAD", linux.name);
    try std.testing.expectEqualStrings("{repo}/libks.so", linux.library);
    const macos = try resolve(sdl2_adapter, .preload, .macos);
    try std.testing.expectEqualStrings("DYLD_INSERT_LIBRARIES", macos.name);
    try std.testing.expectError(error.PreloadUnavailable, resolve(sdl2_adapter, .preload, .windows));
}

test "the dynamic API variable follows the SDL major version" {
    const sdl2 = try resolve(sdl2_adapter, .auto, .windows);
    try std.testing.expectEqual(Mechanism.dynapi, sdl2.mechanism);
    try std.testing.expectEqualStrings("SDL_DYNAMIC_API", sdl2.name);
    try std.testing.expectEqualStrings("{repo}/ks-dynapi", sdl2.library);
    const sdl3 = try resolve(.{ .api = .sdl3, .dynapi = "x" }, .dynapi, .linux);
    try std.testing.expectEqualStrings("SDL3_DYNAMIC_API", sdl3.name);
}

test "a mechanism without a library for this platform is an error" {
    try std.testing.expectError(error.NoAdapterLibrary, resolve(.{ .api = .sdl2, .preload = "x" }, .dynapi, .linux));
    try std.testing.expectError(error.NoAdapterLibrary, resolve(.{ .api = .sdl2, .dynapi = "x" }, .auto, .linux));
}

test "injection names parse" {
    try std.testing.expectEqual(Injection.dynapi, Injection.parse("dynapi").?);
    try std.testing.expectEqual(@as(?Injection, null), Injection.parse("inject"));
}
