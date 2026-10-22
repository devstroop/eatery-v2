//! The kiosk app's headless tests.
//!
//! The shared logic is tested once in `apps/admin`, which runs the
//! superset of the screens. This file tests what the split adds: the
//! binary runs the two boards and nothing that touches money, the picker
//! offers the boards rather than people, and a screen outside the role is
//! refused by the same `rbac.allows` path it always was.

const std = @import("std");
const native_sdk = @import("native_sdk");

const main = @import("main.zig");
const core = @import("ros_core").model;
const msg_mod = @import("ros_core").msg;
const nav = @import("ros_core").navigation;
const rbac = @import("ros_core").rbac;

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = core.Model;
const Msg = msg_mod.Msg;
const Effects = native_sdk.Effects(Msg);
const AppMarkup = canvas.MarkupView(Model, Msg);

const app = core.app_kind;
const boot = core.boot_role;

// ------------------------------------------------------------- helpers

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    const sources = main.app_sources;
    var loader = canvas.ui_markup.SourceSetLoader{ .set = &sources };
    const root_source = main.app_markup;

    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = canvas.ui_markup.resolveImports(arena, "app.native", root_source, loader.loader(), &diagnostic) catch |err| {
        std.debug.print("import resolution failed: {s} at {d}:{d}\n", .{ @errorName(err), diagnostic.line, diagnostic.column });
        return err;
    };

    var view = AppMarkup.fromDocument(document);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

fn fakeFx() !Effects {
    var fx = Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}

// --------------------------------------------------------------- tests

test "the kiosk boots as the kitchen board" {
    try testing.expectEqual(core.AppKind.kiosk, app);
    try testing.expectEqual(nav.Role.kds, boot);

    const model = main.initialModel();
    try testing.expectEqual(nav.Role.kds, model.role);
}

test "the picker offers the two boards, and no people" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    try testing.expect(model.show_role_picker());
    try testing.expect(model.show_device_cards());
    try testing.expect(!model.show_people());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Kitchen");
    _ = try expectByText(tree.root, .text, "Display");
}

test "picking a board signs the device in and opens it" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.display) }, &fx);

    try testing.expect(model.signed_in);
    try testing.expectEqual(nav.Role.display, model.role);
    try testing.expectEqual(nav.Screen.display_board, model.screen());
}

test "the kiosk refuses the roles that are not boards" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    for ([_]nav.Role{ .admin, .waiter }) |role| {
        main.update(&model, .{ .pick_role = @intFromEnum(role) }, &fx);
        try testing.expectEqual(nav.Role.kds, model.role);
        try testing.expect(!model.role_chosen);
    }
}

test "the kiosk refuses every screen its board may not open" {
    for (std.enums.values(nav.Screen)) |screen| {
        if (rbac.allows(boot, screen)) continue;

        var fx = try fakeFx();
        defer fx.deinit();

        var model = main.initialModel();
        main.update(&model, .{ .pick_role = @intFromEnum(boot) }, &fx);
        const before = model.screen();

        main.update(&model, .{ .open_screen = @intCast(screen.index()) }, &fx);

        try testing.expectEqual(before, model.screen());
        try testing.expect(model.error_text.len > 0);
    }
}

test "the shell draws the kitchen rail and the board" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);

    try testing.expect(model.show_shell());
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
    try testing.expectEqual(@as(usize, 1), model.nav_sections().len);

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Kitchen");
}
