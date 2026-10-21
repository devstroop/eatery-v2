//! The data layer: SQL in, model rows out.
//!
//! Two rules keep this layer honest:
//!
//!   * **One place per statement.** Every query lives here as a named
//!     constant, so a schema change is one edit, not a grep.
//!   * **Reads copy, writes are atomic.** A read lands in the model's
//!     bump buffer (the page bytes are drain scratch). A write is one
//!     `dbExec` - the engine runs the statements as a single
//!     transaction, so a half-written order can never exist.
//!
//! Keys: every effect slot has a caller-chosen `u64` key. They live in
//! their own namespace here so a query and a write can never collide.

const std = @import("std");
const native_sdk = @import("native_sdk");

const model_mod = @import("../core/model.zig");
const domain = @import("../domain/models.zig");
const page = @import("page.zig");

const Model = model_mod.Model;
const Effects = native_sdk.Effects(@import("../core/msg.zig").Msg);

// --------------------------------------------------------------- keys

/// Effect keys. One per long-running read plus one per write family.
pub const key_products = 1;
pub const key_tables = 2;
pub const key_employees = 3;
pub const key_orders = 4;
pub const key_customers = 5;
pub const key_categories = 6;
pub const key_company = 7;
pub const key_login = 8;
pub const key_order_lines = 9;
pub const key_config = 10;
pub const key_write_order = 20;
pub const key_write_product = 21;
pub const key_write_table = 22;

// ------------------------------------------------------------ queries

pub const products_sql =
    \\SELECT id, category_id, name, price_minor, product_type, food_type,
    \\       tax_slab_id, stock_qty, active
    \\FROM product
    \\WHERE active = 1
    \\ORDER BY name;
;

pub const categories_sql =
    \\SELECT id, name, sort_order
    \\FROM product_category
    \\ORDER BY sort_order, name;
;

pub const tables_sql =
    \\SELECT id, category_id, name, status, seats, pos_x, pos_y
    \\FROM dining_table
    \\ORDER BY name;
;

pub const employees_sql =
    \\SELECT id, name, role, active
    \\FROM employee
    \\WHERE active = 1
    \\ORDER BY name;
;

pub const customers_sql =
    \\SELECT id, name, phone, email, loyalty_points
    \\FROM customer
    \\ORDER BY name;
;

pub const orders_sql =
    \\SELECT id, order_no, order_type, status, dining_table_id, customer_id,
    \\       employee_id, subtotal_minor, tax_minor, discount_minor,
    \\       total_minor, placed_at, notes
    \\FROM orders
    \\WHERE status <> 5
    \\ORDER BY placed_at DESC
    \\LIMIT 200;
;

pub const order_lines_sql =
    \\SELECT id, order_id, product_id, product_name, qty, unit_price_minor,
    \\       tax_bps, notes
    \\FROM order_line
    \\WHERE order_id IN (SELECT id FROM orders WHERE status <> 5)
    \\ORDER BY id;
;

/// One setting out of `app_config`. The PIN salt lives there.
pub const config_sql =
    \\SELECT key, value FROM app_config WHERE key = 'pin_salt' LIMIT 1;
;

/// The company row. A v2 database holds exactly one company.
pub const company_sql =
    \\SELECT id, name, currency_code, currency_symbol, tax_inclusive
    \\FROM company
    \\LIMIT 1;
;

// -------------------------------------------------------------- reads

/// Ask for the menu. The result arrives as a `.products_loaded` message.
pub fn loadProducts(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_products,
        .sql = products_sql,
        .on_result = Effects.dbMsg(.products_loaded),
    });
}

pub fn loadCategories(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_categories,
        .sql = categories_sql,
        .on_result = Effects.dbMsg(.categories_loaded),
    });
}

pub fn loadTables(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_tables,
        .sql = tables_sql,
        .on_result = Effects.dbMsg(.tables_loaded),
    });
}

pub fn loadEmployees(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_employees,
        .sql = employees_sql,
        .on_result = Effects.dbMsg(.employees_loaded),
    });
}

pub fn loadCustomers(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_customers,
        .sql = customers_sql,
        .on_result = Effects.dbMsg(.customers_loaded),
    });
}

pub fn loadOrders(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_orders,
        .sql = orders_sql,
        .on_result = Effects.dbMsg(.orders_loaded),
    });
}

pub fn loadOrderLines(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_order_lines,
        .sql = order_lines_sql,
        .on_result = Effects.dbMsg(.order_lines_loaded),
    });
}

pub fn loadConfig(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_config,
        .sql = config_sql,
        .on_result = Effects.dbMsg(.config_loaded),
    });
}

/// Write one setting. The write is a single statement and the engine
/// runs it atomically with anything else in the same transaction.
pub fn saveConfigValue(fx: *Effects, key: u64, name: []const u8, value: []const u8, at: i64) void {
    var params: [3]native_sdk.EffectDbValue = .{
        .{ .text = name },
        .{ .text = value },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO app_config (key, value, updated_at) VALUES (?1, ?2, ?3)
            \\ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.config_saved),
    });
}

pub fn loadCompany(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_company,
        .sql = company_sql,
        .on_result = Effects.dbMsg(.company_loaded),
    });
}

/// Load everything the shell needs on boot. One arm, one place.
pub fn loadAll(fx: *Effects) void {
    loadCompany(fx);
    loadCategories(fx);
    loadProducts(fx);
    loadTables(fx);
    loadEmployees(fx);
    loadOrders(fx);
    loadOrderLines(fx);
}

// ------------------------------------------------------------ decoding

/// Land a decoded product page in the model.
pub fn decodeProducts(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.products_buf.reset();
    const count = reader.rows_left;
    const list = model.products_buf.allocSlice(domain.Product, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .category_id = reader.intOf(&values, "category_id", 0),
            .name = model.products_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .price_minor = reader.intOf(&values, "price_minor", 0),
            .product_type = enumFromInt(domain.ProductType, reader.intOf(&values, "product_type", 0)),
            .food_type = enumFromInt(domain.FoodType, reader.intOf(&values, "food_type", 0)),
            .tax_slab_id = reader.intOf(&values, "tax_slab_id", 0),
            .stock_qty = reader.intOf(&values, "stock_qty", 0),
            .active = reader.boolOf(&values, "active"),
        };
    }
    model.products = list[0..index];
}

pub fn decodeCategories(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.categories_buf.reset();
    const count = reader.rows_left;
    const list = model.categories_buf.allocSlice(domain.ProductCategory, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.categories_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .sort_order = reader.intOf(&values, "sort_order", 0),
        };
    }
    model.categories = list[0..index];
}

pub fn decodeTables(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.tables_buf.reset();
    const count = reader.rows_left;
    const list = model.tables_buf.allocSlice(domain.DiningTable, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .category_id = reader.intOf(&values, "category_id", 0),
            .name = model.tables_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .status = enumFromInt(domain.TableStatus, reader.intOf(&values, "status", 0)),
            .status_label = tableStatusLabel(enumFromInt(domain.TableStatus, reader.intOf(&values, "status", 0))),
            .seats = reader.intOf(&values, "seats", 0),
            .pos_x = reader.intOf(&values, "pos_x", 0),
            .pos_y = reader.intOf(&values, "pos_y", 0),
        };
    }
    model.tables = list[0..index];
}

pub fn decodeEmployees(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.employees_buf.reset();
    const count = reader.rows_left;
    const list = model.employees_buf.allocSlice(domain.Employee, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.employees_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .role = reader.intOf(&values, "role", 0),
            .active = reader.boolOf(&values, "active"),
        };
    }
    model.employees = list[0..index];
}

pub fn decodeCustomers(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.customers_buf.reset();
    const count = reader.rows_left;
    const list = model.customers_buf.allocSlice(domain.Customer, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.customers_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .phone = model.customers_buf.dupe(reader.textOf(&values, "phone")) orelse "",
            .email = model.customers_buf.dupe(reader.textOf(&values, "email")) orelse "",
            .loyalty_points = reader.intOf(&values, "loyalty_points", 0),
        };
    }
    model.customers = list[0..index];
}

pub fn decodeOrders(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.orders_buf.reset();
    const count = reader.rows_left;
    const list = model.orders_buf.allocSlice(domain.Order, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .order_no = model.orders_buf.dupe(reader.textOf(&values, "order_no")) orelse "",
            .order_type = enumFromInt(domain.OrderType, reader.intOf(&values, "order_type", 0)),
            .status = enumFromInt(domain.OrderStatus, reader.intOf(&values, "status", 0)),
            .status_label = orderStatusLabel(enumFromInt(domain.OrderStatus, reader.intOf(&values, "status", 0))),
            .type_label = orderTypeLabel(enumFromInt(domain.OrderType, reader.intOf(&values, "order_type", 0))),
            .dining_table_id = reader.intOf(&values, "dining_table_id", 0),
            .customer_id = reader.intOf(&values, "customer_id", 0),
            .employee_id = reader.intOf(&values, "employee_id", 0),
            .subtotal_minor = reader.intOf(&values, "subtotal_minor", 0),
            .tax_minor = reader.intOf(&values, "tax_minor", 0),
            .discount_minor = reader.intOf(&values, "discount_minor", 0),
            .total_minor = reader.intOf(&values, "total_minor", 0),
            .placed_at = reader.intOf(&values, "placed_at", 0),
            .notes = model.orders_buf.dupe(reader.textOf(&values, "notes")) orelse "",
        };
    }
    model.orders = list[0..index];
}

pub fn decodeOrderLines(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.order_lines_buf.reset();
    const count = reader.rows_left;
    const list = model.order_lines_buf.allocSlice(domain.OrderLine, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .order_id = reader.intOf(&values, "order_id", 0),
            .product_id = reader.intOf(&values, "product_id", 0),
            .product_name = model.order_lines_buf.dupe(reader.textOf(&values, "product_name")) orelse "",
            .qty = reader.intOf(&values, "qty", 0),
            .unit_price_minor = reader.intOf(&values, "unit_price_minor", 0),
            .tax_bps = reader.intOf(&values, "tax_bps", 0),
            .notes = model.order_lines_buf.dupe(reader.textOf(&values, "notes")) orelse "",
        };
    }
    model.order_lines = list[0..index];
}

pub fn decodeCompany(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    var values: [page.max_columns]page.Value = undefined;
    if (!reader.nextRow(&values)) return;
    model.company_id = reader.intOf(&values, "id", 0);
    model.company_name = reader.textOf(&values, "name");
    model.currency_code = reader.textOf(&values, "currency_code");
    model.currency_symbol = reader.textOf(&values, "currency_symbol");
    model.tax_inclusive = reader.boolOf(&values, "tax_inclusive");
}

// -------------------------------------------------------------- writes

/// The most lines one order may carry. A POS order with more lines
/// than this is a bug, not a business case - the limit keeps the write
/// path allocation-free.
pub const max_order_lines = 64;

/// Write one order and its lines as a single transaction. The engine
/// runs the statements atomically, so the order is either fully there
/// or not there at all.
///
/// No allocator is needed: `dbExec` executes the statements
/// synchronously, so the parameters can live on the stack for the
/// duration of the call.
pub fn saveOrder(fx: *Effects, order: domain.Order, lines: []const domain.OrderLine) void {
    var statements: [1 + max_order_lines]native_sdk.EffectDbStatement = undefined;
    var line_params: [max_order_lines][9]native_sdk.EffectDbValue = undefined;

    var order_params: [13]native_sdk.EffectDbValue = .{
        .{ .integer = order.id },
        .{ .text = order.order_no },
        .{ .integer = @intFromEnum(order.order_type) },
        .{ .integer = @intFromEnum(order.status) },
        .{ .integer = order.dining_table_id },
        .{ .integer = order.customer_id },
        .{ .integer = order.employee_id },
        .{ .integer = order.subtotal_minor },
        .{ .integer = order.tax_minor },
        .{ .integer = order.discount_minor },
        .{ .integer = order.total_minor },
        .{ .integer = order.placed_at },
        .{ .text = order.notes },
    };
    statements[0] = .{
        .sql =
        \\INSERT INTO orders (id, order_no, order_type, status, dining_table_id,
        \\  customer_id, employee_id, subtotal_minor, tax_minor, discount_minor,
        \\  total_minor, placed_at, notes, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?12)
        \\ON CONFLICT(id) DO UPDATE SET status = ?4, notes = ?13, updated_at = ?12;
        ,
        .params = &order_params,
    };
    var count: usize = 1;

    for (lines) |line| {
        if (count >= statements.len) break;
        const slot = count - 1;
        line_params[slot] = .{
            .{ .integer = line.id },
            .{ .integer = order.id },
            .{ .integer = line.product_id },
            .{ .text = line.product_name },
            .{ .integer = line.qty },
            .{ .integer = line.unit_price_minor },
            .{ .integer = line.tax_bps },
            .{ .text = line.notes },
            .{ .integer = order.placed_at },
        };
        statements[count] = .{
            .sql =
            \\INSERT INTO order_line (id, order_id, product_id, product_name, qty,
            \\  unit_price_minor, tax_bps, notes, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            \\ON CONFLICT(id) DO UPDATE SET qty = ?5, unit_price_minor = ?6;
            ,
            .params = &line_params[slot],
        };
        count += 1;
    }

    fx.dbExec(.{
        .key = key_write_order,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.order_placed),
    });
}

/// Move an order along its lifecycle. The status history is written in
/// the same transaction, so the timeline can never disagree with the
/// order's current status.
pub fn setOrderStatus(fx: *Effects, order_id: i64, status: domain.OrderStatus, at: i64) void {
    fx.dbExec(.{
        .key = key_write_order,
        .statements = &.{
            .{
                .sql = "UPDATE orders SET status = ?2, updated_at = ?3 WHERE id = ?1;",
                .params = &.{ .{ .integer = order_id }, .{ .integer = @intFromEnum(status) }, .{ .integer = at } },
            },
            .{
                .sql =
                \\INSERT INTO order_status_history (order_id, status, changed_at)
                \\VALUES (?1, ?2, ?3);
                ,
                .params = &.{ .{ .integer = order_id }, .{ .integer = @intFromEnum(status) }, .{ .integer = at } },
            },
        },
        .on_result = Effects.dbMsg(.order_status_saved),
    });
}

// ------------------------------------------------------------- helpers

/// The labels the markup binds. Resolved at decode time because the
/// markup binds fields, not methods.
fn orderStatusLabel(status: domain.OrderStatus) []const u8 {
    return status.label();
}

fn orderTypeLabel(order_type: domain.OrderType) []const u8 {
    return order_type.label();
}

fn tableStatusLabel(status: domain.TableStatus) []const u8 {
    return status.label();
}

/// A safe enum cast: an out-of-range database value falls back to the
/// default instead of trapping. A database is allowed to be wrong; the
/// app is not allowed to crash because of it.
fn enumFromInt(comptime T: type, value: i64) T {
    const info = @typeInfo(T).@"enum";
    const narrowed = std.math.cast(info.tag_type, value) orelse return @field(T, info.fields[0].name);
    return std.enums.fromInt(T, narrowed) orelse @field(T, info.fields[0].name);
}
