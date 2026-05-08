const std = @import("std");

pub const ExpansionContext = struct {
    home: []const u8,
    repo: []const u8,
    path: []const u8 = "",
    owns_home: bool = false,
    owns_repo: bool = false,
    owns_path: bool = false,

    pub fn init(allocator: std.mem.Allocator) !ExpansionContext {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        errdefer allocator.free(home);
        const path = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
            else => return err,
        };
        errdefer allocator.free(path);
        const repo = try resolveRepoRoot(allocator);
        return .{ .home = home, .repo = repo, .path = path, .owns_home = true, .owns_repo = true, .owns_path = true };
    }

    pub fn deinit(self: ExpansionContext, allocator: std.mem.Allocator) void {
        if (self.owns_home) allocator.free(self.home);
        if (self.owns_repo) allocator.free(self.repo);
        if (self.owns_path) allocator.free(self.path);
    }
};

pub fn resolveProfileDirs(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var dirs = std.ArrayList([]const u8).empty;
    errdefer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    if (std.process.getEnvVarOwned(allocator, "KATZENSTEG_PROFILE_DIR")) |raw| {
        defer allocator.free(raw);
        var it = std.mem.splitScalar(u8, raw, ':');
        while (it.next()) |segment| {
            const trimmed = std.mem.trim(u8, segment, " \t");
            if (trimmed.len == 0) continue;
            try dirs.append(allocator, try allocator.dupe(u8, trimmed));
        }
        if (dirs.items.len > 0) return dirs;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const repo = try resolveRepoRoot(allocator);
    defer allocator.free(repo);
    try dirs.append(allocator, try std.fs.path.join(allocator, &.{ repo, "profiles" }));

    if (try userConfigProfilesDir(allocator)) |user_dir| {
        try dirs.append(allocator, user_dir);
    }
    return dirs;
}

fn userConfigProfilesDir(allocator: std.mem.Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        if (xdg.len > 0) return try std.fs.path.join(allocator, &.{ xdg, "katzensteg", "profiles" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        if (home.len > 0) return try std.fs.path.join(allocator, &.{ home, ".config", "katzensteg", "profiles" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return null;
}

pub fn resolveRepoRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "KATZENSTEG_REPO")) |repo| return repo else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (try cwdLooksLikeRepo()) return std.fs.cwd().realpathAlloc(allocator, ".");
    return repoRootFromExecutable(allocator) catch std.fs.cwd().realpathAlloc(allocator, ".");
}

fn cwdLooksLikeRepo() !bool {
    var dir = std.fs.cwd().openDir("profiles", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    dir.close();
    return true;
}

fn repoRootFromExecutable(allocator: std.mem.Allocator) ![]const u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    return repoRootFromExecutablePath(allocator, exe_path);
}

pub fn repoRootFromExecutablePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const bin_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    const build_dir = std.fs.path.dirname(bin_dir) orelse return error.InvalidExecutablePath;
    const repo = std.fs.path.dirname(build_dir) orelse return error.InvalidExecutablePath;
    return allocator.dupe(u8, repo);
}

pub fn expandString(allocator: std.mem.Allocator, input: []const u8, expansion: ExpansionContext) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    if (std.mem.eql(u8, input, "~")) {
        try out.appendSlice(allocator, expansion.home);
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.startsWith(u8, input, "~/")) {
        try out.appendSlice(allocator, expansion.home);
        try out.appendSlice(allocator, input[1..]);
        return out.toOwnedSlice(allocator);
    }

    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "{repo}") or std.mem.startsWith(u8, input[i..], "${ROOT}")) {
            try out.appendSlice(allocator, expansion.repo);
            i += if (std.mem.startsWith(u8, input[i..], "{repo}")) "{repo}".len else "${ROOT}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "{home}")) {
            try out.appendSlice(allocator, expansion.home);
            i += "{home}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$ROOT")) {
            try out.appendSlice(allocator, expansion.repo);
            i += "$ROOT".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "${PATH}")) {
            try out.appendSlice(allocator, expansion.path);
            i += "${PATH}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$PATH")) {
            try out.appendSlice(allocator, expansion.path);
            i += "$PATH".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "${HOME}")) {
            try out.appendSlice(allocator, expansion.home);
            i += "${HOME}".len;
            continue;
        }
        if (std.mem.startsWith(u8, input[i..], "$HOME")) {
            try out.appendSlice(allocator, expansion.home);
            i += "$HOME".len;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "launcher context expands home repo root and path placeholders" {
    const expansion = ExpansionContext{ .home = "/Users/test", .repo = "/repo", .path = "/usr/bin:/bin" };

    const home = try expandString(std.testing.allocator, "{home}/roms/game.sfc", expansion);
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("/Users/test/roms/game.sfc", home);

    const legacy_home = try expandString(std.testing.allocator, "$HOME/dev:${HOME}/x", expansion);
    defer std.testing.allocator.free(legacy_home);
    try std.testing.expectEqualStrings("/Users/test/dev:/Users/test/x", legacy_home);

    const repo = try expandString(std.testing.allocator, "{repo}/zig-out:$ROOT/bin:${ROOT}/lib", expansion);
    defer std.testing.allocator.free(repo);
    try std.testing.expectEqualStrings("/repo/zig-out:/repo/bin:/repo/lib", repo);

    const path = try expandString(std.testing.allocator, "$PATH:${PATH}", expansion);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/usr/bin:/bin:/usr/bin:/bin", path);
}
