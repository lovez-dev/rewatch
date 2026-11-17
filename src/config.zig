const std = @import("std");
const cli = @import("cli.zig");
const Allocator = std.mem.Allocator;

pub const default_path = "rewatch.toml";

/// Read before changing cwd. A missing automatically discovered file is optional;
/// an explicitly requested file and all malformed files are errors.
pub fn load(a: Allocator, io: std.Io, options: *cli.Options) !?Document {
    if (options.no_config) return null;
    const path = options.config_path orelse default_path;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound and options.config_path == null) return null;
        std.debug.print("[rewatch] {s}: {s}\n", .{ path, @errorName(err) });
        return error.ConfigReadFailed;
    };
    defer a.free(bytes);
    var diagnostic: Diagnostic = .{};
    var document = parse(a, bytes, &diagnostic) catch |err| {
        if (err == error.InvalidConfig) std.debug.print("[rewatch] {s}:{d}:{d}: {s}\n", .{ path, diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    errdefer document.deinit();
    const current = try std.process.currentPathAlloc(io, a);
    defer a.free(current);
    const absolute = try std.fs.path.resolve(a, &.{ current, path });
    defer a.free(absolute);
    try document.apply(a, options, std.fs.path.dirname(absolute).?);
    return document;
}

pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    message: []const u8 = "invalid configuration",
};

const Values = struct {
    command: ?[]const []const u8 = null,
    pre_commands: ?[]const []const []const u8 = null,
    watch: ?[]const []const u8 = null,
    ignore: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    debounce: ?u32 = null,
    poll_interval: ?u32 = null,
    stop_timeout: ?u32 = null,
    proxy_target: ?[]const u8 = null,
    proxy_listen: ?[]const u8 = null,
    watcher: ?@import("watch/types.zig").Mode = null,
};

pub const Document = struct {
    // All decoded strings, arrays and resolved paths live until deinit.
    arena: std.heap.ArenaAllocator,
    values: Values,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// CLI arrays replace configured arrays; omitted CLI values retain the config.
    /// config_dir is absolute. An explicit CLI cwd remains relative to invocation cwd.
    pub fn apply(self: *Document, a: Allocator, options: *cli.Options, config_dir: []const u8) !void {
        const v = self.values;
        if (options.command.len == 0) if (v.command) |command| {
            options.command = command;
        };
        options.pre_commands = if (options.no_pre_command) &.{} else v.pre_commands orelse &.{};
        if (options.proxy_target == null) options.proxy_target = v.proxy_target;
        if (options.proxy_listen == null) options.proxy_listen = v.proxy_listen;
        if (options.watches.items.len == 0) if (v.watch) |watch| {
            try options.watches.appendSlice(a, watch);
        };
        if (options.ignores.items.len == 0) if (v.ignore) |ignore| {
            try options.ignores.appendSlice(a, ignore);
        };
        if (options.cwd == null) options.cwd = try std.fs.path.resolve(self.arena.allocator(), &.{ config_dir, v.cwd orelse "." });
        if (!options.provided.debounce) options.debounce_ms = v.debounce orelse options.debounce_ms;
        if (!options.provided.poll) options.poll_ms = v.poll_interval orelse options.poll_ms;
        if (!options.provided.stop) options.stop_ms = v.stop_timeout orelse options.stop_ms;
        if (!options.provided.watcher) options.watcher = v.watcher orelse options.watcher;
    }
};

/// Parse this application's flat TOML schema. Unsupported value types and tables
/// are rejected; no unknown fields are silently discarded. Input may be freed on return.
pub fn parse(a: Allocator, input: []const u8, diagnostic: *Diagnostic) !Document {
    var document: Document = .{ .arena = std.heap.ArenaAllocator.init(a), .values = .{} };
    errdefer document.deinit();
    var parser: Parser = .{ .input = input, .allocator = document.arena.allocator(), .diagnostic = diagnostic };
    if (!std.unicode.utf8ValidateSlice(input)) return parser.fail("configuration must be valid UTF-8");
    // A UTF-8 BOM is not part of TOML 1.0.
    if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) return parser.fail("UTF-8 BOM is not supported; save without BOM");
    while (true) {
        try parser.space(true);
        if (parser.pos == input.len) break;
        if (input[parser.pos] == '[') return parser.fail("tables are not supported; use top-level configuration keys");
        const key = try parser.key();
        const Field = enum { command, watch, ignore, cwd, debounce, poll_interval, stop_timeout, pre_command, proxy_target, proxy_listen, watcher };
        const field: Field = if (std.mem.eql(u8, key, "proxy-target")) .proxy_target else if (std.mem.eql(u8, key, "proxy-listen")) .proxy_listen else if (std.mem.eql(u8, key, "pre-command")) .pre_command else if (std.mem.eql(u8, key, "poll-interval")) .poll_interval else if (std.mem.eql(u8, key, "stop-timeout")) .stop_timeout else blk: {
            for ([_]Field{ .command, .watch, .ignore, .cwd, .debounce, .watcher }) |f| {
                if (std.mem.eql(u8, key, @tagName(f))) break :blk f;
            }
            return parser.fail("unknown configuration key");
        };
        const bit = @as(u16, 1) << @intCast(@backingInt(field));
        if (parser.seen & bit != 0) return parser.fail("duplicate configuration key");
        parser.seen |= bit;
        try parser.space(false);
        try parser.expect('=', "expected '=' after key");
        try parser.space(false);
        switch (field) {
            .watcher => {
                const value = try parser.string(false);
                document.values.watcher = std.meta.stringToEnum(@import("watch/types.zig").Mode, value) orelse return parser.fail("watcher must be 'auto' or 'poll'");
            },
            .proxy_target, .proxy_listen => {
                const value = try parser.string(false);
                if (value.len == 0) return parser.fail("proxy addresses must not be empty");
                if (field == .proxy_target) document.values.proxy_target = value else document.values.proxy_listen = value;
            },
            .pre_command => document.values.pre_commands = try parser.commands(),
            .command, .watch, .ignore => {
                const items = try parser.array();
                switch (field) {
                    .command => {
                        if (items.len == 0 or items[0].len == 0) return parser.fail("command must contain a nonempty program name");
                        document.values.command = items;
                    },
                    .watch => {
                        if (items.len == 0) return parser.fail("watch must contain at least one path");
                        for (items) |item| if (item.len == 0) return parser.fail("watch paths must not be empty");
                        document.values.watch = items;
                    },
                    .ignore => {
                        for (items) |item| cli.validateIgnore(item) catch return parser.fail("invalid ignore pattern");
                        document.values.ignore = items;
                    },
                    else => unreachable,
                }
            },
            .cwd => {
                const cwd = try parser.string(false);
                if (cwd.len == 0) return parser.fail("cwd must not be empty");
                document.values.cwd = cwd;
            },
            .debounce, .poll_interval, .stop_timeout => {
                const ms = try parser.duration();
                switch (field) {
                    .debounce => document.values.debounce = ms,
                    .poll_interval => {
                        if (ms < 10) return parser.fail("poll-interval must be at least 10ms");
                        document.values.poll_interval = ms;
                    },
                    .stop_timeout => document.values.stop_timeout = ms,
                    else => unreachable,
                }
            },
        }
        try parser.space(false);
        if (parser.pos < input.len and input[parser.pos] != '\n' and input[parser.pos] != '\r') return parser.fail("expected a newline after value");
    }
    if (document.values.proxy_target != null or document.values.proxy_listen != null) {
        @import("proxy.zig").validate(.{
            .target = document.values.proxy_target orelse "http://127.0.0.1:8080",
            .listen = document.values.proxy_listen orelse "127.0.0.1:3000",
        }) catch return parser.fail("invalid proxy address; use an HTTP origin and IP:port listen address");
    }
    return document;
}

const Parser = struct {
    input: []const u8,
    allocator: Allocator,
    diagnostic: *Diagnostic,
    pos: usize = 0,
    seen: u16 = 0,

    fn fail(self: *Parser, message: []const u8) error{InvalidConfig} {
        var line: usize = 1;
        var column: usize = 1;
        for (self.input[0..self.pos]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        self.diagnostic.* = .{ .line = line, .column = column, .message = message };
        return error.InvalidConfig;
    }

    fn expect(self: *Parser, c: u8, message: []const u8) !void {
        if (self.pos == self.input.len or self.input[self.pos] != c) return self.fail(message);
        self.pos += 1;
    }

    fn newline(self: *Parser) !void {
        if (self.input[self.pos] == '\r') {
            self.pos += 1;
            try self.expect('\n', "bare carriage return is not valid TOML");
        } else self.pos += 1;
    }

    fn space(self: *Parser, multiline: bool) !void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t' => self.pos += 1,
                '#' => {
                    while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') : (self.pos += 1) {
                        const c = self.input[self.pos];
                        if ((c < 0x20 and c != '\t') or c == 0x7f) return self.fail("invalid control character in comment");
                    }
                },
                '\n', '\r' => if (multiline) try self.newline() else return,
                else => return,
            }
        }
    }

    fn key(self: *Parser) ![]const u8 {
        if (self.input[self.pos] == '"' or self.input[self.pos] == '\'') return self.string(true);
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
        }
        if (self.pos == start) return self.fail("expected a configuration key");
        return self.input[start..self.pos];
    }

    fn array(self: *Parser) ![]const []const u8 {
        try self.expect('[', "expected an array of strings");
        var items: std.ArrayList([]const u8) = .empty;
        try self.space(true);
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            try items.append(self.allocator, try self.string(false));
            try self.space(true);
            if (self.pos < self.input.len and self.input[self.pos] == ']') break;
            try self.expect(',', "expected ',' between array elements");
            try self.space(true);
        }
        try self.expect(']', "unterminated array");
        return items.toOwnedSlice(self.allocator);
    }

    fn commands(self: *Parser) ![]const []const []const u8 {
        const start = self.pos;
        try self.expect('[', "expected an array of command argument arrays");
        try self.space(true);
        var commands_list: std.ArrayList([]const []const u8) = .empty;
        // Preserve the original single-command shorthand by normalizing it here.
        if (self.pos < self.input.len and (self.input[self.pos] == '"' or self.input[self.pos] == '\'')) {
            self.pos = start;
            const command = try self.array();
            if (command[0].len == 0) return self.fail("pre-command executable must not be empty");
            try commands_list.append(self.allocator, command);
            return commands_list.toOwnedSlice(self.allocator);
        }
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const command = try self.array();
            if (command.len == 0 or command[0].len == 0) return self.fail("each pre-command must contain a nonempty executable");
            try commands_list.append(self.allocator, command);
            try self.space(true);
            if (self.pos < self.input.len and self.input[self.pos] == ']') break;
            try self.expect(',', "expected ',' between pre-commands");
            try self.space(true);
        }
        try self.expect(']', "unterminated pre-command array");
        return commands_list.toOwnedSlice(self.allocator);
    }

    fn string(self: *Parser, is_key: bool) ![]const u8 {
        if (self.pos == self.input.len) return self.fail("expected a string");
        const quote = self.input[self.pos];
        if (quote != '"' and quote != '\'') return self.fail("expected a quoted string");
        self.pos += 1;
        const multiline = self.pos + 1 < self.input.len and self.input[self.pos] == quote and self.input[self.pos + 1] == quote;
        if (multiline) {
            if (is_key) return self.fail("multiline strings cannot be keys");
            self.pos += 2;
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) try self.newline();
        }
        var bytes: std.ArrayList(u8) = .empty;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == quote) {
                var count: usize = 0;
                while (self.pos + count < self.input.len and self.input[self.pos + count] == quote) : (count += 1) {}
                if (!multiline) {
                    self.pos += 1;
                    return bytes.toOwnedSlice(self.allocator);
                }
                if (count >= 3) {
                    if (count > 5) return self.fail("too many closing quotes");
                    try bytes.appendNTimes(self.allocator, quote, count - 3);
                    self.pos += count;
                    return bytes.toOwnedSlice(self.allocator);
                }
                self.pos += count;
                try bytes.appendNTimes(self.allocator, quote, count);
            } else if (c == '\n' or c == '\r') {
                if (!multiline) return self.fail("newline in a single-line string");
                try self.newline();
                try bytes.append(self.allocator, '\n');
            } else if (c == '\\' and quote == '"') {
                self.pos += 1;
                if (multiline and self.pos < self.input.len and std.mem.indexOfScalar(u8, " \t\r\n", self.input[self.pos]) != null) {
                    var found_newline = false;
                    while (self.pos < self.input.len) {
                        switch (self.input[self.pos]) {
                            ' ', '\t' => self.pos += 1,
                            '\r', '\n' => {
                                try self.newline();
                                found_newline = true;
                            },
                            else => break,
                        }
                    }
                    if (!found_newline) return self.fail("multiline continuation must include a newline");
                    continue;
                }
                if (self.pos == self.input.len) return self.fail("unterminated escape sequence");
                const escaped = self.input[self.pos];
                self.pos += 1;
                switch (escaped) {
                    'b' => try bytes.append(self.allocator, 8),
                    't' => try bytes.append(self.allocator, '\t'),
                    'n' => try bytes.append(self.allocator, '\n'),
                    'f' => try bytes.append(self.allocator, 12),
                    'r' => try bytes.append(self.allocator, '\r'),
                    '"', '\\' => try bytes.append(self.allocator, escaped),
                    'u', 'U' => {
                        const length: usize = if (escaped == 'u') 4 else 8;
                        if (self.input.len - self.pos < length) return self.fail("incomplete Unicode escape");
                        const digits = self.input[self.pos..][0..length];
                        for (digits) |digit| if (!std.ascii.isHex(digit)) return self.fail("invalid Unicode escape");
                        const code = std.fmt.parseInt(u32, digits, 16) catch return self.fail("invalid Unicode escape");
                        self.pos += length;
                        if (code == 0 or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return self.fail("Unicode escape is not a supported scalar value");
                        var encoded: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(@intCast(code), &encoded) catch return self.fail("invalid Unicode scalar");
                        try bytes.appendSlice(self.allocator, encoded[0..len]);
                    },
                    else => return self.fail("invalid TOML escape sequence"),
                }
            } else {
                if ((c < 0x20 and c != '\t') or c == 0x7f) return self.fail("invalid control character in string");
                self.pos += 1;
                try bytes.append(self.allocator, c);
            }
        }
        return self.fail("unterminated string");
    }

    fn duration(self: *Parser) !u32 {
        if (self.pos < self.input.len and (self.input[self.pos] == '"' or self.input[self.pos] == '\'')) {
            const value = try self.string(false);
            return cli.duration(value) catch return self.fail("expected an integer duration such as '150ms' or '2s'");
        }
        const start = self.pos;
        while (self.pos < self.input.len and std.mem.indexOfScalar(u8, " \t\r\n#", self.input[self.pos]) == null) : (self.pos += 1) {}
        const token = self.input[start..self.pos];
        if (token.len == 0) return self.fail("expected a duration string or integer milliseconds");
        var digits = token;
        if (digits[0] == '+') digits = digits[1..];
        var base: u8 = 10;
        if (std.mem.startsWith(u8, digits, "0x")) {
            base = 16;
        } else if (std.mem.startsWith(u8, digits, "0o")) {
            base = 8;
        } else if (std.mem.startsWith(u8, digits, "0b")) base = 2;
        if (base != 10) {
            if (digits.len != token.len) return self.fail("base-prefixed integers cannot have a sign");
            digits = digits[2..];
        } else if (digits.len > 1 and digits[0] == '0') return self.fail("leading zeros are not valid decimal integers");
        if (digits.len == 0) return self.fail("expected integer milliseconds");
        var number: u32 = 0;
        var previous_digit = false;
        for (digits, 0..) |c, index| {
            if (c == '_') {
                if (!previous_digit or index + 1 == digits.len) return self.fail("integer underscores must separate digits");
                previous_digit = false;
                continue;
            }
            const digit = std.fmt.charToDigit(c, base) catch return self.fail("expected nonnegative integer milliseconds");
            number = std.math.mul(u32, number, base) catch return self.fail("duration exceeds u32 milliseconds");
            number = std.math.add(u32, number, digit) catch return self.fail("duration exceeds u32 milliseconds");
            previous_digit = true;
        }
        return number;
    }
};

test "TOML strings arrays comments quoted keys and integer milliseconds" {
    const a = std.testing.allocator;
    const input =
        "# configuration\r\n" ++
        "'command' = [\r\n  \"program\", # comment\r\n  '', '\\literal', \"\\u4F60\\u597D\", \"quote\\\"here\",\r\n]\r\n" ++
        "watch = ['src', 'build.zig']\r\n" ++
        "ignore = ['*.tmp']\r\n" ++
        "cwd = '.'\r\n" ++
        "debounce = +1_000\r\n" ++
        "\"poll-interval\" = 0x1e\r\n" ++
        "stop-timeout = '2s'";
    var diagnostic: Diagnostic = .{};
    var document = try parse(a, input, &diagnostic);
    defer document.deinit();
    const command = document.values.command.?;
    try std.testing.expectEqual(@as(usize, 5), command.len);
    try std.testing.expectEqualStrings("", command[1]);
    try std.testing.expectEqualStrings("\\literal", command[2]);
    try std.testing.expectEqualStrings("\xe4\xbd\xa0\xe5\xa5\xbd", command[3]);
    try std.testing.expectEqualStrings("quote\"here", command[4]);
    try std.testing.expectEqual(@as(u32, 1000), document.values.debounce.?);
    try std.testing.expectEqual(@as(u32, 30), document.values.poll_interval.?);
    try std.testing.expectEqual(@as(u32, 2000), document.values.stop_timeout.?);
}

test "multiline strings normalize CRLF and trim escaped whitespace" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(
        a,
        "command = [\"\"\"\r\nprogram\"\"\", \"\"\"one\\ \r\n  two\"\"\", '''\r\nline1\r\nline2''']\n",
        &diagnostic,
    );
    defer document.deinit();
    try std.testing.expectEqualStrings("program", document.values.command.?[0]);
    try std.testing.expectEqualStrings("onetwo", document.values.command.?[1]);
    try std.testing.expectEqualStrings("line1\nline2", document.values.command.?[2]);
}

test "invalid TOML and schema errors are rejected before command execution" {
    const invalid = [_][]const u8{
        "command = 'program'",          "command = []",            "command = ['']",              "watch = []",              "watch = ['']",
        "ignore = ['!src']",            "cwd = ''",                "poll-interval = 9",           "debounce = -1",           "debounce = 01",
        "debounce = 1__0",              "debounce = 1_",           "debounce = 1.0",              "debounce = true",         "debounce = 4294967296",
        "debounce = '4294967295s'",     "debounce = +0xff",        "command = ['x' 'y']",         "command = ['x'",          "command = ['x'] trailing",
        "command = [\"\\q\"]",          "command = [\"\\uD800\"]", "command = [\"\\U00110000\"]", "command = [\"\\u0000\"]", "command = [\"\xff\"]",
        "command = [\"line\nbreak\"]",  "[watch]\n",               "unknown = 'x'",               "command.name = 'x'",      "debounce = 1\ndebounce = 2",
        "debounce = 1\n'debounce' = 2", "debounce = 1\r",          "\xef\xbb\xbfdebounce = 1",    "# bad\x7f\n",             "command = [\"\"\"x\\ \"\"\"]",
    };
    for (invalid) |input| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, input, &diagnostic));
        try std.testing.expect(diagnostic.message.len > 0);
    }
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "# first\nunknown = 1", &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.line);
}

test "CLI values override config including arrays zero durations and command" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(
        a,
        "command = ['configured']\nwatch = ['configured']\nignore = ['*.tmp']\ncwd = 'project'\ndebounce = 300\npoll-interval = 500\nstop-timeout = 1000",
        &diagnostic,
    );
    defer document.deinit();
    var options = try cli.parse(a, &.{ "--watch", "cli", "--ignore", "*.log", "--debounce", "0", "--stop-timeout", "0", "--cwd", "override", "--", "cli-command", "arg" });
    defer options.deinit(a);
    try document.apply(a, &options, "/config");
    try cli.validate(a, &options);
    try std.testing.expectEqualStrings("cli", options.watches.items[0]);
    try std.testing.expectEqual(@as(usize, 1), options.watches.items.len);
    try std.testing.expectEqualStrings("*.log", options.ignores.items[0]);
    try std.testing.expectEqualStrings("cli-command", options.command[0]);
    try std.testing.expectEqualStrings("override", options.cwd.?);
    try std.testing.expectEqual(@as(u32, 0), options.debounce_ms);
    try std.testing.expectEqual(@as(u32, 0), options.stop_ms);
    try std.testing.expectEqual(@as(u32, 500), options.poll_ms);
}

test "config supplies defaults and paths remain valid after source is freed" {
    const a = std.testing.allocator;
    const input = try a.dupe(u8, "command = ['program', 'arg']\nwatch = ['src']\nignore = []\ncwd = 'project'");
    var diagnostic: Diagnostic = .{};
    var document = parse(a, input, &diagnostic) catch |err| {
        a.free(input);
        return err;
    };
    a.free(input);
    defer document.deinit();
    var options = try cli.parse(a, &.{});
    defer options.deinit(a);
    const current = try std.process.currentPathAlloc(std.testing.io, a);
    defer a.free(current);
    try document.apply(a, &options, current);
    try cli.validate(a, &options);
    try std.testing.expectEqualStrings("program", options.command[0]);
    try std.testing.expectEqualStrings("src", options.watches.items[0]);
    const expected = try std.fs.path.resolve(a, &.{ current, "project" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, options.cwd.?);
    try std.testing.expectEqual(@as(u32, 150), options.debounce_ms);
}

test "pre-command parses argv or an empty array and can be disabled on CLI" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(a, "pre-command = ['zig', 'build', '']\ncommand = ['app']", &diagnostic);
    defer document.deinit();
    var options = try cli.parse(a, &.{});
    defer options.deinit(a);
    try document.apply(a, &options, "/config");
    try cli.validate(a, &options);
    try std.testing.expectEqualStrings("zig", options.pre_commands[0][0]);
    try std.testing.expectEqualStrings("", options.pre_commands[0][2]);
    var disabled = try cli.parse(a, &.{"--no-pre-command"});
    defer disabled.deinit(a);
    try document.apply(a, &disabled, "/config");
    try cli.validate(a, &disabled);
    try std.testing.expectEqual(@as(usize, 0), disabled.pre_commands.len);
    var empty = try parse(a, "pre-command = []", &diagnostic);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.values.pre_commands.?.len);
    for ([_][]const u8{ "pre-command = ['']", "pre-command = 'zig build'", "pre-command = [[]]", "pre-command = [['']]", "pre-command = []\npre-command = []", "pre-command = [['zig'], 'build']", "pre-command = ['zig', ['build']]", "pre-command = [[['zig']]]" }) |input| {
        try std.testing.expectError(error.InvalidConfig, parse(a, input, &diagnostic));
    }
}

test "multiple pre-commands preserve each argument array" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(
        a,
        "pre-command = [\n ['generator', '--output', 'a b', ''], # step 1\n [\"zig\", \"build\", \"-Doptimize=Debug\"],\n]\ncommand = ['app']",
        &diagnostic,
    );
    defer document.deinit();
    var options = try cli.parse(a, &.{});
    defer options.deinit(a);
    try document.apply(a, &options, "/config");
    try cli.validate(a, &options);
    try std.testing.expectEqual(@as(usize, 2), options.pre_commands.len);
    try std.testing.expectEqualStrings("a b", options.pre_commands[0][2]);
    try std.testing.expectEqualStrings("", options.pre_commands[0][3]);
    try std.testing.expectEqualStrings("zig", options.pre_commands[1][0]);
    try std.testing.expectEqualStrings("-Doptimize=Debug", options.pre_commands[1][2]);
}

test "proxy configuration preserves omitted CLI fields and validates overridden values" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(a, "proxy-target = 'http://127.0.0.1:8080'\nproxy-listen = '127.0.0.1:3000'\ncommand = ['server']", &diagnostic);
    defer document.deinit();
    var options = try cli.parse(a, &.{ "--proxy-listen", "127.0.0.1:4000" });
    defer options.deinit(a);
    try document.apply(a, &options, "/config");
    try cli.validate(a, &options);
    try std.testing.expectEqualStrings("127.0.0.1:4000", options.proxy_listen.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", options.proxy_target.?);
    for ([_][]const u8{
        "proxy-target = ''",                           "proxy-listen = ''",                                                              "proxy-target = ['http://127.0.0.1:8080']",
        "proxy-target = 'https://127.0.0.1:8080'",     "proxy-listen = '127.0.0.1:0'",                                                   "proxy-target = 'http://127.0.0.1:8080/path'",
        "proxy-target = 'http://user@127.0.0.1:8080'", "proxy-target = 'http://127.0.0.1:8080'\nproxy-target = 'http://127.0.0.1:8081'",
    }) |input| try std.testing.expectError(error.InvalidConfig, parse(a, input, &diagnostic));
}

test "watcher mode merges with explicit CLI overrides and validates schema" {
    const a = std.testing.allocator;
    var diagnostic: Diagnostic = .{};
    var document = try parse(a, "watcher = 'poll'\ncommand = ['app']", &diagnostic);
    defer document.deinit();
    var options = try cli.parse(a, &.{});
    defer options.deinit(a);
    try document.apply(a, &options, "/config");
    try std.testing.expectEqual(.poll, options.watcher);
    var override = try cli.parse(a, &.{ "--watcher", "auto" });
    defer override.deinit(a);
    try document.apply(a, &override, "/config");
    try std.testing.expectEqual(.auto, override.watcher);
    for ([_][]const u8{ "watcher = 'native'", "watcher = true", "watcher = 'auto'\nwatcher = 'poll'" }) |input|
        try std.testing.expectError(error.InvalidConfig, parse(a, input, &diagnostic));
}
