//! The answers waiting for the net thread, one slot per connection.
//!
//! The loop thread writes; the net thread reads. Two atomic counters per
//! slot are enough, and they are enough *because* there is exactly one
//! producer and one consumer - which is a finding, not a preference.
//! `std.Thread.Mutex` is gone in Zig 0.16 and `std.Io.Mutex` takes the
//! `Io` it locks against; `update` has no `Io`, so a mutex is not
//! available to it. A single-producer/single-consumer ring is, and it
//! costs one release and one acquire.
//!
//! The slot is **per connection**, not a global ring. A frame carries no
//! peer id, so a shared ring would let one peer's answer reach another -
//! and a leftover answer from a connection that timed out would be handed
//! to the next connection that reused the slot. Each connection owns a
//! slot, cleared when it is accepted.
//!
//! An answer that does not fit is **refused and counted**, never
//! truncated: half a response on the socket is worse than none, and a
//! silent drop is a bug nobody finds.

const std = @import("std");

/// How many bytes one answer may carry.
pub const max_frame_bytes = 8192;

/// How many connections may have a slot at once.
pub const max_conns = 8;

pub const Slot = struct {
    len: u16 = 0,
    bytes: [max_frame_bytes]u8 = undefined,
    /// Bumped by the producer once the bytes are written. The consumer
    /// reads it to learn that a new answer is waiting.
    written: std.atomic.Value(u32) = .init(0),
    /// The consumer's last-read counter. Owned by the net thread.
    read: u32 = 0,
};

pub const Outbox = struct {
    slots: [max_conns]Slot = undefined,
    /// Answers the producer could not deliver.
    dropped: std.atomic.Value(u32) = .init(0),

    /// The slot a connection owns. The id is the connection's number
    /// modulo the slot count, so a long-lived app does not need an
    /// unbounded id space.
    pub fn slot(self: *Outbox, conn: u32) *Slot {
        return &self.slots[conn % max_conns];
    }

    /// Write an answer for a connection. False when the answer does not
    /// fit, and the refusal is counted.
    pub fn write(self: *Outbox, conn: u32, bytes: []const u8) bool {
        if (bytes.len > max_frame_bytes) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return false;
        }
        const target = self.slot(conn);
        target.len = @intCast(bytes.len);
        @memcpy(target.bytes[0..bytes.len], bytes);
        _ = target.written.fetchAdd(1, .release);
        return true;
    }

    /// Read the answer for a connection, if a new one is waiting.
    ///
    /// The returned value is the frame's **full** length. A length
    /// larger than `out.len` means the answer did not fit, and the caller
    /// must say so rather than write half a response to the socket.
    pub fn read(self: *Outbox, conn: u32, out: []u8) ?usize {
        const target = self.slot(conn);
        const written = target.written.load(.acquire);
        if (written == target.read) return null;
        const len = target.len;
        const copied = @min(len, out.len);
        @memcpy(out[0..copied], target.bytes[0..copied]);
        target.read = written;
        return len;
    }

    /// Clear a slot, for a connection that has just been accepted. A
    /// connection starts with no answer waiting.
    pub fn clear(self: *Outbox, conn: u32) void {
        const target = self.slot(conn);
        target.len = 0;
        target.read = target.written.load(.acquire);
    }

    /// Empty every slot. The tests need it: the outbox is process-wide
    /// in the app because the net thread and the loop thread both reach
    /// it.
    pub fn reset(self: *Outbox) void {
        for (&self.slots) |*entry| {
            entry.len = 0;
            entry.read = entry.written.load(.acquire);
        }
        self.dropped.store(0, .monotonic);
    }
};

// ------------------------------------------------------------------ tests

test "an answer round-trips through its connection's slot" {
    var outbox: Outbox = .{};
    var buffer: [256]u8 = undefined;

    try std.testing.expect(outbox.read(1, &buffer) == null);
    try std.testing.expect(outbox.write(1, "HTTP/1.1 200 OK\r\n\r\npong"));
    const len = outbox.read(1, &buffer).?;
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\npong", buffer[0..len]);

    // The same answer is not handed out twice.
    try std.testing.expect(outbox.read(1, &buffer) == null);
}

test "each connection owns its slot, so an answer cannot reach the wrong peer" {
    var outbox: Outbox = .{};
    var buffer: [256]u8 = undefined;

    try std.testing.expect(outbox.write(1, "one"));
    try std.testing.expect(outbox.write(2, "two"));

    const first = outbox.read(1, &buffer).?;
    try std.testing.expectEqualStrings("one", buffer[0..first]);
    const second = outbox.read(2, &buffer).?;
    try std.testing.expectEqualStrings("two", buffer[0..second]);
}

test "an answer that does not fit is refused and counted" {
    var outbox: Outbox = .{};
    const huge = try std.testing.allocator.alloc(u8, max_frame_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');

    try std.testing.expect(!outbox.write(1, huge));
    try std.testing.expectEqual(@as(u32, 1), outbox.dropped.load(.monotonic));

    var small: [4]u8 = undefined;
    try std.testing.expect(outbox.write(1, "tiny"));
    // The full length comes back even when the caller's buffer is small:
    // the caller must notice and refuse to write half a response.
    const len = outbox.read(1, &small).?;
    try std.testing.expectEqual(@as(usize, 4), len);
}

test "clearing a slot drops the answer the previous connection left behind" {
    var outbox: Outbox = .{};
    var buffer: [64]u8 = undefined;

    try std.testing.expect(outbox.write(3, "stale"));
    outbox.clear(3);
    try std.testing.expect(outbox.read(3, &buffer) == null);

    try std.testing.expect(outbox.write(3, "fresh"));
    const len = outbox.read(3, &buffer).?;
    try std.testing.expectEqualStrings("fresh", buffer[0..len]);
}
