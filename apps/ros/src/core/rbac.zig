//! Role permissions.
//!
//! This is the whole access-control surface of the app, and it is a pure
//! function on purpose: every navigation arm in `update` asks it before
//! moving, and the unit tests walk the entire matrix. Eatery v1 buried the
//! same idea in a router `redirect:` callback, where it was untestable and
//! silent when it fired.

const std = @import("std");
const nav = @import("navigation.zig");
const domain = @import("../domain/models.zig");

const Role = nav.Role;
const Screen = nav.Screen;

/// Admin is the wildcard. Waiter is scoped to service. The two kiosk roles
/// are device-scoped and sign in without a PIN, so their lists are short
/// and deliberately exclude anything that changes money.
pub fn allows(role: Role, screen: Screen) bool {
    return switch (role) {
        .admin => true,
        .waiter => switch (screen) {
            .role_picker,
            .login,
            .landing,
            .waiter_tables,
            .waiter_menu,
            .waiter_cart,
            .waiter_orders,
            .orders,
            .order_detail,
            .order_confirmation,
            .customers,
            .reset_pin,
            => true,
            else => false,
        },
        .kds => switch (screen) {
            .role_picker,
            .login,
            .kds_board,
            .order_detail,
            => true,
            else => false,
        },
        .display => switch (screen) {
            .role_picker,
            .login,
            .display_board,
            .order_detail,
            => true,
            else => false,
        },
    };
}

/// The landing screen for a role - where the app opens after the role is
/// chosen and the session (if any) is established.
pub fn home(role: Role) Screen {
    return switch (role) {
        .admin => .admin_dashboard,
        .waiter => .waiter_tables,
        .kds => .kds_board,
        .display => .display_board,
    };
}

/// The stored role an employee must hold to work this operating mode.
///
/// The device's mode and the employee's role are two different things: a
/// till in "Admin" mode needs an employee whose stored role is `admin`.
/// A sign-in has to agree on both - otherwise a waiter's PIN opens an
/// admin session, and the permission matrix below stops being a
/// permission matrix at all.
pub fn employee_role(role: Role) domain.EmployeeRole {
    return switch (role) {
        .admin => .admin,
        .waiter => .waiter,
        .kds => .kitchen,
        .display => .display,
    };
}

// The rail tables.
//
// These are FILE-SCOPE constants on purpose. A composite literal built
// inside a function (`&.{ ... }` with any runtime value in it) lives on
// that function's stack frame: returning a slice to it hands the caller a
// pointer to memory that is dead the moment the function returns. The
// markup reads these rows on a later frame and finds garbage - a crash
// that looks like a platform bug and is not one. Keep every table the
// view binds at file scope, with comptime-known contents.

const admin_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.overview), .label = "Overview" },
    .{ .id = @intFromEnum(nav.NavSection.sell), .label = "Sell" },
    .{ .id = @intFromEnum(nav.NavSection.orders), .label = "Orders" },
    .{ .id = @intFromEnum(nav.NavSection.floor), .label = "Floor" },
    .{ .id = @intFromEnum(nav.NavSection.catalog), .label = "Catalog" },
    .{ .id = @intFromEnum(nav.NavSection.people), .label = "People" },
    .{ .id = @intFromEnum(nav.NavSection.system), .label = "System" },
};

const waiter_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.service), .label = "Service" },
};

const kitchen_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.kitchen), .label = "Kitchen" },
};

const display_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.display), .label = "Display" },
};

/// The screens a role can reach from the shell rail, in rail order.
/// The shell draws exactly this list, so the rail can never show a
/// destination the role may not open.
pub fn nav_sections(role: Role) []const nav.NavItem {
    return switch (role) {
        .admin => &admin_rail,
        .waiter => &waiter_rail,
        .kds => &kitchen_rail,
        .display => &display_rail,
    };
}

/// The screen a nav section opens.
pub fn section_screen(section: nav.NavSection) Screen {
    return switch (section) {
        .overview => .admin_dashboard,
        .sell => .pos,
        .orders => .orders,
        .floor => .dining_tables,
        .catalog => .product_categories,
        .people => .employees,
        .system => .settings,
        .service => .waiter_tables,
        .kitchen => .kds_board,
        .display => .display_board,
    };
}
