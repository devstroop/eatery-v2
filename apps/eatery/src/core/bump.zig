//! A bump allocator over a fixed buffer.
//!
//! The model must be default-constructible (`UiApp.create` builds it as
//! `.{}` and the model-contract checker does the same), so it cannot own
//! a heap allocator. It still needs somewhere to keep the rows the view
//! renders - names, labels, and the row structs themselves.
//!
//! `Bump` is that somewhere: a fixed byte buffer the model resets
//! whenever a dataset is replaced. No allocation, no lifetime surprises,
//! and a hard upper bound that the compiler enforces - which is exactly
//! what a POS wants from a menu that someone will try to make huge.

const std = @import("std");

pub fn Bump(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        /// Forget everything. Call this the moment a dataset is replaced
        /// so the old rows cannot leak into the new set.
        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        /// The bytes handed out so far.
        pub fn used(self: *const Self) usize {
            return self.len;
        }

        /// The bytes still available.
        pub fn free(self: *const Self) usize {
            return capacity - self.len;
        }

        /// Hand out `len` bytes, aligned to `alignment`. Returns null
        /// when the buffer is full - a caller that cannot get memory
        /// drops the row rather than growing the model.
        pub fn alloc(self: *Self, len: usize, alignment: usize) ?[]u8 {
            const boundary = if (alignment == 0) 1 else alignment;
            const padded = std.mem.alignForward(usize, self.len, boundary);
            if (padded > capacity) return null;
            if (len > capacity - padded) return null;
            const start = padded;
            self.len = padded + len;
            return self.bytes[start..self.len];
        }

        /// Copy a string into the buffer. The result is owned by the
        /// bump and dies with the next `reset`.
        pub fn dupe(self: *Self, text: []const u8) ?[]const u8 {
            const out = self.alloc(text.len, 1) orelse return null;
            @memcpy(out, text);
            return out;
        }

        /// Hand out a typed slice of `len` elements. This is how a repo
        /// lands a decoded row set in the model without touching the
        /// heap.
        pub fn allocSlice(self: *Self, comptime T: type, len: usize) ?[]T {
            const bytes = self.alloc(len * @sizeOf(T), @alignOf(T)) orelse return null;
            const ptr: [*]T = @ptrCast(@alignCast(bytes.ptr));
            return ptr[0..len];
        }

        /// Copy a fixed-size, NUL-padded field (SQLite TEXT columns
        /// often come back padded). The copy stops at the first NUL.
        pub fn dupeC(self: *Self, text: []const u8) ?[]const u8 {
            const trimmed = std.mem.sliceTo(text, 0);
            return self.dupe(trimmed);
        }
    };
}
