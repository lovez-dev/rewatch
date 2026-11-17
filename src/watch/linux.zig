const std = @import("std");
const linux = std.os.linux;
const Entry = @import("types.zig").Entry;

/// The backend owns one nonblocking descriptor; paths are needed only during init.
pub const Backend = struct {
    fd: linux.fd_t,

    pub fn init(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, entries: []const Entry) !Backend {
        _ = io;
        const result = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(result) != .SUCCESS) return error.InotifyInitFailed;
        const self: Backend = .{ .fd = @intCast(result) };
        errdefer _ = linux.close(self.fd);

        // Deduplicate paths before registration. The kernel retains the watches,
        // so this temporary arena and all path copies can be freed before return.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temporary = arena.allocator();
        var directories: std.StringHashMapUnmanaged(void) = .empty;
        for (roots) |root| {
            try self.addDirectory(temporary, &directories, std.fs.path.dirname(root) orelse root);
        }
        for (entries) |entry| {
            if (entry.kind == .directory) try self.addDirectory(temporary, &directories, entry.path);
        }
        return self;
    }

    fn addDirectory(self: *const Backend, a: std.mem.Allocator, directories: *std.StringHashMapUnmanaged(void), path: []const u8) !void {
        if (directories.contains(path)) return;
        const terminated = try a.dupeSentinel(u8, path, 0);
        try directories.put(a, terminated, {});
        const mask = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE |
            linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CREATE |
            linux.IN.DELETE | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
            linux.IN.ONLYDIR;
        const result = linux.inotify_add_watch(self.fd, terminated, mask);
        if (linux.errno(result) != .SUCCESS) return error.InotifyAddWatchFailed;
    }

    /// Drain a bounded amount of work so continuous writes cannot block the main loop.
    /// Overflow or a lost mount invalidates the native backend and triggers fallback.
    pub fn poll(self: *Backend) !bool {
        var changed = false;
        var buffer: [16 * 1024]u8 = undefined;
        for (0..64) |_| {
            const result = linux.read(self.fd, &buffer, buffer.len);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .AGAIN => return changed,
                .INTR => continue,
                else => return error.InotifyReadFailed,
            }
            if (result == 0) return error.InotifyClosed;
            var offset: usize = 0;
            while (offset < result) {
                const header_size = @sizeOf(linux.inotify_event);
                if (result - offset < header_size) return error.InvalidInotifyEvent;
                const event = std.mem.bytesToValue(linux.inotify_event, buffer[offset..][0..header_size]);
                const size = std.math.add(usize, header_size, event.len) catch return error.InvalidInotifyEvent;
                if (size > result - offset) return error.InvalidInotifyEvent;
                if (event.mask & linux.IN.Q_OVERFLOW != 0) return error.InotifyOverflow;
                if (event.mask & linux.IN.UNMOUNT != 0) return error.InotifyUnmounted;
                changed = true;
                offset += size;
            }
        }
        return changed;
    }

    pub fn deinit(self: *Backend, io: std.Io) void {
        _ = io;
        // close releases every kernel watch; individual rm_watch calls are unnecessary.
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};
