const std = @import("std");

pub const Mode = enum { auto, poll };

/// Paths are valid only during backend initialization.
pub const Entry = struct { path: []const u8, kind: std.Io.File.Kind };
