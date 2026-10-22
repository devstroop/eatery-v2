const std = @import("std");

/// The app shells depend on this package; the shell's build owns the
/// `native_sdk` import, because `Msg` payloads must be the *same*
/// `native_sdk` types the app declares its variants with. Two module
/// instances would be two distinct types.
pub fn build(b: *std.Build) void {
    _ = b.addModule("ros_core", .{ .root_source_file = b.path("src/root.zig") });

    // The package's own tests. A dependency module's tests are not
    // collected by the app that depends on it, so this is where the
    // pure wire code is proved. It needs nothing but `std`.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/net/tests.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the package's own tests");
    test_step.dependOn(&run_tests.step);

    b.default_step.dependOn(&run_tests.step);
}
