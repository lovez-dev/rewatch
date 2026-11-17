const std = @import("std");

pub const Scheduler = struct {
    quiet_ms: u32,
    changed_at: ?i64 = null,

    pub fn changed(self: *Scheduler, now_ms: i64) void {
        self.changed_at = now_ms;
    }

    pub fn ready(self: *const Scheduler, now_ms: i64) bool {
        return if (self.changed_at) |at| now_ms - at >= self.quiet_ms else false;
    }

    pub fn consume(self: *Scheduler) void {
        self.changed_at = null;
    }
};

test "bursts postpone restart until the final change has settled" {
    var scheduler: Scheduler = .{ .quiet_ms = 150 };
    try std.testing.expect(!scheduler.ready(1000));
    scheduler.changed(1000);
    scheduler.changed(1100);
    try std.testing.expect(!scheduler.ready(1249));
    try std.testing.expect(scheduler.ready(1250));
    scheduler.consume();
    try std.testing.expect(!scheduler.ready(2000));
}
