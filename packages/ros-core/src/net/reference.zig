//! The reference snapshot: the menu, the people, the tables and the
//! settings, as one versioned document.
//!
//! The admin app is the only writer. A peer asks for what it is missing
//! with `GET /v1/reference?after=<version>` and keeps the last document
//! it received when the admin is away - the till keeps selling and the
//! kitchen keeps cooking with the menu it has.
//!
//! The rows mirror the tables, not the model's display structs: a peer
//! needs the columns the model does not show, such as the PIN hash and
//! a product's description. The admin builds the document in SQLite
//! (`json_object`/`json_group_array`); this file is the receiving half
//! and the shape both sides agree on.

const std = @import("std");

pub const Snapshot = struct {
    /// The admin's monotonic version. A peer applies a document only
    /// when this is above the version it already has.
    version: u64 = 0,
    company: ?CompanyRow = null,
    categories: []const CategoryRow = &.{},
    tax_slabs: []const TaxSlabRow = &.{},
    employees: []const EmployeeRow = &.{},
    products: []const ProductRow = &.{},
    table_categories: []const TableCategoryRow = &.{},
    tables: []const TableRow = &.{},
    stations: []const StationRow = &.{},
    /// The salt the employee hashes were made with. The peer stores it
    /// so a PIN copied from the admin still verifies.
    pin_salt: ?[]const u8 = null,
};

pub const CompanyRow = struct {
    id: i64,
    name: []const u8,
    currency_code: []const u8,
    currency_symbol: []const u8,
    tax_inclusive: i64,
    currency_decimals: i64,
    address: []const u8,
    phone: []const u8,
    email: []const u8,
    tax_number: []const u8,
    created_at: i64,
};

pub const CategoryRow = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
    active: i64,
};

pub const TaxSlabRow = struct {
    id: i64,
    name: []const u8,
    rate_bps: i64,
    inclusive: i64,
    active: i64,
};

pub const EmployeeRow = struct {
    id: i64,
    name: []const u8,
    role: i64,
    pin_hash: []const u8,
    phone: []const u8,
    email: []const u8,
    active: i64,
    created_at: i64,
};

pub const ProductRow = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    price_minor: i64,
    product_type: i64,
    food_type: i64,
    tax_slab_id: i64,
    /// Null means "not stock controlled".
    stock_qty: ?i64,
    track_stock: i64,
    description: []const u8,
    image_path: []const u8,
    active: i64,
    sort_order: i64,
    created_at: i64,
    updated_at: i64,
};

pub const TableCategoryRow = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
    active: i64,
};

pub const TableRow = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    /// The admin's table status is operational, not reference: the
    /// receiver keeps its own and inserts a new table as free.
    status: i64,
    seats: i64,
    pos_x: i64,
    pos_y: i64,
    width_cells: i64,
    height_cells: i64,
    active: i64,
};

pub const StationRow = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
    active: i64,
};

/// Read a snapshot. The returned slices are owned by `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Snapshot {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0) return error.SnapshotEmpty;
    return std.json.parseFromSliceLeaky(Snapshot, arena, trimmed, .{
        .ignore_unknown_fields = true,
    }) catch return error.SnapshotNotJson;
}

// ------------------------------------------------------------------ tests

test "a snapshot reads the rows the tables carry" {
    const json =
        \\{"version":7,
        \\ "company":{"id":1,"name":"Cafe","currency_code":"INR","currency_symbol":"₹",
        \\  "tax_inclusive":0,"currency_decimals":2,"address":"","phone":"",
        \\  "email":"","tax_number":"","created_at":10},
        \\ "categories":[{"id":1,"name":"Starters","sort_order":0,"active":1}],
        \\ "tax_slabs":[{"id":0,"name":"GST 5","rate_bps":500,"inclusive":0,"active":1}],
        \\ "employees":[{"id":1,"name":"Asha","role":0,"pin_hash":"hash",
        \\  "phone":"","email":"","active":1,"created_at":10}],
        \\ "products":[{"id":1,"category_id":1,"name":"Paneer","price_minor":24500,
        \\  "product_type":0,"food_type":1,"tax_slab_id":0,"stock_qty":null,
        \\  "track_stock":0,"description":"","image_path":"","active":1,
        \\  "sort_order":0,"created_at":10,"updated_at":10}],
        \\ "table_categories":[{"id":1,"name":"Main","sort_order":0,"active":1}],
        \\ "tables":[{"id":1,"category_id":1,"name":"T1","status":0,"seats":4,
        \\  "pos_x":0,"pos_y":0,"width_cells":1,"height_cells":1,"active":1}],
        \\ "stations":[{"id":1,"name":"Grill","sort_order":0,"active":1}],
        \\ "pin_salt":"abcd"}
    ;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const snapshot = try parse(arena_state.allocator(), json);
    try std.testing.expectEqual(@as(u64, 7), snapshot.version);
    try std.testing.expectEqualStrings("Cafe", snapshot.company.?.name);
    try std.testing.expectEqualStrings("INR", snapshot.company.?.currency_code);
    try std.testing.expectEqual(@as(usize, 1), snapshot.categories.len);
    try std.testing.expectEqualStrings("Starters", snapshot.categories[0].name);
    try std.testing.expectEqual(@as(usize, 1), snapshot.employees.len);
    try std.testing.expectEqualStrings("hash", snapshot.employees[0].pin_hash);
    try std.testing.expectEqual(@as(usize, 1), snapshot.products.len);
    try std.testing.expect(snapshot.products[0].stock_qty == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.tables.len);
    try std.testing.expectEqualStrings("abcd", snapshot.pin_salt.?);
}

test "an empty document is refused, not applied" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.SnapshotEmpty, parse(arena_state.allocator(), " \n "));
}
