const std = @import("std");

const defaults = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", "out" };

/// Paths and patterns use / on every platform. Directories are pruned before scanning.
pub fn ignored(path: []const u8, patterns: []const []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        for (defaults) |name| if (std.mem.eql(u8, part, name)) return true;
    }
    for (patterns) |raw| {
        const pattern = std.mem.trim(u8, raw, "/");
        if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
            parts = std.mem.splitScalar(u8, path, '/');
            while (parts.next()) |part| if (glob(pattern, part)) return true;
        } else if (glob(pattern, path)) return true;
    }
    return false;
}

// Match path components separately so * never crosses / and ** matches whole components.
pub fn glob(pattern: []const u8, path: []const u8) bool {
    const p_end = std.mem.indexOfScalar(u8, pattern, '/') orelse pattern.len;
    const s_end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const head = pattern[0..p_end];
    if (std.mem.eql(u8, head, "**")) {
        if (p_end == pattern.len) return true;
        if (glob(pattern[p_end + 1 ..], path)) return true;
        return s_end < path.len and glob(pattern, path[s_end + 1 ..]);
    }
    if (!component(head, path[0..s_end])) return false;
    if (p_end == pattern.len or s_end == path.len) return p_end == pattern.len and s_end == path.len;
    return glob(pattern[p_end + 1 ..], path[s_end + 1 ..]);
}

fn component(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (s < value.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == value[s])) {
            p += 1;
            s += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = s;
        } else if (star) |index| {
            p = index + 1;
            retry += 1;
            s = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
    return p == pattern.len;
}

test "ignore boundaries and recursive glob" {
    const t = std.testing;
    try t.expect(ignored("nested/out/log.txt", &.{}));
    try t.expect(!ignored("src/output.zig", &.{}));
    try t.expect(ignored("nested/a.tmp", &.{"*.tmp"}));
    try t.expect(!ignored("src/generated/a.zig", &.{"src/generated"}));
    try t.expect(ignored("src/generated", &.{"src/generated"}));
    try t.expect(glob("src/**/*.zig", "src/a.zig"));
    try t.expect(glob("src/**/*.zig", "src/a/b.zig"));
    try t.expect(!glob("src/*.zig", "src/a/b.zig"));
    try t.expect(!glob("a?", "a"));
}
