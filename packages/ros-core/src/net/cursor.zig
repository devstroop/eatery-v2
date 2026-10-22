//! The vector cursor: how far this device has read, per source device.
//!
//! A single scalar cursor is wrong for a leaderless system, and the
//! failure is silent. Device C is partitioned; B writes at B's clock 20,
//! A writes at A's clock 500; C pulls from A first and then asks B for
//! "everything above 500" - and B's op 20 is never delivered. Tracking a
//! position per source device is the fix, and it is why this type is not
//! a `u64`.
//!
//! The type owns its storage on purpose: the model must be
//! default-constructible and `update` has no allocator, so a cursor is a
//! fixed array rather than a map that grows on the heap.
//!
//! Wire shape: `GET /v1/ops?since=dev-1:1042,dev-3:87`.

const std = @import("std");

/// A restaurant has a handful of devices. The bound is generous and
/// finite, like every other buffer in the model.
pub const max_devices = 16;
pub const max_device_id_len = 64;

pub const Vector = struct {
    ids: [max_devices][max_device_id_len]u8 = undefined,
    id_lengths: [max_devices]u8 = undefined,
    clocks: [max_devices]u64 = undefined,
    len: usize = 0,

    /// The highest clock this device has applied from `device_id`, or 0
    /// when it has seen nothing from that device.
    pub fn get(self: *const Vector, device_id: []const u8) u64 {
        const index = self.find(device_id) orelse return 0;
        return self.clocks[index];
    }

    /// True when `(device_id, clock)` is already covered.
    pub fn covers(self: *const Vector, device_id: []const u8, clock: u64) bool {
        return self.get(device_id) >= clock;
    }

    /// Record that this device has applied `clock` from `device_id`.
    ///
    /// The position only moves forward: an op delivered out of order
    /// must not lower the cursor and cause a re-read.
    pub fn observe(self: *Vector, device_id: []const u8, clock: u64) error{ CursorFull, DeviceIdTooLong }!void {
        if (device_id.len == 0) return;
        if (device_id.len > max_device_id_len) return error.DeviceIdTooLong;

        if (self.find(device_id)) |index| {
            if (clock > self.clocks[index]) self.clocks[index] = clock;
            return;
        }
        if (self.len == max_devices) return error.CursorFull;

        const index = self.len;
        @memcpy(self.ids[index][0..device_id.len], device_id);
        self.id_lengths[index] = @intCast(device_id.len);
        self.clocks[index] = clock;
        self.len += 1;
    }

    /// The highest clock seen from any source. A writer bumps its own
    /// Lamport clock to `max(own, highest seen) + 1`.
    pub fn highest(self: *const Vector) u64 {
        var top: u64 = 0;
        for (self.clocks[0..self.len]) |clock| {
            if (clock > top) top = clock;
        }
        return top;
    }

    /// Forget every position. A device that bootstraps from a snapshot
    /// starts over.
    pub fn reset(self: *Vector) void {
        self.len = 0;
    }

    /// Read `dev-1:1042,dev-3:87`. An empty string is an empty cursor.
    pub fn parse(self: *Vector, text: []const u8) !void {
        self.reset();
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        var rest = trimmed;
        while (rest.len > 0) {
            const comma = std.mem.indexOfScalar(u8, rest, ',');
            const item = if (comma) |at| rest[0..at] else rest;
            rest = if (comma) |at| rest[at + 1 ..] else "";

            const colon = std.mem.lastIndexOfScalar(u8, item, ':') orelse return error.CursorMalformed;
            const device_id = item[0..colon];
            const clock_text = item[colon + 1 ..];
            if (device_id.len == 0 or clock_text.len == 0) return error.CursorMalformed;

            const clock = std.fmt.parseInt(u64, clock_text, 10) catch return error.CursorMalformed;
            self.observe(device_id, clock) catch |err| return switch (err) {
                error.CursorFull => error.CursorFull,
                error.DeviceIdTooLong => error.CursorMalformed,
            };
        }
    }

    /// Write the cursor without a trailing separator. An empty cursor
    /// writes nothing, which is what `?since=` means.
    pub fn write(self: *const Vector, writer: *std.Io.Writer) !void {
        for (0..self.len) |index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll(self.ids[index][0..self.id_lengths[index]]);
            try writer.writeByte(':');
            try writer.print("{d}", .{self.clocks[index]});
        }
    }

    fn find(self: *const Vector, device_id: []const u8) ?usize {
        for (0..self.len) |index| {
            const length = self.id_lengths[index];
            if (length != device_id.len) continue;
            if (std.mem.eql(u8, self.ids[index][0..length], device_id)) return index;
        }
        return null;
    }
};

// ------------------------------------------------------------------ tests

test "a cursor tracks each device separately - the scalar-cursor bug" {
    var cursor: Vector = .{};
    try cursor.observe("dev-a", 500);
    try cursor.observe("dev-b", 20);

    // A scalar cursor of 500 would drop dev-b's op 20. A vector asks
    // dev-b for what dev-b is missing.
    try std.testing.expect(cursor.covers("dev-a", 500));
    try std.testing.expect(cursor.covers("dev-a", 499));
    try std.testing.expect(!cursor.covers("dev-a", 501));
    try std.testing.expect(!cursor.covers("dev-b", 21));
    try std.testing.expect(cursor.covers("dev-b", 20));

    // A device nobody has heard from has seen nothing.
    try std.testing.expectEqual(@as(u64, 0), cursor.get("dev-c"));
    try std.testing.expectEqual(@as(u64, 500), cursor.highest());
}

test "a cursor only moves forward" {
    var cursor: Vector = .{};
    try cursor.observe("dev-a", 10);
    try cursor.observe("dev-a", 4);
    try std.testing.expectEqual(@as(u64, 10), cursor.get("dev-a"));
}

test "the cursor round-trips through the query string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cursor: Vector = .{};
    try cursor.observe("dev-1", 1042);
    try cursor.observe("dev-3", 87);

    var out = std.Io.Writer.Allocating.init(arena);
    try cursor.write(&out.writer);
    try std.testing.expectEqualStrings("dev-1:1042,dev-3:87", out.written());

    var parsed: Vector = .{};
    try parsed.parse(out.written());
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqual(@as(u64, 1042), parsed.get("dev-1"));
    try std.testing.expectEqual(@as(u64, 87), parsed.get("dev-3"));
}

test "an empty cursor parses and writes as nothing" {
    var cursor: Vector = .{};
    try cursor.parse("");
    try std.testing.expectEqual(@as(usize, 0), cursor.len);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(arena_state.allocator());
    try cursor.write(&out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "a malformed cursor is refused rather than guessed at" {
    var cursor: Vector = .{};
    try std.testing.expectError(error.CursorMalformed, cursor.parse("dev-1"));
    try std.testing.expectError(error.CursorMalformed, cursor.parse("dev-1:"));
    try std.testing.expectError(error.CursorMalformed, cursor.parse(":12"));
    try std.testing.expectError(error.CursorMalformed, cursor.parse("dev-1:twelve"));
}

test "the cursor has a bound and says so instead of forgetting" {
    var cursor: Vector = .{};
    var index: usize = 0;
    while (index < max_devices) : (index += 1) {
        var name: [16]u8 = undefined;
        const device = try std.fmt.bufPrint(&name, "dev-{d}", .{index});
        try cursor.observe(device, 1);
    }
    try std.testing.expectError(error.CursorFull, cursor.observe("dev-overflow", 1));
}
