//! Domain entities.
//!
//! One file for the whole vocabulary: these are the shapes the database
//! rows decode into and the shapes the view renders. Two house rules
//! hold everywhere in this file:
//!
//!   * **Money is `i64` minor units.** Never a float. A rupee, a cent or
//!     a yen is an integer; the currency decides the scale. Eatery v1 kept
//!     money in REAL columns and lost cents to rounding - that class of bug
//!     does not get a second chance here.
//!   * **Time is `i64` epoch milliseconds, UTC.** Every timestamp in the
//!     database is the same shape, so ordering and range queries need no
//!     per-column knowledge.
//!
//! Text is `[]const u8` owned by the loader, never by the model: rows are
//! decoded into an arena the view owns and dropped with it.

const std = @import("std");

/// The three kinds of sale a restaurant runs. The POS picks one per
/// order; the kitchen and the receipt both care.
pub const OrderType = enum(i64) {
    dine_in = 0,
    take_away = 1,
    delivery = 2,

    pub fn label(self: OrderType) []const u8 {
        return switch (self) {
            .dine_in => "Dine in",
            .take_away => "Take away",
            .delivery => "Delivery",
        };
    }
};

/// Order lifecycle. The transition table lives in `domain/orders.zig`.
pub const OrderStatus = enum(i64) {
    pending = 0,
    preparing = 1,
    ready = 2,
    served = 3,
    completed = 4,
    voided = 5,

    pub fn label(self: OrderStatus) []const u8 {
        return switch (self) {
            .pending => "Pending",
            .preparing => "Preparing",
            .ready => "Ready",
            .served => "Served",
            .completed => "Completed",
            .voided => "Voided",
        };
    }

    /// The badge tone for the status, expressed in theme tokens.
    pub fn tone(self: OrderStatus) []const u8 {
        return switch (self) {
            .pending => "warning",
            .preparing => "info",
            .ready => "success",
            .served => "accent",
            .completed => "text_muted",
            .voided => "destructive",
        };
    }

    pub fn fromCode(code: i64) OrderStatus {
        return std.enums.fromInt(OrderStatus, code) catch .pending;
    }
};

/// How a product is prepared. Drives the KDS grouping and whether stock
/// is decremented.
pub const ProductType = enum(i64) {
    dish = 0,
    beverage = 1,
    dessert = 2,
    combo = 3,
    service = 4,

    pub fn label(self: ProductType) []const u8 {
        return switch (self) {
            .dish => "Dish",
            .beverage => "Beverage",
            .dessert => "Dessert",
            .combo => "Combo",
            .service => "Service",
        };
    }
};

/// Vegetarian / non-vegetarian / egg - the usual kitchen markings.
pub const FoodType = enum(i64) {
    non_veg = 0,
    veg = 1,
    egg = 2,
    jain = 3,

    pub fn label(self: FoodType) []const u8 {
        return switch (self) {
            .non_veg => "Non-veg",
            .veg => "Veg",
            .egg => "Egg",
            .jain => "Jain",
        };
    }
};

pub const TableStatus = enum(i64) {
    free = 0,
    occupied = 1,
    reserved = 2,
    dirty = 3,

    pub fn label(self: TableStatus) []const u8 {
        return switch (self) {
            .free => "Free",
            .occupied => "Occupied",
            .reserved => "Reserved",
            .dirty => "Needs cleaning",
        };
    }
};

pub const PaymentMode = enum(i64) {
    cash = 0,
    card = 1,
    upi = 2,
    wallet = 3,
    credit = 4,

    pub fn label(self: PaymentMode) []const u8 {
        return switch (self) {
            .cash => "Cash",
            .card => "Card",
            .upi => "UPI",
            .wallet => "Wallet",
            .credit => "On account",
        };
    }
};

/// The company the device belongs to. One company per database in v2 -
/// the multi-company story from v1 was never used and cost real time.
pub const Company = struct {
    id: i64,
    name: []const u8,
    currency_code: []const u8,
    currency_symbol: []const u8,
    tax_inclusive: bool,
    address: []const u8,
    phone: []const u8,
    tax_number: []const u8,
};

/// A staff member. The PIN hash never enters this struct: the login
/// check happens in SQL, and only the id and display name come back.
pub const Employee = struct {
    id: i64,
    name: []const u8,
    role: i64,
    /// The role, as text.
    role_label: []const u8,
    active: bool,
};

pub const ProductCategory = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
};

pub const Product = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    /// The food marking, as text: the markup binds fields, not methods.
    food_label: []const u8,
    /// Price in minor units (cents, paise, yen...).
    price_minor: i64,
    product_type: ProductType,
    food_type: FoodType,
    tax_slab_id: i64,
    stock_qty: i64,
    active: bool,
};

pub const DiningTableCategory = struct {
    id: i64,
    name: []const u8,
};

pub const DiningTable = struct {
    id: i64,
    category_id: i64,
    name: []const u8,
    status: TableStatus,
    /// The status as text, resolved at decode time - the markup binds
    /// fields, not methods.
    status_label: []const u8,
    seats: i64,
    /// Position on the floor plan, in grid cells.
    pos_x: i64,
    pos_y: i64,
};

/// A category of dining table: "Main room", "Terrace", "Bar".
pub const TableCategory = struct {
    id: i64,
    name: []const u8,
};

pub const Customer = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    email: []const u8,
    loyalty_points: i64,
    /// The points, as the row shows them.
    points_label: []const u8,
};

pub const TaxSlab = struct {
    id: i64,
    name: []const u8,
    /// Rate in basis points (5% == 500).
    rate_bps: i64,
    inclusive: bool,
    active: bool,
    /// "Inclusive" or "Exclusive", as the row shows it.
    tax_label: []const u8,
};

pub const KdsStation = struct {
    id: i64,
    name: []const u8,
    sort_order: i64,
};

/// The roles an employee can have.
pub const EmployeeRole = enum(i64) {
    admin = 0,
    waiter = 1,
    kitchen = 2,
    display = 3,

    pub fn label(self: EmployeeRole) []const u8 {
        return switch (self) {
            .admin => "Admin",
            .waiter => "Waiter",
            .kitchen => "Kitchen",
            .display => "Display",
        };
    }
};

/// A reservation for a table.
pub const Reservation = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    guests: i64,
    reserved_at: i64,
    /// The same moment in epoch SECONDS - the markup's time() takes
    /// seconds, and a division would make it a float.
    reserved_seconds: i64,
    /// 'booked', 'seated' or 'cancelled'.
    status: i64,
    status_label: []const u8,
    notes: []const u8,
};

/// A supplier the restaurant buys from.
pub const Supplier = struct {
    id: i64,
    name: []const u8,
    phone: []const u8,
    email: []const u8,
    address: []const u8,
    gstin: []const u8,
    active: bool,
};

/// An order placed with a supplier.
pub const PurchaseOrder = struct {
    id: i64,
    order_no: []const u8,
    status: i64,
    status_label: []const u8,
    total_minor: i64,
    ordered_at: i64,
    /// The same moment in epoch SECONDS.
    ordered_seconds: i64,
    expected_at: i64,
    notes: []const u8,
};

/// A receipt or kitchen printer.
pub const Printer = struct {
    id: i64,
    name: []const u8,
    /// 'escpos' or 'system'.
    kind: []const u8,
    /// 'ble', 'tcp', 'usb' or 'file'.
    transport: []const u8,
    address: []const u8,
    /// 'receipt', 'kot' or 'report'.
    job: []const u8,
    active: bool,
};

/// A group of choices on a dish.
pub const ModifierGroup = struct {
    id: i64,
    name: []const u8,
    required: bool,
    max_select: i64,
    active: bool,
    /// "Required" or "Optional", as the row shows it.
    required_label: []const u8,
};

/// One choice inside a modifier group: "Extra cheese", "Well done".
pub const Modifier = struct {
    id: i64,
    group_id: i64,
    name: []const u8,
    /// What the choice adds to the price, in minor units. Zero is a
    /// choice that costs nothing.
    price_delta_minor: i64,
    active: bool,
};

/// A discount: a percentage, a fixed amount, or both.
pub const Discount = struct {
    id: i64,
    name: []const u8,
    percent_bps: i64,
    amount_minor: i64,
    active: bool,
    /// The discount as the row shows it: "10%" or "₹50.00".
    value_label: []const u8,
};

/// Which station cooks which product.
pub const ProductStation = struct {
    product_id: i64,
    station_id: i64,
};

/// One line of an order. Prices are frozen at the moment the order was
/// taken - a price change tomorrow must not rewrite yesterday's bills.
pub const OrderLine = struct {
    id: i64,
    order_id: i64,
    product_id: i64,
    /// The kitchen station that cooks this line.
    station_id: i64,
    product_name: []const u8,
    qty: i64,
    unit_price_minor: i64,
    tax_bps: i64,
    notes: []const u8,
};

pub const Order = struct {
    /// True when a payment has been taken for this order. An order
    /// without one is not closed, whatever its status says.
    paid: bool = false,
    id: i64,
    order_no: []const u8,
    order_type: OrderType,
    status: OrderStatus,
    /// Labels resolved at decode time: the markup binds fields.
    status_label: []const u8,
    type_label: []const u8,
    dining_table_id: i64,
    customer_id: i64,
    employee_id: i64,
    subtotal_minor: i64,
    tax_minor: i64,
    discount_minor: i64,
    total_minor: i64,
    placed_at: i64,
    notes: []const u8,
};

/// A printable report of the day's takings. Kept so a device can print
/// an X report without the app being open.
pub const Shift = struct {
    id: i64,
    employee_id: i64,
    opened_at: i64,
    closed_at: i64,
    opening_cash_minor: i64,
    closing_cash_minor: i64,
    expected_cash_minor: i64,
};

/// A payment the restaurant took.
///
/// The money is in minor units, and the mode is an enum resolved to a
/// label at decode time: the markup binds fields, it does not decide
/// what cash is called.
pub const Payment = struct {
    id: i64,
    order_id: i64,
    order_no: []const u8,
    mode: PaymentMode,
    /// The name of the mode, for the view.
    mode_label: []const u8,
    amount_minor: i64,
    reference: []const u8,
    paid_at: i64,
};

/// How the money came in, on one mode.
pub const ReportMode = struct {
    mode: PaymentMode,
    /// The name of the mode, for the view.
    mode_label: []const u8,
    count: i64,
    amount_minor: i64,
};

/// Something the restaurant counts. The stock on the shelf, as of the
/// last count.
pub const StockItem = struct {
    id: i64,
    name: []const u8,
    /// The number on the shelf. Zero is a real number, and so is a
    /// product that is not counted at all.
    stock_qty: i64,
};

/// A device that has been in this restaurant.
pub const Device = struct {
    id: []const u8,
    name: []const u8,
    role: []const u8,
    last_seen_at: i64,
};

/// One piece of the sync sidecar's state.
pub const SyncState = struct {
    key: []const u8,
    value: []const u8,
};

/// One table in the database, and how many rows it holds.
pub const TableCount = struct {
    name: []const u8,
    rows: i64,
};

/// One line of the POS cart. The cart is session state, not database
/// state: it lives in the model until the order is placed.
pub const CartLine = struct {
    product_id: i64,
    /// The product name, frozen at the moment it was added so a later
    /// price change cannot rewrite the cart.
    name: []const u8,
    price_minor: i64,
    qty: i64,
};
