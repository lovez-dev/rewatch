const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;

/// Returns a TCP listener; the caller closes it with Server.deinit(io).
/// Called synchronously during startup, before any process is spawned.
pub fn listen(io: Io, address: Io.net.IpAddress) !Io.net.Server {
    if (builtin.os.tag == .windows) return address.listen(io, .{});

    // Io's reuse_address also sets SO_REUSEPORT on POSIX. Only REUSEADDR
    // permits restarting after TIME_WAIT without sharing an active listener.
    const threaded = Io.Threaded;
    const flags = posix.SOCK.STREAM | if (builtin.os.tag == .linux) posix.SOCK.CLOEXEC else 0;
    const result = posix.system.socket(threaded.posixAddressFamily(&address), flags, posix.IPPROTO.TCP);
    try check(result);
    const fd: posix.fd_t = @intCast(result);
    errdefer threaded.closeFd(fd);

    if (builtin.os.tag != .linux)
        try check(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)));
    const enabled: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enabled));

    var storage: threaded.PosixAddress = undefined;
    var length = threaded.addressToPosix(&address, &storage);
    try check(posix.system.bind(fd, &storage.any, length));
    try check(posix.system.listen(fd, Io.net.default_kernel_backlog));
    try check(posix.system.getsockname(fd, &storage.any, &length));
    return .{ .socket = .{ .handle = fd, .address = threaded.addressFromPosix(&storage) }, .options = {} };
}

fn check(result: anytype) !void {
    switch (posix.errno(result)) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ACCES, .PERM => return error.AccessDenied,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => return error.SystemResources,
        .INTR => return error.Interrupted,
        else => |err| return posix.unexpectedErrno(err),
    }
}

test "listener excludes a second active listener and permits immediate rebinding" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var first = try listen(io, .{ .ip4 = .loopback(0) });
    var open = true;
    defer if (open) first.deinit(io);
    const address = first.socket.address;
    try std.testing.expect(address.getPort() != 0);
    // Close an unexpectedly successful duplicate before reporting failure.
    if (listen(io, address)) |duplicate| {
        var server = duplicate;
        server.deinit(io);
        return error.DuplicateListenerAccepted;
    } else |err| {
        try std.testing.expectEqual(error.AddressInUse, err);
    }
    first.deinit(io);
    open = false;
    var replacement = try listen(io, address);
    defer replacement.deinit(io);
    try std.testing.expect(address.eql(&replacement.socket.address));
}
