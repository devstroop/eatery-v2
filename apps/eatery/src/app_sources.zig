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
    .{ .path = "screens/screen-role-picker.native", .source = @embedFile("screens/screen-role-picker.native") },
    .{ .path = "screens/screen-login.native", .source = @embedFile("screens/screen-login.native") },
    .{ .path = "screens/screen-dashboard.native", .source = @embedFile("screens/screen-dashboard.native") },
    .{ .path = "screens/screen-pos.native", .source = @embedFile("screens/screen-pos.native") },
    .{ .path = "screens/screen-orders.native", .source = @embedFile("screens/screen-orders.native") },
    .{ .path = "screens/screen-tables.native", .source = @embedFile("screens/screen-tables.native") },
    .{ .path = "screens/screen-kitchen.native", .source = @embedFile("screens/screen-kitchen.native") },
};
