//! The embedded markup import closure.
//!
//! Every file the markup imports must also be listed here: the runtime
//! engine's first build reads this set, and hot reload re-resolves the
//! same paths from disk. A missing entry fails loudly at the import
//! site - which is the point: a screen that is not compiled in is a
//! screen that does not exist.
//!
//! The list is the service role's partition: the session screens, the
//! waiter's four screens, the order they come from, the customers the
//! waiter looks up, and the confirmation and PIN reset the role owns.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "screens/screen-session.native", .source = @embedFile("screens/screen-session.native") },
    .{ .path = "screens/screen-sell.native", .source = @embedFile("screens/screen-sell.native") },
    .{ .path = "screens/screen-orders.native", .source = @embedFile("screens/screen-orders.native") },
    .{ .path = "screens/screen-floor.native", .source = @embedFile("screens/screen-floor.native") },
    .{ .path = "screens/screen-people.native", .source = @embedFile("screens/screen-people.native") },
    .{ .path = "screens/screen-service.native", .source = @embedFile("screens/screen-service.native") },
};
