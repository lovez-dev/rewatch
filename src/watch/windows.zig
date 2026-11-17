const std = @import("std");
const Entry = @import("types.zig").Entry;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const w = std.os.windows;

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: extern struct { low: u32 = 0, high: u32 = 0 } = .{},
    event: ?w.HANDLE = null,
};

extern "kernel32" fn CreateFileW(w.LPCWSTR, u32, u32, ?*w.SECURITY_ATTRIBUTES, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn CreateEventW(?*w.SECURITY_ATTRIBUTES, w.BOOL, w.BOOL, ?w.LPCWSTR) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn ResetEvent(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn ReadDirectoryChangesW(w.HANDLE, *anyopaque, u32, w.BOOL, u32, ?*u32, *Overlapped, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetOverlappedResult(w.HANDLE, *Overlapped, *u32, w.BOOL) callconv(.winapi) w.BOOL;
extern "kernel32" fn CancelIoEx(w.HANDLE, ?*Overlapped) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;

const Directory = struct {
    path: []const u8,
    inode: Io.File.INode,
    recursive: bool,
    handle: w.HANDLE,
    event: w.HANDLE,
    overlapped: Overlapped,
    buffer: [16 * 1024]u8 align(4),
    pending: bool = false,

    fn arm(self: *Directory) !void {
        if (ResetEvent(self.event) == .FALSE) return error.NativeWatchFailed;
        self.overlapped = .{ .event = self.event };
        // Include renames, creation/deletion, metadata changes and content writes.
        if (ReadDirectoryChangesW(self.handle, &self.buffer, self.buffer.len, .fromBool(self.recursive), 0x15f, null, &self.overlapped, null) == .FALSE) {
            return error.NativeWatchLost;
        }
        self.pending = true;
    }

    fn deinit(self: *Directory, allocator: Allocator) void {
        if (self.pending) {
            _ = CancelIoEx(self.handle, &self.overlapped);
            var transferred: u32 = 0;
            // The kernel may still write the buffer until cancellation completes.
            _ = GetOverlappedResult(self.handle, &self.overlapped, &transferred, .TRUE);
        }
        w.CloseHandle(self.handle);
        w.CloseHandle(self.event);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

pub const Backend = struct {
    allocator: Allocator,
    io: Io,
    // Each record stays at a stable address until its overlapped request completes.
    directories: std.ArrayList(*Directory) = .empty,

    pub fn init(allocator: Allocator, io: Io, roots: []const []const u8, entries: []const Entry) !Backend {
        _ = entries;
        var self: Backend = .{ .allocator = allocator, .io = io };
        errdefer self.deinit(io);
        for (roots) |root| {
            const stat = try Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
            if (stat.kind == .directory) {
                try self.add(root, true);
            } else if (stat.kind != .file) return error.UnsupportedWatchPath;
            // Observe root replacement/atomic file saves without holding the file open.
            if (std.fs.path.dirname(root)) |parent| try self.add(parent, false);
        }
        for (self.directories.items) |directory| try directory.arm();
        return self;
    }

    fn add(self: *Backend, path: []const u8, recursive: bool) !void {
        for (self.directories.items) |directory| {
            if (w.eqlIgnoreCaseWtf8(directory.path, path)) {
                directory.recursive = directory.recursive or recursive;
                return;
            }
        }
        const stat = try Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false });
        if (stat.kind != .directory) return error.NativeWatchLost;
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, path);
        defer self.allocator.free(wide);
        // No security attributes: handles cannot be inherited by watched commands.
        const handle = CreateFileW(wide.ptr, 1, 7, null, 3, 0x42000000, null);
        if (handle == w.INVALID_HANDLE_VALUE) return error.NativeWatchFailed;
        errdefer w.CloseHandle(handle);
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NativeWatchFailed;
        errdefer w.CloseHandle(event);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const directory = try self.allocator.create(Directory);
        errdefer self.allocator.destroy(directory);
        directory.* = .{
            .path = path_copy,
            .inode = stat.inode,
            .recursive = recursive,
            .handle = handle,
            .event = event,
            .overlapped = .{ .event = event },
            .buffer = undefined,
        };
        try self.directories.append(self.allocator, directory);
    }

    /// Nonblocking. Any notification or overflow asks the caller to reconcile its snapshot.
    pub fn poll(self: *Backend) !bool {
        var changed = false;
        for (self.directories.items) |directory| {
            switch (WaitForSingleObject(directory.event, 0)) {
                0x102 => continue,
                0 => {},
                else => return error.NativeWatchFailed,
            }
            var transferred: u32 = 0;
            if (GetOverlappedResult(directory.handle, &directory.overlapped, &transferred, .FALSE) == .FALSE) {
                if (w.GetLastError() == .IO_INCOMPLETE) continue;
                directory.pending = false;
                return error.NativeWatchLost;
            }
            directory.pending = false;
            // Zero bytes means the system notification buffer overflowed. Both
            // overflow and normal completion require the same full snapshot scan.
            changed = true;
            try directory.arm();
        }
        if (changed) {
            for (self.directories.items) |directory| {
                const current = Io.Dir.cwd().statFile(self.io, directory.path, .{ .follow_symlinks = false }) catch return error.NativeWatchLost;
                if (current.kind != .directory or current.inode != directory.inode) return error.NativeWatchLost;
            }
        }
        return changed;
    }

    pub fn deinit(self: *Backend, io: Io) void {
        _ = io;
        for (self.directories.items) |directory| directory.deinit(self.allocator);
        self.directories.deinit(self.allocator);
        self.* = undefined;
    }
};

test "overlapped directory notifications include nested writes and root deletion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random: [8]u8 = undefined;
    io.random(&random);
    const relative = try std.fmt.allocPrint(allocator, "out/windows-watch-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer allocator.free(relative);
    const directory = try Io.Dir.cwd().createDirPathOpen(io, relative, .{});
    defer Io.Dir.cwd().deleteTree(io, relative) catch {};
    defer directory.close(io);
    const absolute = try Io.Dir.cwd().realPathFileAlloc(io, relative, allocator);
    defer allocator.free(absolute);
    var backend = try Backend.init(allocator, io, &.{absolute}, &.{});
    defer backend.deinit(io);
    {
        const nested = try directory.createDirPathOpen(io, "nested", .{});
        defer nested.close(io);
        try nested.writeFile(io, .{ .sub_path = "source.txt", .data = "created" });
        const deadline = Io.Clock.awake.now(io).toMilliseconds() + 2000;
        while (!try backend.poll()) {
            if (Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TestTimeout;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        try nested.writeFile(io, .{ .sub_path = "source.txt", .data = "updated" });
        const second_deadline = Io.Clock.awake.now(io).toMilliseconds() + 2000;
        while (!try backend.poll()) {
            if (Io.Clock.awake.now(io).toMilliseconds() >= second_deadline) return error.TestTimeout;
            try Io.sleep(io, .fromMilliseconds(10), .awake);
        }
    }
    try Io.Dir.cwd().deleteTree(io, relative);
    const deletion_deadline = Io.Clock.awake.now(io).toMilliseconds() + 2000;
    while (true) {
        _ = backend.poll() catch |err| switch (err) {
            error.NativeWatchLost => break,
            else => return err,
        };
        if (Io.Clock.awake.now(io).toMilliseconds() >= deletion_deadline) return error.TestTimeout;
        try Io.sleep(io, .fromMilliseconds(10), .awake);
    }
}
