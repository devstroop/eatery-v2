//! The message vocabulary.
//!
//! Every state change in the app is one of these. The markup never
//! mutates anything - it dispatches a message, and `update` decides
//! what that means. That is the whole contract.
//!
//! Payload types are fixed by the platform for the messages the runtime
//! delivers (timers, text edits, database results). Messages the app
//! invents carry small scalars, so a template can dispatch them with
//! `on-press="pick_role:{id}"`.

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;

pub const Msg = union(enum) {
    // ------------------------------------------------------------ session

    /// The role picker: the chosen role's index.
    pick_role: u8,
    /// The sign-in PIN changed (the payload is the runtime's text edit).
    pin_edit: canvas.TextInputEvent,
    /// The sign-in form was submitted.
    submit_login,
    /// The PIN check came back.
    login_checked: native_sdk.EffectDbResult,
    /// A PIN was rewritten in the modern form.
    pin_rehashed: native_sdk.EffectDbResult,
    /// Leave the session.
    sign_out,
    /// Back to the role picker (from the sign-in screen).
    pick_role_again,

    // ------------------------------------------------------- first run

    /// The setup form changed.
    setup_company_edit: canvas.TextInputEvent,
    setup_admin_edit: canvas.TextInputEvent,
    setup_pin_edit: canvas.TextInputEvent,
    setup_pin2_edit: canvas.TextInputEvent,
    setup_currency_edit: canvas.TextInputEvent,
    /// The currency SYMBOL changed. It has its own message because it
    /// has its own field: the code and the symbol are two different
    /// things, and a field that writes into the other one is a field
    /// that lies.
    setup_symbol_edit: canvas.TextInputEvent,
    /// Set up the restaurant.
    setup_submit,
    /// The setup write came back.
    setup_created: native_sdk.EffectDbResult,

    // --------------------------------------------------------- navigation

    /// Open a screen by index (see `core/navigation.zig`).
    open_screen: u8,
    /// Open the screen behind a nav section (see `core/rbac.zig`).
    open_section: u8,
    /// Go back one screen.
    go_back,
    /// The nav rail divider moved: the applied fraction, echoed back
    /// through the model's `rail_split`.
    rail_resized: f32,
    /// The menu divider in the POS moved.
    menu_resized: f32,

    // ------------------------------------------------------------- the POS

    /// The product search changed.
    search_edit: canvas.TextInputEvent,
    /// Filter by category.
    set_category: i64,
    /// Clear the category filter. A payload must be a BINDING, so the
    /// "all categories" button cannot carry a literal zero.
    set_category_all,
    /// Add a product to the cart (its id).
    add_to_cart: i64,
    /// Remove a product from the cart (its id).
    remove_from_cart: i64,
    /// Change the cart's order type (its index).
    set_order_type: u8,
    /// Clear the cart.
    clear_cart,
    /// Apply a discount to the cart (the discount's id).
    apply_discount: i64,
    /// Take the discount off the cart.
    clear_discount,
    /// Turn the cart into an order.
    place_order,
    /// The order write came back.
    order_placed: native_sdk.EffectDbResult,

    // --------------------------------------------------------- the waiter

    /// The waiter picked a table: open (or find) its order.
    select_table: i64,
    /// Back to the waiter's floor.
    go_waiter_tables,
    /// Back to the waiter's menu.
    go_waiter_menu,
    /// The waiter's open order.
    go_waiter_cart,
    /// Add a product to the open order of the selected table.
    add_to_order: i64,
    /// The order for the table was opened.
    order_opened: native_sdk.EffectDbResult,
    /// The line was added to the open order.
    order_line_added: native_sdk.EffectDbResult,

    // -------------------------------------------------------- the payment

    /// The payment mode the cashier picked.
    set_payment_mode: i64,
    /// Take the payment for the order that was just placed.
    take_payment,
    /// Back to the point of sale for the next order.
    back_to_pos,
    /// The payment write came back.
    payment_taken: native_sdk.EffectDbResult,

    // ----------------------------------------------------- the lists

    /// The reservations were loaded.
    reservations_loaded: native_sdk.EffectDbResult,
    /// The suppliers were loaded.
    suppliers_loaded: native_sdk.EffectDbResult,
    /// The purchase orders were loaded.
    purchase_orders_loaded: native_sdk.EffectDbResult,
    /// The stock was loaded.
    inventory_loaded: native_sdk.EffectDbResult,

    // ------------------------------------------------------ the order

    /// Open the order with this id.
    open_order: i64,
    /// Take the payment for the order with this id.
    pay_order: i64,
    /// Take the payment for the order being shown.
    pay_selected_order,

    // ------------------------------------------------------ shortcuts

    /// Jump to the point of sale.
    open_pos,
    /// Jump to the order list.
    open_orders,
    /// Jump to the floor.
    open_tables,

    // -------------------------------------------------------- the forms

    /// The currency form changed.
    form_currency_code_edit: canvas.TextInputEvent,
    form_currency_symbol_edit: canvas.TextInputEvent,
    /// Save the currency.
    save_currency,
    /// The currency was saved.
    currency_saved: native_sdk.EffectDbResult,

    /// The product form changed.
    form_product_name_edit: canvas.TextInputEvent,
    form_product_price_edit: canvas.TextInputEvent,
    /// The product's category.
    form_product_category: i64,
    /// The product's food marking.
    form_product_food: i64,
    /// Back to the catalogue.
    open_catalogue,
    /// Back to the people.
    open_employees,
    /// Edit the product with this id.
    edit_product: i64,
    /// Start a new product.
    new_product,
    /// Save the product.
    save_product,
    /// The product was saved.
    product_saved: native_sdk.EffectDbResult,

    /// The employee form changed.
    form_employee_name_edit: canvas.TextInputEvent,
    /// The employee's role.
    form_employee_role: i64,
    /// Edit the employee with this id.
    edit_employee: i64,
    /// Start a new employee.
    new_employee,
    /// Save the employee.
    save_employee,
    /// The employee was saved.
    employee_saved: native_sdk.EffectDbResult,

    // ------------------------------------------------- the settings data

    /// The printers were loaded.
    printers_loaded: native_sdk.EffectDbResult,
    /// The tax slabs were loaded.
    tax_slabs_loaded: native_sdk.EffectDbResult,
    /// The tax slab form changed.
    form_tax_slab_name_edit: canvas.TextInputEvent,
    form_tax_slab_rate_edit: canvas.TextInputEvent,
    form_tax_slab_inclusive,
    /// Open the tax slab form: an existing slab, or a new one.
    edit_tax_slab: i64,
    new_tax_slab,
    save_tax_slab,
    /// Back to the tax slabs.
    open_tax_slabs,
    /// The tax slab was saved.
    tax_slab_saved: native_sdk.EffectDbResult,
    /// The modifier groups were loaded.
    modifier_groups_loaded: native_sdk.EffectDbResult,
    /// The discounts were loaded.
    discounts_loaded: native_sdk.EffectDbResult,

    // ---------------------------------------------------- the company form

    /// The company form changed.
    form_company_name_edit: canvas.TextInputEvent,
    form_company_address_edit: canvas.TextInputEvent,
    form_company_phone_edit: canvas.TextInputEvent,
    form_company_tax_edit: canvas.TextInputEvent,
    /// Save the company.
    save_company,
    /// Back to the settings menu.
    open_settings,
    /// The company was saved.
    company_saved: native_sdk.EffectDbResult,

    // ------------------------------------------------------ the kitchen board

    /// The board refreshes itself: the kitchen is a different device
    /// from the cashier, and a live query only sees the writes this
    /// connection made. A timer is what actually keeps the board
    /// current.
    refresh_orders: native_sdk.EffectTimer,
    /// The board is filtered by a station.
    set_station_filter: i64,
    /// The board shows every station. A payload must be a BINDING, so
    /// "every station" needs a message of its own.
    set_station_filter_all,
    /// The stations were loaded.
    stations_loaded: native_sdk.EffectDbResult,
    /// The product-to-station mapping was loaded.
    product_stations_loaded: native_sdk.EffectDbResult,
    /// An audio event (the chime finished, or failed).
    audio_event: native_sdk.EffectAudio,
    // ------------------------------------------------------ kitchen board

    /// Move an order along its lifecycle (the order id).
    advance_order: i64,
    /// The status write came back.
    order_status_saved: native_sdk.EffectDbResult,

    // -------------------------------------------------------------- data

    products_loaded: native_sdk.EffectDbResult,
    categories_loaded: native_sdk.EffectDbResult,
    tables_loaded: native_sdk.EffectDbResult,
    employees_loaded: native_sdk.EffectDbResult,
    customers_loaded: native_sdk.EffectDbResult,
    orders_loaded: native_sdk.EffectDbResult,
    order_lines_loaded: native_sdk.EffectDbResult,
    company_loaded: native_sdk.EffectDbResult,
    config_loaded: native_sdk.EffectDbResult,
    config_saved: native_sdk.EffectDbResult,
    /// A query or write failed.
    db_failed: native_sdk.EffectDbResult,

    // ------------------------------------------------------------- chrome

    /// Dismiss the error banner.
    dismiss_error,
    /// Flip between the light and dark palette.
    toggle_theme,
    /// The wall clock tick: the model keeps `now_ms` fresh so the
    /// kitchen board can say how long a ticket has waited.
    tick: native_sdk.EffectTimer,

    /// Messages the view never dispatches. The runtime delivers these
    /// (database results) or `update` raises them; no markup binds
    /// them, so they are declared here to keep the lint honest.
    pub const view_unbound = .{
        "login_checked",
        "products_loaded",
        "categories_loaded",
        "tables_loaded",
        "employees_loaded",
        "customers_loaded",
        "orders_loaded",
        "order_lines_loaded",
        "company_loaded",
        "config_loaded",
        "config_saved",
        "setup_created",
        "payment_taken",
        "order_opened",
        "order_line_added",
        "db_failed",
        "order_placed",
        "order_status_saved",
        "tick",
        "stations_loaded",
        "company_saved",
        "currency_saved",
        "product_saved",
        "employee_saved",
        "printers_loaded",
        "tax_slabs_loaded",
        "modifier_groups_loaded",
        "discounts_loaded",
        "reservations_loaded",
        "suppliers_loaded",
        "purchase_orders_loaded",
        "inventory_loaded",
        "product_stations_loaded",
        "audio_event",
    };
};
