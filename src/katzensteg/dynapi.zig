//! SDL_DYNAMIC_API injection. SDL2 and SDL3 read `SDL_DYNAMIC_API` /
//! `SDL3_DYNAMIC_API` on their first call, load the named library and call
//! its `SDL_DYNAPI_entry(apiver, table, tablesize)` with their own jump
//! table; a zero return makes every application call go through that table
//! (SDL2 2.32.10 src/dynapi/SDL_dynapi.c:441-502; SDL3 3.4.16
//! src/dynapi/SDL_dynapi.c:509-567).
//!
//! Katzensteg does not supply an SDL of its own. `install` asks the SDL that
//! loaded it to fill the table (its exported `SDL_DYNAPI_entry` only runs
//! `initialize_jumptable`, which checks the version and size, writes the
//! `_REAL` functions and copies them out; SDL2 SDL_dynapi.c:306-356), keeps
//! that copy as the real functions, and then replaces the wrapped slots.
//!
//! This runs while SDL holds the spinlock of `SDL_InitDynamicAPI`, before its
//! table is initialized (SDL2 SDL_dynapi.c:504-535): calling any exported SDL
//! function here would re-enter that lock. Only the loading SDL's entry
//! point, which does not take it, is called.
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.dynapi);

pub const EntryFn = *const fn (apiver: u32, table: ?*anyopaque, tablesize: u32) callconv(.c) i32;

/// A jump-table slot and the Katzensteg function that replaces it.
pub const Wrapper = extern struct {
    slot: u32,
    function: *const anyopaque,
};

pub const Slot = ?*const anyopaque;

pub const InstallError = error{
    /// SDL's API version is not the one these slot numbers describe.
    VersionMismatch,
    /// The loading SDL refused to fill the table.
    RealEntryFailed,
    OutOfMemory,
};

pub const Installed = struct {
    /// The loading SDL's own functions, indexed by slot.
    real: []Slot,
    wrapped: usize,
};

/// Fills `table` from `real_entry`, keeps a copy as the real functions, then
/// writes each wrapper whose slot the table has. Slots beyond `tablesize`
/// belong to a newer SDL than the running one and are left alone.
pub fn install(
    allocator: std.mem.Allocator,
    expected_apiver: u32,
    apiver: u32,
    table: [*]Slot,
    tablesize: u32,
    real_entry: EntryFn,
    wrappers: []const Wrapper,
) InstallError!Installed {
    if (apiver != expected_apiver) return error.VersionMismatch;
    const count = tablesize / @sizeOf(Slot);
    const real = try allocator.alloc(Slot, count);
    errdefer allocator.free(real);
    @memset(real, null);
    if (real_entry(apiver, @ptrCast(real.ptr), @intCast(count * @sizeOf(Slot))) < 0) return error.RealEntryFailed;
    @memcpy(table[0..count], real);
    var wrapped: usize = 0;
    for (wrappers) |wrapper| {
        if (wrapper.slot >= count) continue;
        table[wrapper.slot] = wrapper.function;
        wrapped += 1;
    }
    return .{ .real = real, .wrapped = wrapped };
}

/// The `SDL_DYNAPI_entry` of the module that owns `table`: the SDL whose
/// first call is loading Katzensteg. Null when that module exports none, or
/// when it is the module holding `self_marker` (Katzensteg itself).
///
/// The comparison is by module, not by the entry's address: on ELF,
/// `&SDL_DYNAPI_entry` taken inside Katzensteg resolves through the global
/// scope to the application's SDL, so it cannot identify Katzensteg.
pub fn loadingEntry(table: *const anyopaque, self_marker: *const anyopaque) ?EntryFn {
    if (builtin.os.tag == .windows) {
        const module = windowsModule(table) orelse return null;
        if (windowsModule(self_marker) == module) return null;
        return @ptrCast(GetProcAddress(module, "SDL_DYNAPI_entry") orelse return null);
    }
    return posixModuleEntry(table, self_marker);
}

const HMODULE = *opaque {};
const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x4;
const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x2;
extern "kernel32" fn GetModuleHandleExW(flags: u32, name: ?*const anyopaque, module: *?HMODULE) callconv(.winapi) c_int;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

fn windowsModule(address: *const anyopaque) ?HMODULE {
    var module: ?HMODULE = null;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, address, &module) == 0) return null;
    return module;
}

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;
extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*const anyopaque;
extern "c" fn dlclose(handle: ?*anyopaque) c_int;
extern "c" fn dlerror() ?[*:0]const u8;

fn posixModuleEntry(table: *const anyopaque, self_marker: *const anyopaque) ?EntryFn {
    var info: DlInfo = undefined;
    if (dladdr(table, &info) == 0) {
        log.warn("dladdr found no module for the SDL jump table at {x}", .{@intFromPtr(table)});
        return null;
    }
    var self_info: DlInfo = undefined;
    if (dladdr(self_marker, &self_info) != 0 and self_info.dli_fbase == info.dli_fbase) return null;
    const name = info.dli_fname orelse "(null)";
    // RTLD_NOLOAD returns the module already mapped (the SDL library, or the
    // executable for a static SDL) and, like any successful dlopen, counts a
    // reference (glibc dl-open.c; macOS dyld dlopen). Closing drops only that
    // reference; SDL's own link keeps the module loaded.
    const rtld_lazy_noload: c_int = if (builtin.os.tag.isDarwin()) 0x1 | 0x10 else 0x1 | 0x4;
    const handle = dlopen(info.dli_fname, rtld_lazy_noload) orelse {
        log.warn("dlopen(RTLD_NOLOAD) of {s} failed: {s}", .{ name, if (dlerror()) |e| std.mem.span(e) else "no error" });
        return null;
    };
    defer _ = dlclose(handle);
    return @ptrCast(dlsym(handle, "SDL_DYNAPI_entry") orelse {
        log.warn("{s} has no SDL_DYNAPI_entry: {s}", .{ name, if (dlerror()) |e| std.mem.span(e) else "no error" });
        return null;
    });
}

/// Removes the variable that loaded Katzensteg, so processes the application
/// starts do not load it too; the preload libraries scrub `LD_PRELOAD` and
/// `DYLD_INSERT_LIBRARIES` the same way. SDL has finished reading it.
fn scrubEnvironment(name: [*:0]const u8) void {
    if (builtin.os.tag == .windows) {
        _ = SetEnvironmentVariableA(name, null);
    } else {
        _ = unsetenv(name);
    }
}
extern "kernel32" fn SetEnvironmentVariableA(name: [*:0]const u8, value: ?[*:0]const u8) callconv(.winapi) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The SDL table Katzensteg wraps. SDL2 and SDL3 serialize their own first
/// calls but not each other's, so two SDLs in one process race to claim it.
var installed_table = std.atomic.Value(?*anyopaque).init(null);

/// The body of each SDL major version's `SDL_DYNAPI_entry`: returns 0 when
/// the table is wrapped and stores the real functions in `real_out`, or -1
/// so SDL falls back to its own functions (SDL2 SDL_dynapi.c:483-499).
pub export fn ks_dynapi_install(
    expected_apiver: u32,
    apiver: u32,
    table: ?*anyopaque,
    tablesize: u32,
    wrappers: [*]const Wrapper,
    wrapper_count: u32,
    self_marker: *const anyopaque,
    env_name: [*:0]const u8,
    real_out: *?[*]Slot,
    real_count_out: *u32,
) callconv(.c) i32 {
    const table_ptr = table orelse return -1;
    if (installed_table.cmpxchgStrong(null, table_ptr, .acq_rel, .acquire)) |previous| {
        // Two SDL copies in one process: keep wrapping the first.
        if (previous != table_ptr) {
            log.warn("a second SDL asked to load Katzensteg; leaving it unwrapped", .{});
            return -1;
        }
    }
    const real_entry = loadingEntry(table_ptr, self_marker) orelse {
        log.warn("the loading SDL exports no SDL_DYNAPI_entry; leaving it unwrapped", .{});
        installed_table.store(null, .release);
        return -1;
    };
    const result = install(std.heap.c_allocator, expected_apiver, apiver, @ptrCast(@alignCast(table_ptr)), tablesize, real_entry, wrappers[0..wrapper_count]) catch |err| {
        log.warn("not wrapping SDL (api version {d}, table {d} bytes): {s}", .{ apiver, tablesize, @errorName(err) });
        installed_table.store(null, .release);
        return -1;
    };
    real_out.* = result.real.ptr;
    real_count_out.* = @intCast(result.real.len);
    scrubEnvironment(env_name);
    log.info("wrapped {d} of {d} functions in a {d}-slot SDL table (api version {d})", .{ result.wrapped, wrapper_count, result.real.len, apiver });
    return 0;
}

// Tests model SDL's entry point: it fills whatever table it is given with
// its own functions, for the size it is asked for.
var fake_functions = [_]u8{0} ** 8;
fn fakeFunction(index: usize) Slot {
    return @ptrCast(&fake_functions[index]);
}
fn fakeEntry(apiver: u32, table: ?*anyopaque, tablesize: u32) callconv(.c) i32 {
    if (apiver != 1 or tablesize > 4 * @sizeOf(Slot)) return -1;
    const slots: [*]Slot = @ptrCast(@alignCast(table.?));
    for (0..tablesize / @sizeOf(Slot)) |i| slots[i] = fakeFunction(i);
    return 0;
}
fn failingEntry(_: u32, _: ?*anyopaque, _: u32) callconv(.c) i32 {
    return -1;
}
var wrapper_function: u8 = 0;

test "install fills the table from the loading SDL, keeps its functions and substitutes wrappers" {
    var table = [_]Slot{null} ** 4;
    const wrappers = [_]Wrapper{.{ .slot = 2, .function = &wrapper_function }};
    const result = try install(std.testing.allocator, 1, 1, &table, @sizeOf(@TypeOf(table)), fakeEntry, &wrappers);
    defer std.testing.allocator.free(result.real);
    try std.testing.expectEqual(@as(usize, 1), result.wrapped);
    try std.testing.expectEqual(fakeFunction(0), table[0]);
    try std.testing.expectEqual(@as(Slot, &wrapper_function), table[2]);
    try std.testing.expectEqual(fakeFunction(3), table[3]);
    try std.testing.expectEqual(@as(usize, 4), result.real.len);
    try std.testing.expectEqual(fakeFunction(2), result.real[2]);
}

test "install leaves slots an older SDL does not have" {
    var table = [_]Slot{null} ** 2;
    const wrappers = [_]Wrapper{ .{ .slot = 1, .function = &wrapper_function }, .{ .slot = 3, .function = &wrapper_function } };
    const result = try install(std.testing.allocator, 1, 1, &table, @sizeOf(@TypeOf(table)), fakeEntry, &wrappers);
    defer std.testing.allocator.free(result.real);
    try std.testing.expectEqual(@as(usize, 1), result.wrapped);
    try std.testing.expectEqual(@as(Slot, &wrapper_function), table[1]);
    try std.testing.expectEqual(@as(usize, 2), result.real.len);
}

test "install rejects another dynamic API version and a failed fill without touching the table" {
    var table = [_]Slot{null} ** 2;
    const wrappers = [_]Wrapper{.{ .slot = 0, .function = &wrapper_function }};
    try std.testing.expectError(error.VersionMismatch, install(std.testing.allocator, 2, 1, &table, @sizeOf(@TypeOf(table)), fakeEntry, &wrappers));
    try std.testing.expectError(error.RealEntryFailed, install(std.testing.allocator, 1, 1, &table, @sizeOf(@TypeOf(table)), failingEntry, &wrappers));
    // A table larger than the loading SDL provides is refused by its entry,
    // as SDL's initialize_jumptable does.
    var large = [_]Slot{null} ** 5;
    try std.testing.expectError(error.RealEntryFailed, install(std.testing.allocator, 1, 1, &large, @sizeOf(@TypeOf(large)), fakeEntry, &wrappers));
    try std.testing.expectEqual(@as(Slot, null), table[0]);
}
