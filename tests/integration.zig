const std = @import("std");
const Runner = @import("runner").Runner;
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedAppAndFixturePaths;
    const app = try Io.Dir.cwd().realPathFileAlloc(io, args[1], a);
    const helper = try Io.Dir.cwd().realPathFileAlloc(io, args[2], a);
    var random: [8]u8 = undefined;
    io.random(&random);
    const relative = try std.fmt.allocPrint(a, "out/integration-{x}/watch space", .{std.mem.readInt(u64, &random, .little)});
    const base = try Io.Dir.cwd().createDirPathOpen(io, relative, .{});
    defer Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(relative).?) catch {};
    defer base.close(io);
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, relative, a);
    const output = try base.createDirPathOpen(io, "out", .{});
    defer output.close(io);
    const expected_args = "\x00a b\x00quote\"here\x00trailing\\\x00你好\x00$(literal)\x00";
    var runner: Runner = .{};
    defer runner.stop(io, 4000) catch runner.deinit(io);

    try runner.start(a, io, &.{
        app,          "--cwd", cwd,  "--poll-interval", "30ms",   "--debounce", "200ms", "--stop-timeout", "100ms",
        "--ignore",   "*.tmp", "--", helper,            "parent", "",           "a b",   "quote\"here",    "trailing\\",
        "你好",
        "$(literal)",
    });
    try waitCount(io, output, ".parent", 1);
    try waitCount(io, output, ".worker", 1);
    try waitCount(io, output, ".heartbeat", 2);
    const original_heartbeats = try entries(a, io, output, ".heartbeat");
    const first = try entries(a, io, output, ".parent");
    const actual = try output.readFileAlloc(io, first[0], a, .limited(4096));
    try std.testing.expectEqualStrings(expected_args, actual);

    // Ignored files and directories must not feed back into the watch loop.
    try base.writeFile(io, .{ .sub_path = "ignored.tmp", .data = "ignored" });
    try sleep(io, 600);
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".parent"));

    for (0..5) |index| {
        const data = try std.fmt.allocPrint(a, "save {d}", .{index});
        try base.writeFile(io, .{ .sub_path = "source.txt", .data = data });
        try sleep(io, 20);
    }
    try waitCount(io, output, ".parent", 2);
    try waitCount(io, output, ".worker", 2);
    try sleep(io, 600);
    try std.testing.expectEqual(@as(usize, 2), try count(io, output, ".parent"));
    try std.testing.expectEqual(@as(usize, 2), try count(io, output, ".worker"));
    try expectStopped(a, io, output, original_heartbeats);
    // The fixture writes this while ignoring graceful shutdown.
    _ = try base.statFile(io, "during-stop.txt", .{});

    // Atomic replacement and deletion both trigger one additional run.
    try base.writeFile(io, .{ .sub_path = "swap.tmp", .data = "atomic replacement" });
    try base.rename("swap.tmp", base, "source.txt", io);
    try waitCount(io, output, ".parent", 3);
    try waitCount(io, output, ".worker", 3);
    try base.deleteFile(io, "source.txt");
    try waitCount(io, output, ".parent", 4);
    try waitCount(io, output, ".worker", 4);

    // Send a signal to the supervisor itself; it must shut down its separate child group.
    runner.process.?.requestStop();
    const deadline = now(io) + 6000;
    var exited = false;
    while (now(io) < deadline) {
        if (try runner.poll(io)) |code| {
            try std.testing.expectEqual(@as(u32, 0), code);
            exited = true;
            break;
        }
        try sleep(io, 20);
    }
    try std.testing.expect(exited);
    try runner.stop(io, 100);
    const heartbeats = try entries(a, io, output, ".heartbeat");
    try expectStopped(a, io, output, heartbeats);

    // A failed command must wait for a change instead of entering a restart loop.
    try runner.start(a, io, &.{ app, "--cwd", cwd, "--poll-interval", "30ms", "--debounce", "100ms", "--", helper, "once" });
    try waitCount(io, output, ".once", 1);
    try sleep(io, 500);
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".once"));
    try base.writeFile(io, .{ .sub_path = "source.txt", .data = "retry" });
    try waitCount(io, output, ".once", 2);
    try runner.stop(io, 4000);
    try configTests(a, io, app, helper, base, cwd);
    try preCommandTests(a, io, app, helper, base, cwd);
    try multiplePreCommandTests(a, io, app, helper, base, cwd);
    try watchRecoveryTests(a, io, app, helper, base, cwd);
    std.debug.print("integration: restart, debounce, ignores, literal args, atomic saves, failure, tree shutdown, TOML and pre-command passed\n", .{});
}

fn watchRecoveryTests(a: std.mem.Allocator, io: Io, app: []const u8, helper: []const u8, base: Io.Dir, cwd: []const u8) !void {
    for ([_][]const u8{ "auto", "poll" }) |mode| {
        const project = try base.createDirPathOpen(io, mode, .{});
        defer project.close(io);
        const project_cwd = try std.fs.path.join(a, &.{ cwd, mode });
        const output = try project.createDirPathOpen(io, "out", .{});
        defer output.close(io);
        const root = try project.createDirPathOpen(io, "watched", .{});
        root.close(io);
        var runner: Runner = .{};
        defer runner.stop(io, 4000) catch runner.deinit(io);
        try runner.start(a, io, &.{ app, "--no-config", "--cwd", project_cwd, "--watch", "watched", "--watcher", mode, "--poll-interval", "30ms", "--debounce", "60ms", "--", helper, "once" });
        try waitCount(io, output, ".once", 1);
        // Native root loss must preserve detection through polling fallback or
        // parent-directory notifications, including later nested registration.
        try project.deleteTree(io, "watched");
        try waitCount(io, output, ".once", 2);
        const nested = try project.createDirPathOpen(io, "watched/nested", .{});
        defer nested.close(io);
        try waitCount(io, output, ".once", 3);
        try nested.writeFile(io, .{ .sub_path = "source.txt", .data = "after recreation" });
        try waitCount(io, output, ".once", 4);
        try sleep(io, 150);
        try std.testing.expectEqual(@as(usize, 4), try count(io, output, ".once"));
        try runner.stop(io, 4000);
    }
}

fn multiplePreCommandTests(a: std.mem.Allocator, io: Io, app: []const u8, helper: []const u8, base: Io.Dir, cwd: []const u8) !void {
    const project = try base.createDirPathOpen(io, "multiple", .{});
    defer project.close(io);
    const output = try project.createDirPathOpen(io, "out", .{});
    defer output.close(io);
    const quoted = try std.json.Stringify.valueAlloc(a, helper, .{});
    const contents = try std.fmt.allocPrint(
        a,
        "pre-command = [\n[{s}, 'step', 'first', '-', '', 'a b', 'quote\"here'],\n[{s}, 'prepare'],\n[{s}, 'step', 'last', 'prepared'],\n]\ncommand = [{s}, 'step', 'multi-main', 'last.done']\ncwd = 'multiple'\npoll-interval = 30\ndebounce = 60\nstop-timeout = 100\n",
        .{ quoted, quoted, quoted, quoted },
    );
    try base.writeFile(io, .{ .sub_path = "multiple.toml", .data = contents });
    const path = try std.fs.path.join(a, &.{ cwd, "multiple.toml" });
    var runner: Runner = .{};
    defer runner.stop(io, 4000) catch runner.deinit(io);
    try runner.start(a, io, &.{ app, "--config", path });
    try waitCount(io, output, ".first", 1);
    try waitCount(io, output, ".prepare", 1);
    const first = try entries(a, io, output, ".first");
    try std.testing.expectEqualStrings("\x00a b\x00quote\"here\x00", try output.readFileAlloc(io, first[0], a, .limited(4096)));
    try std.testing.expectEqual(@as(usize, 0), try count(io, output, ".last"));
    try std.testing.expectEqual(@as(usize, 0), try count(io, output, ".multi-main"));
    try output.writeFile(io, .{ .sub_path = "release", .data = "go" });
    try waitCount(io, output, ".last", 1);
    try waitCount(io, output, ".multi-main", 1);

    // Failure in the middle skips the remaining preparation and main command.
    try output.writeFile(io, .{ .sub_path = "fail", .data = "fail" });
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "middle failure" });
    try waitCount(io, output, ".prepare", 2);
    try sleep(io, 400);
    try std.testing.expectEqual(@as(usize, 2), try count(io, output, ".first"));
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".last"));
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".multi-main"));

    // An edit during a later step reruns the entire sequence from step one.
    try output.deleteFile(io, "fail");
    try output.deleteFile(io, "release");
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "wait at second step" });
    try waitCount(io, output, ".prepare", 3);
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "cancel second step" });
    try waitCount(io, output, ".prepare", 4);
    try std.testing.expectEqual(@as(usize, 4), try count(io, output, ".first"));
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".last"));
    try output.writeFile(io, .{ .sub_path = "release", .data = "go" });
    try waitCount(io, output, ".multi-main", 2);

    // Failure in the final preparation also prevents main from launching.
    try output.writeFile(io, .{ .sub_path = "fail-last", .data = "fail" });
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "last failure" });
    try waitCount(io, output, ".last", 3);
    try sleep(io, 400);
    try std.testing.expectEqual(@as(usize, 2), try count(io, output, ".multi-main"));
    try runner.stop(io, 4000);

    try runner.start(a, io, &.{ app, "--config", path, "--no-pre-command" });
    try waitCount(io, output, ".multi-main", 3);
    try std.testing.expectEqual(@as(usize, 5), try count(io, output, ".first"));
    try runner.stop(io, 4000);
}

fn preCommandTests(a: std.mem.Allocator, io: Io, app: []const u8, helper: []const u8, base: Io.Dir, cwd: []const u8) !void {
    const project = try base.createDirPathOpen(io, "pipeline", .{});
    defer project.close(io);
    const output = try project.createDirPathOpen(io, "out", .{});
    defer output.close(io);
    const quoted_helper = try std.json.Stringify.valueAlloc(a, helper, .{});
    const contents = try std.fmt.allocPrint(
        a,
        "pre-command = [{s}, 'prepare', '', 'literal arg', 'quote\"here']\ncommand = [{s}, 'serve']\nwatch = ['.']\ncwd = 'pipeline'\ndebounce = 60\npoll-interval = 30\nstop-timeout = 100\n",
        .{ quoted_helper, quoted_helper },
    );
    try base.writeFile(io, .{ .sub_path = "pipeline.toml", .data = contents });
    const path = try std.fs.path.join(a, &.{ cwd, "pipeline.toml" });
    var runner: Runner = .{};
    defer runner.stop(io, 4000) catch runner.deinit(io);
    try runner.start(a, io, &.{ app, "--config", path });
    try waitCount(io, output, ".prepare", 1);
    try waitCount(io, output, ".worker", 1);
    try waitCount(io, output, ".heartbeat", 2);
    try std.testing.expectEqual(@as(usize, 0), try count(io, output, ".serve"));
    const records = try entries(a, io, output, ".prepare");
    const arguments = try output.readFileAlloc(io, records[0], a, .limited(4096));
    try std.testing.expectEqualStrings("\x00literal arg\x00quote\"here\x00", arguments);
    const first_heartbeats = try entries(a, io, output, ".heartbeat");

    try output.writeFile(io, .{ .sub_path = "release", .data = "go" });
    try waitCount(io, output, ".serve", 1);
    try expectStopped(a, io, output, first_heartbeats);

    // A change stops the old main command before starting a fresh pre-command.
    try output.deleteFile(io, "release");
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "second run" });
    try waitCount(io, output, ".prepare", 2);
    try waitCount(io, output, ".worker", 2);
    try waitCount(io, output, ".heartbeat", 5);
    const before_cancel = try entries(a, io, output, ".heartbeat");
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "changed during preparation" });
    try waitCount(io, output, ".prepare", 3);
    try waitCount(io, output, ".worker", 3);
    try expectStopped(a, io, output, before_cancel);
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".serve"));

    // A failed pre-command blocks main and does not retry by itself.
    try output.writeFile(io, .{ .sub_path = "fail", .data = "fail" });
    try output.writeFile(io, .{ .sub_path = "release", .data = "go" });
    try sleep(io, 500);
    try std.testing.expectEqual(@as(usize, 3), try count(io, output, ".prepare"));
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".serve"));
    try output.deleteFile(io, "fail");
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "retry after failure" });
    try waitCount(io, output, ".prepare", 4);
    try waitCount(io, output, ".serve", 2);

    // Interrupting the supervisor also cleans up an active preparation and its worker.
    try output.deleteFile(io, "release");
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "stop while preparing" });
    try waitCount(io, output, ".prepare", 5);
    try waitCount(io, output, ".worker", 5);
    // A short successful preparation may finish before writing its own heartbeat.
    try sleep(io, 100);
    try runner.stop(io, 4000);
    try expectStopped(a, io, output, try entries(a, io, output, ".heartbeat"));

    try runner.start(a, io, &.{ app, "--config", path, "--no-pre-command" });
    try waitCount(io, output, ".serve", 3);
    try std.testing.expectEqual(@as(usize, 5), try count(io, output, ".prepare"));
    try runner.stop(io, 4000);

    // A write immediately before successful exit must invalidate that preparation.
    try output.writeFile(io, .{ .sub_path = "release", .data = "go" });
    try output.writeFile(io, .{ .sub_path = "change-on-success", .data = "change" });
    try runner.start(a, io, &.{ app, "--config", path });
    try waitCount(io, output, ".prepare", 7);
    try waitCount(io, output, ".serve", 4);
    try sleep(io, 250);
    try std.testing.expectEqual(@as(usize, 4), try count(io, output, ".serve"));
    try runner.stop(io, 4000);

    const missing = try std.fmt.allocPrint(
        a,
        "pre-command = ['{s}']\ncommand = [{s}, 'serve']\ncwd = 'pipeline'\nstop-timeout = 100\n",
        .{ "nonexistent-rewatch-pre-command-54c0", quoted_helper },
    );
    try base.writeFile(io, .{ .sub_path = "pipeline.toml", .data = missing });
    try runner.start(a, io, &.{ app, "--config", path });
    try sleep(io, 400);
    try std.testing.expectEqual(@as(usize, 4), try count(io, output, ".serve"));
    try runner.stop(io, 4000);
}

fn configTests(a: std.mem.Allocator, io: Io, app: []const u8, helper: []const u8, base: Io.Dir, cwd: []const u8) !void {
    const project = try base.createDirPathOpen(io, "configured project", .{});
    defer project.close(io);
    const output = try project.createDirPathOpen(io, "out", .{});
    defer output.close(io);
    const quoted_helper = try std.json.Stringify.valueAlloc(a, helper, .{});
    const contents = try std.fmt.allocPrint(
        a,
        "command = [{s}, 'once']\nwatch = ['.']\nignore = ['*.tmp']\ncwd = 'configured project'\ndebounce = '60ms'\npoll-interval = 30\nstop-timeout = '100ms'\n",
        .{quoted_helper},
    );
    try base.writeFile(io, .{ .sub_path = "rewatch.toml", .data = contents });
    const path = try std.fs.path.join(a, &.{ cwd, "rewatch.toml" });
    var runner: Runner = .{};
    defer runner.stop(io, 4000) catch runner.deinit(io);

    // Explicit config resolves its cwd relative to its own directory.
    try runner.start(a, io, &.{ app, "--config", path });
    try waitCount(io, output, ".once", 1);
    try project.writeFile(io, .{ .sub_path = "ignored.tmp", .data = "ignored" });
    try sleep(io, 300);
    try std.testing.expectEqual(@as(usize, 1), try count(io, output, ".once"));
    try project.writeFile(io, .{ .sub_path = "source.txt", .data = "trigger" });
    try waitCount(io, output, ".once", 2);
    try runner.stop(io, 4000);

    // Discovery takes place in the invocation directory before configured cwd is applied.
    try withCwdStart(&runner, a, io, cwd, &.{app});
    try waitCount(io, output, ".once", 3);
    try runner.stop(io, 4000);

    // CLI command replaces the array in TOML, preserving all literal arguments.
    try withCwdStart(&runner, a, io, cwd, &.{ app, "--", helper, "override", "literal arg" });
    try waitCount(io, output, ".override", 1);
    try runner.stop(io, 4000);

    const invalid = "command = ['never-start']\npoll-interval = 1\n";
    try base.writeFile(io, .{ .sub_path = "rewatch.toml", .data = invalid });
    const result = try std.process.run(a, io, .{ .argv = &.{ app, "--config", path }, .stderr_limit = .limited(4096) });
    try std.testing.expectEqual(@as(u8, 2), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, ":2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "poll-interval must be at least 10ms") != null);
    try std.testing.expectEqual(@as(usize, 3), try count(io, output, ".once"));

    // --no-config bypasses even malformed discovered config; help also bypasses loading.
    try withCwdStart(&runner, a, io, cwd, &.{ app, "--no-config", "--cwd", "configured project", "--", helper, "once" });
    try waitCount(io, output, ".once", 4);
    try runner.stop(io, 4000);
    const help = try std.process.run(a, io, .{ .argv = &.{ app, "--config", path, "--help" } });
    try std.testing.expect(help.term.success());
    const missing_path = try std.fs.path.join(a, &.{ cwd, "missing.toml" });
    const missing = try std.process.run(a, io, .{ .argv = &.{ app, "--config", missing_path } });
    try std.testing.expectEqual(@as(u8, 2), missing.term.exited);
    try base.deleteFile(io, "rewatch.toml");
}

fn withCwdStart(runner: *Runner, a: std.mem.Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !void {
    const previous = try std.process.currentPathAlloc(io, a);
    try std.process.setCurrentPath(io, cwd);
    defer std.process.setCurrentPath(io, previous) catch unreachable;
    try runner.start(a, io, argv);
}

fn expectStopped(a: std.mem.Allocator, io: Io, output: Io.Dir, names: []const []const u8) !void {
    const stamps = try a.alloc(Io.File.Stat, names.len);
    for (names, stamps) |name, *stamp| stamp.* = try output.statFile(io, name, .{});
    try sleep(io, 200);
    for (names, stamps) |name, stamp| {
        const after = try output.statFile(io, name, .{});
        try std.testing.expectEqual(stamp.mtime.nanoseconds, after.mtime.nanoseconds);
    }
}

fn count(io: Io, dir: Io.Dir, suffix: []const u8) !usize {
    const listing = try dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var iterator = listing.iterate();
    var total: usize = 0;
    while (try iterator.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, suffix)) {
        total += 1;
    };
    return total;
}

fn entries(a: std.mem.Allocator, io: Io, dir: Io.Dir, suffix: []const u8) ![]const []const u8 {
    const listing = try dir.openDir(io, ".", .{ .iterate = true });
    defer listing.close(io);
    var iterator = listing.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try iterator.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, suffix)) {
        try names.append(a, try a.dupe(u8, entry.name));
    };
    return names.toOwnedSlice(a);
}

fn waitCount(io: Io, dir: Io.Dir, suffix: []const u8, expected: usize) !void {
    const deadline = now(io) + 8000;
    while (now(io) < deadline) {
        const actual = try count(io, dir, suffix);
        if (actual == expected) return;
        if (actual > expected) return error.ExcessRestarts;
        try sleep(io, 20);
    }
    std.debug.print("timed out waiting for {d} {s} records\n", .{ expected, suffix });
    return error.TestTimeout;
}

fn sleep(io: Io, ms: u32) !void {
    try Io.sleep(io, .fromMilliseconds(ms), .awake);
}

fn now(io: Io) i64 {
    return Io.Clock.awake.now(io).toMilliseconds();
}
