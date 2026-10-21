//! Screen identity and the navigation stack.
//!
//! There is no router in a Native SDK app: navigation IS model state.
//! `Screen` names every destination in the product, `Role` names the four
//! operating modes a device can be in, and the helpers below keep the stack
//! and the current screen consistent so no arm of `update` can leave the app
//! pointing at a screen the role may not see.

const std = @import("std");

/// The four ways a device runs the product. One binary, four dispatch
/// modes - the same idea as Eatery v1, but the kiosk roles get their own
/// windows instead of a route swap.
pub const Role = enum {
    admin,
    waiter,
    kds,
    display,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .admin => "Admin",
            .waiter => "Waiter",
            .kds => "Kitchen",
            .display => "Display",
        };
    }

    pub fn blurb(self: Role) []const u8 {
        return switch (self) {
            .admin => "Full point of sale, management, configuration and reports.",
            .waiter => "Order taking, table management and the floor plan.",
            .kds => "Live kitchen tickets, station by station. No sign-in.",
            .display => "Customer-facing order status. No sign-in.",
        };
    }

    /// Kiosk roles sign in by device, not by PIN.
    pub fn needs_sign_in(self: Role) bool {
        return switch (self) {
            .admin, .waiter => true,
            .kds, .display => false,
        };
    }
};

/// Every destination in the product. The order of this enum is the
/// navigation contract: `Screen.index()` is what the markup compares
/// against, so **never reorder the variants** - append new ones at the end.
pub const Screen = enum {
    // onboarding and session
    role_picker,
    login,
    landing,
    setup,
    wizard,
    create_company,
    reset_pin,
    upgrade,

    // admin surfaces
    admin_dashboard,
    control_center,

    // point of sale
    pos,
    pos_cart,
    order_confirmation,

    // orders and money
    orders,
    order_detail,
    payments,

    // the floor and the people on it
    customers,
    dining_tables,
    table_categories,
    floor_plan,
    reservations,

    // the catalogue
    kitchen_dishes,
    inventory_items,
    product_categories,
    suppliers,
    purchase_orders,

    // the back office
    employees,
    reports,
    settings,
    settings_company,
    settings_printers,
    settings_tax,
    settings_currency,
    settings_modifiers,
    settings_discounts,
    data_management,
    db_inspector,

    // waiter
    waiter_tables,
    waiter_menu,
    waiter_cart,
    waiter_orders,

    // kiosk
    kds_board,
    display_board,

    // the edit forms (appended: the enum order is a contract)
    product_form,
    employee_form,
    tax_slab_form,
    discount_form,
    category_form,
    categories,
    stock_count,
    modifier_group_form,
    customer_form,

    pub fn index(self: Screen) usize {
        return @intFromEnum(self);
    }

    pub fn title(self: Screen) []const u8 {
        return switch (self) {
            .role_picker => "Choose a role",
            .landing => "Eatery",
            .setup => "Set up",
            .wizard => "Setup wizard",
            .create_company => "Create company",
            .login => "Sign in",
            .reset_pin => "Reset PIN",
            .upgrade => "Upgrade",
            .admin_dashboard => "Dashboard",
            .control_center => "Control center",
            .orders => "Orders",
            .order_detail => "Order",
            .payments => "Payments",
            .customers => "Customers",
            .dining_tables => "Dining tables",
            .table_categories => "Table categories",
            .floor_plan => "Floor plan",
            .kitchen_dishes => "Kitchen dishes",
            .inventory_items => "Inventory",
            .product_categories => "Product categories",
            .suppliers => "Suppliers",
            .purchase_orders => "Purchase orders",
            .reservations => "Reservations",
            .employees => "Employees",
            .reports => "Reports",
            .settings => "Settings",
            .settings_company => "Company",
            .settings_printers => "Printers",
            .settings_tax => "Tax slabs",
            .settings_currency => "Currency & region",
            .settings_modifiers => "Modifier groups",
            .settings_discounts => "Discounts",
            .data_management => "Data management",
            .db_inspector => "Database inspector",
            .pos => "Point of sale",
            .pos_cart => "Cart",
            .order_confirmation => "Order confirmation",
            .waiter_tables => "Tables",
            .waiter_menu => "Menu",
            .waiter_cart => "Cart",
            .waiter_orders => "Orders",
            .kds_board => "Kitchen display",
            .display_board => "Display",
            .product_form => "Product",
            .employee_form => "Employee",
            .tax_slab_form => "Tax slab",
            .discount_form => "Discount",
            .category_form => "Category",
            .categories => "Categories",
            .stock_count => "Count the stock",
            .modifier_group_form => "Modifier group",
            .customer_form => "Customer",
        };
    }

    /// The nav tree the shell draws for a role. `null` means the screen is
    /// not in the role's rail - it is reached by drilling in, not by a tab.
    pub fn nav_section(self: Screen) ?NavSection {
        return switch (self) {
            .admin_dashboard, .control_center, .reports => .overview,
            .pos, .pos_cart, .order_confirmation => .sell,
            .orders, .order_detail, .payments => .orders,
            .customers, .dining_tables, .table_categories, .floor_plan, .reservations => .floor,
            .kitchen_dishes, .inventory_items, .product_categories, .suppliers, .purchase_orders => .catalog,
            .employees => .people,
            .settings,
            .settings_company,
            .settings_printers,
            .settings_tax,
            .settings_currency,
            .settings_modifiers,
            .settings_discounts,
            .data_management,
            .db_inspector => .system,
            .waiter_tables, .waiter_menu, .waiter_cart, .waiter_orders => .service,
            .kds_board => .kitchen,
            .display_board => .display,
            else => null,
        };
    }
};

/// One card of the role picker. Plain data, because the markup cannot
/// call a method on a row.
pub const RoleCard = struct {
    id: usize,
    title: []const u8,
    blurb: []const u8,
    kind: []const u8,
};

// The role cards are a FILE-SCOPE constant on purpose: a composite
// literal built inside a function lives on that function's stack frame,
// and returning a slice to it hands back a pointer to dead memory. The
// markup reads these rows on a later frame.
const role_cards = [_]RoleCard{
    .{ .id = @intFromEnum(Role.admin), .title = "Admin", .blurb = "Full point of sale, management, configuration and reports.", .kind = "PIN sign-in" },
    .{ .id = @intFromEnum(Role.waiter), .title = "Waiter", .blurb = "Order taking, table management and the floor plan.", .kind = "PIN sign-in" },
    .{ .id = @intFromEnum(Role.kds), .title = "Kitchen", .blurb = "Live kitchen tickets, station by station. No sign-in.", .kind = "Kiosk" },
    .{ .id = @intFromEnum(Role.display), .title = "Display", .blurb = "Customer-facing order status. No sign-in.", .kind = "Kiosk" },
};

/// The four roles, in the order the picker shows them.
pub fn roleCards() []const RoleCard {
    return &role_cards;
}

/// One row of the navigation rail. The markup binds `id` and `label`
/// directly - it cannot call a method on a row, so a row is plain data.
pub const NavItem = struct {
    id: usize,
    label: []const u8,
};

/// The top-level rails of the admin shell. The order here IS the rail
/// order on screen.
pub const NavSection = enum {
    overview,
    sell,
    orders,
    floor,
    catalog,
    people,
    system,
    service,
    kitchen,
    display,

    pub fn label(self: NavSection) []const u8 {
        return switch (self) {
            .overview => "Overview",
            .sell => "Sell",
            .orders => "Orders",
            .floor => "Floor",
            .catalog => "Catalog",
            .people => "People",
            .system => "System",
            .service => "Service",
            .kitchen => "Kitchen",
            .display => "Display",
        };
    }

    pub fn index(self: NavSection) usize {
        return @intFromEnum(self);
    }
};

/// The navigation stack. A fixed-capacity array, because the model must
/// be default-constructible and `update` has no allocator to hand out.
///
/// The stack holds the session's history with the current screen on
/// top, so `back` is always "drop the top and show the new top". It is
/// bounded on purpose: pressing the screen already on top is a no-op,
/// and a full stack drops its OLDEST entry rather than refusing the new
/// destination. A service can keep navigating; it never freezes.
///
/// Session transitions do not push a gate and then the home screen.
/// `resetTo` makes the gate the root, so Back from the first screen of
/// a session stays on that screen.
pub const max_depth = 32;

pub const Stack = struct {
    items: [max_depth]Screen = undefined,
    len: usize = 0,

    /// The screen on top.
    pub fn current(self: *const Stack) ?Screen {
        if (self.len == 0) return null;
        return self.items[self.len - 1];
    }

    /// The screen under the current one, or null at a root.
    pub fn peek(self: *const Stack) ?Screen {
        if (self.len < 2) return null;
        return self.items[self.len - 2];
    }

    /// Navigate to a screen.
    ///
    /// Pushing the current screen is a no-op: pressing the same tab
    /// again is not a navigation. At `max_depth` the oldest entry is
    /// dropped, so the history stays bounded and the new destination
    /// still lands.
    pub fn push(self: *Stack, screen: Screen) void {
        if (self.len > 0 and self.items[self.len - 1] == screen) return;
        if (self.len == max_depth) {
            var index: usize = 1;
            while (index < self.len) : (index += 1) {
                self.items[index - 1] = self.items[index];
            }
            self.len -= 1;
        }
        self.items[self.len] = screen;
        self.len += 1;
    }

    /// Go back: drop the current screen and land on the one under it.
    /// Returns null at a root, where the caller stays put.
    pub fn pop(self: *Stack) ?Screen {
        if (self.len <= 1) return null;
        self.len -= 1;
        return self.items[self.len - 1];
    }

    /// Forget the history and land on `screen`.
    pub fn resetTo(self: *Stack, screen: Screen) void {
        self.len = 0;
        self.items[0] = screen;
        self.len = 1;
    }
};
