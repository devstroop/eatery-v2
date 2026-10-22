//! Restaurant OS - a restaurant operating system in one native binary.
//!
//! The app is the Native SDK's app-model shape: a `Model` (what is
//! true), a `Msg` (what happened), and `update` (what is true now).
//! The view is declarative markup in `app.native`; it binds model
//! values and dispatches messages, and it never changes state itself.
//!
//! Everything the world touches - the database, the clock, a printer,
//! the sync sidecar - goes through the effects channel, so `update`
//! stays a pure function of (model, message) and the whole app can be
//! replayed and tested headlessly.
//!
//! The house rules live in `core/model.zig`; read that first.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const core = @import("ros_core").model;
const msg_mod = @import("ros_core").msg;
const update_mod = @import("ros_core").update;
const theme = @import("ros_core").theme;
const auth = @import("ros_core").auth;

const Model = core.Model;
const Msg = msg_mod.Msg;

// ------------------------------------------------------------------ shell

const canvas_label = "main-canvas";
const window_width: f32 = 1280;
const window_height: f32 = 800;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
    native_sdk.security.permission_command,
    native_sdk.security.permission_window,
    native_sdk.security.permission_dialog,
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_clipboard,
    native_sdk.security.permission_network,
    native_sdk.security.permission_notifications,
    native_sdk.security.permission_credentials,
};

const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Restaurant OS Admin canvas",
    .accessibility_label = "Restaurant OS Admin",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Restaurant OS Admin",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ view

/// The update function, re-exported so the tests can drive the app
/// exactly the way the runtime does.
pub const update = update_mod.update;
/// The boot effects, re-exported for the same reason.
pub const boot = update_mod.boot;

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");
pub const app_sources = @import("app_sources.zig").sources;

// -------------------------------------------------------------------- app

const RosApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    // `create` heap-allocates and constructs the model in place: the
    // model carries the row buffers and is far too large for the stack.
    const app_state = try RosApp.create(std.heap.page_allocator, .{
        .name = "ros-admin",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update_mod.update,
        .init_fx = update_mod.boot,
        .tokens_fn = theme.tokens,
        .markup = .{
            .source = app_markup,
            .sources = &app_sources,
            .watch_path = "src/app.native",
            .io = init.io,
        },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    // The installation salt. It is made here because this is the one
    // place with an `Io` (and therefore with randomness); `boot` writes
    // it to the database if this is a fresh installation.
    auth.makeSalt(init.io, &app_state.model.pin_salt_buf);
    app_state.model.pin_salt_len = app_state.model.pin_salt_buf.len;

    // This installation's token. It names the device in the request
    // keys it makes, so two devices cannot mistake each other's sale
    // for a retry of their own.
    auth.makeToken(init.io, &app_state.model.device_token_buf);
    app_state.model.device_token_len = app_state.model.device_token_buf.len;

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "ros-admin",
        .window_title = "Restaurant OS Admin",
        .bundle_id = "com.devstroop.ros.admin",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("tests_data.zig");
}
