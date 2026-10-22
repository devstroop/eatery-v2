//! The embedded markup import closure.
//!
//! Every file the markup imports must also be listed here: the runtime
//! engine's first build reads this set, and hot reload re-resolves the
//! same paths from disk. A missing entry fails loudly at the import
//! site - which is the point: a screen that is not compiled in is a
//! screen that does not exist.
//!
//! The list is the kiosk's partition: the session screens (the device
//! picker and the setup a fresh installation needs), the two boards, and
//! the order detail a ticket opens.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "screens/screen-session.native", .source = @embedFile("screens/screen-session.native") },
    .{ .path = "screens/screen-orders.native", .source = @embedFile("screens/screen-orders.native") },
    .{ .path = "screens/screen-kitchen.native", .source = @embedFile("screens/screen-kitchen.native") },
};
