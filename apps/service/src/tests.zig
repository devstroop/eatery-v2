//! The service app's headless tests.
//!
//! The shared logic - the model, the repository layer, the sign-in - is
//! tested once in `apps/admin`, which runs the superset of the screens.
//! This file tests what the *split* adds: the binary runs one role, the
//! rail is that role's, and a screen the role may not open is refused by
//! the same `rbac.allows` path it always was.

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

test "the service app runs the waiter role, and only that one" {
    try testing.expectEqual(core.AppKind.service, app);
    try testing.expectEqual(nav.Role.waiter, boot);

    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    try testing.expectEqual(nav.Role.waiter, model.role);

    // The back office and the boards are not roles this binary carries.
    for ([_]nav.Role{ .admin, .kds, .display }) |role| {
        main.update(&model, .{ .pick_role = @intFromEnum(role) }, &fx);
        try testing.expectEqual(nav.Role.waiter, model.role);
        try testing.expect(!model.role_chosen);
    }
}

test "the picker offers the people, never the boards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.employees = &.{
        .{ .id = 2, .name = "Ravi", .role = 1, .role_label = "Waiter", .active = true },
    };

    try testing.expect(model.show_people());
    try testing.expect(!model.show_device_cards());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Ravi");
    // A board is not a person, so the service till never offers one.
    try testing.expect(findByText(tree.root, .text, "Kitchen") == null);
    try testing.expect(findByText(tree.root, .text, "Display") == null);
}

test "a person stored for another role cannot sign in here" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.employees = &.{
        .{ .id = 1, .name = "Anita", .role = 0, .role_label = "Admin", .active = true },
    };
    main.update(&model, .{ .pick_employee = 1 }, &fx);

    try testing.expect(!model.role_chosen);
    try testing.expectEqual(nav.Screen.role_picker, model.screen());
    try testing.expect(model.error_text.len > 0);
}

test "the service binary refuses every screen the waiter may not open" {
    for (std.enums.values(nav.Screen)) |screen| {
        if (rbac.allows(boot, screen)) continue;

        var fx = try fakeFx();
        defer fx.deinit();

        var model = main.initialModel();
        model.role_chosen = true;
        model.signed_in = true;
        const before = model.screen();

        main.update(&model, .{ .open_screen = @intCast(screen.index()) }, &fx);

        try testing.expectEqual(before, model.screen());
        try testing.expect(model.error_text.len > 0);
    }
}

test "the shell draws the waiter's rail and its home screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;
    model.employee_id = 2;
    model.employee_name = "Ravi";
    main.update(&model, .{ .open_section = @intFromEnum(nav.NavSection.service) }, &fx);

    try testing.expect(model.show_shell());
    try testing.expectEqual(nav.Screen.waiter_tables, model.screen());
    try testing.expectEqual(@as(usize, 1), model.nav_sections().len);

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "NAVIGATION");
    _ = try expectByText(tree.root, .text, "Ravi");
}

// --------------------------------------------------------- boot pages
//
// A query result arrives as one encoded page: a column count, a row
// count, the column names, then the cells. The boot path reacts to the
// company page, so these two helpers build it and let the waiting
// branch be tested without a database.

const CompanyRow = struct { id: i64, name: []const u8 };

fn putU32(buffer: []u8, at: *usize, value: u32) void {
    std.mem.writeInt(u32, buffer[at.*..][0..4], value, .little);
    at.* += 4;
}

fn putI64(buffer: []u8, at: *usize, value: i64) void {
    std.mem.writeInt(i64, buffer[at.*..][0..8], value, .little);
    at.* += 8;
}

fn putText(buffer: []u8, at: *usize, text: []const u8) void {
    putU32(buffer, at, @intCast(text.len));
    @memcpy(buffer[at.*..][0..text.len], text);
    at.* += text.len;
}

fn putCellInt(buffer: []u8, at: *usize, value: i64) void {
    buffer[at.*] = 1;
    at.* += 1;
    putI64(buffer, at, value);
}

fn putCellText(buffer: []u8, at: *usize, text: []const u8) void {
    buffer[at.*] = 3;
    at.* += 1;
    putText(buffer, at, text);
}

fn companyPage(buffer: []u8, company: ?CompanyRow) []const u8 {
    var at: usize = 0;
    putU32(buffer, &at, 2);
    putU32(buffer, &at, if (company == null) 0 else 1);
    putText(buffer, &at, "id");
    putText(buffer, &at, "name");
    if (company) |row| {
        putCellInt(buffer, &at, row.id);
        putCellText(buffer, &at, row.name);
    }
    return buffer[0..at];
}

// --------------------------------------------------------------- tests

test "a service that starts before the admin waits, then opens its picker" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    var page_buffer: [256]u8 = undefined;

    // Boot finds no company. The admin is the writer, so this binary
    // waits instead of showing the setup wizard and creating a second
    // restaurant whose owner could not even sign in here.
    const empty = companyPage(&page_buffer, null);
    main.update(&model, .{ .company_loaded = .{ .key = 1, .kind = .page, .bytes = empty } }, &fx);
    try testing.expect(model.waiting_for_reference);
    try testing.expect(model.show_waiting());
    try testing.expect(!model.show_role_picker());
    try testing.expect(!model.show_setup());
    try testing.expectEqualStrings("Waiting for the restaurant", model.screen_title());

    // The reference document arrives: the company is here, and the
    // waiter's picker can open.
    const with_company = companyPage(&page_buffer, .{ .id = 1, .name = "Test Diner" });
    main.update(&model, .{ .company_loaded = .{ .key = 2, .kind = .page, .bytes = with_company } }, &fx);
    try testing.expect(!model.waiting_for_reference);
    try testing.expect(!model.show_waiting());
    try testing.expect(model.show_role_picker());
    try testing.expectEqual(@as(i64, 1), model.company_id);

    // Even if the message arrives, the setup is not this binary's to
    // run.
    main.update(&model, .{ .setup_submit = {} }, &fx);
    try testing.expect(model.setup_error.len > 0);
}

test "a waiting terminal says where the restaurant comes from" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    var page_buffer: [256]u8 = undefined;
    const empty = companyPage(&page_buffer, null);
    main.update(&model, .{ .company_loaded = .{ .key = 1, .kind = .page, .bytes = empty } }, &fx);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Waiting for the restaurant");
    _ = try expectByText(tree.root, .text, "No setup is needed here.");
    try testing.expect(findByText(tree.root, .text, "Set up your restaurant") == null);
}
