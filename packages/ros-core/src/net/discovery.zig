//! Discovery: the UDP beacon that tells the other devices this one is
//! here.
//!
//! There is no mDNS in the SDK, and no service registry on a restaurant's
//! LAN either. So a device broadcasts its hello card every five seconds
//! on port 45872, and every peer that hears one learns its address, its
//! role and the port its HTTP server bound.
//!
//! The beacon carries the same record as `GET /v1/hello`: one shape, two
//! carriers. A device that hears nothing for a while forgets the peer -
//! that is 9.4's job; this file only sends and receives.

const std = @import("std");
const protocol = @import("protocol.zig");

/// The limited broadcast address. A restaurant is one subnet; a device
/// that needs a different address passes it to `sendTo`.
pub const default_broadcast = "255.255.255.255";

pub const max_beacon_bytes = 512;

pub fn broadcastAddress() !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parseIp4(default_broadcast, protocol.beacon_port);
}

/// A socket that may send to a broadcast address. Binding to 0.0.0.0
/// with an ephemeral port means the OS picks the interface.
pub fn openSender(io: std.Io) !std.Io.net.Socket {
    var any = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    return any.bind(io, .{
        .mode = .dgram,
        .protocol = .udp,
        .allow_broadcast = true,
    });
}

/// A socket that listens for beacons on `port` - the beacon port by
/// default, or an ephemeral one in a test.
pub fn openReceiver(io: std.Io, port: u16) !std.Io.net.Socket {
    var any = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    return any.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

/// Send one hello card to an address.
pub fn sendTo(
    io: std.Io,
    socket: *const std.Io.net.Socket,
    host: []const u8,
    port: u16,
    hello: protocol.Hello,
) !void {
    var buffer: [max_beacon_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try protocol.encodeHello(&writer, hello);

    var target = try std.Io.net.IpAddress.parseIp4(host, port);
    try socket.send(io, &target, writer.buffered());
}

/// Send one hello card to the broadcast address.
pub fn sendBeacon(io: std.Io, socket: *const std.Io.net.Socket, hello: protocol.Hello) !void {
    var target = try broadcastAddress();
    var buffer: [max_beacon_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try protocol.encodeHello(&writer, hello);
    try socket.send(io, &target, writer.buffered());
}

/// Wait for a beacon. Null on a timeout, which is not an error: an empty
/// room is a normal room.
pub fn receiveBeacon(
    arena: std.mem.Allocator,
    io: std.Io,
    socket: *const std.Io.net.Socket,
    buffer: []u8,
    timeout_ms: i64,
) !?protocol.Hello {
    const incoming = socket.receiveTimeout(
        io,
        buffer,
        .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    ) catch |err| switch (err) {
        error.Timeout => return null,
        else => return err,
    };
    return try protocol.decodeHello(arena, incoming.data);
}

// ------------------------------------------------------------------ tests

test "one socket hears the beacon another sends" {
    const io = std.testing.io;

    var receiver = try openReceiver(io, 0);
    defer std.Io.net.Socket.close(&receiver, io);
    const port = receiver.address.getPort();
    try std.testing.expect(port != 0);

    var sender = try openSender(io);
    defer std.Io.net.Socket.close(&sender, io);

    const hello: protocol.Hello = .{
        .device = "dev-1",
        .role = .admin,
        .host = "127.0.0.1",
        .tcp = 45871,
        .app_version = "0.1.0",
    };
    try sendTo(io, &sender, "127.0.0.1", port, hello);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [max_beacon_bytes]u8 = undefined;
    const heard = (try receiveBeacon(arena_state.allocator(), io, &receiver, &buffer, 2000)).?;
    try std.testing.expectEqualStrings("dev-1", heard.device);
    try std.testing.expectEqual(protocol.DeviceRole.admin, heard.role);
    try std.testing.expectEqual(@as(u16, 45871), heard.tcp);
}

test "an empty room times out instead of failing" {
    const io = std.testing.io;
    var receiver = try openReceiver(io, 0);
    defer std.Io.net.Socket.close(&receiver, io);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [max_beacon_bytes]u8 = undefined;
    try std.testing.expect((try receiveBeacon(arena_state.allocator(), io, &receiver, &buffer, 50)) == null);
}
