const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var tick: u64 = 0;
    while (true) : (tick += 1) {
        std.debug.print("heartbeat {d}; edit this file to restart\n", .{tick});
        try std.Io.sleep(init.io, .fromSeconds(1), .awake);
    }
}
