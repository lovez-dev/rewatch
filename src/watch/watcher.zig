const std = @import("std");
const SnapshotWatcher = @import("poll.zig").Watcher;
const types = @import("types.zig");
const Backend = switch (@import("builtin").os.tag) {
    .windows => @import("windows.zig").Backend,
    .linux => @import("linux.zig").Backend,
    .macos => @import("macos.zig").Backend,
    else => @compileError("unsupported watch platform"),
};
pub const Mode = types.Mode;

pub const Watcher = struct {
    snapshot: SnapshotWatcher,
    native: ?Backend = null,
    // Registration can race with writes. Recheck after each registration and
    // periodically reconcile metadata to recover missed/coalesced notifications.
    recheck: bool = false,
    next_reconcile: i64 = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, roots: []const []const u8, patterns: []const []const u8, mode: Mode) !Watcher {
        var self: Watcher = .{ .snapshot = try SnapshotWatcher.init(a, io, roots, patterns) };
        errdefer self.deinit(io);
        if (mode == .auto) {
            self.native = self.openNative(io) catch |err| blk: {
                std.debug.print("[rewatch] native watch unavailable ({s}); using polling\n", .{@errorName(err)});
                break :blk null;
            };
            self.recheck = self.native != null;
        }
        self.next_reconcile = now(io) + 2000;
        return self;
    }

    /// Cancels OS notifications and closes handles before releasing snapshot paths.
    pub fn deinit(self: *Watcher, io: std.Io) void {
        if (self.native) |*native| native.deinit(io);
        self.snapshot.deinit();
    }

    pub fn name(self: *const Watcher) []const u8 {
        return if (self.native != null) "native" else "poll";
    }

    pub fn intervalMs(self: *const Watcher, poll_ms: u32) u32 {
        return if (self.native != null) 10 else poll_ms;
    }

    /// force is used at preparation/shutdown boundaries, where a complete scan
    /// must precede the next command even if no OS notification has arrived yet.
    pub fn poll(self: *Watcher, io: std.Io, force: bool) !bool {
        var dirty = force or self.recheck or now(io) >= self.next_reconcile;
        if (self.native) |*native| {
            dirty = (native.poll() catch |err| blk: {
                self.fallback(io, err);
                break :blk true;
            }) or dirty;
        } else dirty = true;
        if (!dirty) return false;
        const changed = self.snapshot.poll(io) catch |err| {
            self.recheck = true;
            return err;
        };
        self.recheck = false;
        self.next_reconcile = now(io) + 2000;
        if (changed and self.native != null) {
            // Arm new directories before closing old watches. Recheck afterward
            // to catch changes between the scan and registration.
            const replacement = self.openNative(io) catch |err| {
                self.fallback(io, err);
                return changed;
            };
            self.native.?.deinit(io);
            self.native = replacement;
            self.recheck = true;
        }
        return changed;
    }

    fn fallback(self: *Watcher, io: std.Io, err: anyerror) void {
        if (self.native) |*native| native.deinit(io);
        self.native = null;
        std.debug.print("[rewatch] native watch failed ({s}); using polling\n", .{@errorName(err)});
    }

    fn openNative(self: *Watcher, io: std.Io) !Backend {
        const a = self.snapshot.allocator;
        var entries: std.ArrayList(types.Entry) = .empty;
        defer entries.deinit(a);
        var it = self.snapshot.snapshot.files.iterator();
        while (it.next()) |entry| try entries.append(a, .{ .path = entry.key_ptr.*, .kind = entry.value_ptr.kind });
        return Backend.init(a, io, self.snapshot.roots, entries.items);
    }
};

fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

const TestDir = struct {
    relative: []const u8,
    absolute: [:0]const u8,
    dir: std.Io.Dir,

    fn init() !TestDir {
        const a = std.testing.allocator;
        const io = std.testing.io;
        var random: [8]u8 = undefined;
        io.random(&random);
        const relative = try std.fmt.allocPrint(a, "out/native-{x}", .{std.mem.readInt(u64, &random, .little)});
        errdefer a.free(relative);
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, relative, .{});
        errdefer dir.close(io);
        errdefer std.Io.Dir.cwd().deleteTree(io, relative) catch {};
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, a);
        return .{ .relative = relative, .absolute = absolute, .dir = dir };
    }

    fn deinit(self: TestDir) void {
        self.dir.close(std.testing.io);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.relative) catch {};
        std.testing.allocator.free(self.absolute);
        std.testing.allocator.free(self.relative);
    }
};

fn expectNotification(watcher: *Watcher) !void {
    const io = std.testing.io;
    // Shorter than the safety scan: require an actual native notification.
    const deadline = now(io) + 1500;
    while (now(io) < deadline) {
        if (try watcher.poll(io, false)) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.MissingNativeNotification;
}

test "native notifications cover nested creation writes replacement and deletion with ignores" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fixture = try TestDir.init();
    defer fixture.deinit();
    var watcher = try Watcher.init(a, io, &.{fixture.absolute}, &.{"*.tmp"}, .auto);
    defer watcher.deinit(io);
    try std.testing.expect(watcher.native != null);
    try std.testing.expect(!try watcher.poll(io, false));
    const nested = try fixture.dir.createDirPathOpen(io, "nested", .{});
    defer nested.close(io);
    try expectNotification(&watcher);
    _ = try watcher.poll(io, false);
    try nested.writeFile(io, .{ .sub_path = "file.txt", .data = "created" });
    try expectNotification(&watcher);
    _ = try watcher.poll(io, false);
    try nested.writeFile(io, .{ .sub_path = "file.txt", .data = "modified contents" });
    try expectNotification(&watcher);
    _ = try watcher.poll(io, false);
    try nested.writeFile(io, .{ .sub_path = "swap.tmp", .data = "replacement" });
    const output = try fixture.dir.createDirPathOpen(io, "out/ignored", .{});
    output.close(io);
    const deadline = now(io) + 100;
    while (now(io) < deadline) {
        try std.testing.expect(!try watcher.poll(io, false));
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try nested.rename("swap.tmp", nested, "file.txt", io);
    try expectNotification(&watcher);
    _ = try watcher.poll(io, false);
    try nested.deleteFile(io, "file.txt");
    try expectNotification(&watcher);
}

test "explicit file roots survive replacement deletion and recreation in both modes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const fixture = try TestDir.init();
    defer fixture.deinit();
    const file = try std.fs.path.join(a, &.{ fixture.absolute, "single.txt" });
    defer a.free(file);
    for ([_]Mode{ .auto, .poll }) |mode| {
        try fixture.dir.writeFile(io, .{ .sub_path = "single.txt", .data = "initial" });
        var watcher = try Watcher.init(a, io, &.{file}, &.{}, mode);
        defer watcher.deinit(io);
        try std.testing.expect(!try watcher.poll(io, false));
        try fixture.dir.writeFile(io, .{ .sub_path = "swap.txt", .data = "replacement" });
        try fixture.dir.rename("swap.txt", fixture.dir, "single.txt", io);
        try expectNotification(&watcher);
        _ = try watcher.poll(io, false);
        try fixture.dir.deleteFile(io, "single.txt");
        try expectNotification(&watcher);
        _ = try watcher.poll(io, false);
        try fixture.dir.writeFile(io, .{ .sub_path = "single.txt", .data = "recreated" });
        try expectNotification(&watcher);
        if (mode == .poll) try std.testing.expect(watcher.native == null);
    }
}
