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

pub const Model = struct {
    /// Fields the view never binds directly. Keep this list honest:
    /// it is the boundary between "the model" and "the interface".
    pub const view_unbound = .{
        "stack",
        "employee_id",
        "db_ready",
        "busy",
        "company_id",
        "pending_screen",
        "theme_dark",
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
    currency_code: []const u8 = "USD",
    currency_symbol: []const u8 = "$",
    /// True when the menu's prices already include tax.
    tax_inclusive: bool = false,

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

    // ------------------------------------------------------- the sale

    /// The order that was just placed: the confirmation screen shows
    /// it and the payment is taken against it.
    last_order_id: i64 = 0,
    last_order_no_field: []const u8 = "",
    last_order_type_field: []const u8 = "",
    last_order_total_minor: i64 = 0,
    last_order_items_count: i64 = 0,
    last_order_at: i64 = 0,
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
    /// True while the salt in the model has not been confirmed by the
    /// database - it is the provisional one made at boot.
    salt_is_provisional: bool = true,
    /// The hash of the PIN being checked. Lives in the model so the
    /// query parameter has a stable home.
    login_hash: [64]u8 = undefined,
    /// Storage for the signed-in operator's name.
    operator_buf: bump.Bump(1024) = .{},
    /// Why the last sign-in failed, or empty.
    login_error: []const u8 = "",

    // -------------------------------------------------------------- cart

    /// Storage for the cart lines' names.
    cart_buf: bump.Bump(8 * 1024) = .{},
    /// The open cart. Session state: it dies with the order.
    cart: [max_cart_lines]domain.CartLine = undefined,
    cart_len: usize = 0,
    /// The order type of the open cart.
    cart_order_type: domain.OrderType = .dine_in,

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

    /// The order number of the order just placed.
    pub fn last_order_no(model: *const Model) []const u8 {
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

    /// True when the app is waiting for a first-run setup.
    pub fn show_setup(model: *const Model) bool {
        return model.needs_setup;
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
    pub fn setup_can_submit(model: *const Model) bool {
        const name = std.mem.trim(u8, model.setup_company_name.text(), " ");
        const admin = std.mem.trim(u8, model.setup_admin_name.text(), " ");
        const pin = model.setup_pin.text();
        const pin2 = model.setup_pin2.text();
        if (name.len == 0 or admin.len == 0 or pin.len == 0) return false;
        return std.mem.eql(u8, pin, pin2);
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
                .pending, .preparing, .ready => count += 1,
                .served, .completed, .voided => {},
            }
        }
        const out = arena.alloc(Ticket, count) catch return &.{};
        var index: usize = 0;
        for (model.orders) |order| {
            switch (order.status) {
                .pending, .preparing, .ready => {},
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
