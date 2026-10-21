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
    // The tax slabs are read with the rest of the business's settings:
    // a sale's tax is worked out from them, and a sale that is placed
    // before they arrive would be taxed at nothing.
    repos.loadTaxSlabs(fx);
}

/// A new order on the board gets a sound. The kitchen hears the sale
/// without looking at the screen - and the cashier hears it too, which
/// is how a second cashier knows a table needs serving.
fn announceNewOrder(model: *Model, fx: *Effects) void {
    var newest: i64 = model.last_seen_order_id;
    for (model.orders) |order| {
        if (order.id > newest) newest = order.id;
    }
    if (newest == model.last_seen_order_id) return;
    const first_time = model.last_seen_order_id == 0;
    model.last_seen_order_id = newest;
    // The first board of the shift is not a new sale: the kitchen has
    // not been watching yet.
    if (first_time) return;
    fx.playAudio(.{
        .key = repos.key_chime,
        .path = "assets/chime.wav",
        .on_event = Effects.audioMsg(.audio_event),
    });
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
            .station_id = line.station_id,
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

    // A free table: open an order for it. The order number is a
    // sequence, and the database assigns it.
    const order_id = nextOrderId(model, fx.wallMs());
    model.pending_order_id = order_id;
    repos.openOrderForTable(fx, repos.key_open_order, table.id, model.employee_id, order_id);
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

/// Open the product form: an existing product, or a new one.
fn openProductForm(model: *Model, id: i64) void {
    model.form_product_id = id;
    model.form_product_name_buf.set("");
    model.form_product_price_buf.set("");
    model.form_product_category_id = 0;
    model.form_product_food_id = 0;
    if (id != 0) {
        for (model.products) |product| {
            if (product.id != id) continue;
            model.form_product_name_buf.set(product.name);
            model.form_product_price_buf.set(priceAsTyped(product.price_minor));
            model.form_product_category_id = product.category_id;
            model.form_product_food_id = @intFromEnum(product.food_type);
            break;
        }
    }
    go(model, .product_form);
}

/// Open the employee form: an existing employee, or a new one.
fn openEmployeeForm(model: *Model, id: i64) void {
    model.form_employee_id = id;
    model.form_employee_name_buf.set("");
    model.form_employee_role_id = 0;
    if (id != 0) {
        for (model.employees) |employee| {
            if (employee.id != id) continue;
            model.form_employee_name_buf.set(employee.name);
            model.form_employee_role_id = employee.role;
            break;
        }
    }
    go(model, .employee_form);
}

/// Open the category form: an existing category, or a new one.
fn openCategoryForm(model: *Model, id: i64) void {
    model.form_category_id = id;
    model.form_category_name_buf.set("");
    if (id != 0) {
        for (model.categories) |category| {
            if (category.id != id) continue;
            model.form_category_name_buf.set(category.name);
            break;
        }
    }
    go(model, .category_form);
}

/// Save the category the form is editing.
fn saveCategory(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_category_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The category needs a name";
        return;
    }
    const id = if (model.form_category_id != 0) model.form_category_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveCategory(fx, repos.key_save_category, id, name, fx.wallMs());
}

/// Open the discount form: an existing discount, or a new one.
fn openDiscountForm(model: *Model, id: i64) void {
    model.form_discount_id = id;
    model.form_discount_name_buf.set("");
    model.form_discount_percent_buf.set("");
    model.form_discount_amount_buf.set("");
    if (id != 0) {
        for (model.discounts_list) |discount| {
            if (discount.id != id) continue;
            model.form_discount_name_buf.set(discount.name);
            model.form_discount_percent_buf.set(rateAsTyped(discount.percent_bps));
            model.form_discount_amount_buf.set(priceAsTyped(discount.amount_minor));
            break;
        }
    }
    go(model, .discount_form);
}

/// Open the tax slab form: an existing slab, or a new one.
fn openTaxSlabForm(model: *Model, id: i64) void {
    model.form_tax_slab_id = id;
    model.form_tax_slab_name_buf.set("");
    model.form_tax_slab_rate_buf.set("");
    model.form_tax_slab_inclusive = false;
    if (id != 0) {
        for (model.tax_slabs_list) |slab| {
            if (slab.id != id) continue;
            model.form_tax_slab_name_buf.set(slab.name);
            model.form_tax_slab_rate_buf.set(rateAsTyped(slab.rate_bps));
            model.form_tax_slab_inclusive = slab.inclusive;
            break;
        }
    }
    go(model, .tax_slab_form);
}

/// A rate in basis points, as the form shows it: the percentage, with
/// no decimals the owner did not type.
fn rateAsTyped(rate_bps: i64) []const u8 {
    var buffer: [24]u8 = undefined;
    if (@mod(rate_bps, 100) == 0) {
        const written = std.fmt.bufPrint(&buffer, "{d}", .{ @divTrunc(rate_bps, 100) }) catch return "";
        return written;
    }
    const written = std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ @divTrunc(rate_bps, 100), @mod(rate_bps, 100) }) catch return "";
    return written;
}

/// A price in minor units, as the form shows it: the amount with two
/// decimals and no currency symbol.
fn priceAsTyped(minor: i64) []const u8 {
    var buffer: [24]u8 = undefined;
    const whole = @divTrunc(minor, 100);
    const cents = @mod(minor, 100);
    const written = std.fmt.bufPrint(&buffer, "{d}.{d:0>2}", .{ whole, cents }) catch return "";
    return written;
}

/// Save the discount the form is editing.
///
/// A discount is a share of the bill, an amount off it, or both. The
/// cashier's rule is the one the model already uses: a percentage wins,
/// and an amount is what is left when there is no percentage.
fn saveDiscount(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_discount_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The discount needs a name";
        return;
    }
    const percent = if (model.form_discount_percent_buf.text().len == 0)
        0
    else
        parsePrice(model.form_discount_percent_buf.text()) orelse {
            model.error_text = "The percent must be a number - ten for ten percent";
            return;
        };
    const amount = if (model.form_discount_amount_buf.text().len == 0)
        0
    else
        parsePrice(model.form_discount_amount_buf.text()) orelse {
            model.error_text = "The amount must be a number";
            return;
        };
    if (percent > 10000) {
        model.error_text = "A discount cannot be more than a hundred percent";
        return;
    }
    if (percent == 0 and amount == 0) {
        model.error_text = "A discount has to take something off";
        return;
    }
    const id = if (model.form_discount_id != 0) model.form_discount_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveDiscount(fx, repos.key_save_discount, id, name, percent, amount, fx.wallMs());
}

/// Save the tax slab the form is editing.
///
/// The rate is a percentage, and the percentage's hundredths are the
/// rate's basis points: five percent is five hundred, and twelve and
/// three quarters is one thousand two hundred and seventy five.
fn saveTaxSlab(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_tax_slab_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The tax slab needs a name";
        return;
    }
    const rate = parsePrice(model.form_tax_slab_rate_buf.text()) orelse {
        model.error_text = "The rate must be a number - five for five percent";
        return;
    };
    if (rate > 10000) {
        model.error_text = "A rate cannot be more than a hundred percent";
        return;
    }
    const id = if (model.form_tax_slab_id != 0) model.form_tax_slab_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveTaxSlab(fx, repos.key_save_tax_slab, id, name, rate, model.form_tax_slab_inclusive);
}

/// Save the product the form is editing.
fn saveProduct(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_product_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The product needs a name";
        return;
    }
    const price = parsePrice(model.form_product_price_buf.text()) orelse {
        model.error_text = "The price is not a number";
        return;
    };
    if (model.form_product_category_id == 0) {
        model.error_text = "Pick a category";
        return;
    }
    const id = if (model.form_product_id != 0) model.form_product_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveProduct(
        fx,
        repos.key_save_product,
        id,
        model.form_product_category_id,
        name,
        price,
        model.form_product_food_id,
        fx.wallMs(),
    );
}

/// Save the employee the form is editing.
fn saveEmployee(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_employee_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The employee needs a name";
        return;
    }
    const id = if (model.form_employee_id != 0) model.form_employee_id else fx.wallMs();
    model.busy = true;
    model.error_text = "";
    repos.saveEmployee(fx, repos.key_save_employee, id, name, model.form_employee_role_id, fx.wallMs());
}

/// The price as typed, in minor units. A price is a decimal amount, and
/// a decimal amount is never a float in this app.
fn parsePrice(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;
    var whole: i64 = 0;
    var cents: i64 = 0;
    var after_dot = false;
    var digits: usize = 0;
    for (trimmed) |char| {
        if (char == '.') {
            if (after_dot) return null;
            after_dot = true;
            continue;
        }
        if (!std.ascii.isDigit(char)) return null;
        if (after_dot) {
            if (digits == 0) cents += (char - '0') * 10;
            if (digits == 1) cents += (char - '0');
            digits += 1;
        } else {
            whole = whole * 10 + (char - '0');
        }
    }
    if (digits == 1) cents *= 10;
    return whole * 100 + cents;
}

/// Save the company. The name is the one field that must not be empty:
/// it is on every receipt.
fn saveCompany(model: *Model, fx: *Effects) void {
    const name = std.mem.trim(u8, model.form_name_buf.text(), " ");
    if (name.len == 0) {
        model.error_text = "The restaurant needs a name";
        return;
    }
    model.busy = true;
    model.error_text = "";
    repos.updateCompany(
        fx,
        repos.key_save_company,
        name,
        std.mem.trim(u8, model.form_address_buf.text(), " "),
        std.mem.trim(u8, model.form_phone_buf.text(), " "),
        std.mem.trim(u8, model.form_tax_buf.text(), " "),
    );
}

/// Take the payment for the order that was just placed and close it.
fn takePayment(model: *Model, fx: *Effects) void {
    if (model.last_order_id == 0) {
        model.payment_error = "There is no order to pay for";
        return;
    }
    // One payment at a time: a second tap would take the money twice.
    if (model.payment_pending) {
        model.payment_error = "The payment is still being taken";
        return;
    }
    const order = findOrder(model, model.last_order_id) orelse {
        model.payment_error = "That order is no longer on the board";
        return;
    };
    if (order.status == .completed) {
        model.payment_error = "This order is already paid";
        return;
    }
    const mode = std.enums.fromInt(domain.PaymentMode, model.payment_mode_field) orelse domain.PaymentMode.cash;
    model.busy = true;
    model.payment_pending = true;
    model.payment_error = "";
    repos.takePayment(
        fx,
        repos.key_payment,
        order.id,
        order.status,
        mode,
        order.total_minor,
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
    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(model.pin_salt(), pin, &hash) orelse {
        model.setup_error = "Could not hash the PIN - try again";
        return;
    };

    const code = std.mem.trim(u8, model.setup_currency_code.text(), " ");
    const symbol = std.mem.trim(u8, model.setup_currency_symbol.text(), " ");

    model.busy = true;
    model.setup_error = "";
    const currency = if (code.len == 0) "USD" else code;
    repos.setupCompany(
        fx,
        repos.key_setup,
        name,
        currency,
        if (symbol.len == 0) "$" else symbol,
        admin,
        hashed,
        model.pin_salt(),
        model_mod.decimalsForCurrency(currency),
        std.mem.trim(u8, model.wizard_address_buf.text(), " "),
        std.mem.trim(u8, model.wizard_phone_buf.text(), " "),
        std.mem.trim(u8, model.wizard_tax_buf.text(), " "),
        fx.wallMs(),
    );
}

/// A fresh installation keeps the salt made at boot and writes it once.
///
/// The salt is NOT marked as confirmed here: the write has not happened
/// yet. A failed write that still cleared the flag would leave the app
/// hashing PINs against a salt that is not in the database - the
/// operator signs in, the next boot makes a different salt, and nobody
/// can ever sign in again. The write coming back moves the state to
/// `.verifying`; only the read-back in `config_loaded` confirms the salt
/// the database actually holds.
fn createSalt(model: *Model, fx: *Effects) void {
    repos.saveSalt(fx, repos.key_save_salt, model.pin_salt(), fx.wallMs());
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        // -------------------------------------------------------- session

        .pick_role => |index| {
            const role = std.enums.fromInt(Role, index) orelse return;
            // Choosing a role is a session boundary. The previous
            // operator's cart, filters and history end here.
            resetSession(model, if (role.needs_sign_in()) .login else rbac.home(role));
            model.role = role;
            model.role_chosen = true;
            if (role.needs_sign_in()) return;
            // Kiosk roles are signed in by device.
            model.signed_in = true;
            repos.loadAll(fx);
            // The kitchen and the customer display watch the orders
            // instead of waiting for a refresh: a live query re-runs
            // itself when the `orders` table changes.
            if (role == .kds or role == .display) {
                repos.watchOpenOrders(fx);
                // A live query only sees the writes THIS connection
                // made. The kitchen is usually another device, so the
                // board also re-reads on a timer: that is what makes a
                // sale on the cashier's machine appear on the kitchen's
                // screen.
                fx.startTimer(.{
                    .key = repos.key_board_refresh,
                    .interval_ms = 2000,
                    .mode = .repeating,
                    .on_fire = Effects.timerMsg(.refresh_orders),
                });
            }
        },

        .pin_edit => |event| model.pin.apply(event),

        .submit_login => {
            // The salt has to be the salt the DATABASE holds, or the
            // hash this sign-in computes cannot match the hash the
            // database stored. Until the database has confirmed the
            // salt, there is nothing to hash with that could ever
            // match - so the sign-in waits rather than guessing.
            if (model.pin_salt().len == 0 or model.salt_state != .confirmed) {
                model.login_error = "Still starting up - try again in a moment";
                return;
            }
            // The till stops guessing. A PIN is short, and a short PIN
            // is found by trying every one of them; the till is where
            // that trying happens, so the till is where it stops.
            if (model.login_locked()) {
                model.login_error = "Too many wrong PINs - try again in a moment";
                return;
            }
            if (model.pin.text().len == 0) {
                model.login_error = "Enter your PIN";
                return;
            }
            // The hash the sign-in looks up: the slow one, and the
            // old fast one, so an employee whose PIN was hashed
            // before bcrypt can still sign in.
            const hashed = auth.hashPin(model.pin_salt(), model.pin.text(), &model.login_hash) orelse {
                model.login_error = "Could not check the PIN - try again";
                return;
            };
            model.login_hash_len = hashed.len;
            const legacy = auth.legacyHash(model.pin_salt(), model.pin.text(), &model.login_legacy_hash) orelse {
                model.login_error = "Could not check the PIN - try again";
                return;
            };
            fx.dbQuery(.{
                .key = repos.key_login,
                // The query carries the session's role: the sign-in is
                // for ONE operating mode, and only an employee whose
                // stored role matches it may hold it.
                .sql = repos.login_sql,
                .params = &.{
                    .{ .text = hashed },
                    .{ .text = legacy },
                    .{ .integer = @intFromEnum(rbac.employee_role(model.role)) },
                },
                .on_result = Effects.dbMsg(.login_checked),
            });
        },

        .login_checked => |result| {
            if (result.kind != .page or result.outcome != .ok) {
                noteLoginFailure(model);
                model.login_error = "Sign-in failed - try again";
                model.pin.set("");
                return;
            }
            var reader = page.Reader.init(result.bytes);
            var values: [page.max_columns]page.Value = undefined;
            if (!reader.readHeader() or !reader.nextRow(&values)) {
                noteLoginFailure(model);
                model.login_error = "Wrong PIN";
                model.pin.set("");
                return;
            }
            // The row that came back has to be an employee of THIS
            // mode. The query already asks for that; this is the check
            // that says so, and it is what keeps the permission matrix
            // from being decoration.
            const stored_role = reader.intOf(&values, "role", -1);
            if (stored_role != @intFromEnum(rbac.employee_role(model.role))) {
                model.login_error = "Wrong PIN";
                model.pin.set("");
                return;
            }
            // The row's hash is the one that matched, and the PIN is
            // what it was made from: verify it here, so a row that
            // matched for any other reason is not a sign-in.
            const stored = reader.textOf(&values, "pin_hash");
            if (!auth.verifyPin(model.pin_salt(), model.pin.text(), stored)) {
                model.login_error = "Sign-in failed - try again";
                model.pin.set("");
                return;
            }
            // The session begins now. Reset before taking the name:
            // the reset clears the operator buffer the name lives in.
            const employee_id = reader.intOf(&values, "id", 0);
            const employee_name = reader.textOf(&values, "name");
            resetSession(model, rbac.home(model.role));
            model.employee_id = employee_id;
            model.employee_name = model.operator_buf.dupe(employee_name) orelse "";
            model.signed_in = true;
            model.role_chosen = true;
            // The counter of wrong PINs starts again: the cashier is
            // in, and the till is not holding a grudge.
            model.login_failures = 0;
            model.login_locked_until = 0;
            repos.loadAll(fx);
            // A hash from before bcrypt is rewritten in the modern
            // form, so the next sign-in of this employee is a slow
            // one and the old digest stops being worth anything.
            if (auth.isLegacy(stored)) {
                repos.savePinHash(fx, repos.key_save_pin_hash, model.employee_id, model.login_hash[0..model.login_hash_len]);
            }
        },

        .pick_role_again => {
            resetSession(model, .role_picker);
            model.role_chosen = false;
        },

        .sign_out => {
            // A PIN role goes back to its sign-in gate. A kiosk role
            // has no PIN, so it goes back to the role picker that
            // chooses the device's mode.
            const gate: Screen = if (model.role.needs_sign_in()) .login else .role_picker;
            resetSession(model, gate);
            model.role_chosen = gate == .login;
        },

        // ------------------------------------------------------- first run

        .wizard_next => {
            // The company first, then the owner. The step that is NOT
            // on the screen is not asked for.
            const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
            if (name.len == 0) {
                model.error_text = "Give the restaurant a name";
                return;
            }
            model.error_text = "";
            go(model, .wizard);
        },

        .wizard_back => {
            model.error_text = "";
            go(model, .create_company);
        },

        .wizard_quick_setup => {
            // The quick setup asks for less and takes less. It is the
            // same restaurant, written the same way.
            go(model, .setup);
        },

        .wizard_address_edit => |event| model.wizard_address_buf.apply(event),

        .wizard_phone_edit => |event| model.wizard_phone_buf.apply(event),

        .wizard_tax_edit => |event| model.wizard_tax_buf.apply(event),

        .setup_company_edit => |event| model.setup_company_name.apply(event),

        .setup_admin_edit => |event| model.setup_admin_name.apply(event),

        .setup_pin_edit => |event| model.setup_pin.apply(event),

        .setup_pin2_edit => |event| model.setup_pin2.apply(event),

        .setup_currency_edit => |event| model.setup_currency_code.apply(event),

        .setup_symbol_edit => |event| model.setup_currency_symbol.apply(event),

        .setup_submit => submitSetup(model, fx),

        .setup_created => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                // A failed setup is still a session boundary: nothing
                // from a partial first run may leak into the retry.
                resetSession(model, .setup);
                model.setup_error = switch (result.outcome) {
                    .constraint => "That setup breaks a data rule - try different names",
                    .busy => "The database is busy - try again",
                    else => "Could not set up the restaurant",
                };
                return;
            }
            // The restaurant exists: the operator is signed in, and the
            // app becomes a POS.
            resetSession(model, .admin_dashboard);
            model.needs_setup = false;
            model.signed_in = true;
            model.employee_id = 1;
            model.employee_name = model.operator_buf.dupe(model.setup_admin_name.text()) orelse "";
            model.role_chosen = true;
            model.role = .admin;
            // The setup wrote the salt in the same transaction as the
            // operator's PIN hash, so the salt in the model is now the
            // salt in the database. A sign-in may use it.
            model.salt_state = .confirmed;
            repos.loadAll(fx);
        },

        // ----------------------------------------------------- navigation

        .open_screen => |index| {
            const screen = std.enums.fromInt(Screen, index) orelse return;
            // The company form starts from what is stored: opening the
            // settings shows the saved details, not an empty form. It
            // is seeded HERE, when the screen is opened - seeding it on
            // every load would wipe what the operator is typing.
            if (screen == .settings_company and model.company_id != 0) {
                model.form_name_buf.set(model.company_name_field);
                model.form_address_buf.set(model.company_address_field);
                model.form_phone_buf.set(model.company_phone_field);
                model.form_tax_buf.set(model.company_tax_field);
            }
            go(model, screen);
            // The screen loads what it shows: the effects channel has
            // sixteen slots, and loading everything at once fills them
            // and the late queries are refused.
            repos.loadForScreen(fx, screen);
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

        .open_payments => {
            go(model, .payments);
            repos.loadPayments(fx);
        },

        .open_tables => go(model, .dining_tables),

        // ---------------------------------------------------------- the POS
        .open_order => |id| {
            model.selected_order_id = id;
            go(model, .order_detail);
            repos.loadOrderLines(fx);
        },

        .pay_selected_order => {
            const id = model.selected_order_id;
            if (id == 0) return;
            const order = findOrder(model, id) orelse return;
            model.sale_buf.reset();
            model.last_order_id = order.id;
            model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
            model.last_order_type_field = model.sale_buf.dupe(order.type_label) orelse "";
            model.last_order_total_minor = order.total_minor;
            model.last_order_items_count = 0;
            for (model.order_lines) |line| {
                if (line.order_id != order.id) continue;
                model.last_order_items_count += line.qty;
            }
            model.last_order_at = order.placed_at;
            model.payment_error = "";
            go(model, .order_confirmation);
        },

        .pay_order => |id| {
            // The confirmation screen takes the money, so the sale state
            // is filled in from the order that is being paid.
            const order = findOrder(model, id) orelse return;
            model.sale_buf.reset();
            model.last_order_id = order.id;
            model.last_order_no_field = model.sale_buf.dupe(order.order_no) orelse "";
            model.last_order_type_field = model.sale_buf.dupe(order.type_label) orelse "";
            model.last_order_total_minor = order.total_minor;
            model.last_order_items_count = 0;
            for (model.order_lines) |line| {
                if (line.order_id != order.id) continue;
                model.last_order_items_count += line.qty;
            }
            model.last_order_at = order.placed_at;
            model.payment_error = "";
            go(model, .order_confirmation);
        },

        .search_edit => |event| model.search.apply(event),

        .set_category => |id| model.selected_category = id,

        .set_category_all => model.selected_category = 0,

        .add_to_cart => |product_id| addToCart(model, product_id),

        .remove_from_cart => |product_id| removeFromCart(model, product_id),

        .set_order_type => |index| {
            model.cart_order_type = std.enums.fromInt(domain.OrderType, index) orelse return;
        },

        .apply_discount => |discount_id| {
            for (model.discounts_list) |discount| {
                if (discount.id != discount_id) continue;
                if (!discount.active) break;
                model.cart_discount_id = discount_id;
                model.error_text = "";
                return;
            }
            model.error_text = "That discount is not one you can use";
        },

        .clear_discount => {
            model.cart_discount_id = 0;
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
                // The sale did not happen, so the cart is still the
                // cashier's: the button comes back and the sale can be
                // tried again.
                model.sale_pending = false;
                return;
            }
            model.sale_pending = false;
            model.cart_len = 0;
            model.cart_buf.reset();
            // The sale landed: the next sale is a new attempt, with its
            // own id and its own request key.
            model.cart_attempt_id = 0;
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
            model.payment_pending = false;
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

        // -------------------------------------------------------- the forms

        .form_currency_code_edit => |event| model.form_currency_code_buf.apply(event),

        .form_currency_symbol_edit => |event| model.form_currency_symbol_buf.apply(event),

        .save_currency => {
            const code = std.mem.trim(u8, model.form_currency_code_buf.text(), " ");
            const symbol = std.mem.trim(u8, model.form_currency_symbol_buf.text(), " ");
            if (code.len == 0) {
                model.error_text = "The currency needs a code";
                return;
            }
            model.busy = true;
            repos.saveCurrency(
                fx,
                repos.key_save_currency,
                code,
                if (symbol.len == 0) "$" else symbol,
                model_mod.decimalsForCurrency(code),
            );
        },

        .currency_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the currency";
                return;
            }
            model.error_text = "";
            repos.loadCompany(fx);
        },

        .form_product_name_edit => |event| model.form_product_name_buf.apply(event),

        .form_product_price_edit => |event| model.form_product_price_buf.apply(event),

        .form_product_category => |id| model.form_product_category_id = id,

        .form_product_food => |id| model.form_product_food_id = id,

        .open_catalogue => go(model, .product_categories),

        .open_categories => go(model, .categories),

        .edit_product => |id| openProductForm(model, id),

        .new_product => openProductForm(model, 0),

        .save_product => saveProduct(model, fx),

        .product_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the product";
                return;
            }
            model.error_text = "";
            repos.loadProducts(fx);
            repos.loadCategories(fx);
            go(model, .product_categories);
        },

        .form_employee_name_edit => |event| model.form_employee_name_buf.apply(event),

        .form_employee_role => |id| model.form_employee_role_id = id,

        .edit_employee => |id| openEmployeeForm(model, id),

        .open_employees => go(model, .employees),

        .reset_employee_pin => |id| {
            model.form_reset_employee_id = id;
            model.form_reset_employee_name = "";
            model.form_reset_pin_buf.set("");
            model.form_reset_pin2_buf.set("");
            for (model.employees) |employee| {
                if (employee.id != id) continue;
                model.form_reset_employee_name = employee.name;
                break;
            }
            go(model, .reset_pin);
        },

        .form_reset_pin_edit => |event| model.form_reset_pin_buf.apply(event),

        .form_reset_pin2_edit => |event| model.form_reset_pin2_buf.apply(event),

        .save_reset_pin => {
            const pin = model.form_reset_pin_buf.text();
            if (model.form_reset_employee_id == 0) {
                model.error_text = "Nobody is having their PIN reset";
                return;
            }
            if (!model.pin_is_acceptable(pin)) {
                model.error_text = "A PIN is six digits or more, and digits only";
                return;
            }
            if (!std.mem.eql(u8, pin, model.form_reset_pin2_buf.text())) {
                model.error_text = "The two PINs do not match";
                return;
            }
            var hash: [auth.hash_length]u8 = undefined;
            const hashed = auth.hashPin(model.pin_salt(), pin, &hash) orelse {
                model.error_text = "Could not hash the PIN - try again";
                return;
            };
            model.busy = true;
            model.error_text = "";
            repos.saveEmployeePin(fx, repos.key_save_employee, model.form_reset_employee_id, hashed);
        },

        .employee_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the employee";
                return;
            }
            model.error_text = "";
            repos.loadEmployees(fx);
            go(model, .employees);
        },

        .new_employee => openEmployeeForm(model, 0),

        .save_employee => saveEmployee(model, fx),

        .reservations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeReservations(model, result.bytes);
        },

        .suppliers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeSuppliers(model, result.bytes);
        },

        .purchase_orders_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodePurchaseOrders(model, result.bytes);
        },

        .inventory_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeProducts(model, result.bytes);
        },

        .printers_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodePrinters(model, result.bytes);
        },

        .edit_tax_slab => |id| openTaxSlabForm(model, id),

        .new_tax_slab => openTaxSlabForm(model, 0),

        .save_tax_slab => saveTaxSlab(model, fx),

        .open_tax_slabs => go(model, .settings_tax),

        .tax_slab_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the tax slab";
                return;
            }
            model.error_text = "";
            repos.loadTaxSlabs(fx);
            go(model, .settings_tax);
        },

        .form_tax_slab_name_edit => |event| model.form_tax_slab_name_buf.apply(event),

        .form_tax_slab_rate_edit => |event| model.form_tax_slab_rate_buf.apply(event),

        .form_tax_slab_inclusive => model.form_tax_slab_inclusive = !model.form_tax_slab_inclusive,

        .tax_slabs_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeTaxSlabs(model, result.bytes);
        },

        .modifier_groups_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeModifierGroups(model, result.bytes);
        },

        .edit_category => |id| openCategoryForm(model, id),

        .new_category => openCategoryForm(model, 0),

        .save_category => saveCategory(model, fx),

        .category_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the category";
                return;
            }
            model.error_text = "";
            repos.loadCategories(fx);
            go(model, .product_categories);
        },

        .form_category_name_edit => |event| model.form_category_name_buf.apply(event),

        .edit_discount => |id| openDiscountForm(model, id),

        .new_discount => openDiscountForm(model, 0),

        .save_discount => saveDiscount(model, fx),

        .open_discounts => go(model, .settings_discounts),

        .discount_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the discount";
                return;
            }
            model.error_text = "";
            repos.loadDiscounts(fx);
            go(model, .settings_discounts);
        },

        .form_discount_name_edit => |event| model.form_discount_name_buf.apply(event),

        .form_discount_percent_edit => |event| model.form_discount_percent_buf.apply(event),

        .form_discount_amount_edit => |event| model.form_discount_amount_buf.apply(event),

        .discounts_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeDiscounts(model, result.bytes);
        },

        // ------------------------------------------------ the company form

        .form_company_name_edit => |event| model.form_name_buf.apply(event),

        .form_company_address_edit => |event| model.form_address_buf.apply(event),

        .form_company_phone_edit => |event| model.form_phone_buf.apply(event),

        .form_company_tax_edit => |event| model.form_tax_buf.apply(event),

        .save_company => saveCompany(model, fx),

        .open_settings => go(model, .settings),

        .company_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.error_text = "Could not save the company";
                return;
            }
            model.error_text = "";
            // Read it back: the form's buffers are the edit model, and
            // the company row is the truth.
            repos.loadCompany(fx);
        },

        // -------------------------------------------------- the kitchen board

        .refresh_orders => |timer| {
            if (timer.outcome != .fired) return;
            repos.loadOrders(fx);
        },

        .set_station_filter => |id| model.station_filter_field = id,

        .set_station_filter_all => model.station_filter_field = 0,

        .stations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeStations(model, result.bytes);
        },

        .product_stations_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeProductStations(model, result.bytes);
        },

        .audio_event => |event| {
            // The chime's own outcome. A failed chime is not the
            // operator's problem: the board still shows the order.
            _ = event;
        },

        .advance_order => |order_id| {
            // One move at a time. A second tap would compute the next
            // status from a model that has not caught up yet, and skip a
            // state on the way.
            if (model.advance_order_id != 0) {
                model.error_text = "The order is still being updated";
                return;
            }
            const order = findOrder(model, order_id) orelse {
                model.error_text = "That order is no longer on the board";
                return;
            };
            const next = nextStatus(order.status);
            // An order does not close without the money. The last step
            // of the lifecycle is the payment, and the kitchen cannot
            // take it - so a ticket that has not been paid for stops
            // here, and says why.
            if (next == .completed and !order.paid) {
                model.error_text = "Take the money before closing the order";
                return;
            }
            model.advance_order_id = order_id;
            model.busy = true;
            repos.setOrderStatus(fx, order_id, order.status, next, fx.wallMs());
        },

        .pin_rehashed => |result| {
            // The rewrite is a courtesy: the sign-in has already
            // happened, and a row that could not be rewritten is worth
            // knowing about but not worth failing over.
            if (result.outcome != .ok) {
                model.error_text = "The PIN could not be upgraded - it still works";
            }
        },

        .order_status_saved => |result| {
            model.busy = false;
            if (result.outcome != .ok) {
                model.advance_order_id = 0;
                model.error_text = "Could not update the order";
                return;
            }
            // The orders come back with the status the DATABASE has,
            // not the one the model guessed: the board shows the truth
            // and the next move is computed from it.
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

        .payments_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = "The payments could not be read - try again";
                return;
            }
            model.error_text = "";
            if (result.kind == .page) repos.decodePayments(model, result.bytes);
        },

        .orders_loaded => |result| {
            if (result.outcome != .ok) {
                // A board that cannot read the orders is a board that
                // silently shows the wrong thing. Say so.
                model.error_text = switch (result.outcome) {
                    .rejected => "The order list is busy - try again",
                    .busy => "The database is busy - try again",
                    else => "Could not read the orders",
                };
                return;
            }
            if (result.kind == .page) {
                repos.decodeOrders(model, result.bytes);
                announceNewOrder(model, fx);
            }
            // The order we were moving is not on the board any more. It
            // was deleted, or the database was reset under us, and the
            // operator is told so instead of watching a ticket vanish.
            if (model.advance_order_id != 0) {
                if (findOrder(model, model.advance_order_id) == null) {
                    model.error_text = "That order is no longer on the board";
                }
                model.advance_order_id = 0;
            }
        },

        .order_lines_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeOrderLines(model, result.bytes);
            keepActiveOrder(model);
        },

        .config_loaded => |result| {
            if (result.outcome != .ok) {
                model.error_text = switch (result.outcome) {
                    .busy => "The database is busy - try again",
                    .corrupt => "The database is damaged",
                    else => "Could not read the installation settings",
                };
                return;
            }
            switch (result.kind) {
                .page => {
                    var reader = page.Reader.init(result.bytes);
                    var values: [page.max_columns]page.Value = undefined;
                    if (!reader.readHeader()) return;
                    var has_salt = reader.nextRow(&values);
                    if (has_salt and reader.textOf(&values, "value").len == 0) has_salt = false;
                    if (!has_salt) {
                        // The database has NO salt: this is a fresh
                        // installation, and the salt in the model is
                        // the one it will use. The setup writes it with
                        // the operator's hash.
                        //
                        // If we just wrote a salt and the read does not
                        // find one, the write did not land. Retrying here
                        // would loop; block sign-in and say so.
                        if (model.salt_state == .verifying) {
                            model.salt_state = .unknown;
                            model.error_text = "The installation settings did not save";
                            return;
                        }
                        model.salt_state = .installing;
                        return;
                    }
                    const salt = reader.textOf(&values, "value");
                    const copied = model.pin_salt_buf[0..];
                    const length = @min(salt.len, copied.len);
                    @memcpy(copied[0..length], salt[0..length]);
                    model.pin_salt_len = length;
                    // The database has the salt now: it is the salt a
                    // sign-in has to use.
                    model.salt_state = .confirmed;
                },
                .done => {
                    // The settings query finished. If the database had
                    // no salt, this is a fresh installation and the
                    // provisional salt the app made at boot is the one
                    // that counts - so store it.
                    if (model.salt_state == .installing) createSalt(model, fx);
                },
                .exec => {},
            }
        },

        .config_saved => |result| {
            if (result.outcome == .ok) {
                // `ON CONFLICT DO NOTHING` reports success even when a
                // second instance stored a different salt first. The
                // write alone is not proof: read the salt back, and let
                // `config_loaded` confirm the one the database holds.
                model.salt_state = .verifying;
                repos.loadConfig(fx);
                return;
            }
            // The salt did not land. The model keeps the provisional
            // salt, and a sign-in stays refused until the write works -
            // a sign-in against a salt that is not stored can never be
            // verified, and the operator would be locked out with no
            // way to tell why.
            model.error_text = switch (result.outcome) {
                .busy => "The database is busy - try again",
                .constraint => "The installation settings could not be saved",
                else => "Could not save the installation settings",
            };
        },

        .company_loaded => |result| {
            if (result.outcome != .ok) return;
            if (result.kind == .page) repos.decodeCompany(model, result.bytes);
            model.db_ready = true;
            // No company row: this is a fresh installation, and the
            // app's first job is to become a restaurant.
            if (model.company_id == 0 and !model.needs_setup) {
                model.needs_setup = true;
                // A fresh install opens on the walk-through: the
                // company's record first, then the owner.
                model.stack.resetTo(.create_company);
                model.setup_currency_code.set("USD");
                model.setup_currency_symbol.set("$");
                // The walk-through is the way in: the company's record
                // first, then the owner and their PIN.
                resetNavigation(model, .create_company);
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
    model.stack.push(screen);
    model.screen_index = screen.index();
    model.nav_section = sectionIndex(screen);
}

/// End the current session and land on `gate`.
///
/// This is the ONLY place session state is torn down. Sign-out, role
/// change, a successful sign-in and the setup hand-off all come through
/// here, so "what survives a session" has one answer rather than four.
///
/// Device settings are deliberately kept: the theme, the split widths,
/// the KDS station filter, the installation salt and the device token
/// belong to the machine, not to the operator.
fn resetSession(model: *Model, gate: Screen) void {
    model.signed_in = false;
    model.employee_id = 0;
    model.employee_name = "";
    model.operator_buf.reset();
    model.pin.set("");
    model.login_error = "";

    // Nothing the last operator put in the cart or typed into a filter
    // belongs to the next one.
    model.cart_len = 0;
    model.cart_buf.reset();
    model.cart_order_type = .dine_in;
    model.cart_discount_id = 0;
    model.cart_attempt_id = 0;
    model.sale_pending = false;
    model.payment_pending = false;
    model.search.set("");
    model.selected_category = 0;

    // The waiter's table and its copy of the order lines are session
    // state too.
    model.active_table_id = 0;
    model.active_table_name = "";
    model.active_table_name_field = "";
    model.active_order_id = 0;
    model.pending_order_id = 0;
    model.active_lines = &.{};
    model.waiter_buf.reset();
    model.waiter_lines_buf.reset();

    // The last sale, the detail selection and every form belong to the
    // session that created them.
    model.selected_order_id = 0;
    model.last_order_id = 0;
    model.last_order_no_field = "";
    model.last_order_type_field = "";
    model.last_order_total_minor = 0;
    model.last_order_items_count = 0;
    model.last_order_at = 0;
    model.sale_buf.reset();
    model.payment_error = "";
    model.advance_order_id = 0;

    model.form_currency_code_buf.set("");
    model.form_currency_symbol_buf.set("");
    model.form_product_name_buf.set("");
    model.form_product_price_buf.set("");
    model.form_product_category_id = 0;
    model.form_product_food_id = 0;
    model.form_product_id = 0;
    model.form_employee_name_buf.set("");
    model.form_employee_role_id = 0;
    model.form_employee_id = 0;
    model.form_name_buf.set("");
    model.form_address_buf.set("");
    model.form_phone_buf.set("");
    model.form_tax_buf.set("");

    model.error_text = "";
    model.setup_error = "";
    model.busy = false;

    // History is a session thing. `gate` is the only entry behind the
    // first screen, so Back cannot reach the previous session.
    resetNavigation(model, gate);
}

/// Land on a screen with no history behind it.
fn resetNavigation(model: *Model, gate: Screen) void {
    model.stack.resetTo(gate);
    model.screen_index = gate.index();
    model.nav_section = sectionIndex(gate);
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

/// Count a wrong PIN, and lock the till when there have been too
/// many.
///
/// A PIN is short, and a short PIN is found by trying every one of
/// them. The till is where that trying happens, so the till is where it
/// stops: after a few wrong guesses it refuses for a while, and a
/// shoulder-surfing guesser gets one attempt rather than five.
fn noteLoginFailure(model: *Model) void {
    model.login_failures += 1;
    if (model.login_failures < model_mod.max_login_failures) return;
    model.login_failures = 0;
    model.login_locked_until = model.now_ms + model_mod.login_lockout_ms;
    model.login_error = "Too many wrong PINs - try again in a moment";
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
    // A sale that is already on its way owns the cart. A second tap
    // would write the same cart twice, and the cashier would see two
    // orders for one table.
    if (model.sale_pending) {
        model.error_text = "The sale is still being saved";
        return;
    }
    const now = fx.wallMs();
    // The sale is an attempt, and the attempt keeps its identity until
    // it lands. The order id is the wall clock, but a clock is not a
    // sequence: two sales in the same millisecond would want the same
    // id, and the second one would land on the first. The floor keeps
    // the ids unique without a round trip.
    //
    // A retry is the SAME sale, so a retry keeps the id and the request
    // key the first attempt had. The database is what decides that two
    // writes are the same sale.
    if (model.cart_attempt_id == 0) {
        model.cart_attempt_id = nextOrderId(model, now);
    }
    const order_id = model.cart_attempt_id;

    // The tax, worked out line by line from each product's own slab,
    // and on what is left of each line after the discount. It is
    // worked out before the order is built, because the order carries
    // it.
    var tax_minor: i64 = 0;
    var discount_minor: i64 = 0;
    for (model.cart[0..model.cart_len], 0..) |line, index| {
        const share = model.cart_discount_share(index);
        discount_minor += share;
        const taxable = line.price_minor * line.qty - share;
        tax_minor += model.tax_on(taxable, model.product_tax_bps(line.product_id));
    }

    var order = domain.Order{
        .id = order_id,
        // The order number is a sequence, and the database assigns it:
        // the number on the ticket is the number that was stored.
        .order_no = "",
        .order_type = model.cart_order_type,
        .status = .pending,
        .status_label = domain.OrderStatus.pending.label(),
        .type_label = model.cart_order_type.label(),
        .dining_table_id = 0,
        .customer_id = 0,
        .employee_id = model.employee_id,
        .subtotal_minor = model.cart_total_minor(),
        .tax_minor = tax_minor,
        .discount_minor = discount_minor,
        // The total is what the customer pays. An exclusive price does
        // not carry its tax, so the tax is added; an inclusive one
        // does, so the tax is a memo and the price is the total.
        .total_minor = model.cart_total_minor() + (if (model.tax_inclusive) 0 else tax_minor) - discount_minor,
        .placed_at = now,
        .notes = "",
    };

    var lines: [model_mod.max_cart_lines]domain.OrderLine = undefined;
    var count: usize = 0;
    for (model.cart[0..model.cart_len]) |line| {
        lines[count] = .{
            .id = order_id + @as(i64, @intCast(count)),
            .order_id = order_id,
            .product_id = line.product_id,
            // The line carries the station that cooks it, so the kitchen
            // board can filter by station without a join.
            .station_id = model.station_of_product(line.product_id),
            .product_name = line.name,
            .qty = line.qty,
            .unit_price_minor = line.price_minor,
            // The rate is a snapshot: a slab that changes tomorrow must
            // not rewrite the bill of yesterday.
            .tax_bps = model.product_tax_bps(line.product_id),
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
    model.sale_pending = true;
    // The request key: this device's token and the attempt's id. It is
    // what makes a retry the same sale rather than a second one.
    var key_buffer: [64]u8 = undefined;
    const request_key = makeRequestKey(model, order_id, &key_buffer) orelse {
        model.busy = false;
        model.sale_pending = false;
        model.error_text = "Could not make the request key - try again";
        return;
    };
    repos.saveOrder(fx, order, lines[0..count], request_key);
}

/// The request key: this device's token, a dash, and the attempt's id.
///
/// It is the name of one sale attempt, and it is what the database
/// compares when a write comes in: a key it has already seen is a
/// retry, and the order that is already there stays.
///
/// The token is the device's namespace. A model without one still makes
/// a key - the attempt's id is in it, and the attempt's id is unique
/// within the device - so a sale is never blocked by a missing token.
fn makeRequestKey(model: *Model, attempt_id: i64, buffer: *[64]u8) ?[]const u8 {
    const token = model.device_token_buf[0..model.device_token_len];
    const written = if (token.len == 0)
        std.fmt.bufPrint(buffer, "{d}", .{attempt_id}) catch return null
    else
        std.fmt.bufPrint(buffer, "{s}-{d}", .{ token, attempt_id }) catch return null;
    return written[0..written.len];
}

/// The next order id for this device.
///
/// The order id is the wall clock, but a clock is not a sequence: two
/// sales in the same millisecond would want the same id, and the
/// second one would land on the first - two tickets, one row, and a
/// cashier's ticket with another cashier's lines. The floor keeps the
/// ids unique without a round trip.
fn nextOrderId(model: *Model, now: i64) i64 {
    const id = @max(now, model.last_issued_order_id + 1);
    model.last_issued_order_id = id;
    return id;
}
