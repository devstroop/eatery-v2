const std = @import("std");

/// The app shells depend on this package; the shell's build owns the
/// `native_sdk` import, because `Msg` payloads must be the *same*
/// `native_sdk` types the app declares its variants with. Two module
/// instances would be two distinct types.
pub fn build(b: *std.Build) void {
    _ = b.addModule("ros_core", .{ .root_source_file = b.path("src/root.zig") });
}
