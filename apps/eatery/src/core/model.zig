//! The model: the single source of truth for what the app shows.
//!
//! Three house rules hold here, and they are the reason this file is
//! worth reading before any other:
//!
//!   1. **Everything the view can see is a field or a method on this
//!      struct.** A file-scope function next to the struct is invisible
//!      to the markup - the binding resolver only sees declarations
//!      INSIDE the struct body.
//!   2. **Derived values are methods, never stored fields.** Counts,
//!      sums, filtered views and formatted strings are computed on
//!      rebuild. A field that could be derived is a bug waiting to
//!      drift out of sync with its inputs.
//!   3. **Anything the view must NOT see is listed in `view_unbound`.**
//!      That declaration is the lint that keeps a private field from
//!      becoming an accidental public API.
//!
//! Storage note: the model owns its rows in fixed-capacity bump buffers
//! (see `core/bump.zig`). It has to be default-constructible - the
//! runtime builds it as `.{}` - so it cannot own a heap allocator, and
//! it must not borrow memory from the effects channel, whose payloads
//! are drain scratch that dies with the update.

const std = @import("std");
const native_sdk = @import("native_sdk");

const nav = @import("navigation.zig");
const rbac = @import("rbac.zig");
const domain = @import("../domain/models.zig");
const bump = @import("bump.zig");
const auth = @import("../data/auth.zig");

const canvas = native_sdk.canvas;

pub const Role = nav.Role;
pub const Screen = nav.Screen;
pub const Stack = nav.Stack;

// Dataset buffer sizes. A restaurant menu is small; these bounds are
// deliberately generous and deliberately finite.
pub const products_buffer = 96 * 1024;
pub const tables_buffer = 24 * 1024;
pub const employees_buffer = 16 * 1024;
pub const orders_buffer = 48 * 1024;
pub const customers_buffer = 32 * 1024;
pub const categories_buffer = 16 * 1024;
pub const order_lines_buffer = 48 * 1024;
pub const company_buffer = 1024;
/// The most lines one cart may carry.
pub const max_cart_lines = 50;

/// How many wrong PINs the till takes before it stops taking them.
pub const max_login_failures = 5;

/// How long the till stops taking PINs for, in milliseconds.
pub const login_lockout_ms = 60_000;

/// The decimals of a currency code, for the currencies a restaurant is
/// likely to trade in.
///
/// The company's own exponent is the authority - this is how a code
/// becomes one. A code nobody has heard of is assumed to have two
/// decimals, which is the safe guess: a restaurant that meant three
/// would set it.
pub fn decimalsForCurrency(code: []const u8) i64 {
    const known = [_]struct { code: []const u8, decimals: i64 }{
        .{ .code = "USD", .decimals = 2 },
        .{ .code = "EUR", .decimals = 2 },
        .{ .code = "GBP", .decimals = 2 },
        .{ .code = "INR", .decimals = 2 },
        .{ .code = "AED", .decimals = 2 },
        .{ .code = "SAR", .decimals = 2 },
        .{ .code = "QAR", .decimals = 2 },
        .{ .code = "ZAR", .decimals = 2 },
        .{ .code = "JPY", .decimals = 0 },
        .{ .code = "KRW", .decimals = 0 },
        .{ .code = "VND", .decimals = 0 },
        .{ .code = "KWD", .decimals = 3 },
        .{ .code = "BHD", .decimals = 3 },
        .{ .code = "OMR", .decimals = 3 },
        .{ .code = "JOD", .decimals = 3 },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry.decimals;
    }
    return 2;
}

/// Ten to the power of a small exponent: the divisor a currency's
/// decimals mean.
fn tenTo(exponent: i64) i64 {
    if (exponent <= 0) return 1;
    var value: i64 = 1;
    var index: i64 = 0;
    while (index < exponent) : (index += 1) value *= 10;
    return value;
}

/// Where the installation salt stands.
///
/// The salt is the one piece of state a PIN hash cannot be checked
/// without, and there is exactly one right answer to "which salt?" - the
/// one in the database. These four states say how sure the app is about
/// that, because the difference between "the database has no salt" and
/// "the database has not answered yet" is the difference between
/// installing a salt and guessing one.
pub const SaltState = enum {
    /// The database has not answered yet. The salt in the model is a
    /// guess: nothing may be hashed with it.
    unknown,
    /// The database has no salt. The salt in the model is the one this
    /// installation will use, and it is written with the operator.
    installing,
    /// The write came back, but the database has not been read again.
    /// A second instance may have stored a different salt first, so the
    /// model's salt is not confirmed yet.
    verifying,
    /// The database holds this salt. A sign-in may hash with it.
    confirmed,
};

/// The tax on a price, in minor units.
///
/// `rate_bps` is in basis points, so 500 is five percent. An inclusive
/// price already carries the tax - 100.00 at eighteen percent holds
/// 84.75 of price and 15.25 of tax - so the tax is what is LEFT once
/// the net is taken out. An exclusive price does not, so the tax is
/// added on top.
///
/// The rounding is half up in both cases.
fn taxOn(price_minor: i64, rate_bps: i64, inclusive: bool) i64 {
    if (price_minor <= 0 or rate_bps <= 0) return 0;
    if (inclusive) {
        const divisor = 10000 + rate_bps;
        return @divTrunc(price_minor * rate_bps + @divTrunc(divisor, 2), divisor);
    }
    return @divTrunc(price_minor * rate_bps + 5000, 10000);
}

pub const Model = struct {
    /// Fields the view never binds directly. Keep this list honest:
    /// it is the boundary between "the model" and the interface.
    pub const view_unbound = .{
        "stack",
        "employee_id",
        "db_ready",
        "busy",
        "company_id",
        "theme_dark",
        "salt_state",
        "last_issued_order_id",
        "advance_order_id",
        "login_hash",
        "login_hash_len",
        "login_legacy_hash",
    };

    // ------------------------------------------------------------ session

    /// Which operating mode this device runs in.
    role: Role = .admin,
    /// False until a role is chosen at the role picker.
    role_chosen: bool = false,
    /// True once a sign-in succeeded (kiosk roles sign in by device).
    signed_in: bool = false,
    /// The signed-in employee. The PIN hash never lives here.
    employee_id: i64 = 0,
    employee_name: []const u8 = "",

    // --------------------------------------------------------- navigation

    /// The screen being shown, as the index into `core/navigation.zig`'s
    /// `Screen`. The markup compares this against fixed positions, so
    /// the enum order is a contract: append, never reorder.
    screen_index: usize = 0,
    /// The nav rail's own index, so the rail can mark the current
    /// section.
    nav_section: usize = 0,
    /// The history behind the current screen.
    stack: Stack = .{},
    /// The width of the nav rail, as a fraction of the window.
    rail_split: f32 = 0.18,
    /// The width of the menu pane in the POS, as a fraction.
    menu_split: f32 = 0.62,
    /// The wall clock, kept fresh by a timer so the kitchen board can
    /// say how long a ticket has been waiting.
    now_ms: i64 = 0,

    // ------------------------------------------------------------ company

    company_id: i64 = 0,
    /// The company name, owned by `company_buf`.
    company_name_field: []const u8 = "",
    company_address_field: []const u8 = "",
    company_phone_field: []const u8 = "",
    company_tax_field: []const u8 = "",
    currency_code: []const u8 = "USD",
    currency_symbol: []const u8 = "$",
    /// True when the menu's prices already include tax.
    tax_inclusive: bool = false,
    /// How many decimals this company's currency has. The yen has none,
    /// the dinar has three, and most have two.
    currency_decimals: i64 = 2,

    // ----------------------------------------------------------- datasets

    /// Storage for the rows the view renders.
    products_buf: bump.Bump(products_buffer) = .{},
    tables_buf: bump.Bump(tables_buffer) = .{},
    employees_buf: bump.Bump(employees_buffer) = .{},
    orders_buf: bump.Bump(orders_buffer) = .{},
    customers_buf: bump.Bump(customers_buffer) = .{},
    categories_buf: bump.Bump(categories_buffer) = .{},
    order_lines_buf: bump.Bump(order_lines_buffer) = .{},
    /// Storage for the order just placed.
    sale_buf: bump.Bump(1024) = .{},
    /// Storage for the table the waiter is serving.
    waiter_buf: bump.Bump(1024) = .{},
    /// Storage for the kitchen stations.
    stations_buf: bump.Bump(4096) = .{},
    /// Storage for the product-to-station mapping.
    product_stations_buf: bump.Bump(4096) = .{},
    /// Storage for the lines of the order the waiter is serving. The
    /// names are COPIED: the shared order-line buffer is reset every
    /// time the lines are read again.
    waiter_lines_buf: bump.Bump(8192) = .{},
    /// Storage for the company row's text. The page bytes are drain
    /// scratch: a name read from the database has to be COPIED before
    /// the model keeps it.
    company_buf: bump.Bump(company_buffer) = .{},

    products: []const domain.Product = &.{},
    tables: []const domain.DiningTable = &.{},
    employees: []const domain.Employee = &.{},
    orders: []const domain.Order = &.{},
    customers: []const domain.Customer = &.{},
    categories: []const domain.ProductCategory = &.{},
    order_lines: []const domain.OrderLine = &.{},

    /// The category filter in the POS. 0 means "all".
    selected_category: i64 = 0,
    /// The search text in the POS.
    search: canvas.TextBuffer(64) = .{},

    // -------------------------------------------------------- the forms

    /// The forms the settings and the catalogue edit.
    form_currency_code_buf: canvas.TextBuffer(8) = .{},
    form_currency_symbol_buf: canvas.TextBuffer(8) = .{},
    form_reset_pin_buf: canvas.TextBuffer(8) = .{},
    form_reset_pin2_buf: canvas.TextBuffer(8) = .{},
    form_reset_employee_id: i64 = 0,
    form_reset_employee_name: []const u8 = "",
    form_category_name_buf: canvas.TextBuffer(64) = .{},
    form_category_id: i64 = 0,
    form_discount_name_buf: canvas.TextBuffer(64) = .{},
    form_discount_percent_buf: canvas.TextBuffer(16) = .{},
    form_discount_amount_buf: canvas.TextBuffer(16) = .{},
    form_discount_id: i64 = 0,
    form_tax_slab_name_buf: canvas.TextBuffer(64) = .{},
    form_tax_slab_rate_buf: canvas.TextBuffer(16) = .{},
    form_tax_slab_inclusive: bool = false,
    form_tax_slab_id: i64 = 0,
    form_product_name_buf: canvas.TextBuffer(64) = .{},
    form_product_price_buf: canvas.TextBuffer(16) = .{},
    form_product_category_id: i64 = 0,
    form_product_food_id: i64 = 0,
    /// The product being edited; zero means a new one.
    form_product_id: i64 = 0,
    form_employee_name_buf: canvas.TextBuffer(64) = .{},
    form_employee_role_id: i64 = 0,
    /// The employee being edited; zero means a new one.
    form_employee_id: i64 = 0,

    // ------------------------------------------------------ the order

    /// The order the order-detail screen is showing.
    selected_order_id: i64 = 0,

    // ------------------------------------------------- the settings data

    printers_list: []const domain.Printer = &.{},
    tax_slabs_list: []const domain.TaxSlab = &.{},
    modifier_groups_list: []const domain.ModifierGroup = &.{},
    modifiers_list: []const domain.Modifier = &.{},
    discounts_list: []const domain.Discount = &.{},
    reservations_list: []const domain.Reservation = &.{},
    suppliers_list: []const domain.Supplier = &.{},
    payments_list: []const domain.Payment = &.{},
    report_modes_list: []const domain.ReportMode = &.{},
    stock_items_list: []const domain.StockItem = &.{},
    table_counts_list: []const domain.TableCount = &.{},
    devices_list: []const domain.Device = &.{},
    sync_state_list: []const domain.SyncState = &.{},
    purchase_orders_list: []const domain.PurchaseOrder = &.{},

    /// Storage for the settings rows the screens show.
    printers_buf: bump.Bump(8192) = .{},
    tax_slabs_buf: bump.Bump(4096) = .{},
    modifier_groups_buf: bump.Bump(4096) = .{},
    modifiers_buf: bump.Bump(4096) = .{},
    discounts_buf: bump.Bump(4096) = .{},
    reservations_buf: bump.Bump(8192) = .{},
    suppliers_buf: bump.Bump(8192) = .{},
    payments_buf: bump.Bump(16384) = .{},
    report_modes_buf: bump.Bump(2048) = .{},
    stock_buf: bump.Bump(8192) = .{},
    table_counts_buf: bump.Bump(4096) = .{},
    devices_buf: bump.Bump(4096) = .{},
    sync_state_buf: bump.Bump(4096) = .{},
    purchase_orders_buf: bump.Bump(8192) = .{},

    // ------------------------------------------------- the company form

    /// The company's editable details, held as buffers so the form can
    /// be typed into before it is saved.
    form_name_buf: canvas.TextBuffer(64) = .{},
    form_address_buf: canvas.TextBuffer(128) = .{},
    form_phone_buf: canvas.TextBuffer(32) = .{},
    form_tax_buf: canvas.TextBuffer(32) = .{},

    // ------------------------------------------------------ the kitchen

    /// Which station cooks which product.
    product_stations: []const domain.ProductStation = &.{},
    /// The kitchen stations, and the one the board is filtered by (0
    /// is "every station").
    stations_list: []const domain.KdsStation = &.{},
    station_filter_field: i64 = 0,
    /// The last order the board has seen. A newer one is a new sale,
    /// and the kitchen hears about it.
    last_seen_order_id: i64 = 0,

    // --------------------------------------------------------- the waiter

    /// The table the waiter is serving, and the open order on it.
    active_table_id: i64 = 0,
    active_table_name: []const u8 = "",
    active_order_id: i64 = 0,
    /// The order being opened for a table, before the database
    /// confirms it.
    pending_order_id: i64 = 0,
    /// The lines of the open order.
    active_lines: []const domain.OrderLine = &.{},

    // ------------------------------------------------------- the sale

    /// The dish the owner is assigning a station to.
    selected_dish_id: i64 = 0,
    /// The thing whose stock is being counted.
    form_stock_product_id: i64 = 0,
    /// Its name, for the form's heading.
    form_stock_name_field: []const u8 = "",
    /// The count the owner is typing.
    form_stock_count_buf: canvas.TextBuffer(16) = .{},
    /// Why the count changed.
    form_stock_reason_buf: canvas.TextBuffer(64) = .{},
    /// The customer being edited, zero for a new one.
    form_customer_id: i64 = 0,
    /// The customer's name.
    form_customer_name_buf: canvas.TextBuffer(64) = .{},
    /// The customer's phone.
    form_customer_phone_buf: canvas.TextBuffer(32) = .{},
    /// The customer's email.
    form_customer_email_buf: canvas.TextBuffer(64) = .{},
    /// The customer's address.
    form_customer_address_buf: canvas.TextBuffer(128) = .{},
    /// The group being edited, zero for a new one.
    form_modifier_group_id: i64 = 0,
    /// The group's name.
    form_modifier_group_name_buf: canvas.TextBuffer(64) = .{},
    /// How many choices the group allows.
    form_modifier_max_buf: canvas.TextBuffer(8) = .{},
    /// Whether the order cannot be prepared without a choice.
    form_modifier_required_field: bool = false,
    /// The day's order count, from the report query.
    report_orders_field: i64 = 0,
    /// The day's gross, in minor units.
    report_gross_field: i64 = 0,
    /// The day's tax, in minor units.
    report_tax_field: i64 = 0,
    /// The day's discounts, in minor units.
    report_discount_field: i64 = 0,
    /// The day's net, in minor units.
    report_net_field: i64 = 0,
    /// True while a payment is on its way to the database. The view
    /// binds it: the button that takes the money is disabled while it
    /// holds, so a second tap cannot take the money twice.
    payment_pending: bool = false,
    /// The order whose status is on its way to the database, zero when
    /// there is none. The board's button is disabled while it holds, so
    /// a second tap cannot move the order twice.
    advance_order_id: i64 = 0,
    /// The order that was just placed: the confirmation screen shows
    /// it and the payment is taken against it.
    active_table_name_field: []const u8 = "",
    last_order_id: i64 = 0,
    last_order_no_field: []const u8 = "",
    last_order_type_field: []const u8 = "",
    last_order_total_minor: i64 = 0,
    last_order_items_count: i64 = 0,
    last_order_at: i64 = 0,
    /// True while a sale is on its way to the database. The view binds
    /// it: the button that places the order is disabled while it holds,
    /// so a second tap cannot submit the same cart twice.
    sale_pending: bool = false,
    /// The highest order id this process has issued. The order id is
    /// the wall clock, but a clock is not a sequence: two sales in the
    /// same millisecond would want the same id, and the second one
    /// would merge into the first. The floor keeps the ids unique
    /// without a round trip.
    last_issued_order_id: i64 = 0,
    /// The payment mode the cashier picked.
    payment_mode_field: i64 = 0,
    /// Why the payment failed, or empty.
    payment_error: []const u8 = "",

    // ------------------------------------------------------- first run

    /// True when the database has no company yet: the app opens on the
    /// setup screen instead of the role picker.
    needs_setup: bool = false,
    /// The setup form's fields.
    setup_company_name: canvas.TextBuffer(64) = .{},
    setup_admin_name: canvas.TextBuffer(64) = .{},
    setup_pin: canvas.TextBuffer(8) = .{},
    setup_pin2: canvas.TextBuffer(8) = .{},
    /// The company's record, the parts the quick setup does not ask
    /// for: where the restaurant is, how to reach it, and its tax
    /// number.
    wizard_address_buf: canvas.TextBuffer(128) = .{},
    wizard_phone_buf: canvas.TextBuffer(32) = .{},
    wizard_tax_buf: canvas.TextBuffer(32) = .{},
    setup_currency_code: canvas.TextBuffer(8) = .{},
    setup_currency_symbol: canvas.TextBuffer(8) = .{},
    /// Why the setup failed, or empty.
    setup_error: []const u8 = "",

    // ---------------------------------------------------------- sign-in

    /// The PIN being typed. The view binds a derived method, never the
    /// buffer itself.
    pin: canvas.TextBuffer(8) = .{},
    /// The installation salt, hex. Empty until the database answers.
    pin_salt_buf: [64]u8 = undefined,
    pin_salt_len: usize = 0,
    /// Where the installation salt stands.
    salt_state: SaltState = .unknown,
    /// This installation's token, hex. It is a name, not a secret: it
    /// gives the request keys this device makes a namespace of their
    /// own, so two devices cannot mistake each other's sale for a
    /// retry of their own.
    device_token_buf: [auth.token_len]u8 = undefined,
    device_token_len: usize = 0,
    /// The order id of the sale the cart is waiting to become. Zero
    /// until the cart is submitted; after that it belongs to the sale
    /// until the sale lands, so a retry is the same sale and not a
    /// second one.
    cart_attempt_id: i64 = 0,
    /// The hash of the PIN being checked. Lives in the model so the
    /// query parameter has a stable home.
    login_hash: [auth.hash_length]u8 = undefined,
    /// The length of the hash in `login_hash`. The buffer is larger
    /// than the string, so the length is what says where it ends.
    login_hash_len: usize = 0,
    /// The OLD hash of the same PIN - a SHA-256 digest. It is what the
    /// sign-in looks up as well, so a restaurant whose employees signed
    /// in before bcrypt can still sign in; the next sign-in rewrites
    /// the row in the new form.
    login_legacy_hash: [auth.legacy_len]u8 = undefined,
    /// Storage for the signed-in operator's name.
    operator_buf: bump.Bump(1024) = .{},
    /// Why the last sign-in failed, or empty.
    login_error: []const u8 = "",
    /// How many wrong PINs this session has seen.
    login_failures: i64 = 0,
    /// The moment the till stops accepting PINs, in epoch
    /// milliseconds. Zero when it is not locked.
    login_locked_until: i64 = 0,

    // -------------------------------------------------------------- cart

    /// Storage for the cart lines' names.
    cart_buf: bump.Bump(8 * 1024) = .{},
    /// The open cart. Session state: it dies with the order.
    cart: [max_cart_lines]domain.CartLine = undefined,
    cart_len: usize = 0,
    /// The order type of the open cart.
    cart_order_type: domain.OrderType = .dine_in,
    /// The discount the cashier has applied to the cart, zero for none.
    /// The view binds it: the discount that is chosen is the one that
    /// is highlighted.
    cart_discount_id: i64 = 0,

    // ------------------------------------------------------- app runtime

    /// True once the database has answered its first query.
    db_ready: bool = false,
    /// True while a write is in flight.
    busy: bool = false,
    /// The last error worth showing the operator, or empty.
    error_text: []const u8 = "",
    /// Dark palette instead of the house light one.
    theme_dark: bool = false,

    // ---------------------------------------------------- derived values
    //
    // Everything below is a METHOD: computed on rebuild, never stored.

    /// The devices that have been in this restaurant.
    pub fn devices(model: *const Model) []const domain.Device {
        return model.devices_list;
    }

    /// How many pieces of sync state there are.
    pub fn sync_state_count(model: *const Model) usize {
        return model.sync_state_list.len;
    }

    /// How many devices have been in this restaurant.
    pub fn device_count(model: *const Model) usize {
        return model.devices_list.len;
    }

    /// What the sync sidecar has left behind.
    pub fn sync_state(model: *const Model) []const domain.SyncState {
        return model.sync_state_list;
    }

    /// The tables in the database, and how many rows each holds.
    pub fn table_counts(model: *const Model) []const domain.TableCount {
        return model.table_counts_list;
    }

    /// How many tables the database has.
    pub fn db_table_count(model: *const Model) usize {
        return model.table_counts_list.len;
    }

    /// The screen the app is showing.
    pub fn screen(model: *const Model) Screen {
        return std.enums.fromInt(Screen, model.screen_index) orelse .role_picker;
    }

    /// The title of the current screen.
    pub fn screen_title(model: *const Model) []const u8 {
        return model.screen().title();
    }

    /// The rail rows for the current role.
    pub fn nav_sections(model: *const Model) []const nav.NavItem {
        return rbac.nav_sections(model.role);
    }

    /// The role cards the picker shows.
    pub fn roles(_: *const Model) []const nav.RoleCard {
        return nav.roleCards();
    }

    /// True when there is an error worth showing the operator.
    pub fn has_error(model: *const Model) bool {
        return model.error_text.len > 0;
    }

    /// The error the operator needs to see.
    pub fn error_message(model: *const Model) []const u8 {
        return model.error_text;
    }

    /// The table the waiter is serving.
    pub fn active_table(model: *const Model) []const u8 {
        return model.active_table_name_field;
    }

    /// The open order the waiter is serving, or zero.
    pub fn active_order(model: *const Model) i64 {
        return model.active_order_id;
    }

    /// How many items the open order carries.
    pub fn active_order_item_count(model: *const Model) i64 {
        var count: i64 = 0;
        for (model.active_lines) |line| count += line.qty;
        return count;
    }

    /// What the customer display shows for each order in progress: the
    /// table the order is on (a customer cares about the table, not the
    /// order number), the kind of sale, and where it has got to.
    pub fn display_cards(model: *const Model, arena: std.mem.Allocator) []const DisplayCard {
        var count: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready, .served => count += 1,
                .completed, .voided => {},
            }
        }
        const out = arena.alloc(DisplayCard, count) catch return &.{};
        var index: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready, .served => {},
                .completed, .voided => continue,
            }
            out[index] = .{
                .label = displayLabel(model, order.dining_table_id, order.order_no),
                .status_label = order.status_label,
                .type_label = order.type_label,
                .order_no = order.order_no,
            };
            index += 1;
        }
        return out[0..index];
    }

    /// The kitchen stations, as the board's filter shows them.
    pub fn stations(model: *const Model) []const domain.KdsStation {
        return model.stations_list;
    }

    /// The station that cooks a product, or zero when no station does.
    pub fn station_of_product(model: *const Model, product_id: i64) i64 {
        for (model.product_stations) |mapping| {
            if (mapping.product_id == product_id) return mapping.station_id;
        }
        return 0;
    }

    /// The station the board is filtered by.
    pub fn station_filter(model: *const Model) i64 {
        return model.station_filter_field;
    }

    /// The tax on a line, in minor units.
    ///
    /// The RATE comes from the product's own tax slab: a restaurant
    /// that taxes its food at one rate and its drinks at another has a
    /// slab per product, and the rate is part of the price the customer
    /// was quoted.
    ///
    /// The MODE - whether the price already carries the tax - is the
    /// business's, not the slab's: a restaurant is either inclusive or
    /// it is not, and its menu says so.
    ///
    /// The rounding is half up. A fraction of a minor unit is not a
    /// fraction of a rupee, and the restaurant is not short-changed by
    /// one.
    pub fn line_tax(model: *const Model, product_id: i64, price_minor: i64) i64 {
        const product = model.find_product(product_id) orelse return 0;
        const slab = model.tax_slab(product.tax_slab_id) orelse return 0;
        return taxOn(price_minor, slab.rate_bps, model.tax_inclusive);
    }

    /// The rate a product is taxed at, in basis points. Zero for a
    /// product with no slab.
    pub fn product_tax_bps(model: *const Model, product_id: i64) i64 {
        const product = model.find_product(product_id) orelse return 0;
        const slab = model.tax_slab(product.tax_slab_id) orelse return 0;
        return slab.rate_bps;
    }

    /// The product with this id, or null.
    pub fn find_product(model: *const Model, product_id: i64) ?domain.Product {
        for (model.products) |product| {
            if (product.id == product_id) return product;
        }
        return null;
    }

    /// The tax slab with this id, or null.
    pub fn tax_slab(model: *const Model, slab_id: i64) ?domain.TaxSlab {
        if (slab_id == 0) return null;
        for (model.tax_slabs_list) |slab| {
            if (slab.id == slab_id) return slab;
        }
        return null;
    }

    /// The number to divide a minor-unit amount by to get the units a
    /// person reads: a hundred for most currencies, one for the yen, a
    /// thousand for the dinar.
    pub fn currency_divisor(model: *const Model) i64 {
        return tenTo(model.currency_decimals);
    }

    /// How many decimals this company's currency has.
    pub fn currency_decimal_count(model: *const Model) i64 {
        return model.currency_decimals;
    }

    /// The tax on an amount, at a rate, in the business's mode.
    pub fn tax_on(model: *const Model, amount_minor: i64, rate_bps: i64) i64 {
        return taxOn(amount_minor, rate_bps, model.tax_inclusive);
    }

    /// The discount on the cart, in minor units.
    ///
    /// A percentage discount is a share of the cart; a fixed amount is
    /// itself. The discount is never more than the cart is worth.
    pub fn cart_discount_total(model: *const Model) i64 {
        if (model.cart_discount_id == 0) return 0;
        const subtotal = model.cart_total_minor();
        if (subtotal <= 0) return 0;
        for (model.discounts_list) |discount| {
            if (discount.id != model.cart_discount_id) continue;
            if (!discount.active) return 0;
            if (discount.percent_bps > 0) {
                return @min(@divTrunc(subtotal * discount.percent_bps, 10000), subtotal);
            }
            return @min(discount.amount_minor, subtotal);
        }
        return 0;
    }

    /// The discount that lands on the cart line at `index`.
    ///
    /// The discount is spread across the lines in proportion to what
    /// they are worth, and the LAST line takes the remainder, so the
    /// parts add up to the discount exactly and the arithmetic stays
    /// whole numbers. The tax is worked out on what is left of each
    /// line, which is what the customer actually pays for it.
    pub fn cart_discount_share(model: *const Model, index: usize) i64 {
        const total = model.cart_discount_total();
        if (total <= 0) return 0;
        if (index >= model.cart_len) return 0;
        const subtotal = model.cart_total_minor();
        if (subtotal <= 0) return 0;
        var allocated: i64 = 0;
        for (model.cart[0..index]) |line| {
            allocated += @divTrunc(total * line.price_minor * line.qty, subtotal);
        }
        const remaining = total - allocated;
        if (remaining <= 0) return 0;
        if (index + 1 == model.cart_len) return remaining;
        const line = model.cart[index];
        return @min(@divTrunc(total * line.price_minor * line.qty, subtotal), remaining);
    }

    /// The tax on the cart, in minor units.
    pub fn cart_tax_minor(model: *const Model) i64 {
        var tax: i64 = 0;
        for (model.cart[0..model.cart_len], 0..) |line, index| {
            const taxable = line.price_minor * line.qty - model.cart_discount_share(index);
            tax += model.tax_on(taxable, model.product_tax_bps(line.product_id));
        }
        return tax;
    }

    /// What the customer pays for the cart.
    ///
    /// An exclusive price does not carry its tax, so the tax is added;
    /// an inclusive one does, so the tax is a memo and the price is
    /// the total. The discount comes off either way.
    pub fn cart_amount_due(model: *const Model) i64 {
        const tax = model.cart_tax_minor();
        const on_top = if (model.tax_inclusive) 0 else tax;
        return model.cart_total_minor() + on_top - model.cart_discount_total();
    }

    /// The lines of the open order the waiter is serving.
    pub fn active_order_lines(model: *const Model) []const domain.OrderLine {
        return model.active_lines;
    }

    /// The total of the open order the waiter is serving.
    pub fn active_order_total(model: *const Model) i64 {
        var total: i64 = 0;
        for (model.active_lines) |line| {
            total += line.unit_price_minor * line.qty;
        }
        return total;
    }

    /// How many people are on the team.
    pub fn employee_count(model: *const Model) usize {
        return model.employees.len;
    }

    /// The company form's fields, one binding each.
    pub fn form_company_name(model: *const Model) []const u8 {
        return model.form_name_buf.text();
    }

    pub fn form_company_address(model: *const Model) []const u8 {
        return model.form_address_buf.text();
    }

    pub fn form_company_phone(model: *const Model) []const u8 {
        return model.form_phone_buf.text();
    }

    pub fn form_company_tax(model: *const Model) []const u8 {
        return model.form_tax_buf.text();
    }

    /// The settings menu. This method lives INSIDE the struct on
    /// purpose: the binding resolver only sees the declarations in the
    /// struct body, and a method at file scope is invisible to the
    /// markup.
    pub fn settings_items(_: *const Model) []const SettingsItem {
        return &settings_menu;
    }

    /// The currency the restaurant trades in.
    pub fn company_currency_code(model: *const Model) []const u8 {
        return model.currency_code;
    }

    /// The currency code in the currency form.
    pub fn form_currency_code(model: *const Model) []const u8 {
        return model.form_currency_code_buf.text();
    }

    /// The currency symbol in the currency form.
    pub fn form_currency_symbol(model: *const Model) []const u8 {
        return model.form_currency_symbol_buf.text();
    }

    /// The product name in the product form.
    /// The PIN being typed for the reset.
    pub fn form_reset_pin(model: *const Model) []const u8 {
        return model.form_reset_pin_buf.text();
    }

    /// The PIN being confirmed for the reset.
    pub fn form_reset_pin2(model: *const Model) []const u8 {
        return model.form_reset_pin2_buf.text();
    }

    /// Whose PIN is being reset.
    pub fn form_reset_employee(model: *const Model) []const u8 {
        return model.form_reset_employee_name;
    }

    /// The name of the category being edited.
    pub fn form_category_name(model: *const Model) []const u8 {
        return model.form_category_name_buf.text();
    }

    /// The heading of the category form.
    pub fn category_form_title(model: *const Model) []const u8 {
        if (model.form_category_id == 0) return "New category";
        return "Edit category";
    }

    /// The name of the discount being edited.
    pub fn form_discount_name(model: *const Model) []const u8 {
        return model.form_discount_name_buf.text();
    }

    /// The percentage of the discount being edited, as typed.
    pub fn form_discount_percent(model: *const Model) []const u8 {
        return model.form_discount_percent_buf.text();
    }

    /// The amount off the bill, as typed.
    pub fn form_discount_amount(model: *const Model) []const u8 {
        return model.form_discount_amount_buf.text();
    }

    /// The heading of the discount form.
    pub fn discount_form_title(model: *const Model) []const u8 {
        if (model.form_discount_id == 0) return "New discount";
        return "Edit discount";
    }

    /// The name of the tax slab being edited.
    pub fn form_tax_slab_name(model: *const Model) []const u8 {
        return model.form_tax_slab_name_buf.text();
    }

    /// The rate of the tax slab being edited, as the owner typed it.
    pub fn form_tax_slab_rate(model: *const Model) []const u8 {
        return model.form_tax_slab_rate_buf.text();
    }

    /// True when the price already carries this tax.
    pub fn form_tax_slab_is_inclusive(model: *const Model) bool {
        return model.form_tax_slab_inclusive;
    }

    /// The heading of the tax slab form.
    pub fn tax_slab_form_title(model: *const Model) []const u8 {
        if (model.form_tax_slab_id == 0) return "New tax slab";
        return "Edit tax slab";
    }

    pub fn form_product_name(model: *const Model) []const u8 {
        return model.form_product_name_buf.text();
    }

    /// The product price in the product form, as typed.
    pub fn form_product_price(model: *const Model) []const u8 {
        return model.form_product_price_buf.text();
    }

    /// The category the product form is set to.
    pub fn form_product_category(model: *const Model) i64 {
        return model.form_product_category_id;
    }

    /// The food marking the product form is set to.
    pub fn form_product_food(model: *const Model) i64 {
        return model.form_product_food_id;
    }

    /// The title of the product form: "New product" or the name.
    pub fn product_form_title(model: *const Model) []const u8 {
        if (model.form_product_id == 0) return "New product";
        for (model.products) |product| {
            if (product.id == model.form_product_id) return product.name;
        }
        return "Product";
    }

    /// The employee name in the employee form.
    pub fn form_employee_name(model: *const Model) []const u8 {
        return model.form_employee_name_buf.text();
    }

    /// The role the employee form is set to.
    pub fn form_employee_role(model: *const Model) i64 {
        return model.form_employee_role_id;
    }

    /// The title of the employee form: "New employee" or the name.
    pub fn employee_form_title(model: *const Model) []const u8 {
        if (model.form_employee_id == 0) return "New employee";
        for (model.employees) |employee| {
            if (employee.id == model.form_employee_id) return employee.name;
        }
        return "Employee";
    }

    /// The food markings, as the product form offers them.
    pub fn food_types(_: *const Model) []const FoodTypeOption {
        return &food_type_options;
    }

    /// The roles an employee can have, as the form offers them.
    pub fn employee_roles(_: *const Model) []const RoleOption {
        return &employee_role_options;
    }

    /// How many printers there are.
    pub fn printer_count(model: *const Model) usize {
        return model.printers_list.len;
    }

    /// How many tax slabs there are.
    pub fn tax_slab_count(model: *const Model) usize {
        return model.tax_slabs_list.len;
    }

    /// How many modifier groups there are.
    pub fn modifier_group_count(model: *const Model) usize {
        return model.modifier_groups_list.len;
    }

    /// How many discounts there are.
    pub fn discount_count(model: *const Model) usize {
        return model.discounts_list.len;
    }

    /// How many categories there are.
    pub fn category_count(model: *const Model) usize {
        return model.categories.len;
    }

    /// The order the detail screen is showing, if any.
    pub fn selected_order(model: *const Model) ?domain.Order {
        for (model.orders) |order| {
            if (order.id == model.selected_order_id) return order;
        }
        return null;
    }

    /// The lines of the order the detail screen is showing.
    pub fn selected_order_lines(model: *const Model, arena: std.mem.Allocator) []const domain.OrderLine {
        var count: usize = 0;
        for (model.order_lines) |line| {
            if (line.order_id == model.selected_order_id) count += 1;
        }
        const out = arena.alloc(domain.OrderLine, count) catch return &.{};
        var index: usize = 0;
        for (model.order_lines) |line| {
            if (line.order_id != model.selected_order_id) continue;
            out[index] = line;
            index += 1;
        }
        return out[0..index];
    }

    /// The order number of the order being shown.
    pub fn selected_order_no(model: *const Model) []const u8 {
        const order = model.selected_order() orelse return "";
        return order.order_no;
    }

    /// The status of the order being shown.
    pub fn selected_order_status(model: *const Model) []const u8 {
        const order = model.selected_order() orelse return "";
        return order.status_label;
    }

    /// The kind of sale the order being shown is.
    pub fn selected_order_type(model: *const Model) []const u8 {
        const order = model.selected_order() orelse return "";
        return order.type_label;
    }

    /// When the order being shown was taken, in epoch seconds.
    pub fn selected_order_when(model: *const Model) i64 {
        const order = model.selected_order() orelse return 0;
        return @divTrunc(order.placed_at, 1000);
    }

    /// The total of the order being shown.
    pub fn selected_order_total(model: *const Model) i64 {
        const order = model.selected_order() orelse return 0;
        return order.total_minor;
    }

    /// The reservations.
    pub fn reservations(model: *const Model) []const domain.Reservation {
        return model.reservations_list;
    }

    /// How many reservations are on the book.
    pub fn reservation_count(model: *const Model) usize {
        return model.reservations_list.len;
    }

    /// The dish the owner is assigning a station to.
    pub fn selected_dish(model: *const Model) i64 {
        return model.selected_dish_id;
    }

    /// The name of the station that cooks a dish, or "No station" when
    /// no station does.
    ///
    /// The name is resolved here rather than in the markup: a row
    /// carries plain fields, and the markup cannot call a method on a
    /// loop row.
    pub fn station_name_for(model: *const Model, product_id: i64) []const u8 {
        const station_id = model.station_of_product(product_id);
        for (model.stations_list) |station| {
            if (station.id == station_id) return station.name;
        }
        return "No station";
    }

    /// The name of the station with this id.
    pub fn station_name(model: *const Model, station_id: i64) []const u8 {
        for (model.stations_list) |station| {
            if (station.id == station_id) return station.name;
        }
        return "No station";
    }

    /// The dishes on the menu, each with the station that cooks it.
    ///
    /// Allocated in the view's arena, never freed (see
    /// `visible_products` for why).
    pub fn kitchen_dishes(model: *const Model, arena: std.mem.Allocator) []const KitchenDish {
        const out = arena.alloc(KitchenDish, model.products.len) catch return &.{};
        var index: usize = 0;
        for (model.products) |product| {
            out[index] = .{
                .id = product.id,
                .name = product.name,
                .station_name = model.station_name_for(product.id),
            };
            index += 1;
        }
        return out[0..index];
    }

    /// How many dishes are on the menu.
    pub fn kitchen_dish_count(model: *const Model) usize {
        return model.products.len;
    }

    /// What the restaurant has on the shelf.
    pub fn stock_items(model: *const Model) []const domain.StockItem {
        return model.stock_items_list;
    }

    /// How many things the restaurant counts.
    pub fn stock_item_count(model: *const Model) usize {
        return model.stock_items_list.len;
    }

    /// The thing whose stock is being counted.
    pub fn form_stock_name(model: *const Model) []const u8 {
        return model.form_stock_name_field;
    }

    /// The count the shelf says now, before the owner changes it.
    pub fn form_stock_current(model: *const Model) i64 {
        for (model.stock_items_list) |item| {
            if (item.id == model.form_stock_product_id) return item.stock_qty;
        }
        return 0;
    }

    /// The count the owner is typing.
    pub fn form_stock_count(model: *const Model) []const u8 {
        return model.form_stock_count_buf.text();
    }

    /// Why the count changed.
    pub fn form_stock_reason(model: *const Model) []const u8 {
        return model.form_stock_reason_buf.text();
    }

    /// The orders taken today.
    pub fn report_order_count(model: *const Model) i64 {
        return model.report_orders_field;
    }

    /// The money the orders came to, before tax and discounts.
    pub fn report_gross_minor(model: *const Model) i64 {
        return model.report_gross_field;
    }

    /// The tax the day's orders carried.
    pub fn report_tax_minor(model: *const Model) i64 {
        return model.report_tax_field;
    }

    /// The discount the day's orders carried.
    pub fn report_discount_minor(model: *const Model) i64 {
        return model.report_discount_field;
    }

    /// What the day's orders came to, tax and discounts taken off.
    pub fn report_net_minor(model: *const Model) i64 {
        return model.report_net_field;
    }

    /// How the money came in, one row per mode.
    pub fn report_modes(model: *const Model) []const domain.ReportMode {
        return model.report_modes_list;
    }

    /// How many ways the money came in.
    pub fn report_modes_count(model: *const Model) usize {
        return model.report_modes_list.len;
    }

    /// The first millisecond of the day the report covers.
    ///
    /// The day is the UTC day. An order has no accounting date of its
    /// own yet - that is the trading-day policy, and it is not this
    /// screen's to decide - so the day here is plainly the calendar
    /// day, and it says so on the screen.
    pub fn report_day_start_ms(model: *const Model) i64 {
        if (model.now_ms <= 0) return 0;
        const day = @divFloor(model.now_ms, 86_400_000);
        return day * 86_400_000;
    }

    /// The payments the restaurant has taken.
    pub fn payments(model: *const Model) []const domain.Payment {
        return model.payments_list;
    }

    /// How many payments the restaurant has taken.
    pub fn payment_count(model: *const Model) usize {
        return model.payments_list.len;
    }

    /// The money the restaurant has taken, in minor units.
    pub fn payments_total_minor(model: *const Model) i64 {
        var total: i64 = 0;
        for (model.payments_list) |payment| total += payment.amount_minor;
        return total;
    }

    /// The suppliers.
    pub fn suppliers(model: *const Model) []const domain.Supplier {
        return model.suppliers_list;
    }

    /// How many suppliers the restaurant buys from.
    pub fn supplier_count(model: *const Model) usize {
        return model.suppliers_list.len;
    }

    /// The purchase orders.
    pub fn purchase_orders(model: *const Model) []const domain.PurchaseOrder {
        return model.purchase_orders_list;
    }

    /// How many purchase orders are open.
    pub fn purchase_order_count(model: *const Model) usize {
        return model.purchase_orders_list.len;
    }

    /// The printers the restaurant has.
    pub fn printers(model: *const Model) []const domain.Printer {
        return model.printers_list;
    }

    /// The tax slabs the menu prices against.
    pub fn tax_slabs(model: *const Model) []const domain.TaxSlab {
        return model.tax_slabs_list;
    }

    /// Whether the employee with this id is the last admin.
    ///
    /// A restaurant with no admin cannot open the back office, and
    /// the owner would have no way back in. So the last admin cannot
    /// be deactivated until someone else is one.
    pub fn is_last_admin(model: *const Model, id: i64) bool {
        var admins: usize = 0;
        var is_admin = false;
        for (model.employees) |employee| {
            if (employee.role != @intFromEnum(domain.EmployeeRole.admin)) continue;
            admins += 1;
            if (employee.id == id) is_admin = true;
        }
        return is_admin and admins <= 1;
    }

    /// The customer being edited, by name.
    pub fn form_customer_name(model: *const Model) []const u8 {
        return model.form_customer_name_buf.text();
    }

    /// The customer's phone.
    pub fn form_customer_phone(model: *const Model) []const u8 {
        return model.form_customer_phone_buf.text();
    }

    /// The customer's email.
    pub fn form_customer_email(model: *const Model) []const u8 {
        return model.form_customer_email_buf.text();
    }

    /// The customer's address.
    pub fn form_customer_address(model: *const Model) []const u8 {
        return model.form_customer_address_buf.text();
    }

    /// The choices in the group being edited.
    pub fn modifiers(model: *const Model) []const domain.Modifier {
        return model.modifiers_list;
    }

    /// How many choices the group being edited has.
    pub fn modifier_count(model: *const Model) usize {
        return model.modifiers_list.len;
    }

    /// The group being edited, by name.
    pub fn form_modifier_group_name(model: *const Model) []const u8 {
        return model.form_modifier_group_name_buf.text();
    }

    /// How many choices the group allows.
    pub fn form_modifier_max_select(model: *const Model) []const u8 {
        return model.form_modifier_max_buf.text();
    }

    /// Whether the group must be chosen.
    pub fn form_modifier_required(model: *const Model) bool {
        return model.form_modifier_required_field;
    }

    /// The modifier groups on the menu.
    pub fn modifier_groups(model: *const Model) []const domain.ModifierGroup {
        return model.modifier_groups_list;
    }

    /// The discounts the cashier can apply.
    pub fn discounts(model: *const Model) []const domain.Discount {
        return model.discounts_list;
    }

    /// The tiles on the overview.
    pub fn overview_links(_: *const Model) []const LinkItem {
        return &dashboard_links;
    }

    /// The order number of the order just placed.
    /// The number of the order that was just placed.
    ///
    /// The number is a sequence the DATABASE assigns, so it is only
    /// known once the order has been read back. The loaded order is the
    /// truth; the field is what the sale knew before that.
    pub fn last_order_no(model: *const Model) []const u8 {
        for (model.orders) |order| {
            if (order.id == model.last_order_id) return order.order_no;
        }
        return model.last_order_no_field;
    }

    /// The kind of the order just placed.
    pub fn last_order_type(model: *const Model) []const u8 {
        return model.last_order_type_field;
    }

    /// The total of the order just placed, in minor units.
    pub fn last_order_total(model: *const Model) i64 {
        return model.last_order_total_minor;
    }

    /// How many items the order just placed carries.
    pub fn last_order_items(model: *const Model) i64 {
        return model.last_order_items_count;
    }

    /// When the order just placed was taken, in epoch SECONDS - the
    /// markup's `time()` and `date()` functions take seconds.
    pub fn last_order_time(model: *const Model) i64 {
        return @divTrunc(model.last_order_at, 1000);
    }

    /// The payment mode the cashier picked.
    pub fn payment_mode(model: *const Model) i64 {
        return model.payment_mode_field;
    }

    /// Why the last payment failed, or empty.
    /// The error the operator needs to see.
    pub fn error_text_text(model: *const Model) []const u8 {
        return model.error_text;
    }

    pub fn payment_error_text(model: *const Model) []const u8 {
        return model.payment_error;
    }

    /// True when the last payment failed.
    pub fn payment_failed(model: *const Model) bool {
        return model.payment_error.len > 0;
    }

    /// The payment modes the cashier can pick.
    pub fn payment_modes(_: *const Model) []const PaymentModeOption {
        return &payment_mode_options;
    }

    /// True when the app is showing the walk-through's first step.
    ///
    /// The walk-through is a session screen: it is shown before
    /// anybody is signed in, so it is mounted beside the setup rather
    /// than in the shell's content pane.
    pub fn show_create_company(model: *const Model) bool {
        return model.screen() == .create_company;
    }

    /// True when the app is showing the walk-through's second step.
    pub fn show_wizard(model: *const Model) bool {
        return model.screen() == .wizard;
    }

    /// True when the app is showing the quick setup.
    ///
    /// The screen, not the state: the setup is one way into a fresh
    /// install, and the walk-through is the other. A fresh install
    /// needs a setup, and the screen says WHICH one - the shell draws
    /// the setup only when the setup is the screen being shown, so the
    /// walk-through and the quick setup are never both on the pane.
    pub fn show_setup(model: *const Model) bool {
        return model.screen() == .setup;
    }

    /// The company's address.
    pub fn wizard_address(model: *const Model) []const u8 {
        return model.wizard_address_buf.text();
    }

    /// The company's phone number.
    pub fn wizard_phone(model: *const Model) []const u8 {
        return model.wizard_phone_buf.text();
    }

    /// The company's tax number.
    pub fn wizard_tax_number(model: *const Model) []const u8 {
        return model.wizard_tax_buf.text();
    }

    /// The setup form's company name.
    pub fn setup_company_text(model: *const Model) []const u8 {
        return model.setup_company_name.text();
    }

    /// The setup form's operator name.
    pub fn setup_admin_text(model: *const Model) []const u8 {
        return model.setup_admin_name.text();
    }

    /// The setup form's PIN. The buffer is the edit model; the view
    /// binds the text.
    pub fn setup_pin_text(model: *const Model) []const u8 {
        return model.setup_pin.text();
    }

    /// The setup form's confirmation PIN.
    pub fn setup_pin2_text(model: *const Model) []const u8 {
        return model.setup_pin2.text();
    }

    /// The setup form's currency code.
    pub fn setup_currency_text(model: *const Model) []const u8 {
        return model.setup_currency_code.text();
    }

    /// The setup form's currency symbol.
    pub fn setup_symbol_text(model: *const Model) []const u8 {
        return model.setup_currency_symbol.text();
    }

    /// True when the last setup attempt failed.
    pub fn setup_failed(model: *const Model) bool {
        return model.setup_error.len > 0;
    }

    /// Why the setup failed.
    pub fn setup_error_text(model: *const Model) []const u8 {
        return model.setup_error;
    }

    /// Whether the setup form is complete enough to submit: a company
    /// name, an operator name, a PIN, and the same PIN twice.
    /// True when the setup form is NOT ready to be submitted.
    ///
    /// The button binds this, so the operator cannot press a button
    /// that would only be refused.
    pub fn setup_incomplete(model: *const Model) bool {
        return !model.setup_can_submit();
    }

    pub fn setup_can_submit(model: *const Model) bool {
        const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
        const admin = std.mem.trim(u8, model.setup_admin_name.text(), " ");
        const pin = model.setup_pin.text();
        const pin2 = model.setup_pin2.text();
        if (name.len == 0 or admin.len == 0) return false;
        if (!model.pin_is_acceptable(pin)) return false;
        return std.mem.eql(u8, pin, pin2);
    }

    /// True when a PIN is worth accepting.
    ///
    /// Six digits or more, and digits only. A four-digit PIN is ten
    /// thousand guesses, and a stolen database is worth ten thousand
    /// guesses: the hash can be slow, but it cannot be slow enough to
    /// make a small space safe.
    pub fn pin_is_acceptable(_: *const Model, pin: []const u8) bool {
        if (pin.len < auth.min_pin_len) return false;
        for (pin) |digit| {
            if (digit < '0' or digit > '9') return false;
        }
        return true;
    }

    /// True when the till is refusing PINs for a while.
    pub fn login_locked(model: *const Model) bool {
        return model.login_locked_until > model.now_ms;
    }

    /// How many seconds the till is locked for, or zero.
    pub fn login_locked_seconds(model: *const Model) i64 {
        if (!model.login_locked()) return 0;
        return @divTrunc(model.login_locked_until - model.now_ms, 1000);
    }

    /// True when the last sign-in attempt failed.
    pub fn login_failed(model: *const Model) bool {
        return model.login_error.len > 0;
    }

    /// True before a role has been chosen: the role picker is showing.
    /// A fresh installation shows the setup screen first, so the picker
    /// waits for it.
    pub fn show_role_picker(model: *const Model) bool {
        return !model.role_chosen and !model.needs_setup;
    }

    /// True when a role is chosen but nobody has signed in yet.
    pub fn show_login(model: *const Model) bool {
        return model.role_chosen and !model.signed_in;
    }

    /// True when the shell is showing.
    pub fn show_shell(model: *const Model) bool {
        return model.signed_in;
    }

    /// The role's label.
    pub fn role_label(model: *const Model) []const u8 {
        return model.role.label();
    }

    /// How many products the menu holds.
    pub fn product_count(model: *const Model) usize {
        return model.products.len;
    }

    /// How many tables the floor has.
    pub fn table_count(model: *const Model) usize {
        return model.tables.len;
    }

    /// How many customers the restaurant has.
    pub fn customer_count(model: *const Model) usize {
        return model.customers.len;
    }

    /// How many orders are on the board.
    pub fn order_count(model: *const Model) usize {
        return model.orders.len;
    }

    /// How many open (not yet completed) orders are on the board.
    pub fn open_order_count(model: *const Model) usize {
        var count: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready, .served => count += 1,
                .completed, .voided => {},
            }
        }
        return count;
    }

    /// How many tables are occupied right now.
    pub fn occupied_table_count(model: *const Model) usize {
        var count: usize = 0;
        for (model.tables) |table| {
            if (table.status == .occupied) count += 1;
        }
        return count;
    }

    /// The company name, or a neutral fallback while the database is
    /// still loading.
    pub fn company_label(model: *const Model) []const u8 {
        if (model.company_name_field.len == 0) return "Eatery";
        return model.company_name_field;
    }

    /// The company name, as a slice.
    pub fn company_name(model: *const Model) []const u8 {
        return model.company_name_field;
    }

    /// The installation salt, as a slice.
    pub fn pin_salt(model: *const Model) []const u8 {
        return model.pin_salt_buf[0..model.pin_salt_len];
    }

    /// The sign-in operator's name, or a neutral fallback.
    pub fn operator_label(model: *const Model) []const u8 {
        if (model.employee_name.len == 0) return "Not signed in";
        return model.employee_name;
    }

    /// The search text, trimmed - the markup binds this, never the
    /// `TextBuffer` itself.
    pub fn search_text(model: *const Model) []const u8 {
        return std.mem.trim(u8, model.search.text(), " ");
    }

    /// How many items the cart holds, counting quantity.
    pub fn cart_count(model: *const Model) usize {
        var count: usize = 0;
        for (model.cart[0..model.cart_len]) |line| {
            count += @intCast(@max(line.qty, 0));
        }
        return count;
    }

    /// The cart total in minor units.
    pub fn cart_total_minor(model: *const Model) i64 {
        var total: i64 = 0;
        for (model.cart[0..model.cart_len]) |line| {
            total += line.price_minor * line.qty;
        }
        return total;
    }

    /// Whether the cart holds anything at all.
    pub fn cart_is_empty(model: *const Model) bool {
        return model.cart_len == 0;
    }

    /// The sign-in PIN as typed. The view binds this, never the buffer.
    pub fn pin_text(model: *const Model) []const u8 {
        return model.pin.text();
    }

    /// The order type of the open cart.
    pub fn cart_type_label(model: *const Model) []const u8 {
        return model.cart_order_type.label();
    }

    /// The order types the POS offers.
    pub fn order_types(_: *const Model) []const OrderTypeOption {
        return &order_type_options;
    }

    // ------------------------------------------------- derived row sets
    //
    // These build their rows in the arena the VIEW owns, so the model
    // never grows a cache it has to invalidate.

    /// The menu after the category and search filters. A view binds
    /// this with `<for each="visible_products">`.
    ///
    /// The rows are allocated in the view's arena and are NEVER freed:
    /// Zig 0.16's arena `free` rewinds the arena when the block is the
    /// most recent allocation, so a `deinit` here would hand the rows
    /// back to the allocator and the NEXT allocation would overwrite
    /// them - the view would read a menu of garbage. The arena owns
    /// this memory; nothing in this function frees anything.
    pub fn visible_products(model: *const Model, arena: std.mem.Allocator) []const domain.Product {
        const needle = std.mem.trim(u8, model.search.text(), " ");
        var count: usize = 0;
        for (model.products) |product| {
            if (!productMatches(product, model.selected_category, needle)) continue;
            count += 1;
        }
        const out = arena.alloc(domain.Product, count) catch return &.{};
        var index: usize = 0;
        for (model.products) |product| {
            if (!productMatches(product, model.selected_category, needle)) continue;
            out[index] = product;
            index += 1;
        }
        return out[0..index];
    }

    /// The cart as the view renders it: one row per line, with the
    /// line total. Allocated in the view's arena, never freed (see
    /// `visible_products` for why).
    pub fn cart_lines(model: *const Model, arena: std.mem.Allocator) []const CartRow {
        const out = arena.alloc(CartRow, model.cart_len) catch return &.{};
        var index: usize = 0;
        for (model.cart[0..model.cart_len]) |line| {
            out[index] = .{
                .product_id = line.product_id,
                .name = line.name,
                .qty = line.qty,
                .total_minor = line.price_minor * line.qty,
            };
            index += 1;
        }
        return out[0..index];
    }

    /// The kitchen board: the orders the kitchen still owes, oldest
    /// first, with a one-line summary of what to cook.
    pub fn kitchen_tickets(model: *const Model, arena: std.mem.Allocator) []const Ticket {
        var count: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready => {
                    if (orderOnStation(model, order.id, model.station_filter_field)) count += 1;
                },
                .served, .completed, .voided => {},
            }
        }
        const out = arena.alloc(Ticket, count) catch return &.{};
        var index: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready => {
                    if (!orderOnStation(model, order.id, model.station_filter_field)) continue;
                },
                .served, .completed, .voided => continue,
            }
            out[index] = .{
                .id = order.id,
                .order_no = order.order_no,
                .status_label = order.status_label,
                .summary = summariseOrder(model, order, arena),
                .waiting_label = waitingLabel(model, order, arena),
            };
            index += 1;
        }
        return out[0..index];
    }

    /// How many tickets are on the kitchen board.
    pub fn ticket_count(model: *const Model) usize {
        var count: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready => count += 1,
                .served, .completed, .voided => {},
            }
        }
        return count;
    }

    /// True while an order's status is on its way to the database. The
    /// board's button is disabled while it holds: a second tap would
    /// move the order from a status the model has not caught up with.
    pub fn advancing(model: *const Model) bool {
        return model.advance_order_id != 0;
    }
};

/// One payment mode, as the confirmation screen sees it.
pub const PaymentModeOption = struct {
    id: usize,
    label: []const u8,
};

const payment_mode_options = [_]PaymentModeOption{
    .{ .id = @intFromEnum(domain.PaymentMode.cash), .label = domain.PaymentMode.cash.label() },
    .{ .id = @intFromEnum(domain.PaymentMode.card), .label = domain.PaymentMode.card.label() },
    .{ .id = @intFromEnum(domain.PaymentMode.upi), .label = domain.PaymentMode.upi.label() },
    .{ .id = @intFromEnum(domain.PaymentMode.wallet), .label = domain.PaymentMode.wallet.label() },
};

/// One order type, as the POS filter sees it.
pub const OrderTypeOption = struct {
    id: usize,
    label: []const u8,
};

const order_type_options = [_]OrderTypeOption{
    .{ .id = @intFromEnum(domain.OrderType.dine_in), .label = domain.OrderType.dine_in.label() },
    .{ .id = @intFromEnum(domain.OrderType.take_away), .label = domain.OrderType.take_away.label() },
    .{ .id = @intFromEnum(domain.OrderType.delivery), .label = domain.OrderType.delivery.label() },
};

/// One row of the cart, as the view sees it.
pub const CartRow = struct {
    product_id: i64,
    name: []const u8,
    qty: i64,
    total_minor: i64,
};

/// One dish on the menu, and the station that cooks it.
pub const KitchenDish = struct {
    id: i64,
    name: []const u8,
    /// The station that cooks this dish, by name. The markup binds
    /// fields, so the name is resolved here.
    station_name: []const u8,
};

/// One food marking, as the product form offers it.
pub const FoodTypeOption = struct {
    id: usize,
    label: []const u8,
};

const food_type_options = [_]FoodTypeOption{
    .{ .id = @intFromEnum(domain.FoodType.non_veg), .label = domain.FoodType.non_veg.label() },
    .{ .id = @intFromEnum(domain.FoodType.veg), .label = domain.FoodType.veg.label() },
    .{ .id = @intFromEnum(domain.FoodType.egg), .label = domain.FoodType.egg.label() },
    .{ .id = @intFromEnum(domain.FoodType.jain), .label = domain.FoodType.jain.label() },
};

/// One employee role, as the form offers it.
pub const RoleOption = struct {
    id: usize,
    label: []const u8,
};

const employee_role_options = [_]RoleOption{
    .{ .id = @intFromEnum(domain.EmployeeRole.admin), .label = domain.EmployeeRole.admin.label() },
    .{ .id = @intFromEnum(domain.EmployeeRole.waiter), .label = domain.EmployeeRole.waiter.label() },
    .{ .id = @intFromEnum(domain.EmployeeRole.kitchen), .label = domain.EmployeeRole.kitchen.label() },
    .{ .id = @intFromEnum(domain.EmployeeRole.display), .label = domain.EmployeeRole.display.label() },
};

/// One tile on the overview: a screen the owner can reach from the
/// front page.
pub const LinkItem = struct {
    id: usize,
    title: []const u8,
    detail: []const u8,
};

const dashboard_links = [_]LinkItem{
    .{ .id = @intFromEnum(Screen.reports), .title = "Today", .detail = "What the day came to" },
    .{ .id = @intFromEnum(Screen.payments), .title = "Payments", .detail = "The money that came in" },
    .{ .id = @intFromEnum(Screen.customers), .title = "Customers", .detail = "Who came back" },
    .{ .id = @intFromEnum(Screen.reservations), .title = "Reservations", .detail = "Who is coming" },
    .{ .id = @intFromEnum(Screen.suppliers), .title = "Suppliers", .detail = "Who you buy from" },
    .{ .id = @intFromEnum(Screen.purchase_orders), .title = "Purchase orders", .detail = "What is on its way" },
    .{ .id = @intFromEnum(Screen.settings), .title = "Settings", .detail = "The restaurant's setup" },
};

/// One row of the settings menu.
pub const SettingsItem = struct {
    /// The screen the row opens. Computed from the enum, so a
    /// reordering of `Screen` breaks the build instead of the menu.
    id: usize,
    title: []const u8,
    detail: []const u8,
};

const settings_menu = [_]SettingsItem{
    .{ .id = @intFromEnum(Screen.settings_company), .title = "Company", .detail = "Name, address, tax number" },
    .{ .id = @intFromEnum(Screen.settings_printers), .title = "Printers", .detail = "Receipt and kitchen printers" },
    .{ .id = @intFromEnum(Screen.settings_tax), .title = "Tax slabs", .detail = "The rates and the slabs" },
    .{ .id = @intFromEnum(Screen.settings_currency), .title = "Currency", .detail = "Currency and region" },
    .{ .id = @intFromEnum(Screen.settings_modifiers), .title = "Modifier groups", .detail = "The choices on a dish" },
    .{ .id = @intFromEnum(Screen.settings_discounts), .title = "Discounts", .detail = "Percent and fixed discounts" },
    .{ .id = @intFromEnum(Screen.data_management), .title = "Data", .detail = "Import, export and backup" },
    .{ .id = @intFromEnum(Screen.control_center), .title = "Control centre", .detail = "The devices and the sync" },
    .{ .id = @intFromEnum(Screen.db_inspector), .title = "Database", .detail = "Every table, and what is in it" },
};

/// One card on the customer display.
pub const DisplayCard = struct {
    /// The table the order is on, or the order number when the order
    /// is not for a table.
    label: []const u8,
    status_label: []const u8,
    type_label: []const u8,
    order_no: []const u8,
};

/// The name of the table an order is on. A take-away order has no
/// table, so it falls back to the order number.
fn displayLabel(model: *const Model, table_id: i64, order_no: []const u8) []const u8 {
    for (model.tables) |table| {
        if (table.id == table_id) return table.name;
    }
    return order_no;
}

/// One ticket on the kitchen board.
pub const Ticket = struct {
    id: i64,
    order_no: []const u8,
    status_label: []const u8,
    summary: []const u8,
    waiting_label: []const u8,
};

/// "2x Paneer Tikka, 1x Dal" - what the kitchen has to cook.
fn summariseOrder(model: *const Model, order: domain.Order, arena: std.mem.Allocator) []const u8 {
    // Counted first, then filled: the parts live in the view's arena and
    // are never freed (see `visible_products`).
    var count: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id == order.id) count += 1;
    }
    if (count == 0) return order.notes;
    const parts = arena.alloc([]const u8, count) catch return order.notes;
    var index: usize = 0;
    for (model.order_lines) |line| {
        if (line.order_id != order.id) continue;
        parts[index] = std.fmt.allocPrint(arena, "{d}x {s}", .{ line.qty, line.product_name }) catch order.notes;
        index += 1;
    }
    return std.mem.join(arena, ", ", parts) catch order.notes;
}

/// How long the ticket has been waiting, in minutes.
fn waitingLabel(model: *const Model, order: domain.Order, arena: std.mem.Allocator) []const u8 {
    if (model.now_ms <= 0 or order.placed_at <= 0) return "just now";
    const minutes = @divTrunc(model.now_ms - order.placed_at, 60_000);
    return std.fmt.allocPrint(arena, "{d} min", .{minutes}) catch "";
}

/// Whether an order belongs to a station. A station of zero means
/// "every station": a ticket with no station is everybody's.
fn orderOnStation(model: *const Model, order_id: i64, station: i64) bool {
    if (station == 0) return true;
    for (model.order_lines) |line| {
        if (line.order_id == order_id and line.station_id == station) return true;
    }
    return false;
}

/// Whether a product passes the category and search filters.
fn productMatches(product: domain.Product, category: i64, needle: []const u8) bool {
    if (category != 0 and product.category_id != category) return false;
    if (needle.len > 0 and !containsIgnoreCase(product.name, needle)) return false;
    return true;
}

/// A case-insensitive substring test. The menu is small enough that a
/// linear scan beats building an index.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}
