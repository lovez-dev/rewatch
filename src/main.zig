const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const Watcher = @import("watch/watcher.zig").Watcher;
const Scheduler = @import("scheduler.zig").Scheduler;
const runner_module = @import("runner.zig");
const Runner = runner_module.Runner;
const platform = runner_module.platform;
const proxy_module = @import("proxy.zig");
const Phase = enum { idle, preparing, prepared, running };

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        switch (err) {
            error.InvalidConfig, error.ConfigReadFailed, error.InvalidOptions => std.process.exit(2),
            else => {},
        }
        std.debug.print("[rewatch] {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options = cli.parse(allocator, args[1..]) catch |err| {
        std.debug.print("[rewatch] {s}; use --help for usage\n", .{@errorName(err)});
        std.process.exit(2);
    };
    defer options.deinit(allocator);
    switch (options.action) {
        .help => return std.Io.File.stdout().writeStreamingAll(io, cli.help),
        .version => return std.Io.File.stdout().writeStreamingAll(io, cli.version ++ "\n"),
        .run => {},
    }
    var document = try config.load(allocator, io, &options);
    defer if (document) |*loaded| loaded.deinit();
    cli.validate(allocator, &options) catch |err| {
        std.debug.print("[rewatch] {s}; use --help for usage\n", .{@errorName(err)});
        return error.InvalidOptions;
    };
    if (options.cwd) |cwd| try std.process.setCurrentPath(io, cwd);
    const current = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current);
    var roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }
    for (options.watches.items) |path| {
        const absolute = try std.fs.path.resolve(allocator, &.{ current, path });
        roots.append(allocator, absolute) catch |err| {
            allocator.free(absolute);
            return err;
        };
    }
    try platform.installInterrupt();
    defer platform.uninstallInterrupt();
    var watcher = try Watcher.init(allocator, io, roots.items, options.ignores.items, options.watcher);
    defer watcher.deinit(io);
    var runner: Runner = .{};
    defer runner.deinit(io);
    const proxy: ?*proxy_module.Proxy = if (options.proxy_target) |target| try proxy_module.Proxy.start(allocator, io, .{
        .target = target,
        .listen = options.proxy_listen orelse "127.0.0.1:3000",
    }) else null;
    defer if (proxy) |p| p.stop();
    if (proxy != null) std.debug.print("[rewatch] proxy http://{s} -> {s}\n", .{ options.proxy_listen orelse "127.0.0.1:3000", options.proxy_target.? });
    var scheduler: Scheduler = .{ .quiet_ms = options.debounce_ms };
    std.debug.print("[rewatch] watching {d} path(s); backend: {s}, polling fallback: {d}ms\n", .{ roots.items.len, watcher.name(), options.poll_ms });
    var phase = begin(&runner, allocator, io, &options);
    if (proxy) |p| p.setRunning(phase == .running);
    var pre_index: usize = 0;
    var next_scan = now(io) + watcher.intervalMs(options.poll_ms);
    var scan_failed = false;
    while (!platform.isInterrupted()) {
        var pre_finished = false;
        if (try runner.poll(io)) |code| {
            if (phase == .running) if (proxy) |p| p.setRunning(false);
            try runner.stop(io, options.stop_ms);
            if (phase == .preparing and code == 0) {
                std.debug.print("[rewatch] pre-command {d}/{d} succeeded\n", .{ pre_index + 1, options.pre_commands.len });
                pre_index += 1;
                phase = .prepared;
                pre_finished = true;
            } else {
                const label: []const u8 = if (phase == .preparing) "pre-command" else "command";
                std.debug.print("[rewatch] {s} exited ({d}); waiting for changes\n", .{ label, code });
                phase = .idle;
            }
        }
        const time = now(io);
        // Before using a successful preparation, check for changes since its last scan.
        if (time >= next_scan or pre_finished) {
            const changed = watcher.poll(io, pre_finished or scan_failed) catch |err| {
                if (!scan_failed) std.debug.print("[rewatch] scan failed ({s}); retrying\n", .{@errorName(err)});
                scan_failed = true;
                next_scan = now(io) + options.poll_ms;
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
                continue;
            };
            if (scan_failed) std.debug.print("[rewatch] scanning resumed\n", .{});
            scan_failed = false;
            if (changed) scheduler.changed(now(io));
            next_scan = now(io) + watcher.intervalMs(options.poll_ms);
        }
        if (!scan_failed and scheduler.ready(now(io))) {
            if (runner.process != null) std.debug.print("[rewatch] change detected; restarting\n", .{});
            if (proxy) |p| p.setRunning(false);
            try runner.stop(io, options.stop_ms);
            phase = .idle;
            // Rescan after shutdown so writes during the grace period also settle before launch.
            const changed = watcher.poll(io, true) catch |err| {
                std.debug.print("[rewatch] scan failed ({s}); retrying\n", .{@errorName(err)});
                scan_failed = true;
                continue;
            };
            if (changed) {
                scheduler.changed(now(io));
            } else if (!platform.isInterrupted()) {
                scheduler.consume();
                pre_index = 0;
                phase = begin(&runner, allocator, io, &options);
                if (proxy) |p| p.setRunning(phase == .running);
            }
        }
        if (!scan_failed and phase == .prepared and scheduler.changed_at == null and !platform.isInterrupted()) {
            phase = if (pre_index < options.pre_commands.len)
                if (start(&runner, allocator, io, options.pre_commands[pre_index], "pre-command")) .preparing else .idle
            else if (start(&runner, allocator, io, options.command, "command")) .running else .idle;
            if (proxy) |p| p.setRunning(phase == .running);
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    std.debug.print("[rewatch] stopping\n", .{});
    if (proxy) |p| p.setRunning(false);
    try runner.stop(io, options.stop_ms);
}

fn begin(runner: *Runner, allocator: std.mem.Allocator, io: std.Io, options: *const cli.Options) Phase {
    if (options.pre_commands.len > 0) {
        return if (start(runner, allocator, io, options.pre_commands[0], "pre-command")) .preparing else .idle;
    }
    return if (start(runner, allocator, io, options.command, "command")) .running else .idle;
}

fn start(runner: *Runner, allocator: std.mem.Allocator, io: std.Io, command: []const []const u8, label: []const u8) bool {
    runner.start(allocator, io, command) catch |err| {
        std.debug.print("[rewatch] cannot start {s} {s}: {s}; waiting for changes\n", .{ label, command[0], @errorName(err) });
        return false;
    };
    std.debug.print("[rewatch] started {s}: {s}\n", .{ label, command[0] });
    return true;
}

fn now(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = proxy_module;
    _ = @import("filter.zig");
    _ = @import("scheduler.zig");
    _ = @import("watch/poll.zig");
    _ = @import("watch/watcher.zig");
    _ = runner_module.platform;
}
