const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const net = Io.net;
const tcp_listener = @import("platform/listener.zig");

pub const Options = struct { listen: []const u8, target: []const u8 };
const body_limit = 16 * 1024 * 1024;
const prefix = "/__rewatch/";
const max_connections = 32;

fn targetAuthority(target: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, target, "http://")) return error.InvalidProxyTarget;
    const raw_authority = target[7..];
    const authority = if (std.mem.endsWith(u8, raw_authority, "/")) raw_authority[0 .. raw_authority.len - 1] else raw_authority;
    if (std.mem.indexOfAny(u8, authority, "/?#@ \t\r\n") != null) return error.InvalidProxyTarget;
    return authority;
}

fn address(value: []const u8) !net.IpAddress {
    const parsed = net.IpAddress.parseLiteral(value) catch return error.InvalidProxyAddress;
    if (parsed.getPort() == 0) return error.InvalidProxyAddress;
    return parsed;
}

pub fn validate(options: Options) !void {
    const listener = try address(options.listen);
    const target = try address(try targetAuthority(options.target));
    if (listener.getPort() == target.getPort()) {
        const unspecified = switch (listener) {
            .ip4 => |ip| std.mem.eql(u8, &ip.bytes, &.{ 0, 0, 0, 0 }),
            .ip6 => |ip| std.mem.allEqual(u8, &ip.bytes, 0),
        };
        if (listener.eql(&target) or unspecified) return error.ProxyTargetsItself;
    }
}

pub const Proxy = struct {
    allocator: Allocator,
    io: Io,
    listener: net.Server,
    target: []const u8,
    session: [32]u8,
    // Only the main loop changes run_epoch. The readiness task publishes a matching epoch.
    run_epoch: std.atomic.Value(u64) = .init(0),
    ready_epoch: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u32) = .init(0),
    services: Io.Group = .init,
    connections: Io.Group = .init,

    pub fn start(a: Allocator, io: Io, options: Options) !*Proxy {
        try validate(options);
        const self = try a.create(Proxy);
        errdefer a.destroy(self);
        const target = try std.fmt.allocPrint(a, "http://{s}", .{try targetAuthority(options.target)});
        errdefer a.free(target);
        var random: [16]u8 = undefined;
        io.random(&random);
        const session = std.fmt.bytesToHex(random, .lower);
        const listen_address = try address(options.listen);
        self.* = .{
            .allocator = a,
            .io = io,
            .listener = try tcp_listener.listen(io, listen_address),
            .target = target,
            .session = session,
        };
        errdefer self.listener.deinit(io);
        errdefer self.services.cancel(io);
        try self.services.concurrent(io, acceptLoop, .{self});
        try self.services.concurrent(io, readinessLoop, .{self});
        return self;
    }

    pub fn setRunning(self: *Proxy, running: bool) void {
        const current = self.run_epoch.load(.acquire);
        if (running) {
            if (current & 1 == 0) self.run_epoch.store((current + 2) | 1, .release);
        } else {
            self.run_epoch.store(current & ~@as(u64, 1), .release);
        }
    }

    /// Cancel accept/probe first, then all requests. No task may retain self after this returns.
    pub fn stop(self: *Proxy) void {
        const a = self.allocator;
        self.services.cancel(self.io);
        self.connections.cancel(self.io);
        self.listener.deinit(self.io);
        a.free(self.target);
        a.destroy(self);
    }

    fn acceptLoop(self: *Proxy) Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.debug.print("[rewatch] proxy accept failed: {s}\n", .{@errorName(err)});
                    try Io.sleep(self.io, .fromMilliseconds(100), .awake);
                    continue;
                },
            };
            if (self.active.fetchAdd(1, .acq_rel) >= max_connections) {
                _ = self.active.fetchSub(1, .acq_rel);
                stream.close(self.io);
                continue;
            }
            self.connections.concurrent(self.io, connectionTask, .{ self, stream }) catch |err| {
                _ = self.active.fetchSub(1, .acq_rel);
                stream.close(self.io);
                if (err == error.Canceled) return error.Canceled;
            };
        }
    }

    fn connectionTask(self: *Proxy, stream: net.Stream) Io.Cancelable!void {
        defer stream.close(self.io);
        defer _ = self.active.fetchSub(1, .acq_rel);
        const Result = union(enum) { work: anyerror!void, timeout: Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select: Io.Select(Result) = .init(self.io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.work, serve, .{ self, stream }) catch return;
        select.concurrent(.timeout, delay, .{ self.io, 30_000 }) catch return;
        _ = try select.await();
    }

    fn readinessLoop(self: *Proxy) Io.Cancelable!void {
        var reported_error: ?anyerror = null;
        while (true) {
            const epoch = self.run_epoch.load(.acquire);
            if (epoch & 1 != 0 and self.ready_epoch.load(.acquire) != epoch) {
                const ready = probeWithTimeout(self) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => failure: {
                        if (reported_error == null or reported_error.? != err) {
                            std.debug.print("[rewatch] waiting for upstream: {s}\n", .{@errorName(err)});
                            reported_error = err;
                        }
                        break :failure false;
                    },
                };
                if (ready and self.run_epoch.load(.acquire) == epoch) {
                    reported_error = null;
                    self.ready_epoch.store(epoch, .release);
                }
            }
            try Io.sleep(self.io, .fromMilliseconds(250), .awake);
        }
    }

    fn probeWithTimeout(self: *Proxy) !bool {
        const Result = union(enum) { probe: anyerror!bool, timeout: Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select: Io.Select(Result) = .init(self.io, &buffer);
        defer select.cancelDiscard();
        try select.concurrent(.probe, probe, .{self});
        try select.concurrent(.timeout, delay, .{ self.io, 1000 });
        return switch (try select.await()) {
            .probe => |value| try value,
            .timeout => error.UpstreamTimeout,
        };
    }

    fn probe(self: *Proxy) !bool {
        var client: http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        var request = try client.request(.GET, try std.Uri.parse(self.target), .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer request.deinit();
        try request.sendBodiless();
        const response = try request.receiveHead(&.{});
        return @backingInt(response.head.status) < 500;
    }

    fn serve(self: *Proxy, stream: net.Stream) !void {
        var input_buffer: [16 * 1024]u8 = undefined;
        var output_buffer: [4096]u8 = undefined;
        var input = stream.reader(self.io, &input_buffer);
        var output = stream.writer(self.io, &output_buffer);
        var server: http.Server = .init(&input.interface, &output.interface);
        var request = try server.receiveHead();
        if (request.head.method == .CONNECT) return reply(&request, .not_implemented, "CONNECT is not supported\n");
        var headers_it = request.iterateHeaders();
        while (headers_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) return reply(&request, .not_implemented, "Protocol upgrades are not supported\n");
        }
        if (request.head.target.len == 0 or request.head.target[0] != '/' or std.mem.startsWith(u8, request.head.target, "//"))
            return reply(&request, .bad_request, "Expected an origin-form request target\n");
        if (std.mem.startsWith(u8, request.head.target, prefix)) {
            if (request.head.method != .GET and request.head.method != .HEAD) return reply(&request, .method_not_allowed, "Use GET or HEAD\n");
            const path = request.head.target[0 .. std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len];
            if (std.mem.eql(u8, path, prefix ++ "client.js")) {
                const query = std.mem.indexOfScalar(u8, request.head.target, '?') orelse return reply(&request, .bad_request, "Missing reload session\n");
                if (!std.mem.startsWith(u8, request.head.target[query + 1 ..], "session=")) return reply(&request, .bad_request, "Missing reload session\n");
                if (!std.mem.eql(u8, request.head.target[query + 1 + "session=".len ..], &self.session)) return reply(&request, .not_found, "Unknown reload session\n");
                return request.respond(client_script, .{
                    .keep_alive = false,
                    .extra_headers = &.{ .{ .name = "content-type", .value = "text/javascript; charset=utf-8" }, .{ .name = "cache-control", .value = "no-store" } },
                });
            }
            if (std.mem.eql(u8, path, prefix ++ "state")) {
                const epoch = self.run_epoch.load(.acquire);
                const ready = epoch & 1 != 0 and self.ready_epoch.load(.acquire) == epoch;
                var bytes: [192]u8 = undefined;
                const body = try std.fmt.bufPrint(&bytes, "{{\"session\":\"{s}\",\"generation\":{d},\"ready\":{s}}}", .{ &self.session, epoch >> 1, if (ready) "true" else "false" });
                return request.respond(body, .{ .keep_alive = false, .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
            }
            return reply(&request, .not_found, "Unknown reload endpoint\n");
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const epoch = self.run_epoch.load(.acquire);
        if (epoch & 1 == 0 or self.ready_epoch.load(.acquire) != epoch)
            return reply(&request, .bad_gateway, "Application is not ready\n");
        forward(self, a, &request, epoch >> 1, &self.session) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (err == error.DownstreamWriteFailed) return;
            if (err == error.RequestTooLarge) return reply(&request, .payload_too_large, "Request exceeds 16 MiB\n");
            if (err == error.InvalidRequestHeader) return reply(&request, .bad_request, "Invalid request header\n");
            return reply(&request, .bad_gateway, "Upstream request failed\n");
        };
    }
};

fn delay(io: Io, ms: u32) Io.Cancelable!void {
    try Io.sleep(io, .fromMilliseconds(ms), .awake);
}

fn reply(request: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{ .{ .name = "content-type", .value = "text/plain; charset=utf-8" }, .{ .name = "cache-control", .value = "no-store" } } });
}

fn hopHeader(name: []const u8, connection: []const u8) bool {
    for ([_][]const u8{ "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    var tokens = std.mem.splitScalar(u8, connection, ',');
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(name, std.mem.trim(u8, token, " \t"))) return true;
    return false;
}

fn headerValid(header: http.Header) bool {
    if (header.name.len == 0) return false;
    for (header.name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    for (header.value) |c| if ((c < 32 and c != '\t') or c == 127) return false;
    return true;
}

fn connectionValue(a: Allocator, iterator: http.HeaderIterator) ![]const u8 {
    var it = iterator;
    var value: std.ArrayList(u8) = .empty;
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
            if (value.items.len > 0) try value.append(a, ',');
            try value.appendSlice(a, header.value);
        }
    }
    return value.toOwnedSlice(a);
}

fn forward(self: *Proxy, a: Allocator, incoming: *http.Server.Request, generation: u64, session: []const u8) !void {
    const method = incoming.head.method;
    const target = try a.dupe(u8, incoming.head.target);
    const length = incoming.head.content_length;
    const has_body = length != null or incoming.head.transfer_encoding != .none;
    if (length) |size| if (size > body_limit) return error.RequestTooLarge;
    var headers: std.ArrayList(http.Header) = .empty;
    const connection = try connectionValue(a, incoming.iterateHeaders());
    var iterator = incoming.iterateHeaders();
    while (iterator.next()) |header| {
        if (!headerValid(header)) return error.InvalidRequestHeader;
        if (hopHeader(header.name, connection)) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length") or std.ascii.eqlIgnoreCase(header.name, "accept-encoding") or std.ascii.eqlIgnoreCase(header.name, "expect")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "host")) continue;
        try headers.append(a, .{ .name = try a.dupe(u8, header.name), .value = try a.dupe(u8, header.value) });
    }
    var transfer: [4096]u8 = undefined;
    var body: []u8 = &.{};
    if (has_body) {
        const body_reader = try incoming.readerExpectContinue(&transfer);
        body = body_reader.allocRemaining(a, .limited(body_limit)) catch |err| switch (err) {
            error.StreamTooLong => return error.RequestTooLarge,
            else => return err,
        };
    }
    var client: http.Client = .{ .allocator = a, .io = self.io, .read_buffer_size = 16 * 1024 };
    defer client.deinit();
    const uri = try std.Uri.parse(try std.fmt.allocPrint(a, "{s}{s}", .{ self.target, target }));
    var outgoing = try client.request(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .extra_headers = headers.items,
        .headers = .{ .host = .default, .authorization = .omit, .user_agent = .omit, .connection = .{ .override = "close" }, .accept_encoding = .{ .override = "identity" }, .content_type = .omit },
    });
    defer outgoing.deinit();
    if (has_body) try outgoing.sendBodyComplete(body) else try outgoing.sendBodiless();
    var response = try outgoing.receiveHead(&.{});
    const status = response.head.status;
    if (status.class() == .informational) return error.UnsupportedUpstreamUpgrade;
    const no_body = method == .HEAD or status == .no_content or status == .not_modified;
    const content_type = response.head.content_type orelse "";
    const content_encoding = response.head.content_encoding;
    const is_html = std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t"), "text/html");
    const charset_ok = htmlCharsetIsAsciiCompatible(content_type);
    const inject_candidate = !no_body and status != .partial_content and is_html and charset_ok and content_encoding == .identity;
    var response_headers: std.ArrayList(http.Header) = .empty;
    const response_connection = try connectionValue(a, response.head.iterateHeaders());
    iterator = response.head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!headerValid(header)) return error.InvalidUpstreamHeader;
        if (hopHeader(header.name, response_connection)) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            if (method == .HEAD or status == .not_modified) try response_headers.append(a, .{ .name = try a.dupe(u8, header.name), .value = try a.dupe(u8, header.value) });
            continue;
        }
        try response_headers.append(a, .{ .name = try a.dupe(u8, header.name), .value = try a.dupe(u8, header.value) });
    }
    var response_body: []const u8 = "";
    var inject = false;
    if (!no_body) {
        const raw = try response.reader(&transfer).allocRemaining(a, .limited(body_limit));
        inject = inject_candidate and !hasUnicodeBom(raw);
        response_body = if (inject) try injectScript(a, raw, generation, session) else raw;
    }
    if (inject) {
        var i: usize = 0;
        while (i < response_headers.items.len) {
            const header = response_headers.items[i];
            if (std.ascii.eqlIgnoreCase(header.name, "etag") or std.ascii.eqlIgnoreCase(header.name, "content-md5") or std.ascii.eqlIgnoreCase(header.name, "digest") or std.ascii.eqlIgnoreCase(header.name, "cache-control") or std.ascii.eqlIgnoreCase(header.name, "expires")) {
                _ = response_headers.orderedRemove(i);
            } else i += 1;
        }
        try response_headers.append(a, .{ .name = "cache-control", .value = "no-store" });
    }
    incoming.respond(response_body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = response_headers.items,
        // HEAD/204/304 have distinct length rules; preserve permitted upstream metadata only.
        .transfer_encoding = if (no_body) .none else null,
    }) catch return error.DownstreamWriteFailed;
}

fn htmlCharsetIsAsciiCompatible(content_type: []const u8) bool {
    var params = std.mem.splitScalar(u8, content_type, ';');
    _ = params.next();
    while (params.next()) |param| {
        const separator = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, param[0..separator], " \t"), "charset")) continue;
        const charset = std.mem.trim(u8, param[separator + 1 ..], " \t\"");
        if (charset.len == 0) return false;
        return std.ascii.eqlIgnoreCase(charset, "utf-8") or
            std.ascii.eqlIgnoreCase(charset, "us-ascii") or
            std.ascii.eqlIgnoreCase(charset, "windows-1252") or
            std.ascii.eqlIgnoreCase(charset, "iso-8859-1");
    }
    return true;
}

fn hasUnicodeBom(body: []const u8) bool {
    return std.mem.startsWith(u8, body, &.{ 0x00, 0x00, 0xfe, 0xff }) or
        std.mem.startsWith(u8, body, &.{ 0xff, 0xfe, 0x00, 0x00 }) or
        std.mem.startsWith(u8, body, &.{ 0xfe, 0xff }) or
        std.mem.startsWith(u8, body, &.{ 0xff, 0xfe });
}

fn injectScript(a: Allocator, body: []const u8, generation: u64, session: []const u8) ![]const u8 {
    const script = try std.fmt.allocPrint(a, "<script src=\"{s}client.js?session={s}\" data-generation=\"{d}\"></script>", .{ prefix, session, generation });
    defer a.free(script);
    const at = indexIgnoreCase(body, "</body>") orelse body.len;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ body[0..at], script, body[at..] });
}

fn indexIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    return null;
}

const client_script =
    \\(()=>{const u=new URL(document.currentScript.src),stateUrl=new URL('state',u),generation=Number(document.currentScript.dataset.generation),session=u.searchParams.get('session');async function check(){try{const r=await fetch(stateUrl,{cache:'no-store'});if(r.ok){const s=await r.json();if(s.ready&&(s.session!==session||s.generation!==generation)){location.reload();return}}}catch{}setTimeout(check,500)}check()})();
;

test "proxy options reject unsupported origins and self forwarding" {
    try validate(.{ .listen = "127.0.0.1:3000", .target = "http://127.0.0.1:8080/" });
    try std.testing.expectError(error.InvalidProxyTarget, validate(.{ .listen = "127.0.0.1:3000", .target = "https://127.0.0.1:8080" }));
    try std.testing.expectError(error.InvalidProxyTarget, validate(.{ .listen = "127.0.0.1:3000", .target = "http://127.0.0.1:8080/path" }));
    try std.testing.expectError(error.InvalidProxyTarget, validate(.{ .listen = "127.0.0.1:3000", .target = "http://127.0.0.1:8080//" }));
    try std.testing.expectError(error.ProxyTargetsItself, validate(.{ .listen = "0.0.0.0:3000", .target = "http://127.0.0.1:3000" }));
}

test "HTML injection preserves body and embeds page generation" {
    const a = std.testing.allocator;
    const result = try injectScript(a, "<BODY>hello</BODY>", 12, "session");
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "?session=session\" data-generation=\"12") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "</BODY>"));
    try std.testing.expect(hopHeader("X-Hop", "keep-alive, x-hop"));
}

test "HTML injection is limited to ASCII-compatible encodings" {
    try std.testing.expect(htmlCharsetIsAsciiCompatible("text/html; charset=utf-8"));
    try std.testing.expect(htmlCharsetIsAsciiCompatible("text/html; charset=windows-1252"));
    try std.testing.expect(!htmlCharsetIsAsciiCompatible("text/html; charset=UTF-16LE"));
    try std.testing.expect(!htmlCharsetIsAsciiCompatible("text/html; charset=UTF-32"));
    try std.testing.expect(hasUnicodeBom(&.{ 0xff, 0xfe, 0x3c, 0x00 }));
    try std.testing.expect(!hasUnicodeBom("<html>"));
}
