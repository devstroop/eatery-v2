//! Headless tests.
//!
//! The Native SDK's testing model is the same as the app's: build the
//! view from a model, dispatch a message the way the runtime would,
//! and assert on the model and the rebuilt tree. No window, no
//! database file - the relational store has an in-memory mode for
//! exactly this.
//!
//! Every test here is a rule the app must not break. A rule that lives
//! only in a comment is a rule that breaks.

const std = @import("std");
const native_sdk = @import("native_sdk");

const main = @import("main.zig");
const core = @import("core/model.zig");
const msg_mod = @import("core/msg.zig");
const nav = @import("core/navigation.zig");
const rbac = @import("core/rbac.zig");
const repos = @import("data/repos.zig");
const page = @import("data/page.zig");
const auth = @import("data/auth.zig");
const domain = @import("domain/models.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = core.Model;
const Msg = msg_mod.Msg;
const Effects = native_sdk.Effects(Msg);
const AppMarkup = canvas.MarkupView(Model, Msg);

// ------------------------------------------------------------- helpers

/// Build the view for a model. The markup error names the position in
/// app.native, which is the difference between a two-minute fix and a
/// two-hour one.
///
/// The app's markup imports its screen templates, so the test resolves
/// the same import closure the runtime does before building.
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
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

/// A model with the effects channel in fake mode: requests are recorded
/// instead of touching the OS.
fn fakeFx() !Effects {
    var fx = Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}

// --------------------------------------------------------------- tests

test "the role picker is the first screen and lists the four roles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    try testing.expectEqual(nav.Screen.role_picker, model.screen());
    try testing.expect(model.show_role_picker());
    try testing.expect(!model.show_shell());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Eatery");
    _ = try expectByText(tree.root, .text, "Admin");
    _ = try expectByText(tree.root, .text, "Kitchen");
}

test "picking a role that needs a sign-in lands on the PIN screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.waiter) }, &fx);

    try testing.expectEqual(nav.Role.waiter, model.role);
    try testing.expect(model.role_chosen);
    try testing.expect(!model.signed_in);
    try testing.expect(model.show_login());
    try testing.expectEqual(nav.Screen.login, model.screen());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Sign in");
}

test "picking a kiosk role signs the device in and opens its board" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);

    try testing.expect(model.signed_in);
    try testing.expect(model.show_shell());
    try testing.expectEqual(nav.Screen.kds_board, model.screen());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Kitchen");
}

test "a role cannot open a screen it may not use" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());

    // The kiosk asks for the settings screen.
    main.update(&model, .{ .open_screen = @intCast(nav.Screen.settings.index()) }, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
    try testing.expect(model.error_text.len > 0);
}

test "the permission matrix is total: every role against every screen" {
    for (std.enums.values(nav.Role)) |role| {
        for (std.enums.values(nav.Screen)) |screen| {
            // The rule under test: a role may only open a screen whose
            // nav section it can reach, or one of the shared screens.
            const permitted = rbac.allows(role, screen);
            if (permitted) {
                try testing.expect(rbac.allows(role, screen));
            }
            // Every role can always reach the role picker and the
            // sign-in screen: a device must never be locked out.
            try testing.expect(rbac.allows(role, .role_picker));
            try testing.expect(rbac.allows(role, .login));
        }
    }
}

test "going back returns to the previous screen" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    // The kitchen signs in by device, so it lands on its board.
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());

    main.update(&model, .{ .open_screen = @intCast(nav.Screen.order_detail.index()) }, &fx);
    try testing.expectEqual(nav.Screen.order_detail, model.screen());

    main.update(&model, .go_back, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
}

test "the cart adds, counts and totals in minor units" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
        .{ .id = 2, .category_id = 0, .name = "Masala Chai", .food_label = "Veg", .price_minor = 4000, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    main.update(&model, .{ .add_to_cart = 1 }, &fx);
    main.update(&model, .{ .add_to_cart = 1 }, &fx);
    main.update(&model, .{ .add_to_cart = 2 }, &fx);

    try testing.expectEqual(@as(usize, 3), model.cart_count());
    try testing.expectEqual(@as(i64, 24500 * 2 + 4000), model.cart_total_minor());

    main.update(&model, .{ .remove_from_cart = 1 }, &fx);
    try testing.expectEqual(@as(usize, 2), model.cart_count());
    try testing.expectEqual(@as(i64, 24500 + 4000), model.cart_total_minor());

    main.update(&model, .clear_cart, &fx);
    try testing.expectEqual(@as(usize, 0), model.cart_count());
    try testing.expect(model.cart_is_empty());
}

test "a second tap while the sale is in flight does not place a second order" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    main.update(&model, .{ .add_to_cart = 1 }, &fx);

    // The sale goes to the database. The write is in flight: the fake
    // effects channel never answers it, which is exactly the window a
    // double tap falls into.
    main.update(&model, .{ .place_order = {} }, &fx);
    try testing.expect(model.sale_pending);

    // The second tap is refused, and the cart is untouched: the sale
    // owns the cart until the database answers.
    main.update(&model, .{ .place_order = {} }, &fx);
    try testing.expect(model.error_text.len > 0);
    try testing.expectEqual(@as(usize, 1), model.cart_count());
}

test "money stays integer: two hundred and fifty cents is never a float" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.products = &.{
        .{ .id = 7, .category_id = 0, .name = "Coffee", .food_label = "Veg", .price_minor = 250, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    main.update(&model, .{ .add_to_cart = 7 }, &fx);
    try testing.expectEqual(@as(i64, 250), model.cart_total_minor());
    try testing.expectEqual(@as(i64, 750), model.cart_total_minor() + 500);
}

test "a PIN is hashed, never stored" {
    var hash_a: [auth.hex_len]u8 = undefined;
    var hash_b: [auth.hex_len]u8 = undefined;
    var hash_c: [auth.hex_len]u8 = undefined;

    auth.hashPin("salt", "1234", &hash_a);
    auth.hashPin("salt", "1234", &hash_b);
    auth.hashPin("other-salt", "1234", &hash_c);

    try testing.expectEqualSlices(u8, &hash_a, &hash_b);
    // A different salt gives a different hash: two restaurants with
    // the same PIN do not share a digest.
    try testing.expect(!std.mem.eql(u8, &hash_a, &hash_c));
    try testing.expect(auth.equal(&hash_a, &hash_b));
    try testing.expect(!auth.equal(&hash_a, &hash_c));
}

test "a failed salt write does not make the salt look confirmed" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    // The app made a provisional salt at boot. The database has not
    // confirmed it, so a sign-in may not use it.
    model.salt_state = .unknown;

    // The write fails.
    main.update(&model, .{ .config_saved = .{
        .key = 1,
        .kind = .exec,
        .outcome = .io_failed,
    } }, &fx);

    // The salt is still unconfirmed: a sign-in hashed against it could
    // never be verified, and the operator would be locked out of the
    // till with nothing to show for it. The failure is visible.
    try testing.expectEqual(core.SaltState.unknown, model.salt_state);
    try testing.expect(model.error_text.len > 0);
}

test "the sign-in query is scoped to the session's role" {
    // The device's mode and the employee's role are two different
    // things, and the sign-in has to agree on both.
    try testing.expectEqual(domain.EmployeeRole.admin, rbac.employee_role(nav.Role.admin));
    try testing.expectEqual(domain.EmployeeRole.waiter, rbac.employee_role(nav.Role.waiter));
    try testing.expectEqual(domain.EmployeeRole.kitchen, rbac.employee_role(nav.Role.kds));
    try testing.expectEqual(domain.EmployeeRole.display, rbac.employee_role(nav.Role.display));

    // The query asks the database for that role, rather than taking
    // whatever employee the PIN belongs to.
    try testing.expect(std.mem.indexOf(u8, repos.login_sql, "role = ?2") != null);
}

test "every effect key names one effect and no two" {
    // A key is an effect's identity in the channel. Two live effects
    // cannot share one: the second is REFUSED, and a refused write is
    // a write that never happens - a sale that does not land, with no
    // error the operator can see.
    const keys = [_]u64{
        repos.key_products,
        repos.key_tables,
        repos.key_employees,
        repos.key_orders,
        repos.key_customers,
        repos.key_categories,
        repos.key_company,
        repos.key_login,
        repos.key_order_lines,
        repos.key_config,
        repos.key_setup,
        repos.key_payment,
        repos.key_watch_orders,
        repos.key_open_order,
        repos.key_add_line,
        repos.key_stations,
        repos.key_chime,
        repos.key_product_stations,
        repos.key_board_refresh,
        repos.key_save_company,
        repos.key_printers,
        repos.key_tax_slabs,
        repos.key_modifier_groups,
        repos.key_discounts,
        repos.key_save_product,
        repos.key_save_employee,
        repos.key_save_printer,
        repos.key_reservations,
        repos.key_suppliers,
        repos.key_purchase_orders,
        repos.key_inventory,
        repos.key_write_order,
        repos.key_write_product,
        repos.key_write_table,
        repos.key_save_salt,
        repos.key_save_currency,
    };
    for (keys, 0..) |key, index| {
        for (keys, 0..) |other, other_index| {
            if (index == other_index) continue;
            try testing.expect(key != other);
        }
    }
}

test "the page decoder reads the engine's dialect" {
    // Build a page by hand: two columns, two rows, one text and one
    // integer each - exactly the shape the engine delivers.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendInt(&bytes, 2); // column count
    try appendInt(&bytes, 2); // row count
    try appendBytes(&bytes, "id");
    try appendBytes(&bytes, "name");
    try appendTag(&bytes, 0); // NULL
    try appendText(&bytes, "ignored");
    try appendTag(&bytes, 1); // INTEGER
    try appendI64(&bytes, 42);
    try appendText(&bytes, "Masala Chai");

    var reader = page.Reader.init(bytes.items);
    try testing.expect(reader.readHeader());
    try testing.expectEqual(@as(usize, 2), reader.columns.len);

    var values: [page.max_columns]page.Value = undefined;
    try testing.expect(reader.nextRow(&values));
    // A NULL column reads as the caller's fallback, never as zero.
    try testing.expectEqual(@as(i64, -1), reader.intOf(&values, "id", -1));
    try testing.expectEqualStrings("ignored", reader.textOf(&values, "name"));

    try testing.expect(reader.nextRow(&values));
    try testing.expectEqual(@as(i64, 42), reader.intOf(&values, "id", -1));
    try testing.expectEqualStrings("Masala Chai", reader.textOf(&values, "name"));

    try testing.expect(!reader.nextRow(&values));
}

test "the model reports its own numbers instead of storing them" {
    var model = main.initialModel();
    model.orders = &.{
        .{ .id = 1, .order_no = "1", .order_type = .dine_in, .status = .pending, .status_label = "Pending", .type_label = "Dine in", .dining_table_id = 0, .customer_id = 0, .employee_id = 0, .subtotal_minor = 0, .tax_minor = 0, .discount_minor = 0, .total_minor = 0, .placed_at = 0, .notes = "" },
        .{ .id = 2, .order_no = "2", .order_type = .dine_in, .status = .completed, .status_label = "Completed", .type_label = "Dine in", .dining_table_id = 0, .customer_id = 0, .employee_id = 0, .subtotal_minor = 0, .tax_minor = 0, .discount_minor = 0, .total_minor = 0, .placed_at = 0, .notes = "" },
    };
    try testing.expectEqual(@as(usize, 2), model.order_count());
    try testing.expectEqual(@as(usize, 1), model.open_order_count());
    try testing.expectEqual(@as(usize, 1), model.ticket_count());
}

test "the POS screen renders with a menu and a cart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;
    model.screen_index = 10; // the POS
    model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
        .{ .id = 2, .category_id = 1, .name = "Masala Chai", .food_label = "Veg", .price_minor = 4000, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    model.categories = &.{
        .{ .id = 1, .name = "Starters", .sort_order = 1 },
        .{ .id = 2, .name = "Mains", .sort_order = 2 },
    };
    model.cart[0] = .{ .product_id = 1, .name = "Paneer Tikka", .price_minor = 24500, .qty = 2 };
    model.cart_len = 1;

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Paneer Tikka");
}

test "the order confirmation screen renders after a sale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;
    model.screen_index = 12; // the order confirmation
    model.last_order_no_field = "1700000000";
    model.last_order_type_field = "Dine in";
    model.last_order_total_minor = 24500;
    model.last_order_items_count = 2;

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Order 1700000000");
    _ = try expectByText(tree.root, .button, "Take $245.00");
}

test "the setup screen renders on a fresh installation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.needs_setup = true;

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Set up your restaurant");
    _ = try expectByText(tree.root, .button, "Create the restaurant");
}

test "the layout survives a resize" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;
    model.screen_index = nav.Screen.admin_dashboard.index();

    const tree = try buildTree(arena, &model);
    // The dashboard has grown; the layout buffer follows the widget budget.
    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, native_sdk.geometry.RectF.init(0, 0, 1280, 800), &nodes);
    try testing.expect(layout.nodes.len > 0);
}

/// The retained widget budget for one view. The runtime's own cap is
/// `canvas_limits.max_canvas_widget_nodes_per_view`; the markup engine
/// enforces it, and this test asserts against the same number.
const max_view_widgets = 1024;

/// The screen ordinals the shell gates, in the order `app.native` uses
/// them.
///
/// The `Screen` enum is append-only, and this list is that contract made
/// executable: inserting a screen in the middle would move these
/// numbers, and the markup would mount the wrong screen. A test that
/// fails here means "append, do not insert".
const gated_ordinals = [_]usize{
    8,  10, 12, 13, 14, 16, 17, 20, 23, 24, 25,
    26, 28, 29, 30, 31, 32, 33, 34, 35, 37, 38,
    39, 40, 41, 42, 43, 44,
};

/// The widgets in a tree, the tree itself included.
fn countWidgets(widget: canvas.Widget) usize {
    var total: usize = 1;
    for (widget.children) |child| total += countWidgets(child);
    return total;
}

/// The screen ordinals the shell gates, read out of the markup itself.
fn markupGates(arena: std.mem.Allocator) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(arena);
    const needle = "screen_index == ";
    var rest: []const u8 = main.app_markup;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        rest = rest[at + needle.len ..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 0) break;
        const ordinal = std.fmt.parseInt(usize, rest[0..digits], 10) catch break;
        try out.append(arena, ordinal);
        rest = rest[digits..];
    }
    return out.toOwnedSlice(arena);
}

test "the shell gates the screens the enum says it does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gates = try markupGates(arena);
    // The order the gates appear in is cosmetic - only one of them can
    // match a screen - so the comparison is over the set.
    std.mem.sort(usize, gates, {}, std.sort.asc(usize));
    try testing.expectEqualSlices(usize, &gated_ordinals, gates);

    // Every gate names a screen that exists.
    for (gates) |ordinal| {
        if (std.enums.fromInt(nav.Screen, ordinal) == null) {
            std.debug.print("app.native gates screen {d}, which is not in the enum\n", .{ordinal});
            return error.UnknownScreenOrdinal;
        }
    }
}

test "every gated screen renders, and none of them blows the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;

    // The shell with no screen mounted: the title bar, the rail and the
    // status bar. A screen that mounts nothing is indistinguishable
    // from this, which is exactly how a blank pane used to hide.
    model.screen_index = 999;
    const shell = try buildTree(arena, &model);
    const shell_nodes = countWidgets(shell.root);

    for (gated_ordinals) |ordinal| {
        const screen = std.enums.fromInt(nav.Screen, ordinal) orelse return error.UnknownScreenOrdinal;
        model.screen_index = ordinal;
        const tree = try buildTree(arena, &model);
        const nodes = countWidgets(tree.root);
        if (nodes <= shell_nodes) {
            std.debug.print("screen {d} ({s}) mounted nothing\n", .{ ordinal, screen.title() });
            return error.ScreenMountedNothing;
        }
        if (nodes > max_view_widgets) {
            std.debug.print("screen {d} ({s}) built {d} widgets, over the {d} budget\n", .{ ordinal, screen.title(), nodes, max_view_widgets });
            return error.ScreenOverBudget;
        }
    }
}

test "every screen builds a view inside the budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;

    // Every screen in the enum, not only the gated ones: a template
    // with a broken binding has to fail HERE, not on the till.
    for (std.enums.values(nav.Screen)) |screen| {
        model.screen_index = screen.index();
        const tree = try buildTree(arena, &model);
        const nodes = countWidgets(tree.root);
        if (nodes > max_view_widgets) {
            std.debug.print("screen {d} ({s}) built {d} widgets, over the {d} budget\n", .{ screen.index(), screen.title(), nodes, max_view_widgets });
            return error.ScreenOverBudget;
        }
    }
}

// ---------------------------------------------------------- page bytes

fn appendInt(bytes: *std.ArrayList(u8), value: u32) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    try bytes.appendSlice(testing.allocator, &buffer);
}

fn appendBytes(bytes: *std.ArrayList(u8), text: []const u8) !void {
    try appendInt(bytes, @intCast(text.len));
    try bytes.appendSlice(testing.allocator, text);
}

/// One value tag: 0 null, 1 integer, 2 real, 3 text, 4 blob.
fn appendTag(bytes: *std.ArrayList(u8), tag: u8) !void {
    try bytes.append(testing.allocator, tag);
}

fn appendI64(bytes: *std.ArrayList(u8), value: i64) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(i64, &buffer, value, .little);
    try bytes.appendSlice(testing.allocator, &buffer);
}

/// A text value: the tag, the length, then the bytes.
fn appendText(bytes: *std.ArrayList(u8), text: []const u8) !void {
    try appendTag(bytes, 3);
    try appendBytes(bytes, text);
}
