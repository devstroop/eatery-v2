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
    // anybody in, then the rest of the shell's data.
    repos.loadConfig(fx);
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
                model.error_text = "Could not save the order";
                return;
            }
            model.cart_len = 0;
            model.cart_buf.reset();
            go(model, .order_confirmation);
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
        },

        .config_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind != .page) return;
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader() or !reader.nextRow(&values)) {
                // No salt yet: this is a fresh installation. Make one.
                createSalt(model, fx);
                return;
            }
            const salt = reader.textOf(&values, "value");
            if (salt.len == 0) {
                createSalt(model, fx);
                return;
            }
            const copied = model.pin_salt_buf[0..];
            const length = @min(salt.len, copied.len);
            @memcpy(copied[0..length], salt[0..length]);
            model.pin_salt_len = length;
            model.salt_is_provisional = false;
        },

        .config_saved => {},

        .company_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCompany(model, result.bytes);
            model.db_ready = true;
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

    model.busy = true;
    repos.saveOrder(fx, order, lines[0..count]);
}

/// A readable order number: the wall clock in seconds.
fn allocOrderNo(model: *Model, at: i64) []const u8 {
    const buffer = model.cart_buf.alloc(16, 1) orelse return "0";
    var out: [16]u8 = undefined;
    const written = std.fmt.bufPrint(&out, "{d}", .{@divTrunc(at, 1000)}) catch return "0";
    @memcpy(buffer[0..written.len], written);
    return buffer[0..written.len];
}
