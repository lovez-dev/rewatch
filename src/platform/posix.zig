const std = @import("std");
const p = std.posix;

var interrupted = std.atomic.Value(bool).init(false);
var previous_int: p.Sigaction = undefined;
var previous_term: p.Sigaction = undefined;

fn signalHandler(_: p.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

pub fn installInterrupt() !void {
    interrupted.store(false, .release);
    const action: p.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = p.sigemptyset(),
        .flags = 0,
    };
    p.sigaction(.INT, &action, &previous_int);
    p.sigaction(.TERM, &action, &previous_term);
}

pub fn uninstallInterrupt() void {
    p.sigaction(.INT, &previous_int, null);
    p.sigaction(.TERM, &previous_term, null);
}

pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

pub const Process = struct {
    child: std.process.Child,
    pgid: p.pid_t,
    reaped: bool = false,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Process {
        _ = allocator;
        const child = try std.process.spawn(io, .{ .argv = argv, .pgid = 0 });
        return .{ .child = child, .pgid = child.id.? };
    }

    pub fn poll(self: *Process, io: std.Io) !?u32 {
        _ = io;
        if (self.reaped) return null;
        var status: i32 = 0;
        while (true) {
            const result = p.system.waitpid(self.pgid, &status, p.W.NOHANG);
            switch (p.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return null;
                    self.reaped = true;
                    self.child.id = null;
                    const bits: u32 = @bitCast(status);
                    return if (p.W.IFEXITED(bits)) p.W.EXITSTATUS(bits) else 128 + @as(u32, @backingInt(p.W.TERMSIG(bits)));
                },
                .INTR => continue,
                else => return error.WaitFailed,
            }
        }
    }

    pub fn requestStop(self: *Process) void {
        p.kill(-self.pgid, .TERM) catch {};
    }

    pub fn forceStop(self: *Process) !void {
        p.kill(-self.pgid, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
    }

    pub fn empty(self: *Process, io: std.Io) !bool {
        _ = try self.poll(io);
        if (!self.reaped) return false;
        p.kill(-self.pgid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return true,
            else => return err,
        };
        return false;
    }

    pub fn deinit(self: *Process, io: std.Io) void {
        self.forceStop() catch {};
        if (!self.reaped) self.child.kill(io);
    }
};
