const std = @import("std");
pub const platform = switch (@import("builtin").os.tag) {
    .windows => @import("platform/windows.zig"),
    .linux, .macos => @import("platform/posix.zig"),
    else => @compileError("rewatch supports Windows, Linux and macOS"),
};

pub const Runner = struct {
    // The runner closes the process and all associated handles before replacing it.
    process: ?platform.Process = null,

    pub fn start(self: *Runner, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
        std.debug.assert(self.process == null);
        self.process = try platform.Process.start(allocator, io, argv);
    }

    pub fn poll(self: *Runner, io: std.Io) !?u32 {
        if (self.process) |*process| return process.poll(io);
        return null;
    }

    pub fn stop(self: *Runner, io: std.Io, timeout_ms: u32) !void {
        if (self.process) |*process| {
            defer {
                process.deinit(io);
                self.process = null;
            }
            process.requestStop();
            const started = std.Io.Clock.awake.now(io).toMilliseconds();
            var forced = false;
            while (!try process.empty(io)) {
                const elapsed = std.Io.Clock.awake.now(io).toMilliseconds() - started;
                if (!forced and elapsed >= timeout_ms) {
                    try process.forceStop();
                    forced = true;
                }
                // Bound polling after force; an unresponsive process tree is a fatal error.
                if (forced and elapsed >= @as(i64, timeout_ms) + 5000) return error.ProcessTreeDidNotExit;
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            }
        }
    }

    pub fn deinit(self: *Runner, io: std.Io) void {
        if (self.process) |*process| process.deinit(io);
        self.process = null;
    }
};
