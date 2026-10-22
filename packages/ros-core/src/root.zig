//! Restaurant OS core: the model, the messages, `update`, the domain and
//! the data layer. Shared by every app shell.
//!
//! The apps do not carry copies of this code. They differ in their
//! manifest, their fixed role, the markup they mount and their schema.
//!
//! Imports inside this package stay relative (`../data/repos.zig`), so the
//! tree can move without rewriting them. The app shells import the package
//! by name and reach a module through this file:
//!
//! ```zig
//! const core = @import("ros_core").model;
//! ```

pub const bump = @import("bump.zig");

pub const model = @import("core/model.zig");
pub const msg = @import("core/msg.zig");
pub const update = @import("core/update.zig");
pub const navigation = @import("core/navigation.zig");
pub const rbac = @import("core/rbac.zig");
pub const theme = @import("core/theme.zig");

pub const auth = @import("data/auth.zig");
pub const page = @import("data/page.zig");
pub const repos = @import("data/repos.zig");
pub const starter = @import("data/starter.zig");

pub const models = @import("domain/models.zig");

/// The wire: the protocol vocabulary, the operation record and the
/// vector cursor. Pure data and pure functions - the server and client
/// that move them live above this layer.
pub const net = struct {
    pub const protocol = @import("net/protocol.zig");
    pub const cursor = @import("net/cursor.zig");
    pub const record = @import("net/record.zig");
};

test {
    _ = @import("net/protocol.zig");
    _ = @import("net/cursor.zig");
    _ = @import("net/record.zig");
}
