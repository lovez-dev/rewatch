const std = @import("std");
const filter = @import("../filter.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Stamp = struct {
    kind: Io.File.Kind,
    inode: Io.File.INode,
    size: u64,
    mtime: i96,
    ctime: i96,

    fn from(stat: Io.File.Stat) Stamp {
        return .{
            .kind = stat.kind,
            .inode = stat.inode,
            .size = if (stat.kind == .directory) 0 else stat.size,
            // Directory timestamps change when ignored children are written.
            .mtime = if (stat.kind == .directory) 0 else stat.mtime.nanoseconds,
            .ctime = if (stat.kind == .directory) 0 else stat.ctime.nanoseconds,
        };
    }
};

const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged(Stamp) = .empty,

    fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    fn differs(self: *const Snapshot, other: *const Snapshot) bool {
        if (self.files.count() != other.files.count()) return true;
        var it = self.files.iterator();
        while (it.next()) |entry| {
            const previous = other.files.get(entry.key_ptr.*) orelse return true;
            if (!std.meta.eql(previous, entry.value_ptr.*)) return true;
        }
        return false;
    }
};

pub const Watcher = struct {
    allocator: Allocator,
    // Roots and patterns belong to the caller and must outlive the watcher.
    roots: []const []const u8,
    patterns: []const []const u8,
    snapshot: Snapshot,

    pub fn init(allocator: Allocator, io: Io, roots: []const []const u8, patterns: []const []const u8) !Watcher {
        for (roots) |root| {
            const stat = try Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
            if (stat.kind != .file and stat.kind != .directory) return error.UnsupportedWatchPath;
        }
        var self: Watcher = .{
            .allocator = allocator,
            .roots = roots,
            .patterns = patterns,
            .snapshot = .{ .arena = std.heap.ArenaAllocator.init(allocator) },
        };
        errdefer self.deinit();
        _ = try self.poll(io);
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        self.snapshot.deinit();
    }

    /// A failed scan never replaces the previous complete snapshot.
    pub fn poll(self: *Watcher, io: Io) !bool {
        var next: Snapshot = .{ .arena = std.heap.ArenaAllocator.init(self.allocator) };
        errdefer next.deinit();
        for (self.roots) |root| try self.scan(io, &next, root);
        const changed = next.differs(&self.snapshot);
        self.snapshot.deinit();
        self.snapshot = next;
        return changed;
    }

    fn scan(self: *Watcher, io: Io, snapshot: *Snapshot, root: []const u8) !void {
        const a = snapshot.arena.allocator();
        const stat = Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        if (stat.kind == .sym_link) return;
        if (stat.kind == .file) {
            if (!filter.ignored(std.fs.path.basename(root), self.patterns))
                try snapshot.files.put(a, try a.dupe(u8, root), Stamp.from(stat));
            return;
        }
        if (stat.kind != .directory) return;
        try snapshot.files.put(a, try a.dupe(u8, root), Stamp.from(stat));

        const Frame = struct { dir: Io.Dir, iterator: Io.Dir.Iterator, relative: []const u8 };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |frame| frame.dir.close(io);
            stack.deinit(self.allocator);
        }
        const dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        stack.append(self.allocator, .{ .dir = dir, .iterator = dir.iterate(), .relative = "" }) catch |err| {
            dir.close(io);
            return err;
        };
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const entry = (try top.iterator.next(io)) orelse {
                const frame = stack.pop().?;
                frame.dir.close(io);
                continue;
            };
            const relative = if (top.relative.len == 0)
                try a.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ top.relative, entry.name });
            if (filter.ignored(relative, self.patterns) or entry.kind == .sym_link) continue;
            const info = top.dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => continue,
                else => return err,
            };
            if (info.kind != .file and info.kind != .directory) continue;
            const absolute = try std.fs.path.join(a, &.{ root, relative });
            try snapshot.files.put(a, absolute, Stamp.from(info));
            if (info.kind == .directory) {
                const child = top.dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    else => return err,
                };
                stack.append(self.allocator, .{ .dir = child, .iterator = child.iterate(), .relative = relative }) catch |err| {
                    child.close(io);
                    return err;
                };
            }
        }
    }
};

test "scan detects create modify delete but ignores output" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(a, "out/poll-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer a.free(path);
    const dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer Io.Dir.cwd().deleteTree(io, path) catch {};
    defer dir.close(io);
    const absolute = try Io.Dir.cwd().realPathFileAlloc(io, path, a);
    defer a.free(absolute);
    var watcher = try Watcher.init(a, io, &.{absolute}, &.{"*.tmp"});
    defer watcher.deinit();
    try std.testing.expect(!try watcher.poll(io));
    try dir.writeFile(io, .{ .sub_path = "source.txt", .data = "a" });
    try std.testing.expect(try watcher.poll(io));
    try dir.writeFile(io, .{ .sub_path = "source.txt", .data = "longer" });
    try std.testing.expect(try watcher.poll(io));
    try dir.writeFile(io, .{ .sub_path = "ignored.tmp", .data = "x" });
    try std.testing.expect(!try watcher.poll(io));
    const output = try dir.createDirPathOpen(io, "out/nested", .{});
    output.close(io);
    try std.testing.expect(!try watcher.poll(io));
    try dir.deleteFile(io, "source.txt");
    try std.testing.expect(try watcher.poll(io));
}

test "explicit file and directory roots survive deletion and recreation" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var random: [8]u8 = undefined;
    io.random(&random);
    const path = try std.fmt.allocPrint(a, "out/roots-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer a.free(path);
    const base = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer Io.Dir.cwd().deleteTree(io, path) catch {};
    defer base.close(io);
    const nested = try base.createDirPathOpen(io, "nested", .{});
    nested.close(io);
    try base.writeFile(io, .{ .sub_path = "single.txt", .data = "before" });
    const file_relative = try std.fs.path.join(a, &.{ path, "single.txt" });
    defer a.free(file_relative);
    const file_path = try Io.Dir.cwd().realPathFileAlloc(io, file_relative, a);
    defer a.free(file_path);
    const dir_relative = try std.fs.path.join(a, &.{ path, "nested" });
    defer a.free(dir_relative);
    const dir_path = try Io.Dir.cwd().realPathFileAlloc(io, dir_relative, a);
    defer a.free(dir_path);
    var watcher = try Watcher.init(a, io, &.{ file_path, dir_path }, &.{});
    defer watcher.deinit();
    try base.deleteFile(io, "single.txt");
    try base.deleteTree(io, "nested");
    try std.testing.expect(try watcher.poll(io));
    try std.testing.expect(!try watcher.poll(io));
    try base.writeFile(io, .{ .sub_path = "single.txt", .data = "after" });
    const recreated = try base.createDirPathOpen(io, "nested", .{});
    recreated.close(io);
    try std.testing.expect(try watcher.poll(io));
    try std.testing.expect(!try watcher.poll(io));
}
