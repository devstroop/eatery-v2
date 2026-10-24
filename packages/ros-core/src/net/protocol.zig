//! The wire protocol's fixed names.
//!
//! HTTP/1.1 over raw TCP, NDJSON bodies, one JSON object per line. The
//! shape is `docs/architecture/12-three-apps-and-ipc.md`; this file is
//! the part of it the code must agree on, in one place, so a typo is a
//! compile error rather than a peer that silently never answers.
//!
//! Nothing here allocates or touches the world: it is constants and one
//! record, so the whole protocol vocabulary can be tested headlessly.

const std = @import("std");

/// The protocol version. A peer refuses a different major version and
/// says so, rather than guessing at the fields it does not know.
pub const version = "ros/1";

/// The default TCP port. A device advertises the port it actually bound
/// in the beacon, so a second instance on the same machine can take a
/// different one.
pub const default_port: u16 = 45871;

/// The UDP broadcast port, and how often the beacon is sent.
pub const beacon_port: u16 = 45872;
pub const beacon_interval_ms = 5000;

/// Bodies are one JSON object per line.
pub const content_type = "application/x-ndjson";

/// The endpoints. A path is a constant because the server matches on it
/// and the client builds it from the same string.
pub const endpoints = struct {
    pub const hello = "/v1/hello";
    pub const ops = "/v1/ops";
    pub const reference = "/v1/reference";
    pub const snapshot = "/v1/snapshot";
    pub const events = "/v1/events";
};

/// The device roles, spelled the way `device.role` stores them.
///
/// This is deliberately not `core.navigation.Role`: the wire describes
/// the *device*, and a kiosk is a kiosk whether its board is the
/// kitchen or the customer display. The mapping between the two lives
/// with the app, not with the protocol.
pub const DeviceRole = enum {
    admin,
    waiter,
    kds,
    display,

    pub fn label(self: DeviceRole) []const u8 {
        return @tagName(self);
    }
};

/// The peer card: what a device says about itself.
///
/// The same record is the beacon payload and the `GET /v1/hello`
/// response, so there is one shape to keep true. `tcp` is the port the
/// device actually bound, which is not necessarily `default_port`.
pub const Hello = struct {
    proto: []const u8 = version,
    device: []const u8,
    role: DeviceRole,
    host: []const u8,
    tcp: u16,
    app_version: []const u8,

    pub fn compatible(self: Hello) bool {
        return std.mem.eql(u8, self.proto, version);
    }
};

/// One event-stream notification: the op log moved to `seq`. The line
/// is a hint, not state - the receiver pulls the ops from the cursor it
/// holds - so a lost line costs latency, never an op.
pub fn formatEvent(buffer: []u8, seq: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{{\"seq\":{d}}}\n", .{seq});
}

/// Write the hello card as one JSON line.
pub fn encodeHello(writer: *std.Io.Writer, hello: Hello) !void {
    try std.json.Stringify.value(.{
        .proto = hello.proto,
        .device = hello.device,
        .role = hello.role.label(),
        .host = hello.host,
        .tcp = hello.tcp,
        .app_version = hello.app_version,
    }, .{}, writer);
    try writer.writeByte('\n');
}

/// Read a hello card. The returned slices are owned by `arena`.
pub fn decodeHello(arena: std.mem.Allocator, line: []const u8) !Hello {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyHello;

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch
        return error.HelloNotJson;
    if (root != .object) return error.HelloNotAnObject;

    const proto = try textField(root.object, "proto");
    const device = try textField(root.object, "device");
    const role_text = try textField(root.object, "role");
    const host = try textField(root.object, "host");
    const tcp = try intField(root.object, "tcp");
    const app_version = if (root.object.get("app_version")) |value| switch (value) {
        .string => |text| text,
        else => return error.HelloFieldWrongType,
    } else "";

    const role = std.meta.stringToEnum(DeviceRole, role_text) orelse return error.HelloRoleUnknown;
    if (device.len == 0) return error.HelloDeviceEmpty;
    if (tcp <= 0 or tcp > std.math.maxInt(u16)) return error.HelloPortOutOfRange;

    return .{
        .proto = proto,
        .device = device,
        .role = role,
        .host = host,
        .tcp = @intCast(tcp),
        .app_version = app_version,
    };
}

fn textField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.HelloFieldMissing;
    return switch (value) {
        .string => |text| text,
        else => error.HelloFieldWrongType,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.HelloFieldMissing;
    return switch (value) {
        .integer => |number| number,
        // A JSON integer above i64 is kept as its text. The only field
        // that could be that large is a port, and a port that large is
        // already out of range.
        .number_string => error.HelloFieldWrongType,
        else => error.HelloFieldWrongType,
    };
}

// ------------------------------------------------------------------ tests

test "the hello card round-trips, and the beacon and the endpoint agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hello: Hello = .{
        .device = "dev-3",
        .role = .kds,
        .host = "192.168.1.42",
        .tcp = 45892,
        .app_version = "0.1.0",
    };

    var out = std.Io.Writer.Allocating.init(arena);
    try encodeHello(&out.writer, hello);

    const decoded = try decodeHello(arena, out.written());
    try std.testing.expectEqualStrings(version, decoded.proto);
    try std.testing.expectEqualStrings("dev-3", decoded.device);
    try std.testing.expectEqual(DeviceRole.kds, decoded.role);
    try std.testing.expectEqualStrings("192.168.1.42", decoded.host);
    try std.testing.expectEqual(@as(u16, 45892), decoded.tcp);
    try std.testing.expect(decoded.compatible());
}

test "an event line names the sequence and ends with a newline" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"seq\":42}\n", try formatEvent(&buffer, 42));
}

test "a hello card from another protocol version is not compatible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const decoded = try decodeHello(arena,
        \\{"proto":"ros/2","device":"dev-1","role":"admin","host":"127.0.0.1","tcp":45871}
    );
    try std.testing.expect(!decoded.compatible());
}

test "a hello card with an unknown role or an impossible port is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.HelloRoleUnknown, decodeHello(arena,
        \\{"proto":"ros/1","device":"dev-1","role":"chef","host":"127.0.0.1","tcp":45871}
    ));
    try std.testing.expectError(error.HelloPortOutOfRange, decodeHello(arena,
        \\{"proto":"ros/1","device":"dev-1","role":"admin","host":"127.0.0.1","tcp":70000}
    ));
    try std.testing.expectError(error.HelloFieldMissing, decodeHello(arena,
        \\{"proto":"ros/1","device":"dev-1","role":"admin","tcp":45871}
    ));
    try std.testing.expectError(error.HelloNotJson, decodeHello(arena, "not json"));
}
