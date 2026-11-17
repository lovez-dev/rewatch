const std = @import("std");
const platform = @import("runner").platform;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const pid = if (@import("builtin").os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.posix.system.getpid();
    const is_step = std.mem.eql(u8, args[1], "step");
    const mode = if (is_step) args[2] else args[1];
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, "out", .{});
    defer dir.close(io);
    const name = try std.fmt.allocPrint(a, "{d}.{s}", .{ pid, mode });
    const pending_name = try std.fmt.allocPrint(a, "{s}.pending", .{name});
    const heartbeat = try std.fmt.allocPrint(a, "{d}.heartbeat", .{pid});

    if (is_step) {
        if (!std.mem.eql(u8, args[3], "-")) _ = try dir.statFile(io, args[3], .{});
        var bytes: std.ArrayList(u8) = .empty;
        for (args[4..]) |arg| {
            try bytes.appendSlice(a, arg);
            try bytes.append(a, 0);
        }
        try dir.writeFile(io, .{ .sub_path = pending_name, .data = bytes.items });
        try dir.rename(pending_name, dir, name, io);
        const failure = try std.fmt.allocPrint(a, "fail-{s}", .{mode});
        if (dir.statFile(io, failure, .{})) |_| {
            std.process.exit(7);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const completed = try std.fmt.allocPrint(a, "{s}.done", .{mode});
        try dir.writeFile(io, .{ .sub_path = completed, .data = "done" });
        return;
    }

    const preparing = std.mem.eql(u8, mode, "prepare");
    if (std.mem.eql(u8, mode, "serve")) {
        _ = try dir.statFile(io, "prepared", .{});
    }
    if (std.mem.eql(u8, mode, "parent") or preparing) {
        // Deliberately ignore the shutdown request to exercise forced tree cleanup.
        try platform.installInterrupt();
        if (preparing) dir.deleteFile(io, "worker-ready") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const child = try std.process.spawn(io, .{ .argv = &.{ args[0], "worker" } });
        _ = child; // The test supervisor must clean up both processes.
        var bytes: std.ArrayList(u8) = .empty;
        for (args[2..]) |arg| {
            try bytes.appendSlice(a, arg);
            try bytes.append(a, 0);
        }
        try dir.writeFile(io, .{ .sub_path = pending_name, .data = bytes.items });
    } else {
        try dir.writeFile(io, .{ .sub_path = pending_name, .data = "ready" });
        try platform.installInterrupt();
    }
    try dir.rename(pending_name, dir, name, io);
    if (std.mem.eql(u8, mode, "once")) std.process.exit(7);
    var tick: u64 = 0;
    var changed_on_stop = false;
    while (true) : (tick += 1) {
        if (preparing) {
            const released = if (dir.statFile(io, "release", .{})) |_| true else |err| switch (err) {
                error.FileNotFound => false,
                else => return err,
            };
            const worker_ready = if (dir.statFile(io, "worker-ready", .{})) |_| true else |err| switch (err) {
                error.FileNotFound => false,
                else => return err,
            };
            if (released and worker_ready) {
                const failed = if (dir.statFile(io, "fail", .{})) |_| true else |err| switch (err) {
                    error.FileNotFound => false,
                    else => return err,
                };
                if (failed) std.process.exit(7);
                const change_on_success = if (dir.statFile(io, "change-on-success", .{})) |_| true else |err| switch (err) {
                    error.FileNotFound => false,
                    else => return err,
                };
                if (change_on_success) {
                    try dir.deleteFile(io, "change-on-success");
                    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "source.txt", .data = name });
                }
                try dir.writeFile(io, .{ .sub_path = "prepared", .data = "ready" });
                return;
            }
        }
        if (!changed_on_stop and platform.isInterrupted() and std.mem.eql(u8, mode, "parent")) {
            // Persist a change during the grace period; the supervisor must rescan it.
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "during-stop.txt", .data = name });
            changed_on_stop = true;
        }
        const file = try dir.createFile(io, heartbeat, .{});
        defer file.close(io);
        const bytes = std.mem.asBytes(&tick);
        try file.writeStreamingAll(io, bytes);
        if (tick == 0 and std.mem.eql(u8, mode, "worker")) try dir.writeFile(io, .{ .sub_path = "worker-ready", .data = "ready" });
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
}
