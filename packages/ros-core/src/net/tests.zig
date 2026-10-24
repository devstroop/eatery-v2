//! The package's own test root.
//!
//! A dependency module's tests are not collected by the app that depends
//! on it - `zig build test` in the app collects tests from the app's
//! module only. So the package tests itself: `zig build test` here runs
//! the pure wire code, and `scripts/verify-all.sh` calls it.
//!
//! Only the files that need nothing but `std` are listed. The model and
//! the repository layer need the SDK and the app's build options, and
//! their rules are tested through the apps that mount them.

test {
    _ = @import("protocol.zig");
    _ = @import("cursor.zig");
    _ = @import("record.zig");
    _ = @import("outbox.zig");
    _ = @import("server.zig");
    _ = @import("client.zig");
    _ = @import("discovery.zig");
}
