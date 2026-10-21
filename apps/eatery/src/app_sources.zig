//! The embedded markup import closure.
//!
//! Every file the markup imports must also be listed here: the runtime
//! engine's first build reads this set, and hot reload re-resolves the
//! same paths from disk. A missing entry fails loudly at the import
//! site - which is the point: a screen that is not compiled in is a
//! screen that does not exist.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "screens/screen-setup.native", .source = @embedFile("screens/screen-setup.native") },
    .{ .path = "screens/screen-role-picker.native", .source = @embedFile("screens/screen-role-picker.native") },
    .{ .path = "screens/screen-login.native", .source = @embedFile("screens/screen-login.native") },
    .{ .path = "screens/screen-dashboard.native", .source = @embedFile("screens/screen-dashboard.native") },
    .{ .path = "screens/screen-pos.native", .source = @embedFile("screens/screen-pos.native") },
    .{ .path = "screens/screen-order-detail.native", .source = @embedFile("screens/screen-order-detail.native") },
    .{ .path = "screens/screen-customers.native", .source = @embedFile("screens/screen-customers.native") },
    .{ .path = "screens/screen-reservations.native", .source = @embedFile("screens/screen-reservations.native") },
    .{ .path = "screens/screen-suppliers.native", .source = @embedFile("screens/screen-suppliers.native") },
    .{ .path = "screens/screen-purchase-orders.native", .source = @embedFile("screens/screen-purchase-orders.native") },
    .{ .path = "screens/screen-orders.native", .source = @embedFile("screens/screen-orders.native") },
    .{ .path = "screens/screen-tables.native", .source = @embedFile("screens/screen-tables.native") },
    .{ .path = "screens/screen-settings-printers.native", .source = @embedFile("screens/screen-settings-printers.native") },
    .{ .path = "screens/screen-settings-tax.native", .source = @embedFile("screens/screen-settings-tax.native") },
    .{ .path = "screens/screen-setting-forms.native", .source = @embedFile("screens/screen-setting-forms.native") },
    .{ .path = "screens/screen-settings-modifiers.native", .source = @embedFile("screens/screen-settings-modifiers.native") },
    .{ .path = "screens/screen-settings-discounts.native", .source = @embedFile("screens/screen-settings-discounts.native") },
    .{ .path = "screens/screen-settings-currency.native", .source = @embedFile("screens/screen-settings-currency.native") },
    .{ .path = "screens/screen-settings-data.native", .source = @embedFile("screens/screen-settings-data.native") },
    .{ .path = "screens/screen-catalogue-list.native", .source = @embedFile("screens/screen-catalogue-list.native") },
    .{ .path = "screens/screen-employees-list.native", .source = @embedFile("screens/screen-employees-list.native") },
    .{ .path = "screens/screen-product-form.native", .source = @embedFile("screens/screen-product-form.native") },
    .{ .path = "screens/screen-employee-form.native", .source = @embedFile("screens/screen-employee-form.native") },
    .{ .path = "screens/screen-settings-company.native", .source = @embedFile("screens/screen-settings-company.native") },
    .{ .path = "screens/screen-settings.native", .source = @embedFile("screens/screen-settings.native") },
    .{ .path = "screens/screen-display.native", .source = @embedFile("screens/screen-display.native") },
    .{ .path = "screens/screen-waiter-tables.native", .source = @embedFile("screens/screen-waiter-tables.native") },
    .{ .path = "screens/screen-waiter-menu.native", .source = @embedFile("screens/screen-waiter-menu.native") },
    .{ .path = "screens/screen-waiter-cart.native", .source = @embedFile("screens/screen-waiter-cart.native") },
    .{ .path = "screens/screen-waiter-orders.native", .source = @embedFile("screens/screen-waiter-orders.native") },
    .{ .path = "screens/screen-order-confirmation.native", .source = @embedFile("screens/screen-order-confirmation.native") },
    .{ .path = "screens/screen-kitchen.native", .source = @embedFile("screens/screen-kitchen.native") },
};
