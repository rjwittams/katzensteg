const std = @import("std");
const Io = std.Io;
const raw = @import("posix.zig");
pub const File = struct {
    handle: std.posix.fd_t,
    io: Io,
    pub const INode = std.Io.File.INode;
    pub fn fromNative(io: Io, file: Io.File) File {
        return .{ .handle = file.handle, .io = io };
    }
    pub fn native(self: File) Io.File {
        return .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
    }
    pub fn stdin(io: Io) File {
        return fromNative(io, Io.File.stdin());
    }
    pub fn stdout(io: Io) File {
        return fromNative(io, Io.File.stdout());
    }
    pub fn stderr(io: Io) File {
        return fromNative(io, Io.File.stderr());
    }
    pub fn close(self: File) void {
        raw.close(self.handle);
    }
    pub fn read(self: File, bytes: []u8) !usize {
        return raw.read(self.handle, bytes);
    }
    pub fn write(self: File, bytes: []const u8) !usize {
        return raw.write(self.handle, bytes);
    }
    pub fn writeAll(self: File, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = try self.write(bytes[offset..]);
            if (n == 0) return error.WriteZero;
            offset += n;
        }
    }
    pub fn readAll(self: File, bytes: []u8) !usize {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = try self.read(bytes[offset..]);
            if (n == 0) break;
            offset += n;
        }
        return offset;
    }
    pub fn readToEndAlloc(self: File, allocator: std.mem.Allocator, limit: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) return out.toOwnedSlice(allocator);
            if (n > limit - out.items.len) return error.FileTooBig;
            try out.appendSlice(allocator, buf[0..n]);
        }
    }
    pub fn pwriteAll(self: File, bytes: []const u8, offset: u64) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = try raw.pwrite(self.handle, bytes[sent..], offset + sent);
            if (n == 0) return error.WriteZero;
            sent += n;
        }
    }
    pub fn preadAll(self: File, bytes: []u8, offset: u64) !usize {
        var read_count: usize = 0;
        while (read_count < bytes.len) {
            const n = try raw.pread(self.handle, bytes[read_count..], offset + read_count);
            if (n == 0) break;
            read_count += n;
        }
        return read_count;
    }
    pub fn stat(self: File) !Io.File.Stat {
        return self.native().stat(self.io);
    }
    pub fn getEndPos(self: File) !u64 {
        return (try self.stat()).size;
    }
    pub fn setEndPos(self: File, size: u64) !void {
        return self.native().setLength(self.io, size);
    }
    pub fn seekTo(self: File, offset: u64) !void {
        if (std.c.lseek(self.handle, @intCast(offset), std.c.SEEK.SET) < 0) return error.Unseekable;
    }
    pub fn seekFromEnd(self: File, offset: i64) !void {
        if (std.c.lseek(self.handle, offset, std.c.SEEK.END) < 0) return error.Unseekable;
    }
    pub fn sync(self: File) !void {
        return self.native().sync(self.io);
    }
    pub fn lock(self: File, mode: Io.File.Lock) !void {
        return self.native().lock(self.io, mode);
    }
    pub fn tryLock(self: File, mode: Io.File.Lock) !bool {
        return self.native().tryLock(self.io, mode);
    }
    pub fn unlock(self: File) void {
        self.native().unlock(self.io);
    }
    pub fn writer(self: File, buffer: []u8) Writer {
        return .{ .file = self, .interface = .{ .vtable = &.{ .drain = Writer.drain }, .buffer = buffer } };
    }
    pub fn writerStreaming(self: File, buffer: []u8) Writer {
        return self.writer(buffer);
    }
    pub const Writer = struct {
        file: File,
        interface: Io.Writer,
        err: ?anyerror = null,
        fn drain(interface: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Writer = @fieldParentPtr("interface", interface);
            while (interface.end != 0) {
                const n = self.file.write(interface.buffer[0..interface.end]) catch |err| {
                    self.err = err;
                    return error.WriteFailed;
                };
                if (n == 0) {
                    self.err = error.WriteZero;
                    return error.WriteFailed;
                }
                _ = interface.consume(n);
            }
            for (data, 0..) |bytes, i| {
                if (i == data.len - 1 and splat == 0) break;
                if (bytes.len == 0) continue;
                return self.file.write(bytes) catch |err| {
                    self.err = err;
                    return error.WriteFailed;
                };
            }
            return 0;
        }
    };
};

pub const Dir = struct {
    value: Io.Dir,
    io: Io,
    pub fn close(self: Dir) void {
        self.value.close(self.io);
    }
    pub fn openDir(self: Dir, name: []const u8, options: Io.Dir.OpenOptions) !Dir {
        return .{ .value = try self.value.openDir(self.io, name, options), .io = self.io };
    }
    pub fn openFile(self: Dir, name: []const u8, options: Io.Dir.OpenFileOptions) !File {
        return File.fromNative(self.io, try self.value.openFile(self.io, name, options));
    }
    pub fn createFile(self: Dir, name: []const u8, options: CreateFlags) !File {
        return File.fromNative(self.io, try self.value.createFile(self.io, name, options.native()));
    }
    pub fn deleteFile(self: Dir, name: []const u8) !void {
        return self.value.deleteFile(self.io, name);
    }
    pub fn deleteTree(self: Dir, name: []const u8) !void {
        return self.value.deleteTree(self.io, name);
    }
    pub fn makePath(self: Dir, name: []const u8) !void {
        var it = std.fs.path.componentIterator(name);
        var component = it.last() orelse return error.BadPathName;
        while (true) {
            self.value.createDir(self.io, component.path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    // Follow existing directory symlinks, including macOS /tmp.
                    if ((try self.statFile(component.path)).kind != .directory) return error.NotDir;
                },
                error.FileNotFound => {
                    component = it.previous() orelse return err;
                    continue;
                },
                else => return err,
            };
            component = it.next() orelse return;
        }
    }
    pub fn statFile(self: Dir, name: []const u8) !Io.File.Stat {
        return self.value.statFile(self.io, name, .{});
    }
    pub fn realpathAlloc(self: Dir, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const path = try self.value.realPathFileAlloc(self.io, name, allocator);
        defer allocator.free(path);
        return allocator.dupe(u8, path);
    }
    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, name: []const u8, limit: usize) ![]u8 {
        return self.value.readFileAlloc(self.io, name, allocator, .limited(limit));
    }
    pub fn writeFile(self: Dir, options: struct { sub_path: []const u8, data: []const u8 }) !void {
        return self.value.writeFile(self.io, .{ .sub_path = options.sub_path, .data = options.data });
    }
    pub fn access(self: Dir, name: []const u8, options: Io.Dir.AccessOptions) !void {
        return self.value.access(self.io, name, options);
    }
    pub fn iterate(self: Dir) Iterator {
        return .{ .value = self.value.iterate(), .io = self.io };
    }
    pub const Iterator = struct {
        value: Io.Dir.Iterator,
        io: Io,
        pub fn next(self: *Iterator) !?Io.Dir.Entry {
            return self.value.next(self.io);
        }
    };
};
pub const CreateFlags = struct {
    read: bool = false,
    truncate: bool = true,
    exclusive: bool = false,
    mode: std.c.mode_t = 0o666,
    fn native(self: CreateFlags) Io.Dir.CreateFileOptions {
        return .{ .read = self.read, .truncate = self.truncate, .exclusive = self.exclusive, .permissions = .fromMode(self.mode) };
    }
};
pub fn cwd(io: Io) Dir {
    return .{ .value = .cwd(), .io = io };
}
pub fn openFileAbsolute(io: Io, name: []const u8, options: Io.Dir.OpenFileOptions) !File {
    return cwd(io).openFile(name, options);
}
pub fn createFileAbsolute(io: Io, name: []const u8, options: CreateFlags) !File {
    return cwd(io).createFile(name, options);
}
pub fn deleteFileAbsolute(io: Io, name: []const u8) !void {
    return cwd(io).deleteFile(name);
}
pub fn deleteDirAbsolute(io: Io, name: []const u8) !void {
    return Io.Dir.deleteDirAbsolute(io, name);
}
pub fn renameAbsolute(io: Io, old: []const u8, new: []const u8) !void {
    return Io.Dir.renameAbsolute(old, new, io);
}
pub fn selfExePathAlloc(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(io, allocator);
}
pub const TmpDir = struct {
    underlying: std.testing.TmpDir,
    dir: Dir,
    pub fn cleanup(self: *TmpDir) void {
        self.underlying.cleanup();
    }
};
pub fn tmpDir(options: Io.Dir.OpenOptions) TmpDir {
    const tmp = std.testing.tmpDir(options);
    return .{ .underlying = tmp, .dir = .{ .value = tmp.dir, .io = std.testing.io } };
}
