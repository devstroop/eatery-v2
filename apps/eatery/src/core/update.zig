//! The update function: the only place state changes.
//!
//! Every arm here answers one question - "the world said this, so what
//! is true now?" - and nothing else. The markup dispatches messages;
//! this function decides what they mean. No I/O happens here directly:
//! anything that touches the world goes through the effects channel
//! (`fx`), and anything that comes back arrives as another message.

const std = @import("std");
const native_sdk = @import("native_sdk");

const model_mod = @import("model.zig");
const msg_mod = @import("msg.zig");
const nav = @import("navigation.zig");
const rbac = @import("rbac.zig");
const domain = @import("../domain/models.zig");
const repos = @import("../data/repos.zig");
const page = @import("../data/page.zig");
const auth = @import("../data/auth.zig");

const Model = model_mod.Model;
const Msg = msg_mod.Msg;
const Role = nav.Role;
const Screen = nav.Screen;
const Effects = native_sdk.Effects(Msg);

/// The clock tick. A repeating timer keeps `now_ms` fresh so the
/// kitchen board can show how long a ticket has been waiting.
pub const clock_timer_key: u64 = 100;

/// Boot effects: the clock timer and the first read of the database.
pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    fx.startTimer(.{
        .key = clock_timer_key,
        .interval_ms = 1000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // The first read: the settings the app needs before it can sign
    // anybody in, and the company - an empty database means a fresh
    // installation, and the app opens on the setup screen.
    repos.loadConfig(fx);
    repos.loadCompany(fx);
}

/// Keep the waiter's cart in step with the database: the lines of the
/// order they are serving, with their names copied (the shared
/// order-line buffer is reset on every read).
fn keepActiveOrder(model: *Model) void {
    if (model.active_order_id == 0) {
        model.active_lines = &.{};
        return;
    }
    var count: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id == model.active_order_id) count += 1;
    }
    model.waiter_lines_buf.reset();
    const list = model.waiter_lines_buf.allocSlice(domain.OrderLine, count) orelse {
        model.active_lines = &.{};
        return;
    };
    var index: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id != model.active_order_id) continue;
        list[index] = .{
            .id = line.id,
            .order_id = line.order_id,
            .product_id = line.product_id,
            .product_name = model.waiter_lines_buf.dupe(line.product_name) orelse "",
            .qty = line.qty,
            .unit_price_minor = line.unit_price_minor,
            .tax_bps = line.tax_bps,
            .notes = line.notes,
        };
        index += 1;
    }
    model.active_lines = list[0..index];
}

/// The waiter picked a table. If the table already has an open order,
/// the waiter joins it; if it is free, a new order is opened for it.
fn selectTable(model: *Model, fx: *Effects, table_id: i64) void {
    const table = findTable(model, table_id) orelse return;
    model.waiter_buf.reset();
    model.active_table_id = table.id;
    model.active_table_name_field = model.waiter_buf.dupe(table.name) orelse "";

    // Does the table already have an open order?
    for (model.orders) |order| {
        if (order.dining_table_id != table.id) continue;
        switch (order.status) {
            .pending, .preparing, .ready, .served => {
                model.active_order_id = order.id;
                go(model, .waiter_menu);
                repos.loadOrderLines(fx);
                return;
            },
            .completed, .voided => {},
        }
    }

    // A free table: open an order for it.
    model.pending_order_id = fx.wallMs();
    var number_buffer: [16]u8 = undefined;
    const number = makeOrderNo(&number_buffer, model.pending_order_id);
    repos.openOrderForTable(fx, repos.key_open_order, table.id, model.employee_id, number, model.pending_order_id);
}

/// Add a product to the open order the waiter is serving.
fn addToOrder(model: *Model, fx: *Effects, product_id: i64) void {
    if (model.active_order_id == 0) {
        model.error_text = "Pick a table first";
        return;
    }
    const product = findProduct(model, product_id) orelse return;
    repos.addOrderLine(
        fx,
        repos.key_add_line,
        model.active_order_id,
        product.id,
        product.name,
        product.price_minor,
        fx.wallMs(),
    );
}

/// Take the payment for the order that was just placed and close it.
fn takePayment(model: *Model, fx: *Effects) void {
    if (model.last_order_id == 0) {
        model.payment_error = "There is no order to pay for";
        return;
    }
    const mode = std.enums.fromInt(domain.PaymentMode, model.payment_mode_field) orelse domain.PaymentMode.cash;
    model.busy = true;
    model.payment_error = "";
    repos.takePayment(
        fx,
        repos.key_payment,
        model.last_order_id,
        mode,
        model.last_order_total_minor,
        fx.wallMs(),
    );
}

/// Set up the restaurant: the company, the first operator, and the
/// starter menu and floor. One transaction, in `repos.setupCompany`.
fn submitSetup(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
    const admin = std.mem.trim(u8, model.setup_admin_name.text(), " ");
    const pin = model.setup_pin.text();

    if (name.len == 0) {
        model.setup_error = "Give the restaurant a name";
        return;
    }
    if (admin.len == 0) {
        model.setup_error = "Give the operator a name";
        return;
    }
    if (pin.len == 0) {
        model.setup_error = "Choose a PIN";
        return;
    }
    if (!std.mem.eql(u8, pin, model.setup_pin2.text())) {
        model.setup_error = "The two PINs do not match";
        return;
    }

    // The PIN is hashed with the installation salt, exactly as it is
    // at every other sign-in. The plaintext never reaches the disk.
    var hash: [auth.hex_len]u8 = undefined;
    auth.hashPin(model.pin_salt(), pin, &hash);

    const code = std.mem.trim(u8, model.setup_currency_code.text(), " ");
    const symbol = std.mem.trim(u8, model.setup_currency_symbol.text(), " ");

    model.busy = true;
    model.setup_error = "";
    repos.setupCompany(
        fx,
        repos.key_setup,
        name,
        if (code.len == 0) "USD" else code,
        if (symbol.len == 0) "$" else symbol,
        admin,
        &hash,
        fx.wallMs(),
    );
}

/// A fresh installation keeps the salt made at boot and writes it once.
/// The PIN hashes are useless without it, so it is persisted before the
/// first sign-in is possible.
fn createSalt(model: *Model, fx: *Effects) void {
    model.salt_is_provisional = false;
    repos.saveConfigValue(fx, repos.key_config, "pin_salt", model.pin_salt(), fx.wallMs());
}

/// The SQL behind a sign-in attempt. The PIN is hashed before it gets
/// here - the database never sees a plaintext PIN.
pub const login_sql =
    \\SELECT id, name, role FROM employee
    \\WHERE pin_hash = ?1 AND active = 1
    \\LIMIT 1;
;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        // -------------------------------------------------------- session

        .pick_role => |index| {
            const role = std.enums.fromInt(Role, index) orelse return;
            model.role = role;
            model.role_chosen = true;
            model.login_error = "";
            model.error_text = "";
            if (role.needs_sign_in()) {
                go(model, .login);
            } else {
                // Kiosk roles are signed in by device.
                model.signed_in = true;
                go(model, rbac.home(role));
                repos.loadAll(fx);
                // The kitchen and the customer display watch the orders
                // instead of waiting for a refresh: a live query re-runs
                // itself when the `orders` table changes.
                if (role == .kds or role == .display) repos.watchOpenOrders(fx);
            }
        },

        .pin_edit => |event| model.pin.apply(event),

        .submit_login => {
            if (model.pin_salt().len == 0) {
                model.login_error = "Still starting up - try again in a moment";
                return;
            }
            if (model.pin.text().len == 0) {
                model.login_error = "Enter your PIN";
                return;
            }
            auth.hashPin(model.pin_salt(), model.pin.text(), &model.login_hash);
            fx.dbQuery(.{
                .key = repos.key_login,
                .sql = login_sql,
                .params = &.{.{ .text = model.login_hash[0..] }},
                .on_result = Effects.dbMsg(.login_checked),
            });
        },

        .login_checked => |result| {
            if (result.kind != .page or result.outcome != .ok) {
                model.login_error = "Sign-in failed - try again";
                model.pin.set("");
                return;
            }
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader() or !reader.nextRow(&values)) {
                model.login_error = "Wrong PIN";
                model.pin.set("");
                return;
            }
            model.operator_buf.reset();
            model.employee_id = reader.intOf(&values, "id", 0);
            model.employee_name = model.operator_buf.dupe(reader.textOf(&values, "name")) orelse "";
            model.signed_in = true;
            model.login_error = "";
            model.pin.set("");
            go(model, rbac.home(model.role));
            repos.loadAll(fx);
        },

        .pick_role_again => {
            model.role_chosen = false;
            model.signed_in = false;
            model.login_error = "";
            model.pin.set("");
            model.stack.resetTo(.role_picker);
            model.screen_index = Screen.role_picker.index();
        },

        .sign_out => {
            model.signed_in = false;
            model.employee_id = 0;
            model.employee_name = "";
            model.stack.resetTo(.login);
            model.screen_index = Screen.login.index();
        },

        // ------------------------------------------------------- first run

        .setup_company_edit => |event| model.setup_company_name.apply(event),

        .setup_admin_edit => |event| model.setup_admin_name.apply(event),

        .setup_pin_edit => |event| model.setup_pin.apply(event),

        .setup_pin2_edit => |event| model.setup_pin2.apply(event),

        .setup_currency_edit => |event| model.setup_currency_code.apply(event),

        .setup_submit => submitSetup(model, fx),

        .setup_created => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.setup_error = switch (result.outcome) {
                    .constraint => "That setup breaks a data rule - try different names",
                    .busy => "The database is busy - try again",
                    else => "Could not set up the restaurant",
                };
                return;
            }
            // The restaurant exists: the operator is signed in, and the
            // app becomes a POS.
            model.setup_error = "";
            model.needs_setup = false;
            model.signed_in = true;
            model.employee_id = 1;
            model.employee_name = model.operator_buf.dupe(model.setup_admin_name.text()) orelse "";
            model.role_chosen = true;
            model.role = .admin;
            model.stack.resetTo(.admin_dashboard);
            model.screen_index = Screen.admin_dashboard.index();
            model.nav_section = 0;
            repos.loadAll(fx);
        },

        // ----------------------------------------------------- navigation

        .open_screen => |index| {
            const screen = std.enums.fromInt(Screen, index) orelse return;
            go(model, screen);
        },

        .open_section => |ordinal| {
            // The rail row carries the SECTION ORDINAL, not its position
            // in the list: the two differ the moment a role's rail is
            // not the full set (the waiter's rail has one row, and its
            // ordinal is 7).
            const section = std.enums.fromInt(nav.NavSection, ordinal) orelse return;
            const section_id = section.index();
            var known = false;
            for (rbac.nav_sections(model.role)) |row| {
                if (row.id == section_id) known = true;
            }
            if (!known) return;
            go(model, rbac.section_screen(section));
        },

        .go_back => {
            if (model.stack.pop()) |screen| {
                model.screen_index = screen.index();
                model.nav_section = sectionIndex(screen);
            }
        },

        .rail_resized => |fraction| model.rail_split = fraction,

        .menu_resized => |fraction| model.menu_split = fraction,

        .open_pos => go(model, .pos),

        .open_orders => go(model, .orders),

        .open_tables => go(model, .dining_tables),

        // ---------------------------------------------------------- the POS

        .search_edit => |event| model.search.apply(event),

        .set_category => |id| model.selected_category = id,

        .set_category_all => model.selected_category = 0,

        .add_to_cart => |product_id| addToCart(model, product_id),

        .remove_from_cart => |product_id| removeFromCart(model, product_id),

        .set_order_type => |index| {
            model.cart_order_type = std.enums.fromInt(domain.OrderType, index) orelse return;
        },

        .clear_cart => {
            model.cart_len = 0;
            model.cart_buf.reset();
        },

        .place_order => placeOrder(model, fx),

        .order_placed => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                // The operator is told WHAT failed, not just that
                // something did: a rejected order is a data problem
                // (a table that no longer exists, a product that was
                // deleted mid-sale) and a busy database is not.
                model.error_text = switch (result.outcome) {
                    .constraint => "The order broke a data rule - check the table and the products",
                    .busy => "The database is busy - try again",
                    .misuse => "The order was malformed",
                    .io_failed => "Storage error - the order was not saved",
                    else => "Could not save the order",
                };
                return;
            }
            model.cart_len = 0;
            model.cart_buf.reset();
            go(model, .order_confirmation);
            repos.loadOrders(fx);
        },

        // ----------------------------------------------------- the waiter

        .select_table => |table_id| selectTable(model, fx, table_id),

        .go_waiter_tables => go(model, .waiter_tables),

        .go_waiter_menu => go(model, .waiter_menu),

        .go_waiter_cart => go(model, .waiter_cart),

        .order_opened => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not open the table";
                return;
            }
            // The order exists: the waiter can add to it.
            model.active_order_id = model.pending_order_id;
            model.pending_order_id = 0;
            go(model, .waiter_menu);
            repos.loadOrderLines(fx);
        },

        .add_to_order => |product_id| addToOrder(model, fx, product_id),

        .order_line_added => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not add the item";
                return;
            }
            // The line is on the order: read the order back so the
            // waiter sees the running total.
            repos.loadOrderLines(fx);
            repos.loadOrders(fx);
        },

        // ---------------------------------------------------- the payment

        .set_payment_mode => |id| model.payment_mode_field = id,

        .take_payment => takePayment(model, fx),

        .back_to_pos => {
            // The sale is over: the confirmation state goes, and the
            // next order starts from an empty cart.
            model.last_order_id = 0;
            model.last_order_no_field = "";
            model.last_order_type_field = "";
            model.last_order_total_minor = 0;
            model.last_order_items_count = 0;
            model.payment_error = "";
            go(model, .pos);
        },

        .payment_taken => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.payment_error = switch (result.outcome) {
                    .constraint => "The payment broke a data rule",
                    .busy => "The database is busy - try again",
                    else => "Could not take the payment",
                };
                return;
            }
            model.payment_error = "";
            // The sale is done: back to the order list, where the
            // closed order is now a completed one.
            go(model, .orders);
            repos.loadOrders(fx);
        },

        // -------------------------------------------------- the kitchen board

        .advance_order => |order_id| {
            const order = findOrder(model, order_id) orelse return;
            const next = nextStatus(order.status);
            repos.setOrderStatus(fx, order_id, next, fx.wallMs());
        },

        .order_status_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not update the order";
                return;
            }
            repos.loadOrders(fx);
        },

        // -------------------------------------------------------------- data

        .products_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not load the menu";
                return;
            }
            if (result.kind == .page) repos.decodeProducts(model, result.bytes);
        },

        .categories_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCategories(model, result.bytes);
        },

        .tables_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "Could not load the tables";
                return;
            }
            if (result.kind == .page) repos.decodeTables(model, result.bytes);
        },

        .employees_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeEmployees(model, result.bytes);
        },

        .customers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCustomers(model, result.bytes);
        },

        .orders_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeOrders(model, result.bytes);
        },

        .order_lines_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeOrderLines(model, result.bytes);
            keepActiveOrder(model);
        },

        .config_loaded => |result| {
            if (result.outcome != .ok) return;
            switch (result.kind) {
                .page => {
                    var reader = page.Reader.init(result.bytes);
                    var values: [page.max_columns]page.Value = undefined;
                    if (!reader.readHeader() or !reader.nextRow(&values)) return;
                    const salt = reader.textOf(&values, "value");
                    if (salt.len == 0) return;
                    const copied = model.pin_salt_buf[0..];
                    const length = @min(salt.len, copied.len);
                    @memcpy(copied[0..length], salt[0..length]);
                    model.pin_salt_len = length;
                    // The database has the salt now: it is not the
                    // provisional one any more.
                    model.salt_is_provisional = false;
                },
                .done => {
                    // The settings query finished. If the database had
                    // no salt, this is a fresh installation and the
                    // provisional salt the app made at boot is the one
                    // that counts - so store it.
                    if (model.salt_is_provisional) createSalt(model, fx);
                },
                .exec => {},
            }
        },

        .config_saved => {},

        .company_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCompany(model, result.bytes);
            model.db_ready = true;
            // No company row: this is a fresh installation, and the
            // app's first job is to become a restaurant.
            if (model.company_id == 0 and !model.needs_setup) {
                model.needs_setup = true;
                model.setup_currency_code.set("USD");
                model.setup_currency_symbol.set("$");
                model.stack.resetTo(.setup);
                model.screen_index = Screen.setup.index();
            }
        },

        .db_failed => |result| {
            model.busy = false;
            model.error_text = switch (result.outcome) {
                .busy => "The database is busy - try again",
                .io_failed => "Storage error",
                .corrupt => "The database is damaged",
                else => "The database refused the request",
            };
        },

        // ----------------------------------------------------------- chrome

        .dismiss_error => model.error_text = "",

        .toggle_theme => model.theme_dark = !model.theme_dark,

        .tick => |timer| {
            if (timer.outcome != .fired) return;
            model.now_ms = fx.wallMs();
        },
    }
}

// ------------------------------------------------------------- helpers

/// Move to a screen, refusing destinations the role may not open.
fn go(model: *Model, screen: Screen) void {
    if (!rbac.allows(model.role, screen)) {
        model.error_text = "This role cannot open that screen";
        return;
    }
    if (!model.stack.push(screen)) {
        // The history is full: keep the current screen rather than
        // losing the way back.
        return;
    }
    model.screen_index = screen.index();
    model.nav_section = sectionIndex(screen);
}

/// The nav section a screen belongs to, as the index the rail uses.
fn sectionIndex(screen: Screen) usize {
    const section = screen.nav_section() orelse return 0;
    return section.index();
}

fn addToCart(model: *Model, product_id: i64) void {
    for (model.cart[0..model.cart_len], 0..) |line, index| {
        if (line.product_id == product_id) {
            model.cart[index].qty += 1;
            return;
        }
    }
    if (model.cart_len >= model_mod.max_cart_lines) return;
    const product = findProduct(model, product_id) orelse return;
    const name = model.cart_buf.dupe(product.name) orelse return;
    model.cart[model.cart_len] = .{
        .product_id = product.id,
        .name = name,
        .price_minor = product.price_minor,
        .qty = 1,
    };
    model.cart_len += 1;
}

fn removeFromCart(model: *Model, product_id: i64) void {
    var index: usize = 0;
    while (index < model.cart_len) : (index += 1) {
        if (model.cart[index].product_id != product_id) continue;
        if (model.cart[index].qty > 1) {
            model.cart[index].qty -= 1;
            return;
        }
        // Drop the line and shift the rest down.
        var next = index + 1;
        while (next < model.cart_len) : (next += 1) {
            model.cart[next - 1] = model.cart[next];
        }
        model.cart_len -= 1;
        return;
    }
}

fn findProduct(model: *const Model, product_id: i64) ?domain.Product {
    for (model.products) |product| {
        if (product.id == product_id) return product;
    }
    return null;
}

fn findTable(model: *const Model, table_id: i64) ?domain.DiningTable {
    for (model.tables) |table| {
        if (table.id == table_id) return table;
    }
    return null;
}

fn findOrder(model: *const Model, order_id: i64) ?domain.Order {
    for (model.orders) |order| {
        if (order.id == order_id) return order;
    }
    return null;
}

/// The order lifecycle. A voided order is terminal - it never moves
/// forward again.
fn nextStatus(status: domain.OrderStatus) domain.OrderStatus {
    return switch (status) {
        .pending => .preparing,
        .preparing => .ready,
        .ready => .served,
        .served => .completed,
        .completed, .voided => status,
    };
}

/// Turn the cart into an order and write it.
///
/// The order id is the wall clock in milliseconds: a POS writes one
/// order at a time, so the clock is unique enough, and it keeps the
/// order number readable ("1749843210123"). A dedicated sequence would
/// be better - see the roadmap.
fn placeOrder(model: *Model, fx: *Effects) void {
    if (model.cart_len == 0) {
        model.error_text = "The cart is empty";
        return;
    }
    const now = fx.wallMs();
    var order = domain.Order{
        .id = now,
        .order_no = "pending",
        .order_type = model.cart_order_type,
        .status = .pending,
        .status_label = domain.OrderStatus.pending.label(),
        .type_label = model.cart_order_type.label(),
        .dining_table_id = 0,
        .customer_id = 0,
        .employee_id = model.employee_id,
        .subtotal_minor = model.cart_total_minor(),
        .tax_minor = 0,
        .discount_minor = 0,
        .total_minor = model.cart_total_minor(),
        .placed_at = now,
        .notes = "",
    };
    order.order_no = model.cart_buf.dupe(allocOrderNo(model, now)) orelse "";

    var lines: [model_mod.max_cart_lines]domain.OrderLine = undefined;
    var count: usize = 0;
    for (model.cart[0..model.cart_len]) |line| {
        lines[count] = .{
            .id = now + @as(i64, @intCast(count)),
            .order_id = now,
            .product_id = line.product_id,
            .product_name = line.name,
            .qty = line.qty,
            .unit_price_minor = line.price_minor,
            .tax_bps = 0,
            .notes = "",
        };
        count += 1;
    }

    // The confirmation screen shows this order and the payment is
    // taken against it.
    model.sale_buf.reset();
    model.last_order_id = order.id;
    model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
    model.last_order_type_field = model.sale_buf.dupe(order.order_type.label()) orelse "";
    model.last_order_total_minor = order.total_minor;
    model.last_order_items_count = 0;
    for (lines[0..count]) |line| model.last_order_items_count += line.qty;
    model.last_order_at = order.placed_at;
    model.payment_error = "";

    model.busy = true;
    repos.saveOrder(fx, order, lines[0..count]);
}

/// The order number. It is the wall clock in MILLISECONDS: unique (the
/// column is UNIQUE), sortable, and the same value as the order id, so
/// a number on a ticket is a number you can trace. A per-day sequence
/// ("1, 2, 3") is nicer on a receipt and is a later change.
fn makeOrderNo(buffer: *[16]u8, at: i64) []const u8 {
    const written = std.fmt.bufPrint(buffer, "{d}", .{at}) catch return "0";
    return written;
}

/// The order number for the POS cart, owned by the cart's buffer.
fn allocOrderNo(model: *Model, at: i64) []const u8 {
    const buffer = model.cart_buf.alloc(16, 1) orelse return "0";
    var out: [16]u8 = undefined;
    const written = makeOrderNo(&out, at);
    @memcpy(buffer[0..written.len], written);
    return buffer[0..written.len];
}
