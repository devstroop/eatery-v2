//! The dialing half of the wire: the URLs this app asks for, and the
//! bodies it reads back.
//!
//! The request itself is `fx.fetch`, because the SDK already speaks
//! HTTP and the response arrives as a `Msg`. That is a deliberate choice
//! rather than a shortcut: the client would otherwise need its own
//! socket, its own TLS story and its own cancellation, and the fetch
//! already has all three. See `architecture/12` - "Why the client is
//! `fx.fetch` and not a socket".
//!
//! So this module is pure: it builds the URL, and it parses the NDJSON
//! the peer answers with. Nothing here touches the network, which is
//! what makes it testable with no socket at all.

const std = @import("std");
const cursor_mod = @import("cursor.zig");
const record = @import("record.zig");
const protocol = @import("protocol.zig");

pub const max_url_bytes = 512;

/// `http://<host>:<port>`
pub fn formatBase(buffer: []u8, host: []const u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://{s}:{d}", .{ host, port });
}

/// `http://<host>:<port>/v1/hello`
pub fn formatHello(buffer: []u8, host: []const u8, port: u16) ![]const u8 {
    return std.fmt.bufPrint(buffer, "http://{s}:{d}{s}", .{ host, port, protocol.endpoints.hello });
}

/// `http://<host>:<port>/v1/ops?since=<cursor>`
///
/// An empty cursor is written as `since=` with nothing after it, which
/// means "everything you have" rather than "nothing at all".
pub fn formatOps(buffer: []u8, host: []const u8, port: u16, cursor: *const cursor_mod.Vector) ![]const u8 {
    var cursor_buffer: [cursor_mod.max_devices * (cursor_mod.max_device_id_len + 24)]u8 = undefined;
    var writer = std.Io.Writer.fixed(&cursor_buffer);
    try cursor.write(&writer);

    return std.fmt.bufPrint(
        buffer,
        "http://{s}:{d}{s}?since={s}",
        .{ host, port, protocol.endpoints.ops, writer.buffered() },
    );
}

/// `http://<host>:<port>/v1/reference?after=<version>`
pub fn formatReference(buffer: []u8, host: []const u8, port: u16, after: u64) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "http://{s}:{d}{s}?after={d}",
        .{ host, port, protocol.endpoints.reference, after },
    );
}

/// Parse an NDJSON body into operations. A blank line is skipped, and a
/// malformed line is an error: a peer that sends half a record must be
/// told, not half-applied.
pub fn decodeOps(arena: std.mem.Allocator, body: []const u8) ![]record.Op {
    var ops: std.ArrayList(record.Op) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try ops.append(arena, try record.decode(arena, trimmed));
    }
    return ops.toOwnedSlice(arena);
}

// ------------------------------------------------------------------ tests

test "the URLs name the endpoint and carry the whole vector cursor" {
    var buffer: [max_url_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("http://10.0.0.4:45871", try formatBase(&buffer, "10.0.0.4", 45871));
    try std.testing.expectEqualStrings("http://10.0.0.4:45871/v1/hello", try formatHello(&buffer, "10.0.0.4", 45871));

    var cursor: cursor_mod.Vector = .{};
    try std.testing.expectEqualStrings(
        "http://10.0.0.4:45871/v1/ops?since=",
        try formatOps(&buffer, "10.0.0.4", 45871, &cursor),
    );

    try cursor.observe("dev-1", 1042);
    try cursor.observe("dev-3", 87);
    try std.testing.expectEqualStrings(
        "http://10.0.0.4:45871/v1/ops?since=dev-1:1042,dev-3:87",
        try formatOps(&buffer, "10.0.0.4", 45871, &cursor),
    );
}

test "a reference URL asks after the version the peer holds" {
    var buffer: [max_url_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "http://10.0.0.4:45871/v1/reference?after=0",
        try formatReference(&buffer, "10.0.0.4", 45871, 0),
    );
    try std.testing.expectEqualStrings(
        "http://10.0.0.4:45871/v1/reference?after=12",
        try formatReference(&buffer, "10.0.0.4", 45871, 12),
    );
}

test "a body of two records decodes, and a blank line is not a record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"dev-a:1:1","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1,"device_id":"dev-a","created_at":1,"data":{}}
        \\
        \\{"id":"dev-b:2:1","entity_table":"order","entity_id":"O-2","operation":"update","logical_clock":2,"device_id":"dev-b","created_at":2,"data":{}}
        \\
    ;

    const ops = try decodeOps(arena, body);
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("dev-a:1:1", ops[0].id);
    try std.testing.expectEqual(record.Operation.update, ops[1].operation);
}

test "a malformed line in the middle fails the whole body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"dev-a:1:1","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1,"device_id":"dev-a","created_at":1,"data":{}}
        \\not json
    ;
    try std.testing.expectError(error.OpNotJson, decodeOps(arena, body));
}

test "an empty body is an empty answer, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ops = try decodeOps(arena_state.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), ops.len);
}
