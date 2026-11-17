const std = @import("std");
const Entry = @import("types.zig").Entry;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const c = std.c;

/// kqueue reports hints; the caller checks snapshots before scheduling a restart.
/// Each registered vnode retains one descriptor until deinit. Resource limits or
/// unsupported filesystems fail initialization so the caller can use polling.
pub const Backend = struct {
    allocator: Allocator,
    queue: c.fd_t,
    files: std.ArrayList(Io.File) = .empty,

    pub fn init(a: Allocator, io: Io, roots: []const []const u8, entries: []const Entry) !Backend {
        const queue = c.kqueue();
        if (queue < 0) return error.NativeWatchUnavailable;
        var self: Backend = .{ .allocator = a, .queue = queue };
        errdefer self.deinit(io);
        if (c.fcntl(queue, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0)
            return error.NativeWatchUnavailable;

        // Path slices are valid during init only. The map is discarded before
        // returning; open descriptors keep registrations independent of storage.
        var paths: std.StringHashMapUnmanaged(void) = .empty;
        defer paths.deinit(a);
        for (entries) |entry| {
            if (entry.kind != .file and entry.kind != .directory) continue;
            try self.add(io, &paths, entry.path);
        }
        // Parent watches see atomic file replacement and watched-root removal.
        for (roots) |root| {
            const parent = std.fs.path.dirname(root) orelse root;
            try self.add(io, &paths, parent);
        }
        return self;
    }

    fn add(self: *Backend, io: Io, paths: *std.StringHashMapUnmanaged(void), path: []const u8) !void {
        const result = try paths.getOrPut(self.allocator, path);
        if (result.found_existing) return;
        const file = try Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
        errdefer file.close(io);
        const change: c.Kevent = .{
            .ident = @intCast(file.handle),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.CLEAR,
            .fflags = c.NOTE.DELETE | c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB | c.NOTE.LINK | c.NOTE.RENAME | c.NOTE.REVOKE,
            .data = 0,
            .udata = 0,
        };
        var unused: [0]c.Kevent = .{};
        if (c.kevent(self.queue, @ptrCast(&change), 1, &unused, 0, null) < 0)
            return error.NativeWatchUnavailable;
        try self.files.append(self.allocator, file);
    }

    /// Drain one bounded batch without blocking the supervisor's main loop.
    pub fn poll(self: *Backend) !bool {
        var events: [64]c.Kevent = undefined;
        const empty: [0]c.Kevent = .{};
        const timeout: c.timespec = .{ .sec = 0, .nsec = 0 };
        const count = c.kevent(self.queue, &empty, 0, &events, events.len, &timeout);
        if (count < 0) return error.NativeWatchFailed;
        for (events[0..@intCast(count)]) |event| {
            if (event.flags & c.EV.ERROR != 0 or event.fflags & c.NOTE.REVOKE != 0)
                return error.NativeWatchFailed;
        }
        return count != 0;
    }

    pub fn deinit(self: *Backend, io: Io) void {
        _ = c.close(self.queue);
        for (self.files.items) |file| file.close(io);
        self.files.deinit(self.allocator);
        self.* = undefined;
    }
};
