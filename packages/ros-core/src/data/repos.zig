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
const record = @import("../net/record.zig");
const reference = @import("../net/reference.zig");
const cursor_mod = @import("../net/cursor.zig");
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
pub const key_payments = 42;
pub const key_report = 43;
pub const key_report_modes = 44;
pub const key_stock = 45;
pub const key_save_stock = 46;
pub const key_save_station = 47;
pub const key_db_tables = 48;
pub const key_modifiers = 51;
pub const key_save_modifier_group = 52;
pub const key_table_categories = 55;
pub const key_db_table_count = 57;
pub const key_save_table_category = 56;
pub const key_save_customer = 53;
pub const key_deactivate_employee = 54;
pub const key_devices = 49;
pub const key_sync_state = 50;
pub const key_sync_apply = 58;
pub const key_sync_cursor = 59;
pub const key_reference_bump = 60;
pub const key_reference_snapshot = 61;
pub const key_reference_version = 62;
pub const key_reference_apply = 63;

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

/// How many tables the database really has.
///
/// The app knows how many tables its own schema creates. A database
/// with MORE tables than that was made by a newer version of the app,
/// and this version must not write to it: a write that a newer app
/// would understand differently is a write that corrupts.
pub const db_table_count_sql =
    \\SELECT COUNT(*) AS n FROM sqlite_master
    \\WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
;

/// The categories the tables are grouped into.
pub const table_categories_sql =
    \\SELECT id, name FROM dining_table_category ORDER BY name;
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

/// The day's takings, in one row.
///
/// The day is the calendar day the report was asked for: the caller
/// passes the first millisecond of it, and the query counts the orders
/// placed since. A voided order is not money and is not counted.
pub const report_sql =
    \\SELECT COUNT(*) AS order_count,
    \\       COALESCE(SUM(subtotal_minor), 0) AS gross_minor,
    \\       COALESCE(SUM(tax_minor), 0) AS tax_minor,
    \\       COALESCE(SUM(discount_minor), 0) AS discount_minor,
    \\       COALESCE(SUM(total_minor), 0) AS net_minor
    \\FROM orders
    \\WHERE placed_at >= ?1 AND status <> 5;
;

/// The day's takings, split by the way they were paid.
pub const report_modes_sql =
    \\SELECT mode, COUNT(*) AS n, COALESCE(SUM(amount_minor), 0) AS amount_minor
    \\FROM payment
    \\WHERE paid_at >= ?1
    \\GROUP BY mode
    \\ORDER BY amount_minor DESC;
;

/// The money the restaurant has taken, newest first.
pub const payments_sql =
    \\SELECT p.id, p.order_id, o.order_no, p.mode, p.amount_minor,
    \\       p.reference, p.paid_at
    \\FROM payment p
    \\JOIN orders o ON o.id = p.order_id
    \\ORDER BY p.paid_at DESC
    \\LIMIT 200;
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
/// The sign-in reads the employee the picker chose.
///
/// The lookup is by EMPLOYEE, not by hash. The person is already
/// known - the picker said who - so the hash only has to be verified,
/// and one bcrypt call does that. Finding the employee by the hash
/// would need the hash to be findable, which is why the salt used to
/// be derived rather than random, and why the sign-in used to hash
/// once per candidate.
/// The id the setup gives the first employee.
///
/// The setup's PIN hash is derived from this id, so it is named here
/// once: the insert and the hash must not drift apart, or the first
/// administrator's PIN could never be verified.
pub const first_employee_id: i64 = 1;

pub const login_sql =
    \\SELECT id, name, role, pin_hash FROM employee
    \\WHERE id = ?1 AND active = 1
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

/// The stock on the shelf: the things the restaurant counts.
pub const stock_sql =
    \\SELECT id, name, COALESCE(stock_qty, 0) AS stock_qty
    \\FROM product
    \\WHERE track_stock = 1 AND active = 1
    \\ORDER BY name;
;

/// The tables in the database, and how many rows each holds.
///
/// The list is written out here rather than read from SQLite's own
/// catalogue, because SQLite cannot count the rows of a table it only
/// knows the NAME of. A test proves the two agree: every table the
/// schema creates is counted here, and no table is counted twice.
///
/// The names are in single quotes, and that matters: in SQL a double
/// quote means an IDENTIFIER, so `SELECT "company"` asks for a column
/// called company and the statement does not even prepare. The name is
/// text here, and single quotes say so.
pub const table_counts_sql =
    \\SELECT 'app_config' AS name, (SELECT COUNT(*) FROM app_config) AS n
    \\UNION ALL SELECT 'auto_print' AS name, (SELECT COUNT(*) FROM auto_print) AS n
    \\UNION ALL SELECT 'business_hours' AS name, (SELECT COUNT(*) FROM business_hours) AS n
    \\UNION ALL SELECT 'company' AS name, (SELECT COUNT(*) FROM company) AS n
    \\UNION ALL SELECT 'compliance_report' AS name, (SELECT COUNT(*) FROM compliance_report) AS n
    \\UNION ALL SELECT 'currency' AS name, (SELECT COUNT(*) FROM currency) AS n
    \\UNION ALL SELECT 'customer' AS name, (SELECT COUNT(*) FROM customer) AS n
    \\UNION ALL SELECT 'customer_loyalty' AS name, (SELECT COUNT(*) FROM customer_loyalty) AS n
    \\UNION ALL SELECT 'device' AS name, (SELECT COUNT(*) FROM device) AS n
    \\UNION ALL SELECT 'dining_table' AS name, (SELECT COUNT(*) FROM dining_table) AS n
    \\UNION ALL SELECT 'dining_table_category' AS name, (SELECT COUNT(*) FROM dining_table_category) AS n
    \\UNION ALL SELECT 'discount' AS name, (SELECT COUNT(*) FROM discount) AS n
    \\UNION ALL SELECT 'employee' AS name, (SELECT COUNT(*) FROM employee) AS n
    \\UNION ALL SELECT 'expense' AS name, (SELECT COUNT(*) FROM expense) AS n
    \\UNION ALL SELECT 'expense_category' AS name, (SELECT COUNT(*) FROM expense_category) AS n
    \\UNION ALL SELECT 'holiday_hours' AS name, (SELECT COUNT(*) FROM holiday_hours) AS n
    \\UNION ALL SELECT 'kds_station' AS name, (SELECT COUNT(*) FROM kds_station) AS n
    \\UNION ALL SELECT 'loyalty_transaction' AS name, (SELECT COUNT(*) FROM loyalty_transaction) AS n
    \\UNION ALL SELECT 'modifier' AS name, (SELECT COUNT(*) FROM modifier) AS n
    \\UNION ALL SELECT 'modifier_group' AS name, (SELECT COUNT(*) FROM modifier_group) AS n
    \\UNION ALL SELECT 'op_log' AS name, (SELECT COUNT(*) FROM op_log) AS n
    \\UNION ALL SELECT 'order_discount' AS name, (SELECT COUNT(*) FROM order_discount) AS n
    \\UNION ALL SELECT 'order_line' AS name, (SELECT COUNT(*) FROM order_line) AS n
    \\UNION ALL SELECT 'order_line_modifier' AS name, (SELECT COUNT(*) FROM order_line_modifier) AS n
    \\UNION ALL SELECT 'order_status_history' AS name, (SELECT COUNT(*) FROM order_status_history) AS n
    \\UNION ALL SELECT 'orders' AS name, (SELECT COUNT(*) FROM orders) AS n
    \\UNION ALL SELECT 'payment' AS name, (SELECT COUNT(*) FROM payment) AS n
    \\UNION ALL SELECT 'printer' AS name, (SELECT COUNT(*) FROM printer) AS n
    \\UNION ALL SELECT 'product' AS name, (SELECT COUNT(*) FROM product) AS n
    \\UNION ALL SELECT 'product_category' AS name, (SELECT COUNT(*) FROM product_category) AS n
    \\UNION ALL SELECT 'product_modifier' AS name, (SELECT COUNT(*) FROM product_modifier) AS n
    \\UNION ALL SELECT 'product_station' AS name, (SELECT COUNT(*) FROM product_station) AS n
    \\UNION ALL SELECT 'purchase_order' AS name, (SELECT COUNT(*) FROM purchase_order) AS n
    \\UNION ALL SELECT 'purchase_order_item' AS name, (SELECT COUNT(*) FROM purchase_order_item) AS n
    \\UNION ALL SELECT 'reservation' AS name, (SELECT COUNT(*) FROM reservation) AS n
    \\UNION ALL SELECT 'sequence' AS name, (SELECT COUNT(*) FROM sequence) AS n
    \\UNION ALL SELECT 'shift' AS name, (SELECT COUNT(*) FROM shift) AS n
    \\UNION ALL SELECT 'stock_adjustment' AS name, (SELECT COUNT(*) FROM stock_adjustment) AS n
    \\UNION ALL SELECT 'subscription' AS name, (SELECT COUNT(*) FROM subscription) AS n
    \\UNION ALL SELECT 'supplier' AS name, (SELECT COUNT(*) FROM supplier) AS n
    \\UNION ALL SELECT 'sync_state' AS name, (SELECT COUNT(*) FROM sync_state) AS n
    \\UNION ALL SELECT 'tax_slab' AS name, (SELECT COUNT(*) FROM tax_slab) AS n
    \\UNION ALL SELECT 'time_entry' AS name, (SELECT COUNT(*) FROM time_entry) AS n
    \\UNION ALL SELECT 'void_log_entry' AS name, (SELECT COUNT(*) FROM void_log_entry) AS n
;


/// The devices that have been in this restaurant.
pub const devices_sql =
    \\SELECT id, name, role, last_seen_at FROM device ORDER BY name, id;
;

/// What the sync sidecar has left behind.
pub const sync_state_sql =
    \\SELECT key, value FROM sync_state ORDER BY key;
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

/// The choices inside the modifier groups.
pub const modifiers_sql =
    \\SELECT id, group_id, name, price_delta_minor, active FROM modifier
    \\ORDER BY group_id, sort_order, name;
;

/// The discounts the cashier can apply.
pub const discounts_sql =
    \\SELECT id, name, percent_bps, amount_minor, active FROM discount ORDER BY name;
;

/// The company row. A Restaurant OS database holds exactly one company.
pub const company_sql =
    \\SELECT id, name, currency_code, currency_symbol, tax_inclusive,
    \\       address, phone, tax_number, currency_decimals
    \\FROM company
    \\LIMIT 1;
;

// -------------------------------------------------------------- reads

/// Ask the database a question.
///
/// Every read goes through here, so this is the ONE place the app says
/// it is loading. A screen that shows nothing while its data is on the
/// way is a screen that looks broken; one that says "loading" is a
/// screen that is working.
fn query(
    model: *Model,
    fx: *Effects,
    key: u64,
    sql: []const u8,
    params: []const native_sdk.EffectDbValue,
    on_result: Effects.DbMsgFn,
) void {
    model.reading = true;
    model.read_started_at = model.now_ms;
    fx.dbQuery(.{
        .key = key,
        .sql = sql,
        .params = params,
        .on_result = on_result,
    });
}

/// Ask for the menu. The result arrives as a `.products_loaded` message.
pub fn loadProducts(model: *Model, fx: *Effects) void {
    query(model, fx, key_products, products_sql, &.{}, Effects.dbMsg(.products_loaded));
}

pub fn loadCategories(model: *Model, fx: *Effects) void {
    query(model, fx, key_categories, categories_sql, &.{}, Effects.dbMsg(.categories_loaded));
}

/// Load the dining tables.
pub fn loadTables(model: *Model, fx: *Effects) void {
    query(model, fx, key_tables, tables_sql, &.{}, Effects.dbMsg(.tables_loaded));
}

/// Load the tables in the DATABASE, and the row count of each.
pub fn loadTableCounts(model: *Model, fx: *Effects) void {
    query(model, fx, key_db_tables, table_counts_sql, &.{}, Effects.dbMsg(.db_tables_loaded));
}

pub fn loadEmployees(model: *Model, fx: *Effects) void {
    query(model, fx, key_employees, employees_sql, &.{}, Effects.dbMsg(.employees_loaded));
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

pub fn loadOrders(model: *Model, fx: *Effects) void {
    query(model, fx, key_orders, orders_sql, &.{}, Effects.dbMsg(.orders_loaded));
}

/// Send a dish to a station.
///
/// A dish is cooked at one station, so the mapping is replaced rather
/// than added: the old rows go and the new one arrives, in the same
/// transaction. A dish at two stations would send the ticket to two
/// kitchens.
pub fn saveDishStation(fx: *Effects, key: u64, product_id: i64, station_id: i64) void {
    // Each statement gets the parameters it uses: a statement that
    // binds one parameter and is given two is refused by the engine.
    var remove: [1]native_sdk.EffectDbValue = .{.{ .integer = product_id }};
    var add: [2]native_sdk.EffectDbValue = .{
        .{ .integer = product_id },
        .{ .integer = station_id },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{
            .{
                .sql = "DELETE FROM product_station WHERE product_id = ?1;",
                .params = &remove,
            },
            .{
                .sql = "INSERT INTO product_station (product_id, station_id) VALUES (?1, ?2);",
                .params = &add,
            },
        },
        .on_result = Effects.dbMsg(.dish_assigned),
    });
}

/// Load the number of tables the database really has.
pub fn loadDbTableCount(model: *Model, fx: *Effects) void {
    query(model, fx, key_db_table_count, db_table_count_sql, &.{}, Effects.dbMsg(.db_table_count_loaded));
}

/// Load the categories of tables.
pub fn loadTableCategories(model: *Model, fx: *Effects) void {
    query(model, fx, key_table_categories, table_categories_sql, &.{}, Effects.dbMsg(.table_categories_loaded));
}

/// Write a category of tables: a new one, or the one the form is editing.
pub fn saveTableCategory(fx: *Effects, key: u64, id: i64, name: []const u8) void {
    var params: [2]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO dining_table_category (id, name) VALUES (?1, ?2)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.table_category_saved),
    });
}

/// Load the devices and the sync state, for the control centre.

pub fn loadDevices(model: *Model, fx: *Effects) void {
    query(model, fx, key_devices, devices_sql, &.{}, Effects.dbMsg(.devices_loaded));
}

pub fn loadSyncState(model: *Model, fx: *Effects) void {
    query(model, fx, key_sync_state, sync_state_sql, &.{}, Effects.dbMsg(.sync_state_loaded));
}

/// Load the stock on the shelf.
pub fn loadStock(model: *Model, fx: *Effects) void {
    query(model, fx, key_stock, stock_sql, &.{}, Effects.dbMsg(.stock_loaded));
}

/// Write a count of the stock, and say why it changed.
///
/// The count and the reason are one transaction: a number that moved
/// with no reason behind it is a number nobody can trust later. The
/// `stock_adjustment` row is the ledger - the count is what the shelf
/// says now, and the adjustment says how it got there.
pub fn saveStockCount(
    fx: *Effects,
    key: u64,
    product_id: i64,
    qty: i64,
    delta: i64,
    reason: []const u8,
    at: i64,
) void {
    // The count, the move, the reason, the product and the moment. The
    // count is what the shelf says now; the move is how far it came.
    var params: [5]native_sdk.EffectDbValue = .{
        .{ .integer = qty },
        .{ .integer = delta },
        .{ .text = reason },
        .{ .integer = product_id },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{
            .{
                .sql =
                \\INSERT INTO stock_adjustment (id, product_id, delta, reason, reference, created_at)
                \\VALUES ((SELECT COALESCE(MAX(id), 0) + 1 FROM stock_adjustment), ?4, ?2, ?3, '', ?5);
                ,
                .params = &params,
            },
            .{
                .sql = "UPDATE product SET stock_qty = ?1, updated_at = ?5 WHERE id = ?4;",
                .params = &params,
            },
        },
        .on_result = Effects.dbMsg(.stock_saved),
    });
}

/// Load the day's takings, and the way they were paid.
pub fn loadReport(model: *Model, fx: *Effects, day_start_ms: i64) void {
    var params: [1]native_sdk.EffectDbValue = .{.{ .integer = day_start_ms }};
    query(model, fx, key_report, report_sql, &params, Effects.dbMsg(.report_loaded));
    query(model, fx, key_report_modes, report_modes_sql, &params, Effects.dbMsg(.report_modes_loaded));
}

/// Load the payments the restaurant has taken.
pub fn loadPayments(model: *Model, fx: *Effects) void {
    query(model, fx, key_payments, payments_sql, &.{}, Effects.dbMsg(.payments_loaded));
}

pub fn loadOrderLines(model: *Model, fx: *Effects) void {
    query(model, fx, key_order_lines, order_lines_sql, &.{}, Effects.dbMsg(.order_lines_loaded));
}

pub fn loadConfig(model: *Model, fx: *Effects) void {
    query(model, fx, key_config, config_sql, &.{}, Effects.dbMsg(.config_loaded));
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

pub fn loadProductStations(model: *Model, fx: *Effects) void {
    query(model, fx, key_product_stations, product_stations_sql, &.{}, Effects.dbMsg(.product_stations_loaded));
}

pub fn loadReservations(model: *Model, fx: *Effects) void {
    query(model, fx, key_reservations, reservations_sql, &.{}, Effects.dbMsg(.reservations_loaded));
}

pub fn loadSuppliers(model: *Model, fx: *Effects) void {
    query(model, fx, key_suppliers, suppliers_sql, &.{}, Effects.dbMsg(.suppliers_loaded));
}

pub fn loadPurchaseOrders(model: *Model, fx: *Effects) void {
    query(model, fx, key_purchase_orders, purchase_orders_sql, &.{}, Effects.dbMsg(.purchase_orders_loaded));
}

pub fn loadInventory(model: *Model, fx: *Effects) void {
    query(model, fx, key_inventory, inventory_sql, &.{}, Effects.dbMsg(.inventory_loaded));
}

/// The settings and the lists, loaded when their screen is opened.
/// The effects channel has sixteen slots: loading everything at once
/// fills them, and the queries that arrive late are refused.
/// The data a screen shows.
///
/// This is the ONE place that knows what a screen reads, so opening a
/// screen and trying it again after a failure read the same things.
pub fn loadForScreen(model: *Model, fx: *Effects, screen: nav.Screen) void {
    switch (screen) {
        // the admin's screens
        .admin_dashboard => {
            loadOrders(model, fx);
            loadOrderLines(model, fx);
            loadProducts(model, fx);
            loadCategories(model, fx);
            loadTables(model, fx);
            loadEmployees(model, fx);
        },
        .pos => {
            loadProducts(model, fx);
            loadCategories(model, fx);
            loadDiscounts(model, fx);
        },
        .orders => loadOrders(model, fx),
        .order_detail => {
            loadOrders(model, fx);
            loadOrderLines(model, fx);
        },
        .order_confirmation => loadOrders(model, fx),
        .payments => loadPayments(model, fx),
        .reports => loadReport(model, fx, model.report_day_start_ms()),
        .customers => loadCustomers(model, fx),
        .dining_tables => loadTables(model, fx),
        .reservations => loadReservations(model, fx),
        .suppliers => loadSuppliers(model, fx),
        .purchase_orders => loadPurchaseOrders(model, fx),
        .employees => loadEmployees(model, fx),
        .product_categories => {
            loadCategories(model, fx);
            loadProducts(model, fx);
        },
        .categories => {
            loadCategories(model, fx);
            loadProducts(model, fx);
        },
        .kitchen_dishes => {
            loadProducts(model, fx);
            loadStations(model, fx);
            loadProductStations(model, fx);
        },
        .inventory_items => loadStock(model, fx),
        .settings => {},
        .settings_company => loadCompany(model, fx),
        .settings_currency => loadCompany(model, fx),
        .settings_printers => loadPrinters(model, fx),
        .settings_tax => loadTaxSlabs(model, fx),
        .settings_modifiers => {
            loadModifierGroups(model, fx);
            loadModifiers(model, fx);
        },
        .settings_discounts => loadDiscounts(model, fx),
        .data_management => {
            loadProducts(model, fx);
            loadCategories(model, fx);
            loadTables(model, fx);
            loadOrders(model, fx);
            loadEmployees(model, fx);
        },
        .db_inspector => loadTableCounts(model, fx),
        .control_center => {
            loadDevices(model, fx);
            loadSyncState(model, fx);
        },

        // the kitchen and the waiter
        .kds_board => {
            loadOrders(model, fx);
            loadOrderLines(model, fx);
            loadStations(model, fx);
            loadProductStations(model, fx);
        },
        .waiter_tables => loadTables(model, fx),
        .waiter_menu => {
            loadProducts(model, fx);
            loadCategories(model, fx);
        },
        .waiter_cart => {},
        .waiter_orders => loadOrders(model, fx),
        .display_board => {
            loadOrders(model, fx);
            loadOrderLines(model, fx);
        },

        else => {},
    }
}

pub fn loadCustomers(model: *Model, fx: *Effects) void {
    query(model, fx, key_customers, customers_sql, &.{}, Effects.dbMsg(.customers_loaded));
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

pub fn loadPrinters(model: *Model, fx: *Effects) void {
    query(model, fx, key_printers, printers_sql, &.{}, Effects.dbMsg(.printers_loaded));
}

pub fn loadTaxSlabs(model: *Model, fx: *Effects) void {
    query(model, fx, key_tax_slabs, tax_slabs_sql, &.{}, Effects.dbMsg(.tax_slabs_loaded));
}

pub fn loadModifierGroups(model: *Model, fx: *Effects) void {
    query(model, fx, key_modifier_groups, modifier_groups_sql, &.{}, Effects.dbMsg(.modifier_groups_loaded));
}

/// Load the choices in the modifier groups.
pub fn loadModifiers(model: *Model, fx: *Effects) void {
    query(model, fx, key_modifiers, modifiers_sql, &.{}, Effects.dbMsg(.modifiers_loaded));
}

/// The employee has left.
///
/// The row stays: the orders they took still name them, and a bill
/// that cannot say who served it is a bill nobody can defend. What
/// changes is that the employee is no longer on the team and can no
/// longer sign in - the sign-in query asks for `active = 1`.
pub fn deactivateEmployee(fx: *Effects, key: u64, id: i64) void {
    var params: [1]native_sdk.EffectDbValue = .{.{ .integer = id }};
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql = "UPDATE employee SET active = 0 WHERE id = ?1;",
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.employee_saved),
    });
}

/// Write a customer: a new one, or the one the form is editing.
pub fn saveCustomer(
    fx: *Effects,
    key: u64,
    id: i64,
    name: []const u8,
    phone: []const u8,
    email: []const u8,
    address: []const u8,
    at: i64,
) void {
    var params: [6]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .text = phone },
        .{ .text = email },
        .{ .text = address },
        .{ .integer = at },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO customer (id, name, phone, email, address, loyalty_points, notes, active, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, 0, '', 1, ?6)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2, phone = ?3, email = ?4, address = ?5;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.customer_saved),
    });
}

/// Write a modifier group: a new one, or the one the form is editing.
pub fn saveModifierGroup(
    fx: *Effects,
    key: u64,
    id: i64,
    name: []const u8,
    required: bool,
    max_select: i64,
) void {
    var params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = id },
        .{ .text = name },
        .{ .integer = if (required) 1 else 0 },
        .{ .integer = max_select },
    };
    fx.dbExec(.{
        .key = key,
        .statements = &.{.{
            .sql =
            \\INSERT INTO modifier_group (id, name, required, max_select, sort_order, active)
            \\VALUES (?1, ?2, ?3, ?4, 0, 1)
            \\ON CONFLICT(id) DO UPDATE SET name = ?2, required = ?3, max_select = ?4;
            ,
            .params = &params,
        }},
        .on_result = Effects.dbMsg(.modifier_group_saved),
    });
}

pub fn loadDiscounts(model: *Model, fx: *Effects) void {
    query(model, fx, key_discounts, discounts_sql, &.{}, Effects.dbMsg(.discounts_loaded));
}

pub fn loadStations(model: *Model, fx: *Effects) void {
    query(model, fx, key_stations, stations_sql, &.{}, Effects.dbMsg(.stations_loaded));
}

pub fn loadCompany(model: *Model, fx: *Effects) void {
    query(model, fx, key_company, company_sql, &.{}, Effects.dbMsg(.company_loaded));
}

/// Load everything the shell needs on boot. One arm, one place.
pub fn loadAll(model: *Model, fx: *Effects) void {
    loadCompany(model, fx);
    loadStations(model, fx);
    loadProductStations(model, fx);

    loadCategories(model, fx);
    loadProducts(model, fx);
    loadTables(model, fx);
    loadEmployees(model, fx);
    loadCustomers(model, fx);
    loadOrders(model, fx);
    loadOrderLines(model, fx);
    // The Lamport clock and the vector cursor are as much a part of
    // boot as the menu: a device that forgets them reuses a clock or
    // re-applies its own history.
    loadSyncState(model, fx);
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

/// Decode the devices that have been in this restaurant.
pub fn decodeDevices(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.devices_buf.reset();
    const count = reader.rows_left;
    const list = model.devices_buf.allocSlice(domain.Device, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = model.devices_buf.dupe(reader.textOf(&values, "id")) orelse "",
            .name = model.devices_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .role = model.devices_buf.dupe(reader.textOf(&values, "role")) orelse "",
            .last_seen_at = reader.intOf(&values, "last_seen_at", 0),
        };
    }
    model.devices_list = list[0..index];
}

/// Decode what the sync sidecar has left behind.
pub fn decodeSyncState(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.sync_state_buf.reset();
    const count = reader.rows_left;
    const list = model.sync_state_buf.allocSlice(domain.SyncState, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .key = model.sync_state_buf.dupe(reader.textOf(&values, "key")) orelse "",
            .value = model.sync_state_buf.dupe(reader.textOf(&values, "value")) orelse "",
        };
    }
    model.sync_state_list = list[0..index];

    // The clock and the cursor are the two rows the wire depends on.
    // They are read on boot so a restart neither reuses a clock nor
    // re-applies the ops it already has.
    for (list[0..index]) |row| {
        if (std.mem.eql(u8, row.key, "clock")) {
            model.sync_clock = std.fmt.parseInt(u64, row.value, 10) catch 0;
        } else if (std.mem.eql(u8, row.key, "cursor")) {
            model.sync_cursor.parse(row.value) catch {};
        }
    }
}

/// Decode the tables in the database.
/// Decode the tables in the DATABASE, and the row count of each.
pub fn decodeTableCounts(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.table_counts_buf.reset();
    const count = reader.rows_left;
    const list = model.table_counts_buf.allocSlice(domain.TableCount, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .name = model.table_counts_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .rows = reader.intOf(&values, "n", 0),
        };
    }
    model.table_counts_list = list[0..index];
}

/// Decode the categories of tables.
pub fn decodeTableCategories(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.table_categories_buf.reset();
    const count = reader.rows_left;
    const list = model.table_categories_buf.allocSlice(domain.TableCategory, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.table_categories_buf.dupe(reader.textOf(&values, "name")) orelse "",
        };
    }
    model.table_categories_list = list[0..index];
}

/// Decode the choices in the modifier groups.
pub fn decodeModifiers(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.modifiers_buf.reset();
    const count = reader.rows_left;
    const list = model.modifiers_buf.allocSlice(domain.Modifier, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .group_id = reader.intOf(&values, "group_id", 0),
            .name = model.modifiers_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .price_delta_minor = reader.intOf(&values, "price_delta_minor", 0),
            .active = reader.boolOf(&values, "active"),
        };
    }
    model.modifiers_list = list[0..index];
}

/// Decode the stock on the shelf.
pub fn decodeStock(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.stock_buf.reset();
    const count = reader.rows_left;
    const list = model.stock_buf.allocSlice(domain.StockItem, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .name = model.stock_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .stock_qty = reader.intOf(&values, "stock_qty", 0),
        };
    }
    model.stock_items_list = list[0..index];
}

/// Decode the day's takings.
pub fn decodeReport(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    var values: [page.max_columns]page.Value = undefined;
    if (!reader.nextRow(&values)) return;
    model.report_orders_field = reader.intOf(&values, "order_count", 0);
    model.report_gross_field = reader.intOf(&values, "gross_minor", 0);
    model.report_tax_field = reader.intOf(&values, "tax_minor", 0);
    model.report_discount_field = reader.intOf(&values, "discount_minor", 0);
    model.report_net_field = reader.intOf(&values, "net_minor", 0);
}

/// Decode the day's takings, split by the way they were paid.
pub fn decodeReportModes(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.report_modes_buf.reset();
    const count = reader.rows_left;
    const list = model.report_modes_buf.allocSlice(domain.ReportMode, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        const mode = enumFromInt(domain.PaymentMode, reader.intOf(&values, "mode", 0));
        list[index] = .{
            .mode = mode,
            .mode_label = mode.label(),
            .count = reader.intOf(&values, "n", 0),
            .amount_minor = reader.intOf(&values, "amount_minor", 0),
        };
    }
    model.report_modes_list = list[0..index];
}

/// Decode the payments the restaurant has taken.
pub fn decodePayments(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.payments_buf.reset();
    const count = reader.rows_left;
    const list = model.payments_buf.allocSlice(domain.Payment, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        const mode = enumFromInt(domain.PaymentMode, reader.intOf(&values, "mode", 0));
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .order_id = reader.intOf(&values, "order_id", 0),
            .order_no = model.payments_buf.dupe(reader.textOf(&values, "order_no")) orelse "",
            .mode = mode,
            .mode_label = mode.label(),
            .amount_minor = reader.intOf(&values, "amount_minor", 0),
            .reference = model.payments_buf.dupe(reader.textOf(&values, "reference")) orelse "",
            .paid_at = reader.intOf(&values, "paid_at", 0),
        };
    }
    model.payments_list = list[0..index];
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
    model: *Model,
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
    var statements: [6]native_sdk.EffectDbStatement = undefined;
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
    statements[0] = .{
        // The history first: it says the order closed, and it is only
        // true if the order was still open.
        .sql =
        \\INSERT INTO order_status_history (order_id, status, changed_at)
        \\SELECT ?1, ?2, ?3
        \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?1 AND status = ?4);
        ,
        .params = &history_params,
    };
    statements[1] = .{
        // The payment, for the same reason: one order, one payment.
        // The id is the order id, so the primary key says so too.
        .sql =
        \\INSERT INTO payment (id, order_id, mode, amount_minor, reference, paid_at, created_at)
        \\SELECT ?1, ?2, ?3, ?4, '', ?5, ?5
        \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?2 AND status = ?6);
        ,
        .params = &payment_params,
    };
    statements[2] = .{
        .sql = "UPDATE orders SET status = ?2, updated_at = ?3 WHERE id = ?1 AND status = ?4;",
        .params = &order_params,
    };
    statements[3] = .{
        // The guest has paid and gone, so the table is free again - in
        // the same transaction as the payment, so a table is never free
        // while the money is still owed.
        .sql =
        \\UPDATE dining_table SET status = 0
        \\WHERE id = (SELECT dining_table_id FROM orders WHERE id = ?1);
        ,
        .params = &.{.{ .integer = order_id }},
    };
    var count: usize = 4;

    const snapshot = record.PaymentSnapshot{
        .order_id = order_id,
        .mode = @intFromEnum(mode),
        .amount_minor = amount_minor,
        .paid_at = at,
    };
    var json_buffer: [256]u8 = undefined;
    var op_id_buffer: [96]u8 = undefined;
    var entity_buffer: [32]u8 = undefined;
    var clock_buffer: [32]u8 = undefined;
    var op_params: [8]native_sdk.EffectDbValue = undefined;
    var clock_params: [1]native_sdk.EffectDbValue = undefined;

    const op_ready = build_op: {
        var json_writer = std.Io.Writer.fixed(&json_buffer);
        std.json.Stringify.value(snapshot, .{}, &json_writer) catch break :build_op false;
        const data_json = json_writer.buffered();

        const device_id = syncDeviceId(model);
        const clock = nextSyncClock(model);
        const op_id = record.formatId(&op_id_buffer, device_id, clock, 0) catch break :build_op false;
        const entity_id = std.fmt.bufPrint(&entity_buffer, "{d}", .{order_id}) catch break :build_op false;
        const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{clock}) catch break :build_op false;

        op_params = .{
            .{ .text = op_id },
            .{ .text = "payment" },
            .{ .text = entity_id },
            .{ .text = "create" },
            .{ .text = data_json },
            .{ .integer = @intCast(clock) },
            .{ .text = device_id },
            .{ .integer = at },
        };
        clock_params = .{.{ .text = clock_text }};
        model.sync_cursor.observe(device_id, clock) catch {};

        const wire_op: record.Op = .{
            .id = op_id,
            .entity_table = "payment",
            .entity_id = entity_id,
            .operation = .create,
            .logical_clock = clock,
            .device_id = device_id,
            .created_at = at,
            .data_json = data_json,
        };
        var wire_buffer: [8 * 1024]u8 = undefined;
        var wire_writer = std.Io.Writer.fixed(&wire_buffer);
        if (record.encode(&wire_writer, wire_op)) {
            cacheOp(model, wire_op, wire_writer.buffered());
        } else |_| {}
        break :build_op true;
    };

    if (op_ready) {
        statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
        count += 1;
        statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
        count += 1;
    }

    fx.dbExec(.{
        .key = key,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.payment_taken),
    });
    saveCursor(model, fx);
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
        .{ .integer = first_employee_id },
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

/// The op row joins the write's own transaction. `previous_json` and
/// the host/parent columns are the sidecar's; a peer writes them empty,
/// exactly as `record.zig` says.
const insert_op_log_sql =
    \\INSERT INTO op_log (id, entity_table, entity_id, operation, data_json,
    \\  previous_json, logical_clock, device_id, host_id, parent_id, created_at)
    \\VALUES (?1, ?2, ?3, ?4, ?5, '{}', ?6, ?7, '', '', ?8)
    \\ON CONFLICT(id) DO NOTHING;
;

/// The local Lamport clock is durable: a device that restarts must not
/// reuse a clock and make an old op look new.
const save_clock_sql =
    \\INSERT INTO sync_state (key, value) VALUES ('clock', ?1)
    \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
;

/// The cursor is durable too. It is a cache of the op log, so a lost
/// write costs a re-read, not a lost op - but a device that forgets it
/// re-applies its own history on every restart.
const save_cursor_sql =
    \\INSERT INTO sync_state (key, value) VALUES ('cursor', ?1)
    \\ON CONFLICT(key) DO UPDATE SET value = excluded.value;
;

/// The device id the op is written under. The token is generated at
/// boot; a model without one still writes, under "local", so a sale is
/// never blocked by a missing token.
fn syncDeviceId(model: *Model) []const u8 {
    if (model.device_token_len == 0) return "local";
    return model.device_token_buf[0..model.device_token_len];
}

/// The next Lamport clock. The writer bumps to `max(own, highest seen)
/// + 1`, and the vector cursor is where the highest seen lives.
fn nextSyncClock(model: *Model) u64 {
    const highest = @max(model.sync_clock, model.sync_cursor.highest());
    model.sync_clock = highest + 1;
    return model.sync_clock;
}

/// An id from a snapshot: zero and null both mean "no row". The apply
/// path turns a missing reference into NULL rather than failing the
/// foreign key, so an order still arrives on a device that has not
/// received the reference data yet.
fn nullableIdParam(value: ?i64) native_sdk.EffectDbValue {
    if (value) |id| {
        if (id == 0) return .null_value;
        return .{ .integer = id };
    }
    return .null_value;
}

/// Write the vector cursor. It is a separate effect from the op
/// itself because it is a cache: the op log is the truth, and a cursor
/// write that loses a race costs a re-read, not an op.
fn saveCursor(model: *Model, fx: *Effects) void {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    model.sync_cursor.write(&writer) catch return;
    var params: [1]native_sdk.EffectDbValue = .{.{ .text = writer.buffered() }};
    fx.dbExec(.{
        .key = key_sync_cursor,
        .statements = &.{.{ .sql = save_cursor_sql, .params = &params }},
        .on_result = Effects.dbMsg(.sync_applied),
    });
}

/// Remember one op line for a peer that pulls. The cache is a recent
/// window, not the log: when it fills it starts over, and a peer that
/// missed the window falls back to the durable op_log.
pub fn cacheOp(model: *Model, op: record.Op, line: []const u8) void {
    if (line.len == 0) return;
    if (model.sync_cache_count == model_mod.sync_cache_slots or
        model.sync_cache_buf.free() < line.len)
    {
        model.sync_cache_buf.reset();
        model.sync_cache_count = 0;
    }
    const offset = model.sync_cache_buf.len;
    const stored = model.sync_cache_buf.dupe(line) orelse return;
    const meta = &model.sync_cache_meta[model.sync_cache_count];
    const device_len = @min(op.device_id.len, meta.device.len);
    meta.* = .{
        .device_len = device_len,
        .clock = op.logical_clock,
        .offset = offset,
        .len = stored.len,
    };
    @memcpy(meta.device[0..device_len], op.device_id[0..device_len]);
    model.sync_cache_count += 1;
}

/// Write the cached ops above `since` as NDJSON. The cursor is the
/// requester's vector: an op is new to it when its clock is above the
/// position for its device.
pub fn writeCachedOps(model: *const Model, since: []const u8, body: []u8) usize {
    var cursor: cursor_mod.Vector = .{};
    cursor.parse(since) catch {};

    var writer = std.Io.Writer.fixed(body);
    for (model.sync_cache_meta[0..model.sync_cache_count]) |meta| {
        const device = meta.device[0..meta.device_len];
        if (meta.clock <= cursor.get(device)) continue;
        const line = model.sync_cache_buf.bytes[meta.offset..][0..meta.len];
        writer.writeAll(line) catch break;
    }
    return writer.end;
}

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
pub fn saveOrder(model: *Model, fx: *Effects, order: domain.Order, lines: []const domain.OrderLine, request_key: []const u8) void {
    // The order, its lines, the stock it takes, and the op row: three
    // statements per line plus four, and one transaction for all of
    // them.
    var statements: [4 + 3 * max_order_lines]native_sdk.EffectDbStatement = undefined;
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

    // The op the peers receive. One op carries the whole order - the
    // header and its lines - so a receiving device can show the ticket
    // in one transaction. The order number is absent on purpose: the
    // receiver's database assigns its own, and the order's identity is
    // the id both devices already agree on.
    var snapshot_lines: [max_order_lines]record.OrderLineSnapshot = undefined;
    var snapshot_count: usize = 0;
    for (lines) |line| {
        if (snapshot_count == max_order_lines) break;
        snapshot_lines[snapshot_count] = .{
            .id = line.id,
            .product_id = if (line.product_id == 0) null else line.product_id,
            .product_name = line.product_name,
            .qty = line.qty,
            .unit_price_minor = line.unit_price_minor,
            .tax_bps = line.tax_bps,
            .notes = line.notes,
        };
        snapshot_count += 1;
    }
    const snapshot = record.OrderSnapshot{
        .id = order.id,
        .order_type = @intFromEnum(order.order_type),
        .status = @intFromEnum(order.status),
        .dining_table_id = if (order.dining_table_id == 0) null else order.dining_table_id,
        .customer_id = if (order.customer_id == 0) null else order.customer_id,
        .employee_id = if (order.employee_id == 0) null else order.employee_id,
        .subtotal_minor = order.subtotal_minor,
        .tax_minor = order.tax_minor,
        .discount_minor = order.discount_minor,
        .total_minor = order.total_minor,
        .placed_at = order.placed_at,
        .notes = order.notes,
        .lines = snapshot_lines[0..snapshot_count],
    };

    var json_buffer: [16 * 1024]u8 = undefined;
    var op_id_buffer: [96]u8 = undefined;
    var entity_buffer: [32]u8 = undefined;
    var clock_buffer: [32]u8 = undefined;
    var op_params: [8]native_sdk.EffectDbValue = undefined;
    var clock_params: [1]native_sdk.EffectDbValue = undefined;

    const op_ready = build_op: {
        var json_writer = std.Io.Writer.fixed(&json_buffer);
        std.json.Stringify.value(snapshot, .{}, &json_writer) catch break :build_op false;
        const data_json = json_writer.buffered();

        const device_id = syncDeviceId(model);
        const clock = nextSyncClock(model);
        const op_id = record.formatId(&op_id_buffer, device_id, clock, 0) catch break :build_op false;
        const entity_id = std.fmt.bufPrint(&entity_buffer, "{d}", .{order.id}) catch break :build_op false;
        const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{clock}) catch break :build_op false;

        op_params = .{
            .{ .text = op_id },
            .{ .text = "order" },
            .{ .text = entity_id },
            .{ .text = "create" },
            .{ .text = data_json },
            .{ .integer = @intCast(clock) },
            .{ .text = device_id },
            .{ .integer = order.placed_at },
        };
        clock_params = .{.{ .text = clock_text }};
        // The device has now seen its own op. A peer that echoes it
        // back is a duplicate, not a new sale.
        model.sync_cursor.observe(device_id, clock) catch {};

        const wire_op: record.Op = .{
            .id = op_id,
            .entity_table = "order",
            .entity_id = entity_id,
            .operation = .create,
            .logical_clock = clock,
            .device_id = device_id,
            .created_at = order.placed_at,
            .data_json = data_json,
        };
        var wire_buffer: [8 * 1024]u8 = undefined;
        var wire_writer = std.Io.Writer.fixed(&wire_buffer);
        if (record.encode(&wire_writer, wire_op)) {
            cacheOp(model, wire_op, wire_writer.buffered());
        } else |_| {}
        break :build_op true;
    };

    if (op_ready) {
        statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
        count += 1;
        statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
        count += 1;
    }

    fx.dbExec(.{
        .key = key_write_order,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.order_placed),
    });
    saveCursor(model, fx);
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
    model: *Model,
    fx: *Effects,
    order_id: i64,
    from_status: domain.OrderStatus,
    to_status: domain.OrderStatus,
    at: i64,
) void {
    var statements: [4]native_sdk.EffectDbStatement = undefined;
    var history_params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = @intFromEnum(to_status) },
        .{ .integer = at },
        .{ .integer = @intFromEnum(from_status) },
    };
    var order_params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = order_id },
        .{ .integer = @intFromEnum(to_status) },
        .{ .integer = at },
        .{ .integer = @intFromEnum(from_status) },
    };
    statements[0] = .{
        // The history first, and only for an order that is where the
        // move expects it: the row says the order BECAME this status,
        // and it is only true if it was not already.
        .sql =
        \\INSERT INTO order_status_history (order_id, status, changed_at)
        \\SELECT ?1, ?2, ?3
        \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?1 AND status = ?4);
        ,
        .params = &history_params,
    };
    statements[1] = .{
        .sql = "UPDATE orders SET status = ?2, updated_at = ?3 WHERE id = ?1 AND status = ?4;",
        .params = &order_params,
    };
    var count: usize = 2;

    const snapshot = record.OrderStatusSnapshot{
        .id = order_id,
        .status = @intFromEnum(to_status),
        .changed_at = at,
    };
    var json_buffer: [256]u8 = undefined;
    var op_id_buffer: [96]u8 = undefined;
    var entity_buffer: [32]u8 = undefined;
    var clock_buffer: [32]u8 = undefined;
    var op_params: [8]native_sdk.EffectDbValue = undefined;
    var clock_params: [1]native_sdk.EffectDbValue = undefined;

    const op_ready = build_op: {
        var json_writer = std.Io.Writer.fixed(&json_buffer);
        std.json.Stringify.value(snapshot, .{}, &json_writer) catch break :build_op false;
        const data_json = json_writer.buffered();

        const device_id = syncDeviceId(model);
        const clock = nextSyncClock(model);
        const op_id = record.formatId(&op_id_buffer, device_id, clock, 0) catch break :build_op false;
        const entity_id = std.fmt.bufPrint(&entity_buffer, "{d}", .{order_id}) catch break :build_op false;
        const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{clock}) catch break :build_op false;

        op_params = .{
            .{ .text = op_id },
            .{ .text = "order_status" },
            .{ .text = entity_id },
            .{ .text = "update" },
            .{ .text = data_json },
            .{ .integer = @intCast(clock) },
            .{ .text = device_id },
            .{ .integer = at },
        };
        clock_params = .{.{ .text = clock_text }};
        model.sync_cursor.observe(device_id, clock) catch {};

        const wire_op: record.Op = .{
            .id = op_id,
            .entity_table = "order_status",
            .entity_id = entity_id,
            .operation = .update,
            .logical_clock = clock,
            .device_id = device_id,
            .created_at = at,
            .data_json = data_json,
        };
        var wire_buffer: [8 * 1024]u8 = undefined;
        var wire_writer = std.Io.Writer.fixed(&wire_buffer);
        if (record.encode(&wire_writer, wire_op)) {
            cacheOp(model, wire_op, wire_writer.buffered());
        } else |_| {}
        break :build_op true;
    };

    if (op_ready) {
        statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
        count += 1;
        statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
        count += 1;
    }

    fx.dbExec(.{
        .key = key_write_order,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.order_status_saved),
    });
    saveCursor(model, fx);
}

// ------------------------------------------------------------- apply
//
// The receiving half of the op log. An op is applied only when its
// clock is above the cursor for its source device; that is the
// idempotency rule, and it is what makes a repeat, a reconnect and a
// re-ask safe. The write joins the op row and the local clock in one
// transaction, so a peer can pass the op on without ever seeing half
// of it.

/// Apply one op from a peer.
pub fn applyOp(model: *Model, fx: *Effects, op: record.Op) void {
    if (model.sync_cursor.covers(op.device_id, op.logical_clock)) {
        model.sync_skipped += 1;
        return;
    }

    var arena_buffer: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buffer);
    const arena = fba.allocator();

    if (std.mem.eql(u8, op.entity_table, "order")) {
        const snapshot = record.parseOrder(arena, op.data_json) catch {
            model.sync_rejected += 1;
            return;
        };
        applyOrder(fx, op, snapshot);
    } else if (std.mem.eql(u8, op.entity_table, "order_status")) {
        const snapshot = record.parseOrderStatus(arena, op.data_json) catch {
            model.sync_rejected += 1;
            return;
        };
        applyOrderStatus(fx, op, snapshot);
    } else if (std.mem.eql(u8, op.entity_table, "payment")) {
        const snapshot = record.parsePayment(arena, op.data_json) catch {
            model.sync_rejected += 1;
            return;
        };
        applyPayment(fx, op, snapshot);
    } else {
        // The other tables arrive with their own slices. Refusing an
        // op we do not understand is safer than writing half of it.
        model.sync_rejected += 1;
        return;
    }

    model.sync_cursor.observe(op.device_id, op.logical_clock) catch {
        model.sync_rejected += 1;
        return;
    };
    model.sync_clock = @max(model.sync_clock, op.logical_clock);
    model.sync_applied += 1;

    // Keep the op for the next peer in the chain. A device that only
    // applied an op still holds it, and the pull after that is how the
    // change reaches a third instance.
    var wire_buffer: [8 * 1024]u8 = undefined;
    var wire_writer = std.Io.Writer.fixed(&wire_buffer);
    if (record.encode(&wire_writer, op)) {
        cacheOp(model, op, wire_writer.buffered());
    } else |_| {}

    saveCursor(model, fx);
}

fn applyOrder(fx: *Effects, op: record.Op, snapshot: record.OrderSnapshot) void {
    var statements: [4 + max_order_lines]native_sdk.EffectDbStatement = undefined;
    var count: usize = 0;

    // The number is local. The bump is conditional on the order id
    // being new, so a duplicate op does not consume a second number.
    var sequence_params: [2]native_sdk.EffectDbValue = .{
        .{ .integer = snapshot.placed_at },
        .{ .integer = snapshot.id },
    };
    statements[count] = .{
        .sql =
        \\INSERT INTO sequence (name, value, updated_at)
        \\SELECT 'order_no', 1, ?1
        \\WHERE NOT EXISTS (SELECT 1 FROM orders WHERE id = ?2)
        \\ON CONFLICT(name) DO UPDATE SET value = value + 1, updated_at = ?1;
        ,
        .params = &sequence_params,
    };
    count += 1;

    // A reference row this device has not received yet becomes NULL,
    // not a foreign-key failure: the ticket still arrives, and the
    // reference-data slice (#109) fills in the name later.
    var order_params: [13]native_sdk.EffectDbValue = .{
        .{ .integer = snapshot.id },
        .{ .integer = snapshot.order_type },
        .{ .integer = snapshot.status },
        nullableIdParam(snapshot.dining_table_id),
        nullableIdParam(snapshot.customer_id),
        nullableIdParam(snapshot.employee_id),
        .{ .integer = snapshot.subtotal_minor },
        .{ .integer = snapshot.tax_minor },
        .{ .integer = snapshot.discount_minor },
        .{ .integer = snapshot.total_minor },
        .{ .integer = snapshot.placed_at },
        .{ .text = snapshot.notes },
        .{ .text = op.id },
    };
    statements[count] = .{
        .sql =
        \\INSERT INTO orders (id, order_no, order_type, status, dining_table_id,
        \\  customer_id, employee_id, subtotal_minor, tax_minor, discount_minor,
        \\  total_minor, placed_at, notes, created_at, updated_at, request_key)
        \\VALUES (?1, (SELECT printf('%06d', value) FROM sequence WHERE name = 'order_no'),
        \\  ?2, ?3,
        \\  (SELECT id FROM dining_table WHERE id = ?4),
        \\  (SELECT id FROM customer WHERE id = ?5),
        \\  (SELECT id FROM employee WHERE id = ?6),
        \\  ?7, ?8, ?9, ?10, ?11, ?12, ?11, ?11, ?13)
        \\ON CONFLICT DO NOTHING;
        ,
        .params = &order_params,
    };
    count += 1;

    var line_params: [max_order_lines][9]native_sdk.EffectDbValue = undefined;
    for (snapshot.lines) |line| {
        // Two slots are reserved for the op row and the clock.
        if (count + 3 > statements.len) break;
        const slot = count - 2;
        line_params[slot] = .{
            .{ .integer = line.id },
            .{ .integer = snapshot.id },
            nullableIdParam(line.product_id),
            .{ .text = line.product_name },
            .{ .integer = line.qty },
            .{ .integer = line.unit_price_minor },
            .{ .integer = line.tax_bps },
            .{ .text = line.notes },
            .{ .integer = snapshot.placed_at },
        };
        statements[count] = .{
            .sql =
            \\INSERT INTO order_line (id, order_id, product_id, product_name, qty,
            \\  unit_price_minor, tax_bps, notes, created_at)
            \\SELECT ?1, ?2, (SELECT id FROM product WHERE id = ?3), ?4, ?5, ?6, ?7, ?8, ?9
            \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?2)
            \\ON CONFLICT DO NOTHING;
            ,
            .params = &line_params[slot],
        };
        count += 1;
    }

    var op_params: [8]native_sdk.EffectDbValue = .{
        .{ .text = op.id },
        .{ .text = op.entity_table },
        .{ .text = op.entity_id },
        .{ .text = op.operation.label() },
        .{ .text = op.data_json },
        .{ .integer = @intCast(op.logical_clock) },
        .{ .text = op.device_id },
        .{ .integer = op.created_at },
    };
    statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
    count += 1;

    var clock_buffer: [32]u8 = undefined;
    const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{op.logical_clock}) catch return;
    var clock_params: [1]native_sdk.EffectDbValue = .{.{ .text = clock_text }};
    statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
    count += 1;

    fx.dbExec(.{
        .key = key_sync_apply,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.sync_applied),
    });
}

fn applyOrderStatus(fx: *Effects, op: record.Op, snapshot: record.OrderStatusSnapshot) void {
    var statements: [4]native_sdk.EffectDbStatement = undefined;
    var params: [3]native_sdk.EffectDbValue = .{
        .{ .integer = snapshot.id },
        .{ .integer = snapshot.status },
        .{ .integer = snapshot.changed_at },
    };
    statements[0] = .{
        // The status is monotonic. `voided` is the terminal exception:
        // it can end an open ticket, but it cannot undo a completed
        // one.
        .sql =
        \\UPDATE orders SET status = ?2, updated_at = ?3
        \\WHERE id = ?1 AND status <> ?2
        \\  AND (status < ?2 OR (?2 = 5 AND status < 4));
        ,
        .params = &params,
    };
    statements[1] = .{
        .sql =
        \\INSERT INTO order_status_history (order_id, status, changed_at)
        \\SELECT ?1, ?2, ?3 WHERE changes() > 0;
        ,
        .params = &params,
    };
    var count: usize = 2;

    var op_params: [8]native_sdk.EffectDbValue = .{
        .{ .text = op.id },
        .{ .text = op.entity_table },
        .{ .text = op.entity_id },
        .{ .text = op.operation.label() },
        .{ .text = op.data_json },
        .{ .integer = @intCast(op.logical_clock) },
        .{ .text = op.device_id },
        .{ .integer = op.created_at },
    };
    statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
    count += 1;

    var clock_buffer: [32]u8 = undefined;
    const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{op.logical_clock}) catch return;
    var clock_params: [1]native_sdk.EffectDbValue = .{.{ .text = clock_text }};
    statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
    count += 1;

    fx.dbExec(.{
        .key = key_sync_apply,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.sync_applied),
    });
}

fn applyPayment(fx: *Effects, op: record.Op, snapshot: record.PaymentSnapshot) void {
    var statements: [6]native_sdk.EffectDbStatement = undefined;

    // The payment id is the order id, so a second delivery is the same
    // row, not a second charge.
    var payment_params: [4]native_sdk.EffectDbValue = .{
        .{ .integer = snapshot.order_id },
        .{ .integer = snapshot.mode },
        .{ .integer = snapshot.amount_minor },
        .{ .integer = snapshot.paid_at },
    };
    statements[0] = .{
        .sql =
        \\INSERT INTO payment (id, order_id, mode, amount_minor, reference, paid_at, created_at)
        \\SELECT ?1, ?1, ?2, ?3, '', ?4, ?4
        \\WHERE EXISTS (SELECT 1 FROM orders WHERE id = ?1)
        \\ON CONFLICT(id) DO NOTHING;
        ,
        .params = &payment_params,
    };

    var order_params: [3]native_sdk.EffectDbValue = .{
        .{ .integer = snapshot.order_id },
        .{ .integer = snapshot.paid_at },
        .{ .integer = @intFromEnum(domain.OrderStatus.completed) },
    };
    statements[1] = .{
        // Paid closes an open ticket. It does not reopen a voided one.
        .sql = "UPDATE orders SET status = ?3, updated_at = ?2 WHERE id = ?1 AND status < ?3;",
        .params = &order_params,
    };
    statements[2] = .{
        .sql =
        \\INSERT INTO order_status_history (order_id, status, changed_at)
        \\SELECT ?1, ?3, ?2 WHERE changes() > 0;
        ,
        .params = &order_params,
    };
    statements[3] = .{
        .sql =
        \\UPDATE dining_table SET status = 0
        \\WHERE id = (SELECT dining_table_id FROM orders WHERE id = ?1);
        ,
        .params = &.{.{ .integer = snapshot.order_id }},
    };
    var count: usize = 4;

    var op_params: [8]native_sdk.EffectDbValue = .{
        .{ .text = op.id },
        .{ .text = op.entity_table },
        .{ .text = op.entity_id },
        .{ .text = op.operation.label() },
        .{ .text = op.data_json },
        .{ .integer = @intCast(op.logical_clock) },
        .{ .text = op.device_id },
        .{ .integer = op.created_at },
    };
    statements[count] = .{ .sql = insert_op_log_sql, .params = &op_params };
    count += 1;

    var clock_buffer: [32]u8 = undefined;
    const clock_text = std.fmt.bufPrint(&clock_buffer, "{d}", .{op.logical_clock}) catch return;
    var clock_params: [1]native_sdk.EffectDbValue = .{.{ .text = clock_text }};
    statements[count] = .{ .sql = save_clock_sql, .params = &clock_params };
    count += 1;

    fx.dbExec(.{
        .key = key_sync_apply,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.sync_applied),
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

// ------------------------------------------------------- reference data
//
// The admin is the only writer. It publishes one versioned document and
// a peer applies it whole, so there is never a second opinion about the
// menu. The version lives in `app_config`: a counter needs no table of
// its own and no migration, and the salt already lives there.

const reference_snapshot_sql =
    \\SELECT
    \\  COALESCE((SELECT CAST(value AS INTEGER) FROM app_config WHERE key = 'reference_version'), 1) AS version,
    \\  json_object(
    \\    'version', COALESCE((SELECT CAST(value AS INTEGER) FROM app_config WHERE key = 'reference_version'), 1),
    \\    'company', (SELECT json_object(
    \\      'id', id, 'name', name, 'currency_code', currency_code,
    \\      'currency_symbol', currency_symbol, 'tax_inclusive', tax_inclusive,
    \\      'currency_decimals', currency_decimals, 'address', address,
    \\      'phone', phone, 'email', email, 'tax_number', tax_number,
    \\      'created_at', created_at) FROM company LIMIT 1),
    \\    'categories', (SELECT json_group_array(json_object(
    \\      'id', id, 'name', name, 'sort_order', sort_order, 'active', active))
    \\      FROM product_category),
    \\    'tax_slabs', (SELECT json_group_array(json_object(
    \\      'id', id, 'name', name, 'rate_bps', rate_bps,
    \\      'inclusive', inclusive, 'active', active)) FROM tax_slab),
    \\    'employees', (SELECT json_group_array(json_object(
    \\      'id', id, 'name', name, 'role', role, 'pin_hash', pin_hash,
    \\      'phone', phone, 'email', email, 'active', active,
    \\      'created_at', created_at)) FROM employee),
    \\    'products', (SELECT json_group_array(json_object(
    \\      'id', id, 'category_id', category_id, 'name', name,
    \\      'price_minor', price_minor, 'product_type', product_type,
    \\      'food_type', food_type, 'tax_slab_id', tax_slab_id,
    \\      'stock_qty', stock_qty, 'track_stock', track_stock,
    \\      'description', description, 'image_path', image_path,
    \\      'active', active, 'sort_order', sort_order,
    \\      'created_at', created_at, 'updated_at', updated_at)) FROM product),
    \\    'table_categories', (SELECT json_group_array(json_object(
    \\      'id', id, 'name', name, 'sort_order', sort_order, 'active', active))
    \\      FROM dining_table_category),
    \\    'tables', (SELECT json_group_array(json_object(
    \\      'id', id, 'category_id', category_id, 'name', name,
    \\      'status', status, 'seats', seats, 'pos_x', pos_x, 'pos_y', pos_y,
    \\      'width_cells', width_cells, 'height_cells', height_cells,
    \\      'active', active)) FROM dining_table),
    \\    'stations', (SELECT json_group_array(json_object(
    \\      'id', id, 'name', name, 'sort_order', sort_order, 'active', active))
    \\      FROM kds_station),
    \\    'pin_salt', (SELECT value FROM app_config WHERE key = 'pin_salt' LIMIT 1)
    \\  ) AS snapshot;
;

const reference_version_sql =
    \\SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM app_config WHERE key = 'reference_version'), 0) AS version;
;

const bump_reference_sql =
    \\INSERT INTO app_config (key, value, updated_at) VALUES ('reference_version', '2', 0)
    \\ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1, updated_at = 0;
;

/// Build the admin's document and cache it for `GET /v1/reference`.
pub fn loadReferenceSnapshot(model: *Model, fx: *Effects) void {
    query(model, fx, key_reference_snapshot, reference_snapshot_sql, &.{}, Effects.dbMsg(.reference_loaded));
}

/// Read the last version this device applied. The admin's base is one;
/// a peer starts at zero, so its first ask receives the whole document.
pub fn loadReferenceVersion(model: *Model, fx: *Effects) void {
    query(model, fx, key_reference_version, reference_version_sql, &.{}, Effects.dbMsg(.reference_version_loaded));
}

/// Move the admin's version. Every reference write calls this, and the
/// resulting `.reference_bumped` rebuilds the document.
pub fn bumpReferenceVersion(fx: *Effects) void {
    fx.dbExec(.{
        .key = key_reference_bump,
        .statements = &.{.{ .sql = bump_reference_sql }},
        .on_result = Effects.dbMsg(.reference_bumped),
    });
}

/// Apply a peer's document in one transaction. The rows are upserted in
/// foreign-key order, the peer's live table status survives, and the
/// version moves last - so a failure leaves both the data and the
/// cursor where they were.
pub fn applyReference(
    model: *Model,
    fx: *Effects,
    snapshot: reference.Snapshot,
    allocator: std.mem.Allocator,
    at: i64,
) void {
    _ = model;
    var statements: [512]native_sdk.EffectDbStatement = undefined;
    var count: usize = 0;

    if (snapshot.company) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 11) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .text = row.currency_code };
        params[3] = .{ .text = row.currency_symbol };
        params[4] = .{ .integer = row.tax_inclusive };
        params[5] = .{ .integer = row.currency_decimals };
        params[6] = .{ .text = row.address };
        params[7] = .{ .text = row.phone };
        params[8] = .{ .text = row.email };
        params[9] = .{ .text = row.tax_number };
        params[10] = .{ .integer = row.created_at };
        if (!appendReferenceStatement(&statements, &count, reference_company_sql, params)) return;
    }

    for (snapshot.categories) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 4) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .integer = row.sort_order };
        params[3] = .{ .integer = row.active };
        if (!appendReferenceStatement(&statements, &count, reference_category_sql, params)) return;
    }

    for (snapshot.tax_slabs) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 5) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .integer = row.rate_bps };
        params[3] = .{ .integer = row.inclusive };
        params[4] = .{ .integer = row.active };
        if (!appendReferenceStatement(&statements, &count, reference_tax_slab_sql, params)) return;
    }

    for (snapshot.employees) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 8) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .integer = row.role };
        params[3] = .{ .text = row.pin_hash };
        params[4] = .{ .text = row.phone };
        params[5] = .{ .text = row.email };
        params[6] = .{ .integer = row.active };
        params[7] = .{ .integer = row.created_at };
        if (!appendReferenceStatement(&statements, &count, reference_employee_sql, params)) return;
    }

    for (snapshot.products) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 15) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .integer = row.category_id };
        params[2] = .{ .text = row.name };
        params[3] = .{ .integer = row.price_minor };
        params[4] = .{ .integer = row.product_type };
        params[5] = .{ .integer = row.food_type };
        params[6] = .{ .integer = row.tax_slab_id };
        params[7] = if (row.stock_qty) |qty| .{ .integer = qty } else .null_value;
        params[8] = .{ .integer = row.track_stock };
        params[9] = .{ .text = row.description };
        params[10] = .{ .text = row.image_path };
        params[11] = .{ .integer = row.active };
        params[12] = .{ .integer = row.sort_order };
        params[13] = .{ .integer = row.created_at };
        params[14] = .{ .integer = row.updated_at };
        if (!appendReferenceStatement(&statements, &count, reference_product_sql, params)) return;
    }

    for (snapshot.table_categories) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 4) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .integer = row.sort_order };
        params[3] = .{ .integer = row.active };
        if (!appendReferenceStatement(&statements, &count, reference_table_category_sql, params)) return;
    }

    for (snapshot.tables) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 9) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .integer = row.category_id };
        params[2] = .{ .text = row.name };
        params[3] = .{ .integer = row.seats };
        params[4] = .{ .integer = row.pos_x };
        params[5] = .{ .integer = row.pos_y };
        params[6] = .{ .integer = row.width_cells };
        params[7] = .{ .integer = row.height_cells };
        params[8] = .{ .integer = row.active };
        if (!appendReferenceStatement(&statements, &count, reference_table_sql, params)) return;
    }

    for (snapshot.stations) |row| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 4) catch return;
        params[0] = .{ .integer = row.id };
        params[1] = .{ .text = row.name };
        params[2] = .{ .integer = row.sort_order };
        params[3] = .{ .integer = row.active };
        if (!appendReferenceStatement(&statements, &count, reference_station_sql, params)) return;
    }

    // The salt belongs to the hashes in the document: a PIN copied from
    // the admin verifies on the peer because both use this one.
    if (snapshot.pin_salt) |salt| {
        const params = allocator.alloc(native_sdk.EffectDbValue, 2) catch return;
        params[0] = .{ .text = salt };
        params[1] = .{ .integer = at };
        if (!appendReferenceStatement(&statements, &count, reference_salt_sql, params)) return;
    }

    const version_text = std.fmt.allocPrint(allocator, "{d}", .{snapshot.version}) catch return;
    const version_params = allocator.alloc(native_sdk.EffectDbValue, 2) catch return;
    version_params[0] = .{ .text = version_text };
    version_params[1] = .{ .integer = at };
    if (!appendReferenceStatement(&statements, &count, reference_version_upsert_sql, version_params)) return;

    fx.dbExec(.{
        .key = key_reference_apply,
        .statements = statements[0..count],
        .on_result = Effects.dbMsg(.reference_applied),
    });
}

fn appendReferenceStatement(
    statements: []native_sdk.EffectDbStatement,
    count: *usize,
    sql: []const u8,
    params: []const native_sdk.EffectDbValue,
) bool {
    if (count.* >= statements.len) return false;
    statements[count.*] = .{ .sql = sql, .params = params };
    count.* += 1;
    return true;
}

const reference_company_sql =
    \\INSERT INTO company (id, name, currency_code, currency_symbol, tax_inclusive,
    \\  currency_decimals, address, phone, email, tax_number, created_at)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, currency_code = ?3,
    \\  currency_symbol = ?4, tax_inclusive = ?5, currency_decimals = ?6,
    \\  address = ?7, phone = ?8, email = ?9, tax_number = ?10;
;

const reference_category_sql =
    \\INSERT INTO product_category (id, name, sort_order, active)
    \\VALUES (?1, ?2, ?3, ?4)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, sort_order = ?3, active = ?4;
;

const reference_tax_slab_sql =
    \\INSERT INTO tax_slab (id, name, rate_bps, inclusive, active)
    \\VALUES (?1, ?2, ?3, ?4, ?5)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, rate_bps = ?3,
    \\  inclusive = ?4, active = ?5;
;

const reference_employee_sql =
    \\INSERT INTO employee (id, name, role, pin_hash, phone, email, active, created_at)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, role = ?3, pin_hash = ?4,
    \\  phone = ?5, email = ?6, active = ?7;
;

const reference_product_sql =
    \\INSERT INTO product (id, category_id, name, price_minor, product_type,
    \\  food_type, tax_slab_id, stock_qty, track_stock, description, image_path,
    \\  active, sort_order, created_at, updated_at)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
    \\ON CONFLICT(id) DO UPDATE SET category_id = ?2, name = ?3,
    \\  price_minor = ?4, product_type = ?5, food_type = ?6, tax_slab_id = ?7,
    \\  stock_qty = ?8, track_stock = ?9, description = ?10, image_path = ?11,
    \\  active = ?12, sort_order = ?13, updated_at = ?15;
;

const reference_table_category_sql =
    \\INSERT INTO dining_table_category (id, name, sort_order, active)
    \\VALUES (?1, ?2, ?3, ?4)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, sort_order = ?3, active = ?4;
;

const reference_table_sql =
    \\INSERT INTO dining_table (id, category_id, name, status, seats, pos_x,
    \\  pos_y, width_cells, height_cells, active)
    \\VALUES (?1, ?2, ?3, 0, ?4, ?5, ?6, ?7, ?8, ?9)
    \\ON CONFLICT(id) DO UPDATE SET category_id = ?2, name = ?3, seats = ?4,
    \\  pos_x = ?5, pos_y = ?6, width_cells = ?7, height_cells = ?8, active = ?9;
;

const reference_station_sql =
    \\INSERT INTO kds_station (id, name, sort_order, active)
    \\VALUES (?1, ?2, ?3, ?4)
    \\ON CONFLICT(id) DO UPDATE SET name = ?2, sort_order = ?3, active = ?4;
;

const reference_salt_sql =
    \\INSERT INTO app_config (key, value, updated_at) VALUES ('pin_salt', ?1, ?2)
    \\ON CONFLICT(key) DO UPDATE SET value = ?1, updated_at = ?2;
;

const reference_version_upsert_sql =
    \\INSERT INTO app_config (key, value, updated_at) VALUES ('reference_version', ?1, ?2)
    \\ON CONFLICT(key) DO UPDATE SET value = ?1, updated_at = ?2;
;
