//! The operation record - the unit the peers exchange.
//!
//! One JSON object per line, and the field names are the `op_log`
//! column names on purpose: the table and the wire are the same record,
//! and only two things differ.
//!
//! 1. `data_json` is a JSON string in the column and a nested object on
//!    the wire. It is the same value in two encodings, so the codec
//!    parses on the way in and serialises on the way out.
//! 2. `previous_json`, `host_id` and `parent_id` are not carried. They
//!    only meant anything under the host-elected sidecar this design
//!    replaces; the receiving side writes `'{}'` and `''`, and a later
//!    migration may drop the columns.
//!
//! Two rules hold for every value: money is an integer in minor units
//! (a fractional part is refused, never truncated), and time is epoch
//! milliseconds.
//!
//! An op is **idempotent** by `id`. Applying one whose id is already
//! known is a no-op, which is what makes a repeat, a reconnect and a
//! re-ask safe.

const std = @import("std");

pub const Operation = enum {
    create,
    update,
    delete,

    pub fn label(self: Operation) []const u8 {
        return @tagName(self);
    }
};

/// One operation, decoded. The slices point into the arena the caller
/// supplied to `decode`, or into the caller's own storage for a local
/// write.
pub const Op = struct {
    id: []const u8,
    entity_table: []const u8,
    entity_id: []const u8,
    operation: Operation,
    logical_clock: u64,
    device_id: []const u8,
    created_at: i64,
    /// The row snapshot as JSON text - the column's encoding.
    data_json: []const u8 = "{}",
};

pub const ParsedId = struct {
    device_id: []const u8,
    clock: u64,
    sequence: u64,
};

/// `<device_id>:<logical_clock>:<sequence>` - unique without a
/// coordinator, and recognisable from its own text.
pub fn formatId(buffer: []u8, device_id: []const u8, clock: u64, sequence: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}:{d}:{d}", .{ device_id, clock, sequence });
}

pub fn parseId(id: []const u8) !ParsedId {
    const first = std.mem.indexOfScalar(u8, id, ':') orelse return error.OpIdMalformed;
    const last = std.mem.lastIndexOfScalar(u8, id, ':') orelse return error.OpIdMalformed;
    if (first == last) return error.OpIdMalformed;

    const device_id = id[0..first];
    const clock_text = id[first + 1 .. last];
    const sequence_text = id[last + 1 ..];
    if (device_id.len == 0 or clock_text.len == 0 or sequence_text.len == 0) return error.OpIdMalformed;
    if (std.mem.indexOfScalar(u8, clock_text, ':') != null) return error.OpIdMalformed;

    return .{
        .device_id = device_id,
        .clock = std.fmt.parseInt(u64, clock_text, 10) catch return error.OpIdMalformed,
        .sequence = std.fmt.parseInt(u64, sequence_text, 10) catch return error.OpIdMalformed,
    };
}

pub fn validate(op: Op) !void {
    const parsed = try parseId(op.id);
    if (!std.mem.eql(u8, parsed.device_id, op.device_id)) return error.OpDeviceMismatch;
    if (op.entity_table.len == 0) return error.OpTableEmpty;
    if (op.logical_clock == 0) return error.OpClockZero;
    if (op.created_at < 0) return error.OpTimeNegative;

    const trimmed = std.mem.trim(u8, op.data_json, " \t\r\n");
    if (trimmed.len == 0) return error.OpDataEmpty;
    if (trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.OpDataNotAnObject;
}

/// Write one NDJSON line.
pub fn encode(writer: *std.Io.Writer, op: Op) !void {
    try validate(op);

    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(op.id, .{}, writer);
    try writer.writeAll(",\"entity_table\":");
    try std.json.Stringify.value(op.entity_table, .{}, writer);
    try writer.writeAll(",\"entity_id\":");
    try std.json.Stringify.value(op.entity_id, .{}, writer);
    try writer.writeAll(",\"operation\":");
    try std.json.Stringify.value(op.operation.label(), .{}, writer);
    try writer.writeAll(",\"logical_clock\":");
    try std.json.Stringify.value(op.logical_clock, .{}, writer);
    try writer.writeAll(",\"device_id\":");
    try std.json.Stringify.value(op.device_id, .{}, writer);
    try writer.writeAll(",\"created_at\":");
    try std.json.Stringify.value(op.created_at, .{}, writer);
    try writer.writeAll(",\"data\":");
    try writer.writeAll(op.data_json);
    try writer.writeAll("}\n");
}

/// Read one NDJSON line. The returned slices are owned by `arena`.
pub fn decode(arena: std.mem.Allocator, line: []const u8) !Op {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.OpEmpty;

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch
        return error.OpNotJson;
    if (root != .object) return error.OpNotAnObject;

    const id = try textField(root.object, "id");
    const entity_table = try textField(root.object, "entity_table");
    const entity_id = try optionalText(root.object, "entity_id");
    const operation_text = try textField(root.object, "operation");
    const clock = try intField(root.object, "logical_clock");
    const device_id = try textField(root.object, "device_id");
    const created_at = try intField(root.object, "created_at");

    const operation = std.meta.stringToEnum(Operation, operation_text) orelse return error.OpOperationUnknown;
    if (clock <= 0 or clock > std.math.maxInt(u64)) return error.OpClockZero;

    // The data arrives as a nested object and is stored as its text. It
    // is re-serialised rather than sliced out of the line, so the column
    // always holds canonical JSON.
    const data_json = if (root.object.get("data")) |data| switch (data) {
        .object => blk: {
            try rejectFractions(data);
            var out = std.Io.Writer.Allocating.init(arena);
            try std.json.Stringify.value(data, .{}, &out.writer);
            break :blk out.written();
        },
        .null => "{}",
        else => return error.OpDataNotAnObject,
    } else "{}";

    const op: Op = .{
        .id = id,
        .entity_table = entity_table,
        .entity_id = entity_id,
        .operation = operation,
        .logical_clock = @intCast(clock),
        .device_id = device_id,
        .created_at = created_at,
        .data_json = data_json,
    };
    try validate(op);
    return op;
}

/// Money is an integer in minor units. A fractional value is a bug on
/// the writer's side, and accepting it would put a float in the ledger.
fn rejectFractions(value: std.json.Value) !void {
    switch (value) {
        .float => return error.OpFractionOnWire,
        .number_string => |text| {
            if (std.mem.indexOfAny(u8, text, ".eE") != null) return error.OpFractionOnWire;
        },
        .array => |items| for (items.items) |item| try rejectFractions(item),
        .object => |object| for (object.values()) |item| try rejectFractions(item),
        else => {},
    }
}

fn textField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.OpFieldMissing;
    return switch (value) {
        .string => |text| text,
        else => error.OpFieldWrongType,
    };
}

fn optionalText(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => error.OpFieldWrongType,
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.OpFieldMissing;
    return switch (value) {
        .integer => |number| number,
        else => error.OpFieldWrongType,
    };
}

// ------------------------------------------------------------------ tests

const order_line =
    \\{"id":"dev-3:1042:7","entity_table":"order","entity_id":"O-000123","operation":"create","logical_clock":1042,"device_id":"dev-3","created_at":1758000000000,"data":{"table_id":12,"status":"pending","total_minor":24500}}
;

test "an operation round-trips and keeps the data as nested text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const op = try decode(arena, order_line);
    try std.testing.expectEqualStrings("dev-3:1042:7", op.id);
    try std.testing.expectEqualStrings("order", op.entity_table);
    try std.testing.expectEqualStrings("O-000123", op.entity_id);
    try std.testing.expectEqual(Operation.create, op.operation);
    try std.testing.expectEqual(@as(u64, 1042), op.logical_clock);
    try std.testing.expectEqualStrings("dev-3", op.device_id);
    try std.testing.expectEqual(@as(i64, 1758000000000), op.created_at);
    try std.testing.expect(std.mem.indexOf(u8, op.data_json, "\"total_minor\":24500") != null);

    var out = std.Io.Writer.Allocating.init(arena);
    try encode(&out.writer, op);

    const again = try decode(arena, out.written());
    try std.testing.expectEqualStrings(op.id, again.id);
    try std.testing.expectEqualStrings(op.data_json, again.data_json);
    try std.testing.expectEqual(op.operation, again.operation);
}

test "a fractional value on the wire is refused, not truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.OpFractionOnWire, decode(arena,
        \\{"id":"dev-3:1042:8","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1042,"device_id":"dev-3","created_at":1,"data":{"total":245.5}}
    ));
    // A number too large for i64 comes back as text; a fractional one
    // written that way is still refused.
    try std.testing.expectError(error.OpFractionOnWire, decode(arena,
        \\{"id":"dev-3:1042:9","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1042,"device_id":"dev-3","created_at":1,"data":{"total":2.5e3}}
    ));
}

test "the id, the operation and the clock are checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.OpOperationUnknown, decode(arena,
        \\{"id":"dev-3:1042:7","entity_table":"order","entity_id":"O-1","operation":"upsert","logical_clock":1042,"device_id":"dev-3","created_at":1,"data":{}}
    ));
    try std.testing.expectError(error.OpDeviceMismatch, decode(arena,
        \\{"id":"dev-3:1042:7","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1042,"device_id":"dev-9","created_at":1,"data":{}}
    ));
    try std.testing.expectError(error.OpIdMalformed, decode(arena,
        \\{"id":"dev-3-1042-7","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":1042,"device_id":"dev-3","created_at":1,"data":{}}
    ));
    try std.testing.expectError(error.OpClockZero, decode(arena,
        \\{"id":"dev-3:0:7","entity_table":"order","entity_id":"O-1","operation":"create","logical_clock":0,"device_id":"dev-3","created_at":1,"data":{}}
    ));
}

test "the id carries the writer and the clock" {
    var buffer: [64]u8 = undefined;
    const id = try formatId(&buffer, "dev-3", 1042, 7);
    try std.testing.expectEqualStrings("dev-3:1042:7", id);

    const parsed = try parseId(id);
    try std.testing.expectEqualStrings("dev-3", parsed.device_id);
    try std.testing.expectEqual(@as(u64, 1042), parsed.clock);
    try std.testing.expectEqual(@as(u64, 7), parsed.sequence);
}

test "an op without data still carries an empty object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const op = try decode(arena,
        \\{"id":"dev-1:5:1","entity_table":"config","entity_id":"theme","operation":"delete","logical_clock":5,"device_id":"dev-1","created_at":1}
    );
    try std.testing.expectEqualStrings("{}", op.data_json);
}
