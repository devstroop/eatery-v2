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
const nav = @import("../core/navigation.zig");
pub const page = @import("page.zig");
const starter = @import("starter.zig");

const Model = model_mod.Model;
const Effects = native_sdk.Effects(@import("../core/msg.zig").Msg);

// --------------------------------------------------------------- keys
//
// Effect keys. One per long-running read plus one per write family.
//
// A key is an effect's identity in the channel: two live effects cannot
// share one. A write that reuses a live key is REFUSED (the outcome is
// `.rejected`), so a collision is a write that silently never happens -
// the worst kind of bug in a till. Every key below is used exactly once.
//
// `28` is not used: it was the reservation for the printer write that
// became `key_save_printer`.
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
pub const key_setup = 11;
pub const key_payment = 12;
pub const key_watch_orders = 13;
pub const key_open_order = 14;
pub const key_add_line = 15;
pub const key_stations = 16;
pub const key_chime = 17;
pub const key_product_stations = 18;
pub const key_board_refresh = 19;
pub const key_save_company = 20;
pub const key_printers = 21;
pub const key_tax_slabs = 22;
pub const key_modifier_groups = 23;
pub const key_discounts = 24;
pub const key_save_product = 25;
pub const key_save_employee = 26;
pub const key_save_printer = 27;
pub const key_reservations = 29;
pub const key_suppliers = 30;
pub const key_purchase_orders = 31;
pub const key_inventory = 32;
pub const key_write_order = 33;
pub const key_write_product = 34;
pub const key_write_table = 35;
pub const key_save_salt = 36;
pub const key_save_currency = 37;
pub const key_save_tax_slab = 39;
pub const key_save_discount = 40;
pub const key_save_category = 41;
pub const key_save_pin_hash = 38;

// ------------------------------------------------------------ queries

pub const products_sql =
    \\SELECT id, category_id, name, price_minor, product_type, food_type,
    \\       tax_slab_id, stock_qty, active
    \\FROM product
    \\WHERE active = 1
    \\ORDER BY name;
;

/// The categories on the menu. A category that is not in use is not
/// shown: the menu a customer reads is the menu the kitchen cooks.
pub const categories_sql =
    \\SELECT id, name, sort_order
    \\FROM product_category
    \\WHERE active = 1
    \\ORDER BY sort_order, name;
;

/// The tables on the floor. A table that is not in use is not shown:
/// the board is what the floor looks like, not what it once looked like.
pub const tables_sql =
    \\SELECT id, category_id, name, status, seats, pos_x, pos_y
    \\FROM dining_table
    \\WHERE active = 1
    \\ORDER BY name;
;

pub const employees_sql =
    \\SELECT id, name, role, active
    \\FROM employee
    \\WHERE active = 1
    \\ORDER BY name;
;

/// The customers the restaurant knows. One the restaurant has
/// forgotten is not a customer.
pub const customers_sql =
    \\SELECT id, name, phone, email, loyalty_points
    \\FROM customer
    \\WHERE active = 1
    \\ORDER BY name;
;

/// The orders, with what has been paid for them.
///
/// The payment count is here because the order list has to know, before
/// anyone is offered the chance to close an order, whether the money
/// has been taken. An order that can be closed without being paid for
/// is a sale the restaurant never sees.
pub const orders_sql =
    \\SELECT id, order_no, order_type, status, dining_table_id, customer_id,
    \\       employee_id, subtotal_minor, tax_minor, discount_minor,
    \\       total_minor, placed_at, notes,
    \\       (SELECT COUNT(*) FROM payment WHERE order_id = orders.id) AS paid
    \\FROM orders
    \\WHERE status <> 5
    \\ORDER BY placed_at DESC
    \\LIMIT 200;
;

pub const order_lines_sql =
    \\SELECT id, order_id, product_id, product_name, qty, unit_price_minor,
    \\       tax_bps, notes, station_id
    \\FROM order_line
    \\WHERE order_id IN (SELECT id FROM orders WHERE status <> 5)
    \\ORDER BY id;
;

/// One setting out of `app_config`. The PIN salt lives there.
pub const config_sql =
    \\SELECT key, value FROM app_config WHERE key = 'pin_salt' LIMIT 1;
;

/// The sign-in query.
///
/// The role is part of the lookup, not a check afterwards: the session
/// is for ONE operating mode, and the employee who may work that mode is
/// the one whose stored role says so. A PIN that belongs to a waiter
/// finds no row here when the till is in admin mode, and the sign-in is
/// refused.
///
/// The two parameters are the PIN hash (text) and the stored role
/// (integer) - see `rbac.employee_role`.
pub const login_sql =
    \\SELECT id, name, role, pin_hash FROM employee
    \\WHERE (pin_hash = ?1 OR pin_hash = ?2) AND role = ?3 AND active = 1
    \\LIMIT 1;
;

/// Which station cooks which product.
pub const product_stations_sql =
    \\SELECT product_id, station_id FROM product_station;
;

/// The kitchen stations a ticket can be routed to.
pub const stations_sql =
    \\SELECT id, name, sort_order FROM kds_station WHERE active = 1 ORDER BY sort_order, name;
;

/// The reservations.
pub const reservations_sql =
    \\SELECT id, name, phone, guests, reserved_at, status, notes FROM reservation ORDER BY reserved_at;
;

/// The suppliers.
/// The suppliers the restaurant buys from. One it no longer buys
/// from is not on the list.
pub const suppliers_sql =
    \\SELECT id, name, phone, email, address, gstin, active FROM supplier WHERE active = 1 ORDER BY name;
;

/// The purchase orders.
pub const purchase_orders_sql =
    \\SELECT id, supplier_id, order_no, status, total_minor, ordered_at, expected_at, notes
    \\FROM purchase_order ORDER BY ordered_at DESC;
;

/// The stock on the shelf.
pub const inventory_sql =
    \\SELECT id, name, stock_qty, track_stock, active FROM product
    \\WHERE track_stock = 1 ORDER BY name;
;

/// The printers the restaurant has.
pub const printers_sql =
    \\SELECT id, name, kind, transport, address, job, active FROM printer ORDER BY name;
;

/// The tax slabs the menu prices against.
pub const tax_slabs_sql =
    \\SELECT id, name, rate_bps, inclusive, active FROM tax_slab ORDER BY name;
;

/// The modifier groups on the menu.
pub const modifier_groups_sql =
    \\SELECT id, name, required, max_select, active FROM modifier_group ORDER BY sort_order, name;
;

/// The discounts the cashier can apply.
pub const discounts_sql =
    \\SELECT id, name, percent_bps, amount_minor, active FROM discount ORDER BY name;
;

/// The company row. A v2 database holds exactly one company.
pub const company_sql =
    \\SELECT id, name, currency_code, currency_symbol, tax_inclusive,
    \\       address, phone, tax_number, currency_decimals
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

/// Watch the open orders. The kitchen board is the one screen that
/// must not wait for a refresh: a live query re-runs itself when
/// SQLite says the `orders` table changed.
pub fn watchOpenOrders(fx: *Effects) void {
    fx.dbSubscribe(.{
        .key = key_watch_orders,
        .sql = orders_sql,
        .tables = &.{"orders"},
        .on_result = Effects.dbMsg(.orders_loaded),
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

/// Store the installation salt, if the database does not have one yet.
///
/// The write is a single statement and the engine runs it atomically
/// with anything else in the same transaction.
///
/// The salt is written ONCE and never replaced. Every PIN hash in the
/// database was computed against the salt that is already there, so a
/// later boot that overwrites it would lock every employee out of the
/// till. `DO NOTHING` makes the first salt win.
///
/// The setup transaction writes the salt too - that is the path a fresh
/// installation takes, because the operator's PIN hash and the salt it
/// was hashed with must land together or not at all.
pub fn saveSalt(fx: *Effects, key: u64, salt: []const u8, at: i64) void {
    var params: [2]native_sdk.EffectDbValue = .{
        .{ .text = salt },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO app_config (key, value, updated_at) VALUES ('pin_salt', ?1, ?2)
            \\ON CONFLICT(key) DO NOTHING;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.config_saved),
    });
}

pub fn loadProductStations(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_product_stations,
        .sql = product_stations_sql,
        .on_result = Effects.dbMsg(.product_stations_loaded),
    });
}

pub fn loadReservations(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_reservations,
        .sql = reservations_sql,
        .on_result = Effects.dbMsg(.reservations_loaded),
    });
}

pub fn loadSuppliers(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_suppliers,
        .sql = suppliers_sql,
        .on_result = Effects.dbMsg(.suppliers_loaded),
    });
}

pub fn loadPurchaseOrders(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_purchase_orders,
        .sql = purchase_orders_sql,
        .on_result = Effects.dbMsg(.purchase_orders_loaded),
    });
}

pub fn loadInventory(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_inventory,
        .sql = inventory_sql,
        .on_result = Effects.dbMsg(.inventory_loaded),
    });
}

/// The settings and the lists, loaded when their screen is opened.
/// The effects channel has sixteen slots: loading everything at once
/// fills them, and the queries that arrive late are refused.
pub fn loadForScreen(fx: *Effects, screen: nav.Screen) void {
    switch (screen) {
        .settings_printers => loadPrinters(fx),
        .settings_tax => loadTaxSlabs(fx),
        .settings_modifiers => loadModifierGroups(fx),
        .settings_discounts => loadDiscounts(fx),
        .customers => loadCustomers(fx),
        .pos => loadDiscounts(fx),
        .reservations => loadReservations(fx),
        .suppliers => loadSuppliers(fx),
        .purchase_orders => loadPurchaseOrders(fx),
        else => {},
    }
}

pub fn loadCustomers(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_customers,
        .sql = customers_sql,
        .on_result = Effects.dbMsg(.customers_loaded),
    });
}

/// Replace an employee's PIN.
///
/// A hash is replaced, not added: the old one stops working the moment
/// the new one is written, which is what a reset means.
pub fn saveEmployeePin(fx: *Effects, key: u64, employee_id: i64, hash: []const u8) void {
    var params: [2]native_sdk.EffectDbValue = .{
        .{ .text = hash },
        .{ .integer = employee_id },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql = "UPDATE employee SET pin_hash = ?1 WHERE id = ?2;",
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.employee_saved),
    });
}

/// Write a category: a new one, or the one the form is editing.
pub fn saveCategory(fx: *Effects, key: u64, id: i64, name: []const u8, at: i64) void {
    var params: [3]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO product_category (id, name, sort_order, active)
            \\VALUES (?1, ?2, 0, 1)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.category_saved),
    });
}

/// Write a discount: a new one, or the one the form is editing.
pub fn saveDiscount(
    fx: *Effects,
    key: u64,
    id: i64,
    name: []const u8,
    percent_bps: i64,
    amount_minor: i64,
    at: i64,
) void {
    var params: [6]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .integer = percent_bps },
        .{ .integer = amount_minor },
        .{ .integer = 1 },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO discount (id, name, percent_bps, amount_minor, active, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2, percent_bps = ?3, amount_minor = ?4;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.discount_saved),
    });
}

/// Write a tax slab: a new one, or the one the form is editing.
pub fn saveTaxSlab(
    fx: *Effects,
    key: u64,
    id: i64,
    name: []const u8,
    rate_bps: i64,
    inclusive: bool,
) void {
    var params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .integer = rate_bps },
        .{ .integer = if (inclusive) 1 else 0 },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO tax_slab (id, name, rate_bps, inclusive, active)
            \\VALUES (?1, ?2, ?3, ?4, 1)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2, rate_bps = ?3, inclusive = ?4;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.tax_slab_saved),
    });
}

pub fn loadPrinters(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_printers,
        .sql = printers_sql,
        .on_result = Effects.dbMsg(.printers_loaded),
    });
}

pub fn loadTaxSlabs(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_tax_slabs,
        .sql = tax_slabs_sql,
        .on_result = Effects.dbMsg(.tax_slabs_loaded),
    });
}

pub fn loadModifierGroups(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_modifier_groups,
        .sql = modifier_groups_sql,
        .on_result = Effects.dbMsg(.modifier_groups_loaded),
    });
}

pub fn loadDiscounts(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_discounts,
        .sql = discounts_sql,
        .on_result = Effects.dbMsg(.discounts_loaded),
    });
}

pub fn loadStations(fx: *Effects) void {
    fx.dbQuery(.{
        .key = key_stations,
        .sql = stations_sql,
        .on_result = Effects.dbMsg(.stations_loaded),
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
    loadStations(fx);
    loadProductStations(fx);

    loadCategories(fx);
    loadProducts(fx);
    loadTables(fx);
    loadEmployees(fx);
    loadCustomers(fx);
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
            .food_label = enumFromInt(domain.FoodType, reader.intOf(&values, "food_type", 0)).label(),
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
            .role_label = enumFromInt(domain.EmployeeRole, reader.intOf(&values, "role", 0)).label(),
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
            .points_label = "points",
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
            .paid = reader.intOf(&values, "paid", 0) > 0,
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
            .station_id = reader.intOf(&values, "station_id", 0),
            .notes = model.order_lines_buf.dupe(reader.textOf(&values, "notes")) orelse "",
        };
    }
    model.order_lines = list[0..index];
}

pub fn decodeProductStations(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.product_stations_buf.reset();
    const count = reader.rows_left;
    const list = model.product_stations_buf.allocSlice(domain.ProductStation, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .product_id = reader.intOf(&values, "product_id", 0),
            .station_id = reader.intOf(&values, "station_id", 0),
        };
    }
    model.product_stations = list[0..index];
}

pub fn decodeStations(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.stations_buf.reset();
    const count = reader.rows_left;
    const list = model.stations_buf.allocSlice(domain.KdsStation, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.stations_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .sort_order = reader.intOf(&values, "sort_order", 0),
        };
    }
    model.stations_list = list[0..index];
}

pub fn decodeReservations(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.reservations_buf.reset();
    const count = reader.rows_left;
    const list = model.reservations_buf.allocSlice(domain.Reservation, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        const status = reader.intOf(&values, "status", 0);
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.reservations_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .phone = model.reservations_buf.dupe(reader.textOf(&values, "phone")) orelse "",
            .guests = reader.intOf(&values, "guests", 0),
            .reserved_at = reader.intOf(&values, "reserved_at", 0),
            .reserved_seconds = @divTrunc(reader.intOf(&values, "reserved_at", 0), 1000),
            .status = status,
            .status_label = reservationStatusLabel(status),
            .notes = model.reservations_buf.dupe(reader.textOf(&values, "notes")) orelse "",
        };
    }
    model.reservations_list = list[0..index];
}

pub fn decodeSuppliers(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.suppliers_buf.reset();
    const count = reader.rows_left;
    const list = model.suppliers_buf.allocSlice(domain.Supplier, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.suppliers_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .phone = model.suppliers_buf.dupe(reader.textOf(&values, "phone")) orelse "",
            .email = model.suppliers_buf.dupe(reader.textOf(&values, "email")) orelse "",
            .address = model.suppliers_buf.dupe(reader.textOf(&values, "address")) orelse "",
            .gstin = model.suppliers_buf.dupe(reader.textOf(&values, "gstin")) orelse "",
            .active = reader.boolOf(&values, "active"),
        };
    }
    model.suppliers_list = list[0..index];
}

pub fn decodePurchaseOrders(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.purchase_orders_buf.reset();
    const count = reader.rows_left;
    const list = model.purchase_orders_buf.allocSlice(domain.PurchaseOrder, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        const status = reader.intOf(&values, "status", 0);
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .order_no = model.purchase_orders_buf.dupe(reader.textOf(&values, "order_no")) orelse "",
            .status = status,
            .status_label = purchaseStatusLabel(status),
            .total_minor = reader.intOf(&values, "total_minor", 0),
            .ordered_at = reader.intOf(&values, "ordered_at", 0),
            .ordered_seconds = @divTrunc(reader.intOf(&values, "ordered_at", 0), 1000),
            .expected_at = reader.intOf(&values, "expected_at", 0),
            .notes = model.purchase_orders_buf.dupe(reader.textOf(&values, "notes")) orelse "",
        };
    }
    model.purchase_orders_list = list[0..index];
}

/// A reservation's status, as the row shows it.
fn reservationStatusLabel(status: i64) []const u8 {
    return switch (status) {
        0 => "Booked",
        1 => "Seated",
        2 => "Cancelled",
        else => "Booked",
    };
}

/// A purchase order's status, as the row shows it.
fn purchaseStatusLabel(status: i64) []const u8 {
    return switch (status) {
        0 => "Ordered",
        1 => "Part received",
        2 => "Received",
        3 => "Cancelled",
        else => "Ordered",
    };
}

pub fn decodePrinters(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.printers_buf.reset();
    const count = reader.rows_left;
    const list = model.printers_buf.allocSlice(domain.Printer, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.printers_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .kind = model.printers_buf.dupe(reader.textOf(&values, "kind")) orelse "",
            .transport = model.printers_buf.dupe(reader.textOf(&values, "transport")) orelse "",
            .address = model.printers_buf.dupe(reader.textOf(&values, "address")) orelse "",
            .job = model.printers_buf.dupe(reader.textOf(&values, "job")) orelse "",
            .active = reader.boolOf(&values, "active"),
        };
    }
    model.printers_list = list[0..index];
}

pub fn decodeTaxSlabs(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.tax_slabs_buf.reset();
    const count = reader.rows_left;
    const list = model.tax_slabs_buf.allocSlice(domain.TaxSlab, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.tax_slabs_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .rate_bps = reader.intOf(&values, "rate_bps", 0),
            .inclusive = reader.boolOf(&values, "inclusive"),
            .active = reader.boolOf(&values, "active"),
            .tax_label = if (reader.boolOf(&values, "inclusive")) "Inclusive" else "Exclusive",
        };
    }
    model.tax_slabs_list = list[0..index];
}

pub fn decodeModifierGroups(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.modifier_groups_buf.reset();
    const count = reader.rows_left;
    const list = model.modifier_groups_buf.allocSlice(domain.ModifierGroup, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.modifier_groups_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .required = reader.boolOf(&values, "required"),
            .max_select = reader.intOf(&values, "max_select", 1),
            .active = reader.boolOf(&values, "active"),
            .required_label = if (reader.boolOf(&values, "required")) "Required" else "Optional",
        };
    }
    model.modifier_groups_list = list[0..index];
}

pub fn decodeDiscounts(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.discounts_buf.reset();
    const count = reader.rows_left;
    const list = model.discounts_buf.allocSlice(domain.Discount, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.discounts_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .percent_bps = reader.intOf(&values, "percent_bps", 0),
            .amount_minor = reader.intOf(&values, "amount_minor", 0),
            .active = reader.boolOf(&values, "active"),
            .value_label = discountValueLabel(
                reader.intOf(&values, "percent_bps", 0),
                reader.intOf(&values, "amount_minor", 0),
            ),
        };
    }
    model.discounts_list = list[0..index];
}

pub fn decodeCompany(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    var values: [page.max_columns]page.Value = undefined;
    if (!reader.nextRow(&values)) return;
    // The page bytes are drain scratch: the model keeps these strings,
    // so they are COPIED into its own buffer.
    model.company_buf.reset();
    model.company_id = reader.intOf(&values, "id", 0);
    model.company_name_field = model.company_buf.dupe(reader.textOf(&values, "name")) orelse "";
    model.company_address_field = model.company_buf.dupe(reader.textOf(&values, "address")) orelse "";
    model.company_phone_field = model.company_buf.dupe(reader.textOf(&values, "phone")) orelse "";
    model.company_tax_field = model.company_buf.dupe(reader.textOf(&values, "tax_number")) orelse "";
    model.currency_code = model.company_buf.dupe(reader.textOf(&values, "currency_code")) orelse "";
    model.currency_symbol = model.company_buf.dupe(reader.textOf(&values, "currency_symbol")) orelse "";
    model.tax_inclusive = reader.boolOf(&values, "tax_inclusive");
    model.currency_decimals = reader.intOf(&values, "currency_decimals", 2);
}

/// Open an order for a table. A table that already has an open order
/// is not given a second one: the waiter keeps adding to the order the
/// table already has.
pub fn openOrderForTable(
    fx: *Effects,
    key: u64,
    table_id: i64,
    employee_id: i64,
    at: i64,
) void {
    // The order number is a sequence, and the database assigns it: the
    // statement that takes the next number and the statement that
    // stores the order are one transaction.
    var sequence_params: [1]native_sdk.EffectDbValue = .{.{ .integer = at }};
    var order_params: [3]native_sdk.EffectDbValue = .{
        .{ .integer = at },
        .{ .integer = table_id },
        .{ .integer = employee_id },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{
            .{
                .sql =
                \\INSERT INTO sequence (name, value, updated_at) VALUES ('order_no', 1, ?1)
                \\ON CONFLICT(name) DO UPDATE SET value = value + 1, updated_at = ?1;
                ,
                .params = &sequence_params,
            },
            .{
                .sql =
                \\INSERT INTO orders (id, order_no, order_type, status, dining_table_id,
                \\  customer_id, employee_id, subtotal_minor, tax_minor, discount_minor,
                \\  total_minor, placed_at, notes, created_at, updated_at)
                \\VALUES (?1, (SELECT printf('%06d', value) FROM sequence WHERE name = 'order_no'),
                \\  0, 0, ?2, NULL, ?3, 0, 0, 0, 0, ?1, '', ?1, ?1);
                ,
                .params = &order_params,
            },
            .{
                // The table is occupied now that it has an order. The
                // board shows what is true, and a table that says
                // "Free" while a guest is sitting at it is a lie the
                // whole floor has to work around.
                .sql = "UPDATE dining_table SET status = 1 WHERE id = ?1;",
                .params = &.{.{ .integer = table_id }},
            },
        },
        .on_result = Effects.dbMsg(.order_opened),
    });
}

/// Add one line to an open order and bring the order's total up with
/// it. One transaction, so a line never exists without its total.
pub fn addOrderLine(
    fx: *Effects,
    key: u64,
    order_id: i64,
    product_id: i64,
    product_name: []const u8,
    unit_price_minor: i64,
    at: i64,
) void {
    var line_params: [5]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = product_id },
        .{ .text = product_name },
        .{ .integer = unit_price_minor },
        .{ .integer = at },
    };
    var order_params: [2]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{
            .{
                // The line id is left to SQLite: two lines added in the
                // same millisecond are still two lines.
                .sql =
                \\INSERT INTO order_line (id, order_id, product_id, product_name, qty,
                \\  unit_price_minor, tax_bps, notes, created_at)
                \\VALUES (NULL, ?1, ?2, ?3, 1, ?4, 0, '', ?5);
                ,
                .params = &line_params,
            },
            .{
                .sql =
                \\UPDATE orders SET
                \\  subtotal_minor = (SELECT COALESCE(SUM(unit_price_minor * qty), 0) FROM order_line WHERE order_id = ?1),
                \\  total_minor = (SELECT COALESCE(SUM(unit_price_minor * qty), 0) FROM order_line WHERE order_id = ?1),
                \\  updated_at = ?2
                \\WHERE id = ?1;
                ,
                .params = &order_params,
            },
        },
        .on_result = Effects.dbMsg(.order_line_added),
    });
}

/// Save the company's details. One statement, one row.
pub fn updateCompany(
    fx: *Effects,
    key: u64,
    name: []const u8,
    address: []const u8,
    phone: []const u8,
    tax_number: []const u8,
) void {
    // The parameters match the placeholders EXACTLY: the engine refuses
    // a statement whose parameter count differs from the placeholders it
    // uses, and the refusal is a silent no-write.
    var params: [4]native_sdk.EffectDbValue = .{
        .{ .text = name },
        .{ .text = address },
        .{ .text = phone },
        .{ .text = tax_number },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\UPDATE company SET name = ?1, address = ?2, phone = ?3, tax_number = ?4
            \\WHERE id = (SELECT id FROM company LIMIT 1);
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.company_saved),
    });
}

/// Save a product. A product of id zero is a new one.
pub fn saveProduct(
    fx: *Effects,
    key: u64,
    id: i64,
    category_id: i64,
    name: []const u8,
    price_minor: i64,
    food_type: i64,
    at: i64,
) void {
    var params: [7]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .integer = category_id },
        .{ .text = name },
        .{ .integer = price_minor },
        .{ .integer = food_type },
        .{ .integer = at },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO product (id, category_id, name, price_minor, product_type, food_type,
            \\  tax_slab_id, stock_qty, track_stock, active, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, 0, ?5, 0, NULL, 0, 1, ?6, ?7)
            \\ON CONFLICT(id) DO UPDATE SET category_id = ?2, name = ?3, price_minor = ?4,
            \\  food_type = ?5, updated_at = ?7;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.product_saved),
    });
}

/// Save an employee. An employee of id zero is a new one.
/// Rewrite an employee's PIN hash in the modern form.
///
/// The sign-in finds the employee by the hash it computes, so the row
/// keeps the hash it was given - but an old SHA-256 digest is worth
/// nothing to an attacker with the database, and this is the moment to
/// replace it.
pub fn savePinHash(fx: *Effects, key: u64, employee_id: i64, hash: []const u8) void {
    var params: [2]native_sdk.EffectDbValue = .{
        .{ .text = hash },
        .{ .integer = employee_id },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql = "UPDATE employee SET pin_hash = ?1 WHERE id = ?2;",
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.pin_rehashed),
    });
}

pub fn saveEmployee(
    fx: *Effects,
    key: u64,
    id: i64,
    name: []const u8,
    role: i64,
    at: i64,
) void {
    var params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .integer = role },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO employee (id, name, role, pin_hash, active, created_at)
            \\VALUES (?1, ?2, ?3, '', 1, ?4)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2, role = ?3;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.employee_saved),
    });
}

/// Save the currency the restaurant trades in.
pub fn saveCurrency(fx: *Effects, key: u64, code: []const u8, symbol: []const u8, decimals: i64) void {
    var params: [3]native_sdk.EffectDbValue = .{
        .{ .text = code },
        .{ .text = symbol },
        .{ .integer = decimals },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\UPDATE company SET currency_code = ?1, currency_symbol = ?2, currency_decimals = ?3
            \\WHERE id = (SELECT id FROM company LIMIT 1);
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.currency_saved),
    });
}

/// Take the payment for an order and close it. ONE transaction: the
/// money and the closed order land together, or neither does. A paid
/// order that is still open is a cashier's worst day.
pub fn takePayment(
    fx: *Effects,
    key: u64,
    order_id: i64,
    from_status: domain.OrderStatus,
    mode: domain.PaymentMode,
    amount_minor: i64,
    at: i64,
) void {
    // Each statement carries its OWN parameters: the engine checks that
    // a statement's parameter count matches the placeholders it uses,
    // and one shared array for three different statements never does.
    //
    // The payment, the history and the close are all CONDITIONAL on the
    // order being where it should be. A second tap finds the order
    // closed, writes nothing, and the customer is charged once.
    var payment_params: [6]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = order_id },
        .{ .integer = @intFromEnum(mode) },
        .{ .integer = amount_minor },
        .{ .integer = at },
        .{ .integer = @intFromEnum(from_status) },
    };
    var order_params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = @intFromEnum(domain.OrderStatus.completed) },
        .{ .integer = at },
        .{ .integer = @intFromEnum(from_status) },
    };
    var history_params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = @intFromEnum(domain.OrderStatus.completed) },
        .{ .integer = at },
        .{ .integer = @intFromEnum(from_status) },
    };

    fx.dbExec(.{
        .key = key,
        .statements = &.{
            .{
                // The history first: it says the order closed, and it
                // is only true if the order was still open.
                .sql =
                \\INSERT INTO order_status_history (order_id, status, changed_at)
                \\SELECT ?1, ?2, ?3
                \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?1 AND status = ?4);
                ,
                .params = &history_params,
            },
            .{
                // The payment, for the same reason: one order, one
                // payment. The index on the table says so too.
                .sql =
                \\INSERT INTO payment (id, order_id, mode, amount_minor, reference, paid_at, created_at)
                \\SELECT ?1, ?2, ?3, ?4, '', ?5, ?5
                \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?2 AND status = ?6);
                ,
                .params = &payment_params,
            },
            .{
                .sql = "UPDATE orders SET status = ?2, updated_at = ?3 WHERE id = ?1 AND status = ?4;",
                .params = &order_params,
            },
            .{
                // The guest has paid and gone, so the table is free
                // again - in the same transaction as the payment, so a
                // table is never free while the money is still owed.
                .sql =
                \\UPDATE dining_table SET status = 0
                \\WHERE id = (SELECT dining_table_id FROM orders WHERE id = ?1);
                ,
                .params = &.{.{ .integer = order_id }},
            },
        },
        .on_result = Effects.dbMsg(.payment_taken),
    });
}

/// The first-run setup: the company, the first operator, the
/// installation salt, and a starter menu and floor. ONE transaction - a
/// restaurant that exists with no company, or a company with no
/// operator, is worse than a setup that failed and can be retried.
///
/// The salt is in the same transaction as the operator's PIN hash, and
/// it is the salt that hash was computed with. A hash without its salt
/// is a PIN that can never be verified, so the two must land together:
/// either the whole installation is there, or none of it is.
///
/// The salt is written with `DO UPDATE` here, unlike the boot-time
/// writer: at this point the installation has no company and no
/// employees, so there is no existing hash to invalidate, and the salt
/// the operator's PIN was hashed with must be the salt that is stored.
pub fn setupCompany(
    fx: *Effects,
    key: u64,
    name: []const u8,
    currency_code: []const u8,
    currency_symbol: []const u8,
    admin_name: []const u8,
    pin_hash: []const u8,
    pin_salt: []const u8,
    currency_decimals: i64,
    address: []const u8,
    phone: []const u8,
    tax_number: []const u8,
    at: i64,
) void {
    const statement_count = comptime 3 + starter.categories.len + starter.dishes.len + starter.stations.len + starter.dishes.len + 1 + starter.tables.len;
    var statements: [statement_count]native_sdk.EffectDbStatement = undefined;
    var count: usize = 0;

    var company_params: [10]native_sdk.EffectDbValue = .{
        .{ .integer = 1 },
        .{ .text = name },
        .{ .text = currency_code },
        .{ .text = currency_symbol },
        .{ .integer = 0 },
        .{ .integer = at },
        .{ .integer = currency_decimals },
        .{ .text = address },
        .{ .text = phone },
        .{ .text = tax_number },
    };
    statements[count] = .{
        .sql =
        \\INSERT INTO company (id, name, currency_code, currency_symbol, tax_inclusive,
        \\  created_at, currency_decimals, address, phone, tax_number)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
        ,
        .params = &company_params,
    };
    count += 1;

    var employee_params: [6]native_sdk.EffectDbValue = .{
        .{ .integer = 1 },
        .{ .text = admin_name },
        .{ .integer = 0 },
        .{ .text = pin_hash },
        .{ .integer = 1 },
        .{ .integer = at },
    };
    statements[count] = .{
        .sql =
        \\INSERT INTO employee (id, name, role, pin_hash, active, created_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        ,
        .params = &employee_params,
    };
    count += 1;

    // The salt the operator's PIN was hashed with, in the same
    // transaction as the hash itself.
    var salt_params: [2]native_sdk.EffectDbValue = .{
        .{ .text = pin_salt },
        .{ .integer = at },
    };
    statements[count] = .{
        .sql =
        \\INSERT INTO app_config (key, value, updated_at) VALUES ('pin_salt', ?1, ?2)
        \\ON CONFLICT(key) DO UPDATE SET value = ?1, updated_at = ?2;
        ,
        .params = &salt_params,
    };
    count += 1;

    // The parameter arrays are declared HERE, not inside the loops: a
    // parameter array declared in a loop body dies at the end of the
    // iteration, and the statement would then point at dead memory.
    var station_params: [starter.stations.len][3]native_sdk.EffectDbValue = undefined;
    var mapping_params: [starter.dishes.len][2]native_sdk.EffectDbValue = undefined;
    var category_params: [starter.categories.len][3]native_sdk.EffectDbValue = undefined;
    var product_params: [starter.dishes.len][8]native_sdk.EffectDbValue = undefined;
    var table_params: [starter.tables.len][5]native_sdk.EffectDbValue = undefined;

    // The categories, in menu order.
    for (starter.categories, 0..) |category, index| {
        category_params[index] = .{
            .{ .integer = @intCast(index + 1) },
            .{ .text = category },
            .{ .integer = @intCast(index + 1) },
        };
        statements[count] = .{
            .sql = "INSERT INTO product_category (id, name, sort_order) VALUES (?1, ?2, ?3);",
            .params = &category_params[index],
        };
        count += 1;
    }

    // The dishes, each against its category.
    for (starter.dishes, 0..) |dish, index| {
        const category_id = categoryIdOf(dish.category);
        product_params[index] = .{
            .{ .integer = @intCast(index + 1) },
            .{ .integer = category_id },
            .{ .text = dish.name },
            .{ .integer = dish.price_minor },
            .{ .integer = @intFromEnum(dish.product_type) },
            .{ .integer = @intFromEnum(dish.food_type) },
            .{ .integer = 0 },
            .{ .integer = at },
        };
        statements[count] = .{
            .sql =
            \\INSERT INTO product (id, category_id, name, price_minor, product_type, food_type,
            \\  tax_slab_id, stock_qty, track_stock, active, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, 0, 1, ?8, ?8);
            ,
            .params = &product_params[index],
        };
        count += 1;
    }

    // The kitchen stations, and which station cooks which dish.
    for (starter.stations, 0..) |station, index| {
        station_params[index] = .{
            .{ .integer = @intCast(index + 1) },
            .{ .text = station.name },
            .{ .integer = @intCast(index + 1) },
        };
        statements[count] = .{
            .sql = "INSERT INTO kds_station (id, name, sort_order, active) VALUES (?1, ?2, ?3, 1);",
            .params = &station_params[index],
        };
        count += 1;
    }
    for (starter.dishes, 0..) |dish, index| {
        mapping_params[index] = .{
            .{ .integer = @intCast(index + 1) },
            .{ .integer = @intCast(starter.stationOf(dish)) },
        };
        statements[count] = .{
            .sql = "INSERT INTO product_station (product_id, station_id) VALUES (?1, ?2);",
            .params = &mapping_params[index],
        };
        count += 1;
    }

    // The floor: one category, and the tables in it.
    var table_category_params: [1]native_sdk.EffectDbValue = .{.{ .text = starter.table_category }};
    statements[count] = .{
        .sql = "INSERT INTO dining_table_category (id, name) VALUES (1, ?1);",
        .params = &table_category_params,
    };
    count += 1;

    for (starter.tables, 0..) |table, index| {
        table_params[index] = .{
            .{ .integer = @intCast(index + 1) },
            .{ .integer = 1 },
            .{ .text = table.name },
            .{ .integer = table.seats },
            .{ .integer = @intCast(index) },
        };
        statements[count] = .{
            .sql =
            \\INSERT INTO dining_table (id, category_id, name, status, seats, pos_x, pos_y, active)
            \\VALUES (?1, ?2, ?3, 0, ?4, ?5, 0, 1);
            ,
            .params = &table_params[index],
        };
        count += 1;
    }

    fx.dbExec(.{
        .key = key,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.setup_created),
    });
}

/// The id of a starter category. The categories are written in menu
/// order, so the id is the position in that list.
fn categoryIdOf(name: []const u8) i64 {
    for (starter.categories, 0..) |category, index| {
        if (std.mem.eql(u8, category, name)) return @intCast(index + 1);
    }
    return 1;
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
/// A duplicate order id is a constraint failure, and it is left as one.
/// The write used to swallow it and update the order that was already
/// there, which merged two sales into one row - the second cashier's
/// ticket became the first cashier's ticket with the first cashier's
/// lines and the second cashier's status.
///
/// No allocator is needed: `dbExec` executes the statements
/// synchronously, so the parameters can live on the stack for the
/// duration of the call.
pub fn saveOrder(fx: *Effects, order: domain.Order, lines: []const domain.OrderLine, request_key: []const u8) void {
    // The order, its lines, and the stock it takes: three statements
    // per line, and one transaction for all of them.
    var statements: [2 + 3 * max_order_lines]native_sdk.EffectDbStatement = undefined;
    var line_params: [max_order_lines][9]native_sdk.EffectDbValue = undefined;
    var stock_params: [max_order_lines][3]native_sdk.EffectDbValue = undefined;

    // The order number is a sequence, and the database assigns it. The
    // statement that takes the next number and the statement that
    // stores the order are one transaction, so a sale that fails does
    // not consume a number and a number is never stored twice.
    //
    // The bump is conditional on the request key being new: a RETRY is
    // the same sale, and it must not take a second number with it. The
    // gap a naive bump would leave is exactly the kind of thing a
    // jurisdiction asks about.
    var sequence_params: [2]native_sdk.EffectDbValue = .{
        .{ .integer = order.placed_at },
        .{ .text = request_key },
    };
    statements[0] = .{
        .sql =
        \\INSERT INTO sequence (name, value, updated_at)
        \\SELECT 'order_no', 1, ?1
        \\WHERE NOT EXISTS (SELECT 1 FROM orders WHERE request_key = ?2)
        \\ON CONFLICT(name) DO UPDATE SET value = value + 1, updated_at = ?1;
        ,
        .params = &sequence_params,
    };

    var order_params: [13]native_sdk.EffectDbValue = .{
        .{ .integer = order.id },
        .{ .integer = @intFromEnum(order.order_type) },
        .{ .integer = @intFromEnum(order.status) },
        // A table or a customer of zero means "none" - and "none" is
        // NULL, not the id zero: a foreign key that points at zero
        // points at a row that does not exist, and the write fails.
        idParam(order.dining_table_id),
        idParam(order.customer_id),
        idParam(order.employee_id),
        .{ .integer = order.subtotal_minor },
        .{ .integer = order.tax_minor },
        .{ .integer = order.discount_minor },
        .{ .integer = order.total_minor },
        .{ .integer = order.placed_at },
        .{ .text = order.notes },
        .{ .text = request_key },
    };
    statements[1] = .{
        .sql =
        \\INSERT INTO orders (id, order_no, order_type, status, dining_table_id,
        \\  customer_id, employee_id, subtotal_minor, tax_minor, discount_minor,
        \\  total_minor, placed_at, notes, created_at, updated_at, request_key)
        \\VALUES (?1, (SELECT printf('%06d', value) FROM sequence WHERE name = 'order_no'),
        \\  ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?11, ?11, ?13)
        \\ON CONFLICT(request_key) DO NOTHING;
        ,
        .params = &order_params,
    };
    var count: usize = 2;

    for (lines) |line| {
        if (count >= statements.len) break;
        const slot = count - 2;
        line_params[slot] = .{
            .{ .integer = line.id },
            .{ .integer = order.id },
            idParam(line.product_id),
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
            \\ON CONFLICT(id) DO NOTHING;
            ,
            .params = &line_params[slot],
        };
        count += 1;

        // The stock goes down with the sale, in the same transaction:
        // a dish that was sold is a dish that is not on the shelf, and
        // a sale that did not happen leaves the shelf alone. Only the
        // products that are counted come down - the others are not
        // tracked, and subtracting from them would be a lie.
        stock_params[slot] = .{
            .{ .integer = line.qty },
            .{ .integer = line.product_id },
            .{ .integer = order.placed_at },
        };
        statements[count] = .{
            .sql =
            \\UPDATE product SET stock_qty = COALESCE(stock_qty, 0) - ?1, updated_at = ?3
            \\WHERE id = ?2 AND track_stock = 1;
            ,
            .params = &stock_params[slot],
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
///
/// The move is CONDITIONAL: it happens only from the status the order
/// is in now, and the history row is written only when the order was
/// really there. A second tap - a double click, or two devices - finds
/// the order already moved on, writes nothing, and leaves the history
/// with one row instead of two.
///
/// The order's status is the model's, not the database's, because the
/// model read it a moment ago; the database is the one that decides
/// whether the move still applies.
pub fn setOrderStatus(
    fx: *Effects,
    order_id: i64,
    from_status: domain.OrderStatus,
    to_status: domain.OrderStatus,
    at: i64,
) void {
    fx.dbExec(.{
        .key = key_write_order,
        .statements = &.{
            .{
                // The history first, and only for an order that is
                // where the move expects it: the row says the order
                // BECAME this status, and it is only true if it was
                // not already.
                .sql =
                \\INSERT INTO order_status_history (order_id, status, changed_at)
                \\SELECT ?1, ?2, ?3
                \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?1 AND status = ?4);
                ,
                .params = &.{
                    .{ .integer = order_id },
                    .{ .integer = @intFromEnum(to_status) },
                    .{ .integer = at },
                    .{ .integer = @intFromEnum(from_status) },
                },
            },
            .{
                .sql = "UPDATE orders SET status = ?2, updated_at = ?3 WHERE id = ?1 AND status = ?4;",
                .params = &.{
                    .{ .integer = order_id },
                    .{ .integer = @intFromEnum(to_status) },
                    .{ .integer = at },
                    .{ .integer = @intFromEnum(from_status) },
                },
            },
        },
        .on_result = Effects.dbMsg(.order_status_saved),
    });
}

// ------------------------------------------------------------- helpers

/// An id for a foreign key. Zero means "no row", and "no row" is NULL:
/// a foreign key that points at zero points at a row that does not
/// exist, and the write fails.
fn idParam(value: i64) native_sdk.EffectDbValue {
    return if (value == 0) .null_value else .{ .integer = value };
}

/// A discount as the row shows it: the percentage, the amount, or both.
fn discountValueLabel(percent_bps: i64, amount_minor: i64) []const u8 {
    if (percent_bps > 0 and amount_minor > 0) return "both";
    if (percent_bps > 0) return "percent";
    if (amount_minor > 0) return "amount";
    return "none";
}

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
