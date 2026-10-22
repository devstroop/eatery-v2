//! Reading the relational store's page format.
//!
//! The engine delivers query results as one encoded page per delivery.
//! The dialect is fixed and little-endian:
//!
//!   u32 column count
//!   u32 row count
//!   per column:  u32 byte length, then the column name
//!   per row, per column, row-major:
//!     tag 0        NULL
//!     tag 1 + i64  INTEGER
//!     tag 2 + f64  REAL (bit pattern)
//!     tag 3 + u32 length, then bytes   TEXT
//!     tag 4 + u32 length, then bytes   BLOB
//!
//! Two facts shape this API:
//!
//!   * The page bytes are **drain scratch**. They are valid through the
//!     update that receives them and dead after it, so every value the
//!     model keeps has to be COPIED (into the model's bump buffer).
//!   * `update` has **no allocator**. So the reader streams: it never
//!     materialises the whole page, and the caller copies each row into
//!     its own storage as it goes.

const std = @import("std");

pub const Value = union(enum) {
    null_value,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn int(self: Value) i64 {
        return switch (self) {
            .integer => |v| v,
            .real => |v| @intFromFloat(v),
            else => 0,
        };
    }

    pub fn float(self: Value) f64 {
        return switch (self) {
            .integer => |v| @floatFromInt(v),
            .real => |v| v,
            else => 0,
        };
    }

    /// The text of a value, or the empty string for anything else.
    pub fn asText(self: Value) []const u8 {
        return switch (self) {
            .text => |v| v,
            else => "",
        };
    }

    /// Whether the value is a non-zero integer.
    pub fn truthy(self: Value) bool {
        return self.int() != 0;
    }
};

/// The most columns one query may select. The reader is a stack
/// allocation, so this is a compile-time bound.
pub const max_columns = 64;

pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    /// The column names live IN the reader: a local array would leave
    /// `columns` pointing at a dead stack frame the moment the header
    /// was parsed.
    column_names: [max_columns][]const u8 = undefined,
    columns: []const []const u8 = &.{},
    rows_left: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    /// Read the header: the column count, the row count, and the column
    /// names. The names point into the page bytes (drain scratch).
    pub fn readHeader(self: *Reader) bool {
        const column_count = readU32(self.bytes, &self.at) orelse return false;
        const row_count = readU32(self.bytes, &self.at) orelse return false;
        if (column_count > max_columns) return false;
        var index: usize = 0;
        while (index < column_count) : (index += 1) {
            self.column_names[index] = readBytes(self.bytes, &self.at) orelse return false;
        }
        self.columns = self.column_names[0..column_count];
        self.rows_left = row_count;
        return true;
    }

    /// The index of a selected column, or null when the query did not
    /// select it. Repos use this so a column reorder in SQL cannot
    /// silently swap two fields in a decoder.
    pub fn indexOf(self: *const Reader, name: []const u8) ?usize {
        for (self.columns, 0..) |column, index| {
            if (std.mem.eql(u8, column, name)) return index;
        }
        return null;
    }

    /// Read the next row into `out`, which must be at least as long as
    /// the column count. Returns false at the end of the page.
    pub fn nextRow(self: *Reader, out: []Value) bool {
        if (self.rows_left == 0) return false;
        if (out.len < self.columns.len) return false;
        for (self.columns, 0..) |_, index| {
            out[index] = readValue(self.bytes, &self.at) orelse return false;
        }
        self.rows_left -= 1;
        return true;
    }

    /// The integer value of one column of the row in `out`.
    pub fn intOf(self: *const Reader, out: []const Value, name: []const u8, fallback: i64) i64 {
        const index = self.indexOf(name) orelse return fallback;
        if (index >= out.len) return fallback;
        return switch (out[index]) {
            .null_value => fallback,
            else => out[index].int(),
        };
    }

    /// The boolean value of one column of the row in `out`.
    pub fn boolOf(self: *const Reader, out: []const Value, name: []const u8) bool {
        return self.intOf(out, name, 0) != 0;
    }

    /// The text value of one column of the row in `out`. The slice
    /// points into the page bytes - copy it before keeping it.
    pub fn textOf(self: *const Reader, out: []const Value, name: []const u8) []const u8 {
        const index = self.indexOf(name) orelse return "";
        if (index >= out.len) return "";
        return out[index].asText();
    }
};

fn readU32(bytes: []const u8, at: *usize) ?u32 {
    if (bytes.len -| at.* < 4) return null;
    const value = std.mem.readInt(u32, bytes[at.*..][0..4], .little);
    at.* += 4;
    return value;
}

fn readBytes(bytes: []const u8, at: *usize) ?[]const u8 {
    const len = readU32(bytes, at) orelse return null;
    if (bytes.len -| at.* < len) return null;
    const slice = bytes[at.*..][0..len];
    at.* += len;
    if (!std.unicode.utf8ValidateSlice(slice)) return "";
    return slice;
}

fn readValue(bytes: []const u8, at: *usize) ?Value {
    if (bytes.len -| at.* < 1) return null;
    const tag = bytes[at.*];
    at.* += 1;
    return switch (tag) {
        0 => Value.null_value,
        1 => blk: {
            if (bytes.len -| at.* < 8) return null;
            const value = std.mem.readInt(i64, bytes[at.*..][0..8], .little);
            at.* += 8;
            break :blk Value{ .integer = value };
        },
        2 => blk: {
            if (bytes.len -| at.* < 8) return null;
            const bits = std.mem.readInt(u64, bytes[at.*..][0..8], .little);
            at.* += 8;
            break :blk Value{ .real = @bitCast(bits) };
        },
        3 => blk: {
            const text = readBytes(bytes, at) orelse return null;
            break :blk Value{ .text = text };
        },
        4 => blk: {
            const blob = readBytes(bytes, at) orelse return null;
            break :blk Value{ .blob = blob };
        },
        else => null,
    };
}
