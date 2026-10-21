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
    /// Turn the cart into an order.
    place_order,
    /// The order write came back.
    order_placed: native_sdk.EffectDbResult,

    // ------------------------------------------------------ shortcuts

    /// Jump to the point of sale.
    open_pos,
    /// Jump to the order list.
    open_orders,
    /// Jump to the floor.
    open_tables,

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
        "db_failed",
        "order_placed",
        "order_status_saved",
        "tick",
    };
};
