//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{
        .name = "ros-admin",
        .manifest = "app.json",
    });

    // `packages/ros-core` owns the model, the messages, `update`, the
    // domain and the data layer. The app is a shell over it.
    //
    // Two things have to be wired, not one:
    //
    // 1. The package needs the *same* `native_sdk` module instance the app
    //    uses. A second instance would be a second set of types, and the
    //    `Msg` payloads would stop matching across the boundary. The SDK
    //    does exactly this for its own contract step (build/app.zig).
    // 2. Both `exe.root_module` and `tests.root_module` need the package.
    //    The second is the module the SDK's analysis and model-contract
    //    steps compile against, so missing it fails `native check` while
    //    `zig build` still succeeds.
    const sdk_mod = artifacts.tests.root_module.import_table.get("native_sdk").?;
    const ros_core = b.dependency("ros_core", .{}).module("ros_core");
    ros_core.addImport("native_sdk", sdk_mod);

    // The core cannot import the app, so the app tells it which binary it
    // is building: `admin`, `service` or `kiosk`. The constant fixes the
    // role and decides whether the picker offers the device modes.
    const app_options = b.addOptions();
    app_options.addOption([]const u8, "app", "admin");
    ros_core.addImport("app_options", app_options.createModule());

    artifacts.exe.root_module.addImport("ros_core", ros_core);
    artifacts.tests.root_module.addImport("ros_core", ros_core);
}
