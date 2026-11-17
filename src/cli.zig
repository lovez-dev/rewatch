const std = @import("std");

pub const version = "0.1.0";
pub const help =
    \\Usage: rewatch [options] [-- <program> [args...]]
    \\
    \\Run a command and restart it when watched files change.
    \\
    \\  --config <path>            Read TOML config (default: ./rewatch.toml)
    \\  --no-config                Disable automatic config discovery
    \\  --no-pre-command           Skip all configured pre-commands
    \\  --proxy-target <origin>    Proxy upstream, e.g. http://127.0.0.1:8080
    \\  --proxy-listen <address>   Proxy IP:port (default: 127.0.0.1:3000)
    \\  --watch <path>             Watch a file or directory (repeatable; default: .)
    \\  --ignore <pattern>         Ignore a path or glob (repeatable)
    \\  --watcher <auto|poll>      Native notifications with fallback (default: auto)
    \\  --debounce <duration>      Wait for quiet before restarting (default: 150ms)
    \\  --poll-interval <duration> Fallback scan interval (default: 300ms; minimum: 10ms)
    \\  --stop-timeout <duration>  Graceful shutdown deadline (default: 2s)
    \\  --cwd <path>              Base directory for watches and the command
    \\  -h, --help                Show help
    \\  --version                 Show version
    \\
    \\Durations accept integer milliseconds (150 or 150ms) or seconds (2s).
    \\Commands run directly. Use an explicit shell for scripts, pipes or redirection.
    \\Ignore patterns use /, *, ** and ?. They do not read .gitignore.
    \\
;

pub const Options = struct {
    // Strings refer to argv or the config document; both must outlive these options.
    watches: std.ArrayList([]const u8) = .empty,
    ignores: std.ArrayList([]const u8) = .empty,
    command: []const []const u8 = &.{},
    pre_commands: []const []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    debounce_ms: u32 = 150,
    poll_ms: u32 = 300,
    watcher: @import("watch/types.zig").Mode = .auto,
    stop_ms: u32 = 2000,
    config_path: ?[]const u8 = null,
    no_config: bool = false,
    no_pre_command: bool = false,
    proxy_target: ?[]const u8 = null,
    proxy_listen: ?[]const u8 = null,
    provided: struct { debounce: bool = false, poll: bool = false, stop: bool = false, watcher: bool = false } = .{},
    action: enum { run, help, version } = .run,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.watches.deinit(allocator);
        self.ignores.deinit(allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    errdefer options.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command = args[i + 1 ..];
            if (options.command.len == 0) return error.MissingCommand;
            break;
        }
        if (std.mem.eql(u8, arg, "--no-config")) {
            options.no_config = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-pre-command")) {
            options.no_pre_command = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.action = .help;
            return options;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            options.action = .version;
            return options;
        }
        const known = [_][]const u8{ "--config", "--watch", "--ignore", "--cwd", "--debounce", "--poll-interval", "--stop-timeout", "--proxy-target", "--proxy-listen", "--watcher" };
        var found = false;
        for (known) |name| {
            if (std.mem.eql(u8, name, arg)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownOption;
        i += 1;
        if (i == args.len or args[i].len == 0 or std.mem.eql(u8, args[i], "--")) return error.MissingValue;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = value;
        } else if (std.mem.eql(u8, arg, "--proxy-target")) {
            options.proxy_target = value;
        } else if (std.mem.eql(u8, arg, "--proxy-listen")) {
            options.proxy_listen = value;
        } else if (std.mem.eql(u8, arg, "--watcher")) {
            options.watcher = std.meta.stringToEnum(@TypeOf(options.watcher), value) orelse return error.InvalidWatcher;
            options.provided.watcher = true;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            try options.watches.append(allocator, value);
        } else if (std.mem.eql(u8, arg, "--ignore")) {
            try validateIgnore(value);
            try options.ignores.append(allocator, value);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            options.cwd = value;
        } else if (std.mem.eql(u8, arg, "--debounce")) {
            options.debounce_ms = try duration(value);
            options.provided.debounce = true;
        } else if (std.mem.eql(u8, arg, "--poll-interval")) {
            options.poll_ms = try duration(value);
            options.provided.poll = true;
            if (options.poll_ms < 10) return error.PollIntervalTooSmall;
        } else {
            options.stop_ms = try duration(value);
            options.provided.stop = true;
        }
    }
    if (options.no_config and options.config_path != null) return error.ConflictingConfigOptions;
    return options;
}

/// Validate after configuration and command-line overrides have been merged.
pub fn validate(allocator: std.mem.Allocator, options: *Options) !void {
    if (options.proxy_target) |target| {
        try @import("proxy.zig").validate(.{ .target = target, .listen = options.proxy_listen orelse "127.0.0.1:3000" });
    } else if (options.proxy_listen != null) return error.ProxyTargetRequired;
    if (options.command.len == 0 or options.command[0].len == 0) return error.MissingCommand;
    for (options.command) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
    }
    for (options.pre_commands) |command| {
        if (command.len == 0 or command[0].len == 0) return error.InvalidPreCommand;
        for (command) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidPreCommand;
    }
    if (options.watches.items.len == 0) try options.watches.append(allocator, ".");
}

pub fn validateIgnore(value: []const u8) !void {
    if (std.mem.trim(u8, value, "/").len == 0 or std.mem.indexOfAny(u8, value, "\\[]!") != null) return error.InvalidIgnorePattern;
}

pub fn duration(value: []const u8) !u32 {
    const seconds = std.mem.endsWith(u8, value, "s") and !std.mem.endsWith(u8, value, "ms");
    const digits = if (std.mem.endsWith(u8, value, "ms")) value[0 .. value.len - 2] else if (seconds) value[0 .. value.len - 1] else value;
    if (digits.len == 0) return error.InvalidDuration;
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidDuration;
    const number = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidDuration;
    return std.math.mul(u32, number, if (seconds) 1000 else 1) catch error.InvalidDuration;
}

test "command arguments remain literal and options stop at separator" {
    const a = std.testing.allocator;
    var options = try parse(a, &.{ "--debounce", "2s", "--", "program", "", "--watch", "a b", "$(echo x)" });
    defer options.deinit(a);
    try std.testing.expectEqual(@as(u32, 2000), options.debounce_ms);
    try std.testing.expectEqualStrings("", options.command[1]);
    try std.testing.expectEqualStrings("--watch", options.command[2]);
}

test "reject missing commands and invalid durations" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingCommand, parse(a, &.{"--"}));
    try std.testing.expectError(error.MissingValue, parse(a, &.{"--watch"}));
    try std.testing.expectError(error.InvalidDuration, parse(a, &.{ "--debounce", "-1", "--", "x" }));
    try std.testing.expectError(error.InvalidDuration, duration("4294967295s"));
    try std.testing.expectError(error.PollIntervalTooSmall, parse(a, &.{ "--poll-interval", "0", "--", "x" }));
    try std.testing.expectError(error.ConflictingConfigOptions, parse(a, &.{ "--config", "custom.toml", "--no-config" }));
    var options = try parse(a, &.{});
    defer options.deinit(a);
    try std.testing.expectError(error.MissingCommand, validate(a, &options));
}

test "proxy listener requires a target and CLI supports origin overrides" {
    const a = std.testing.allocator;
    var missing = try parse(a, &.{ "--proxy-listen", "127.0.0.1:4000", "--", "server" });
    defer missing.deinit(a);
    try std.testing.expectError(error.ProxyTargetRequired, validate(a, &missing));
    var options = try parse(a, &.{ "--proxy-target", "http://127.0.0.1:8080", "--", "server" });
    defer options.deinit(a);
    try validate(a, &options);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", options.proxy_target.?);
}

test "watcher mode defaults to auto and rejects unknown modes" {
    const a = std.testing.allocator;
    var defaults = try parse(a, &.{ "--", "server" });
    defer defaults.deinit(a);
    try std.testing.expectEqual(.auto, defaults.watcher);
    var polling = try parse(a, &.{ "--watcher", "poll", "--", "server" });
    defer polling.deinit(a);
    try std.testing.expectEqual(.poll, polling.watcher);
    try std.testing.expectError(error.InvalidWatcher, parse(a, &.{ "--watcher", "native" }));
}
