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

    /// The first-run walk-through moved on to the next step.
    wizard_next,
    /// The first-run walk-through went back a step.
    wizard_back,
    /// The owner wants the quick setup instead of the walk-through.
    wizard_quick_setup,
    /// The company's record changed in the walk-through.
    wizard_address_edit: canvas.TextInputEvent,
    wizard_phone_edit: canvas.TextInputEvent,
    wizard_tax_edit: canvas.TextInputEvent,
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
    /// The payments the restaurant has taken.
    payments_loaded: native_sdk.EffectDbResult,
    /// The day's takings.
    report_loaded: native_sdk.EffectDbResult,
    /// The stock on the shelf.
    stock_loaded: native_sdk.EffectDbResult,
    /// The stock was counted.
    stock_saved: native_sdk.EffectDbResult,
    /// The day's takings by mode.
    report_modes_loaded: native_sdk.EffectDbResult,

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
    /// Jump to the payments the restaurant has taken.
    open_payments,
    /// Jump to the day's report.
    open_reports,
    /// Open the cart on its own.
    open_pos_cart,
    /// Back to the dashboard.
    open_dashboard,
    /// Open the stock on the shelf.
    open_inventory,
    /// Open the dishes and the stations that cook them.
    open_kitchen_dishes,
    /// Open the modifier groups.
    open_modifier_groups,
    /// Open the categories of tables.
    open_table_categories,
    /// Open the plan of the room.
    open_floor_plan,
    /// Edit the category of tables with this id.
    edit_table_category: i64,
    /// Start a new category of tables.
    new_table_category,
    /// The category's name changed.
    form_table_category_name_edit: canvas.TextInputEvent,
    /// Save the category.
    save_table_category,
    /// The category was saved.
    table_category_saved: native_sdk.EffectDbResult,
    /// The categories of tables.
    table_categories_loaded: native_sdk.EffectDbResult,
    /// Open the customers.
    open_customers,
    /// Edit the customer with this id.
    edit_customer: i64,
    /// The employee with this id has left.
    deactivate_employee: i64,
    /// Start a new customer.
    new_customer,
    /// The customer's name changed.
    form_customer_name_edit: canvas.TextInputEvent,
    /// The customer's phone changed.
    form_customer_phone_edit: canvas.TextInputEvent,
    /// The customer's email changed.
    form_customer_email_edit: canvas.TextInputEvent,
    /// The customer's address changed.
    form_customer_address_edit: canvas.TextInputEvent,
    /// Save the customer.
    save_customer,
    /// The customer was saved.
    customer_saved: native_sdk.EffectDbResult,
    /// Edit the modifier group with this id.
    edit_modifier_group: i64,
    /// Start a new modifier group.
    new_modifier_group,
    /// The group's name changed.
    form_modifier_group_name_edit: canvas.TextInputEvent,
    /// How many choices the group allows changed.
    form_modifier_max_edit: canvas.TextInputEvent,
    /// Whether the group is required changed.
    form_modifier_required,
    /// Save the group.
    save_modifier_group,
    /// The group was saved.
    modifier_group_saved: native_sdk.EffectDbResult,
    /// The choices in the modifier groups.
    modifiers_loaded: native_sdk.EffectDbResult,
    /// Open the database inspector.
    open_db_inspector,
    /// Open the control centre.
    open_control_center,
    /// The tables in the database.
    db_tables_loaded: native_sdk.EffectDbResult,
    /// The devices that have been here.
    devices_loaded: native_sdk.EffectDbResult,
    /// The sync state.
    sync_state_loaded: native_sdk.EffectDbResult,
    /// Choose the dish to assign a station to.
    select_dish: i64,
    /// Send the chosen dish to the station with this id.
    assign_station: i64,
    /// The dish was sent to a station.
    dish_assigned: native_sdk.EffectDbResult,
    /// Count the stock of the product with this id.
    count_stock: i64,
    /// The count being typed.
    form_stock_count_edit: canvas.TextInputEvent,
    /// The reason for the count.
    form_stock_reason_edit: canvas.TextInputEvent,
    /// Save the count.
    save_stock_count,
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
    /// Open the categories the menu is organised by.
    open_categories,
    /// Edit the product with this id.
    edit_product: i64,
    /// Start a new product.
    new_product,
    /// Save the product.
    save_product,
    /// The product was saved.
    product_saved: native_sdk.EffectDbResult,

    /// Reset an employee's PIN.
    reset_employee_pin: i64,
    /// The reset form changed.
    form_reset_pin_edit: canvas.TextInputEvent,
    form_reset_pin2_edit: canvas.TextInputEvent,
    /// Save the new PIN.
    save_reset_pin,
    /// The employee form changed.
    form_employee_name_edit: canvas.TextInputEvent,
    /// The employee's role.
    form_employee_role: i64,
    /// Edit the employee with this id.
    edit_employee: i64,
    /// Back to the employees.
    open_employees,
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
    /// The category form changed.
    form_category_name_edit: canvas.TextInputEvent,
    /// Open the category form: an existing category, or a new one.
    edit_category: i64,
    new_category,
    save_category,
    /// The category was saved.
    category_saved: native_sdk.EffectDbResult,
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
    /// The discount form changed.
    form_discount_name_edit: canvas.TextInputEvent,
    form_discount_percent_edit: canvas.TextInputEvent,
    form_discount_amount_edit: canvas.TextInputEvent,
    /// Open the discount form: an existing discount, or a new one.
    edit_discount: i64,
    new_discount,
    save_discount,
    /// Back to the discounts.
    open_discounts,
    /// The discount was saved.
    discount_saved: native_sdk.EffectDbResult,

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
    /// Try the read that failed again.
    retry_read,
    /// Flip between the light and dark palette.
    toggle_theme,
    /// The wall clock tick: the model keeps `now_ms` fresh so the
    /// kitchen board can say how long a ticket has waited.
    tick: native_sdk.EffectTimer,

    /// Messages the view never dispatches. The runtime delivers these
    /// (database results) or `update` raises them; no markup binds
    /// them, so they are declared here to keep the lint honest.
    /// Whether this message is a read, and how it went.
    ///
    /// Null for anything that is not a read. The list is the one place
    /// that knows which messages carry a read's answer, so the app's
    /// loading state and its retry do not have to be told twice.
    pub fn readOutcome(msg: Msg) ?bool {
        return switch (msg) {
            .products_loaded => |r| r.outcome == .ok,
            .categories_loaded => |r| r.outcome == .ok,
            .tables_loaded => |r| r.outcome == .ok,
            .db_tables_loaded => |r| r.outcome == .ok,
            .employees_loaded => |r| r.outcome == .ok,
            .orders_loaded => |r| r.outcome == .ok,
            .order_lines_loaded => |r| r.outcome == .ok,
            .customers_loaded => |r| r.outcome == .ok,
            .company_loaded => |r| r.outcome == .ok,
            .config_loaded => |r| r.outcome == .ok,
            .payments_loaded => |r| r.outcome == .ok,
            .report_loaded => |r| r.outcome == .ok,
            .report_modes_loaded => |r| r.outcome == .ok,
            .stock_loaded => |r| r.outcome == .ok,
            .devices_loaded => |r| r.outcome == .ok,
            .sync_state_loaded => |r| r.outcome == .ok,
            .modifiers_loaded => |r| r.outcome == .ok,
            .modifier_groups_loaded => |r| r.outcome == .ok,
            .discounts_loaded => |r| r.outcome == .ok,
            .printers_loaded => |r| r.outcome == .ok,
            .tax_slabs_loaded => |r| r.outcome == .ok,
            .reservations_loaded => |r| r.outcome == .ok,
            .suppliers_loaded => |r| r.outcome == .ok,
            .purchase_orders_loaded => |r| r.outcome == .ok,
            .inventory_loaded => |r| r.outcome == .ok,
            .stations_loaded => |r| r.outcome == .ok,
            .product_stations_loaded => |r| r.outcome == .ok,
            else => null,
        };
    }

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
        "payments_loaded",
        "report_loaded",
        "stock_loaded",
        "stock_saved",
        "dish_assigned",
        "modifier_group_saved",
        "table_category_saved",
        "table_categories_loaded",
        "customer_saved",
        "modifiers_loaded",
        "db_tables_loaded",
        "devices_loaded",
        "sync_state_loaded",
        "report_modes_loaded",
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
