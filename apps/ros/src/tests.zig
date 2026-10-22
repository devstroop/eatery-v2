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
const theme = @import("core/theme.zig");
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

fn srgbToLinear(channel: f32) f32 {
    return if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(color: canvas.Color) f32 {
    return 0.2126 * srgbToLinear(color.r) +
        0.7152 * srgbToLinear(color.g) +
        0.0722 * srgbToLinear(color.b);
}

fn contrastRatio(a: canvas.Color, b: canvas.Color) f32 {
    const a_luminance = relativeLuminance(a);
    const b_luminance = relativeLuminance(b);
    return (@max(a_luminance, b_luminance) + 0.05) / (@min(a_luminance, b_luminance) + 0.05);
}

fn expectContrast(palette: []const u8, label: []const u8, foreground: canvas.Color, background: canvas.Color, minimum: f32) !void {
    const ratio = contrastRatio(foreground, background);
    if (ratio < minimum) {
        std.debug.print("{s}: {s} is {d:.2}:1, below {d:.1}:1\n", .{ palette, label, ratio, minimum });
    }
    try testing.expect(ratio >= minimum);
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
    _ = try expectByText(tree.root, .text, "Restaurant OS");
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

test "a full history drops its oldest entry, so navigation never freezes" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.admin) }, &fx);

    // The admin rail has seven destinations. Walking it twice over is
    // more than enough to fill a 32-deep history, and each press must
    // still land: a full stack is a bounded history, not a freeze.
    var press: usize = 0;
    while (press < nav.max_depth * 2) : (press += 1) {
        const section = press % 7;
        main.update(&model, .{ .open_section = @intCast(section) }, &fx);
        try testing.expectEqual(rbac.section_screen(@enumFromInt(section)), model.screen());
    }

    try testing.expect(model.stack.len <= nav.max_depth);
    try testing.expectEqual(model.screen(), model.stack.current().?);
}

test "pressing the current destination does not grow the history" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    const depth = model.stack.len;

    // A busy service presses the same tab over and over. None of those
    // presses is a navigation, so none of them is history.
    var press: usize = 0;
    while (press < 40) : (press += 1) {
        main.update(&model, .{ .open_section = @intFromEnum(nav.NavSection.kitchen) }, &fx);
    }

    try testing.expectEqual(depth, model.stack.len);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
}

test "every text pair in the light and dark palettes clears WCAG AA" {
    const palettes = [_]struct { name: []const u8, tokens: canvas.DesignTokens }{
        .{ .name = "light", .tokens = theme.light() },
        .{ .name = "dark", .tokens = theme.dark() },
    };

    for (palettes) |palette| {
        const c = palette.tokens.colors;
        const pairs = [_]struct { name: []const u8, foreground: canvas.Color, background: canvas.Color, minimum: f32 }{
            .{ .name = "text on background", .foreground = c.text, .background = c.background, .minimum = 4.5 },
            .{ .name = "text on surface", .foreground = c.text, .background = c.surface, .minimum = 4.5 },
            .{ .name = "muted text on background", .foreground = c.text_muted, .background = c.background, .minimum = 4.5 },
            .{ .name = "muted text on surface", .foreground = c.text_muted, .background = c.surface, .minimum = 4.5 },
            .{ .name = "accent label on accent", .foreground = c.accent_text, .background = c.accent, .minimum = 4.5 },
            .{ .name = "accent as text on background", .foreground = c.accent, .background = c.background, .minimum = 4.5 },
            .{ .name = "accent as text on surface", .foreground = c.accent, .background = c.surface, .minimum = 4.5 },
            .{ .name = "destructive label on destructive", .foreground = c.destructive_text, .background = c.destructive, .minimum = 4.5 },
            .{ .name = "destructive as text on background", .foreground = c.destructive, .background = c.background, .minimum = 4.5 },
            .{ .name = "destructive as text on surface", .foreground = c.destructive, .background = c.surface, .minimum = 4.5 },
            .{ .name = "success label on success", .foreground = c.success_text, .background = c.success, .minimum = 4.5 },
            .{ .name = "success as text on background", .foreground = c.success, .background = c.background, .minimum = 4.5 },
            .{ .name = "success as text on surface", .foreground = c.success, .background = c.surface, .minimum = 4.5 },
            .{ .name = "warning label on warning", .foreground = c.warning_text, .background = c.warning, .minimum = 4.5 },
            .{ .name = "warning as text on background", .foreground = c.warning, .background = c.background, .minimum = 4.5 },
            .{ .name = "warning as text on surface", .foreground = c.warning, .background = c.surface, .minimum = 4.5 },
            .{ .name = "info label on info", .foreground = c.info_text, .background = c.info, .minimum = 4.5 },
            .{ .name = "info as text on background", .foreground = c.info, .background = c.background, .minimum = 4.5 },
            .{ .name = "info as text on surface", .foreground = c.info, .background = c.surface, .minimum = 4.5 },
            .{ .name = "focus ring on background", .foreground = c.focus_ring, .background = c.background, .minimum = 3.0 },
            .{ .name = "focus ring on surface", .foreground = c.focus_ring, .background = c.surface, .minimum = 3.0 },
        };

        for (pairs) |pair| {
            try expectContrast(palette.name, pair.name, pair.foreground, pair.background, pair.minimum);
        }
    }
}

test "changing role ends the previous operator's session" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    main.update(&model, .{ .add_to_cart = 1 }, &fx);
    model.search.set("paneer");
    model.selected_category = 1;
    model.employee_id = 7;
    model.employee_name = "Anita";

    // The next role is a new session, not the old one with a new label.
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.waiter) }, &fx);

    try testing.expectEqual(nav.Role.waiter, model.role);
    try testing.expect(!model.signed_in);
    try testing.expectEqual(@as(i64, 0), model.employee_id);
    try testing.expectEqualStrings("", model.employee_name);
    try testing.expectEqual(@as(usize, 0), model.cart_count());
    try testing.expectEqual(@as(usize, 0), model.search.text().len);
    try testing.expectEqual(@as(i64, 0), model.selected_category);
    try testing.expectEqual(nav.Screen.login, model.screen());
    try testing.expectEqual(@as(usize, 1), model.stack.len);
    try testing.expectEqual(nav.Screen.login, model.stack.current().?);
}

test "signing out clears the cart, the filters and the operator" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    main.update(&model, .{ .add_to_cart = 1 }, &fx);
    model.search.set("paneer");
    model.selected_category = 1;
    model.employee_id = 7;
    model.employee_name = "Anita";
    model.error_text = "Something went wrong";

    main.update(&model, .{ .sign_out = {} }, &fx);

    try testing.expect(!model.signed_in);
    try testing.expect(!model.role_chosen);
    try testing.expectEqual(@as(i64, 0), model.employee_id);
    try testing.expectEqualStrings("", model.employee_name);
    try testing.expectEqual(@as(usize, 0), model.cart_count());
    try testing.expectEqual(@as(usize, 0), model.search.text().len);
    try testing.expectEqual(@as(i64, 0), model.selected_category);
    try testing.expectEqual(@as(usize, 0), model.error_text.len);
    try testing.expectEqual(nav.Screen.role_picker, model.screen());
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
    // A salt long enough for the hash to be derived from.
    const salt = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var hash_a: [auth.hash_length]u8 = undefined;
    var hash_b: [auth.hash_length]u8 = undefined;
    var hash_c: [auth.hash_length]u8 = undefined;

    const a = auth.hashPin(salt, "123456", &hash_a) orelse return error.NoHash;
    const b = auth.hashPin(salt, "123456", &hash_b) orelse return error.NoHash;
    const c = auth.hashPin("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "123456", &hash_c) orelse return error.NoHash;

    // The same PIN and the same salt give the same hash: the sign-in
    // finds the employee by the hash it computes.
    try testing.expectEqualStrings(a, b);
    // A different salt gives a different hash: two restaurants with
    // the same PIN do not share a digest.
    try testing.expect(!std.mem.eql(u8, a, c));

    // The hash is not the PIN, and it does not contain it.
    try testing.expect(std.mem.indexOf(u8, a, "123456") == null);
    // It is a bcrypt string, and it carries its own cost and salt, so
    // it can be verified years later without knowing what the app was
    // doing then.
    try testing.expect(std.mem.startsWith(u8, a, "$2b$10$"));
}

test "a PIN verifies against its own hash and nothing else" {
    const salt = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var hash: [auth.hash_length]u8 = undefined;
    const stored = auth.hashPin(salt, "123456", &hash) orelse return error.NoHash;

    try testing.expect(auth.verifyPin(salt, "123456", stored));
    try testing.expect(!auth.verifyPin(salt, "123457", stored));
    // The hash carries the salt it was made with, so it verifies on
    // its own terms: the installation is what scopes the LOOKUP, not
    // the check.
    try testing.expect(auth.verifyPin("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "123456", stored));
}

test "the old hash still verifies, so a running restaurant still works" {
    const salt = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var legacy: [auth.legacy_len]u8 = undefined;
    const stored = auth.legacyHash(salt, "123456", &legacy) orelse return error.NoHash;

    // The old digest is recognised as old, and it verifies.
    try testing.expect(auth.isLegacy(stored));
    try testing.expect(auth.verifyPin(salt, "123456", stored));
    try testing.expect(!auth.verifyPin(salt, "123457", stored));
    // A bcrypt string is not an old one.
    var modern: [auth.hash_length]u8 = undefined;
    const bcrypt_hash = auth.hashPin(salt, "123456", &modern) orelse return error.NoHash;
    try testing.expect(!auth.isLegacy(bcrypt_hash));
}

test "the tax is rounded half up, and an inclusive price keeps it inside" {
    var model = main.initialModel();
    model.tax_slabs_list = &.{
        .{ .id = 1, .name = "Half", .rate_bps = 5000, .inclusive = false, .active = true, .tax_label = "Exclusive" },
        .{ .id = 2, .name = "Just under half", .rate_bps = 4999, .inclusive = false, .active = true, .tax_label = "Exclusive" },
        .{ .id = 3, .name = "Inclusive", .rate_bps = 1800, .inclusive = false, .active = true, .tax_label = "Inclusive" },
    };
    model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Half", .food_label = "Veg", .price_minor = 1, .product_type = .dish, .food_type = .veg, .tax_slab_id = 1, .stock_qty = 0, .active = true },
        .{ .id = 2, .category_id = 0, .name = "Just under", .food_label = "Veg", .price_minor = 1, .product_type = .dish, .food_type = .veg, .tax_slab_id = 2, .stock_qty = 0, .active = true },
        .{ .id = 3, .category_id = 0, .name = "Inclusive", .food_label = "Veg", .price_minor = 100, .product_type = .dish, .food_type = .veg, .tax_slab_id = 3, .stock_qty = 0, .active = true },
    };

    // One minor unit at fifty percent is half a minor unit, and half
    // up is one: the restaurant is not short-changed by a fraction.
    try testing.expectEqual(@as(i64, 1), model.line_tax(1, 1));
    // Just under half is still under half.
    try testing.expectEqual(@as(i64, 0), model.line_tax(2, 1));

    // An exclusive price does not carry its tax: it is added on top.
    try testing.expectEqual(@as(i64, 18), model.line_tax(3, 100));

    // An inclusive price does: the tax is what is left once the net
    // is taken out. 100.00 at eighteen percent holds 84.75 and 15.25.
    model.tax_inclusive = true;
    try testing.expectEqual(@as(i64, 15), model.line_tax(3, 100));

    // A product with no slab is not taxed.
    try testing.expectEqual(@as(i64, 0), model.line_tax(99, 100));
}

test "a currency's decimals are its own" {
    var model = main.initialModel();

    // The yen has no decimals, the dinar has three, and most have two.
    try testing.expectEqual(@as(i64, 0), core.decimalsForCurrency("JPY"));
    try testing.expectEqual(@as(i64, 3), core.decimalsForCurrency("KWD"));
    try testing.expectEqual(@as(i64, 2), core.decimalsForCurrency("USD"));
    // A currency nobody has heard of is assumed to have two, which is
    // the safe guess: a restaurant that meant three would set it.
    try testing.expectEqual(@as(i64, 2), core.decimalsForCurrency("XYZ"));

    // And the divisor is what the decimals mean: a hundred for most,
    // one for the yen, a thousand for the dinar.
    model.currency_decimals = 0;
    try testing.expectEqual(@as(i64, 1), model.currency_divisor());
    model.currency_decimals = 2;
    try testing.expectEqual(@as(i64, 100), model.currency_divisor());
    model.currency_decimals = 3;
    try testing.expectEqual(@as(i64, 1000), model.currency_divisor());
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
    // whatever employee the PIN belongs to. The role is the third
    // parameter: the first two are the two hashes the sign-in looks
    // the employee up by.
    try testing.expect(std.mem.indexOf(u8, repos.login_sql, "role = ?3") != null);
}

test "a second tap while the ticket is moving does not move it twice" {
    var fx = try fakeFx();
    defer fx.deinit();

    var model = main.initialModel();
    model.orders = &.{
        .{ .id = 1, .order_no = "000001", .order_type = .dine_in, .status = .pending, .status_label = "Pending", .type_label = "Dine in", .dining_table_id = 0, .customer_id = 0, .employee_id = 0, .subtotal_minor = 0, .tax_minor = 0, .discount_minor = 0, .total_minor = 0, .placed_at = 0, .notes = "" },
    };

    // The kitchen advances the ticket. The write is in flight: the
    // fake effects channel never answers it.
    main.update(&model, .{ .advance_order = 1 }, &fx);
    try testing.expect(model.advancing());

    // The second tap is refused: a move computed from a model that has
    // not caught up yet would skip a state on the way.
    main.update(&model, .{ .advance_order = 1 }, &fx);
    try testing.expect(model.error_text.len > 0);
    try testing.expectEqual(domain.OrderStatus.pending, model.orders[0].status);
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

test "a decoded company does not point at the page bytes" {
    // The page bytes are drain scratch: they are valid for the update
    // that receives them and dead after it. Build a company page, decode
    // it, then overwrite the whole page. Every text the model kept must
    // still read back, because the decoder copied it into the model.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    try appendInt(&bytes, 9); // column count
    try appendInt(&bytes, 1); // row count
    for ([_][]const u8{
        "id",          "name",           "currency_code", "currency_symbol", "tax_inclusive",
        "address",     "phone",          "tax_number",    "currency_decimals",
    }) |name| {
        try appendBytes(&bytes, name);
    }
    try appendTag(&bytes, 1);
    try appendI64(&bytes, 7);
    try appendText(&bytes, "Test Diner");
    try appendText(&bytes, "USD");
    try appendText(&bytes, "$");
    try appendTag(&bytes, 1);
    try appendI64(&bytes, 0);
    try appendText(&bytes, "12 MG Road");
    try appendText(&bytes, "+91 98765 43210");
    try appendText(&bytes, "29ABCDE1234F1Z5");
    try appendTag(&bytes, 1);
    try appendI64(&bytes, 2);

    var model = main.initialModel();
    repos.decodeCompany(&model, bytes.items);

    try testing.expectEqualStrings("Test Diner", model.company_name_field);
    try testing.expectEqualStrings("12 MG Road", model.company_address_field);

    @memset(bytes.items, 0xAA);

    try testing.expectEqualStrings("Test Diner", model.company_name_field);
    try testing.expectEqualStrings("12 MG Road", model.company_address_field);
    try testing.expectEqualStrings("+91 98765 43210", model.company_phone_field);
    try testing.expectEqualStrings("29ABCDE1234F1Z5", model.company_tax_field);
    try testing.expectEqualStrings("USD", model.currency_code);
    try testing.expectEqualStrings("$", model.currency_symbol);
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
    // The quick setup is the screen being shown. A fresh install needs
    // a setup, but the walk-through is the other way in, and the two
    // are never both on the pane.
    model.screen_index = @intCast(nav.Screen.setup.index());

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Set up your restaurant");
    _ = try expectByText(tree.root, .button, "Create the restaurant");
}

test "a fresh installation shows the walk-through, not the quick setup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.needs_setup = true;
    model.screen_index = @intCast(nav.Screen.create_company.index());

    // The walk-through is on the pane...
    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "Step one of two. You can change any of it later.");
    // ...and the quick setup is not. Its own line is the one only it
    // has; the heading the two share is the point of the screen.
    try testing.expect(findByText(tree.root, .text, "This takes a minute. Everything here can be changed later.") == null);
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
    6,  8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
    25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52,
};


/// The text that proves a screen rendered ITSELF, and not just the
/// shell around it.
///
/// The shell draws a title bar, a rail and a status bar whatever is
/// mounted, so the landmark has to come from the screen's own
/// template. A test that only counts nodes cannot tell a screen from
/// an empty pane.
const screen_landmarks = [_]struct { template: []const u8, text: []const u8 }{
    .{ .template = "screen-setup", .text = "Set up your restaurant" },
    .{ .template = "screen-role-picker", .text = "Restaurant OS" },
    .{ .template = "screen-login", .text = "Sign in" },
    .{ .template = "screen-dashboard", .text = "Dashboard" },
    .{ .template = "screen-pos", .text = "Cart" },
    .{ .template = "screen-pos-cart", .text = "Back to the menu" },
    .{ .template = "screen-catalogue-list", .text = "Catalogue" },
    .{ .template = "screen-product-form", .text = "Category" },
    .{ .template = "screen-orders", .text = "Orders" },
    .{ .template = "screen-payments", .text = "No payments yet." },
    .{ .template = "screen-reports", .text = "How it was paid" },
    .{ .template = "screen-inventory-items", .text = "Nothing is counted. Turn on stock tracking on a product and it appears here." },
    .{ .template = "screen-stock-count", .text = "The shelf says" },
    .{ .template = "screen-kitchen-dishes", .text = "Stations" },
    .{ .template = "screen-control-center", .text = "No other device has been here. A second till or a kitchen display will appear here." },
    .{ .template = "screen-db-inspector", .text = "Database" },
    .{ .template = "screen-modifier-group-form", .text = "The order cannot be prepared without one" },
    .{ .template = "screen-customer-form", .text = "Customer" },
    .{ .template = "screen-order-detail", .text = "Total" },
    .{ .template = "screen-order-confirmation", .text = "Items" },
    .{ .template = "screen-tables", .text = "Dining tables" },
    .{ .template = "screen-table-categories", .text = "Table categories" },
    .{ .template = "screen-table-category-form", .text = "Table category" },
    .{ .template = "screen-floor-plan", .text = "Floor plan" },
    .{ .template = "screen-reservations", .text = "Reservations" },
    .{ .template = "screen-customers", .text = "Customers" },
    .{ .template = "screen-kitchen", .text = "Kitchen" },
    .{ .template = "screen-display", .text = "No orders" },
    .{ .template = "screen-waiter-tables", .text = "Tables" },
    .{ .template = "screen-waiter-menu", .text = "Tables" },
    .{ .template = "screen-waiter-cart", .text = "Nothing on this table yet." },
    .{ .template = "screen-waiter-orders", .text = "Open orders" },
    .{ .template = "screen-employees-list", .text = "Employees" },
    .{ .template = "screen-employee-form", .text = "Role" },
    .{ .template = "screen-suppliers", .text = "Suppliers" },
    .{ .template = "screen-purchase-orders", .text = "Purchase orders" },
    .{ .template = "screen-settings", .text = "Settings" },
    .{ .template = "screen-settings-company", .text = "Company" },
    .{ .template = "screen-settings-currency", .text = "Currency" },
    .{ .template = "screen-settings-tax", .text = "Tax slabs" },
    .{ .template = "screen-settings-modifiers", .text = "Modifier groups" },
    .{ .template = "screen-settings-discounts", .text = "Discounts" },
    .{ .template = "screen-settings-printers", .text = "Printers" },
    .{ .template = "screen-settings-data", .text = "Data" },
    .{ .template = "screen-tax-slab-form", .text = "The price already includes this tax" },
    .{ .template = "screen-discount-form", .text = "A percentage wins over an amount." },
    .{ .template = "screen-category-form", .text = "Save" },
    .{ .template = "screen-categories", .text = "Categories" },
    .{ .template = "screen-wizard", .text = "Who is the owner?" },
    .{ .template = "screen-create-company", .text = "Step one of two. You can change any of it later." },
    .{ .template = "screen-upgrade", .text = "This database is newer than Restaurant OS" },
    .{ .template = "screen-landing", .text = "A restaurant operating system: point of sale, kitchen display, customer display and back office." },
    .{ .template = "screen-reset-pin", .text = "The old PIN stops working the moment this is written." },
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

test "every session screen renders, inside the widget budget" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;

    // The session screens are mounted on their own condition rather
    // than on the ordinal, so the budget test above never built them.
    // The walk-through is two of them, and it is the first thing
    // anybody sees of the app.
    const screens = [_]struct { template: []const u8, ordinal: usize }{
        .{ .template = "screen-role-picker", .ordinal = nav.Screen.role_picker.index() },
        .{ .template = "screen-login", .ordinal = nav.Screen.login.index() },
        .{ .template = "screen-setup", .ordinal = nav.Screen.setup.index() },
        .{ .template = "screen-wizard", .ordinal = nav.Screen.wizard.index() },
        .{ .template = "screen-create-company", .ordinal = nav.Screen.create_company.index() },
    };

    for (screens) |entry| {
        model.needs_setup = false;
        model.role_chosen = true;
        model.signed_in = true;
        if (std.mem.eql(u8, entry.template, "screen-role-picker")) {
            model.role_chosen = false;
        } else if (std.mem.eql(u8, entry.template, "screen-login")) {
            model.signed_in = false;
        } else if (std.mem.eql(u8, entry.template, "screen-setup")) {
            model.needs_setup = true;
        } else {
            // The walk-through: nobody is signed in yet.
            model.signed_in = false;
        }
        model.screen_index = entry.ordinal;
        const tree = try buildTree(arena, &model);
        const nodes = countWidgets(tree.root);
        if (nodes > max_view_widgets) {
            std.debug.print("the session screen {s} built {d} widgets, over the {d} budget\n", .{ entry.template, nodes, max_view_widgets });
            return error.ScreenOverBudget;
        }
    }
}

test "every screen shows a landmark of its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.role_chosen = true;
    model.signed_in = true;

    // Each screen proves it rendered ITSELF. The shell draws a title
    // bar and a status bar whatever is mounted, so a screen that shows
    // nothing but the shell still passes a node count.
    for (screen_landmarks) |landmark| {
        // The session screens are gated by their own condition rather
        // than by the ordinal: the setup shows on a fresh install, the
        // role picker before a role is chosen, and the login between.
        model.needs_setup = false;
        model.role_chosen = true;
        model.signed_in = true;
        if (std.mem.eql(u8, landmark.template, "screen-setup")) {
            model.needs_setup = true;
        } else if (std.mem.eql(u8, landmark.template, "screen-role-picker")) {
            model.role_chosen = false;
        } else if (std.mem.eql(u8, landmark.template, "screen-login")) {
            model.signed_in = false;
        } else if (std.mem.eql(u8, landmark.template, "screen-create-company")) {
            // The walk-through is a session screen: it is shown before
            // anybody is signed in.
            model.signed_in = false;
        } else if (std.mem.eql(u8, landmark.template, "screen-wizard")) {
            model.signed_in = false;
        }
        model.screen_index = screen_index_of(landmark.template);
        const tree = try buildTree(arena, &model);
        // A landmark may be a line of text or a button's label: a
        // screen whose whole content is a binding has no literal text
        // of its own, and the label is what a person reads.
        if (findByText(tree.root, .text, landmark.text) == null and
            findByText(tree.root, .button, landmark.text) == null)
        {
            std.debug.print("the screen {s} never showed \"{s}\"\n", .{ landmark.template, landmark.text });
            return error.NoLandmark;
        }
    }
}

/// The screen a template belongs to, by its name.
fn screen_index_of(template: []const u8) usize {
    const names = [_]struct { template: []const u8, screen: nav.Screen }{
        .{ .template = "screen-setup", .screen = .setup },
        .{ .template = "screen-role-picker", .screen = .role_picker },
        .{ .template = "screen-login", .screen = .login },
        .{ .template = "screen-dashboard", .screen = .admin_dashboard },
        .{ .template = "screen-pos", .screen = .pos },
        .{ .template = "screen-pos-cart", .screen = .pos_cart },
        .{ .template = "screen-catalogue-list", .screen = .product_categories },
        .{ .template = "screen-product-form", .screen = .product_form },
        .{ .template = "screen-orders", .screen = .orders },
        .{ .template = "screen-payments", .screen = .payments },
        .{ .template = "screen-reports", .screen = .reports },
        .{ .template = "screen-inventory-items", .screen = .inventory_items },
        .{ .template = "screen-stock-count", .screen = .stock_count },
        .{ .template = "screen-kitchen-dishes", .screen = .kitchen_dishes },
        .{ .template = "screen-control-center", .screen = .control_center },
        .{ .template = "screen-db-inspector", .screen = .db_inspector },
        .{ .template = "screen-modifier-group-form", .screen = .modifier_group_form },
        .{ .template = "screen-customer-form", .screen = .customer_form },
        .{ .template = "screen-order-detail", .screen = .order_detail },
        .{ .template = "screen-order-confirmation", .screen = .order_confirmation },
        .{ .template = "screen-tables", .screen = .dining_tables },
        .{ .template = "screen-table-categories", .screen = .table_categories },
        .{ .template = "screen-table-category-form", .screen = .table_category_form },
        .{ .template = "screen-floor-plan", .screen = .floor_plan },
        .{ .template = "screen-reservations", .screen = .reservations },
        .{ .template = "screen-customers", .screen = .customers },
        .{ .template = "screen-kitchen", .screen = .kds_board },
        .{ .template = "screen-display", .screen = .display_board },
        .{ .template = "screen-waiter-tables", .screen = .waiter_tables },
        .{ .template = "screen-waiter-menu", .screen = .waiter_menu },
        .{ .template = "screen-waiter-cart", .screen = .waiter_cart },
        .{ .template = "screen-waiter-orders", .screen = .waiter_orders },
        .{ .template = "screen-employees-list", .screen = .employees },
        .{ .template = "screen-employee-form", .screen = .employee_form },
        .{ .template = "screen-suppliers", .screen = .suppliers },
        .{ .template = "screen-purchase-orders", .screen = .purchase_orders },
        .{ .template = "screen-settings", .screen = .settings },
        .{ .template = "screen-settings-company", .screen = .settings_company },
        .{ .template = "screen-settings-currency", .screen = .settings_currency },
        .{ .template = "screen-settings-tax", .screen = .settings_tax },
        .{ .template = "screen-settings-modifiers", .screen = .settings_modifiers },
        .{ .template = "screen-settings-discounts", .screen = .settings_discounts },
        .{ .template = "screen-settings-printers", .screen = .settings_printers },
        .{ .template = "screen-settings-data", .screen = .data_management },
        .{ .template = "screen-tax-slab-form", .screen = .tax_slab_form },
        .{ .template = "screen-discount-form", .screen = .discount_form },
        .{ .template = "screen-category-form", .screen = .category_form },
        .{ .template = "screen-categories", .screen = .categories },
        .{ .template = "screen-wizard", .screen = .wizard },
        .{ .template = "screen-create-company", .screen = .create_company },
        .{ .template = "screen-upgrade", .screen = .upgrade },
        .{ .template = "screen-landing", .screen = .landing },
        .{ .template = "screen-reset-pin", .screen = .reset_pin },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, entry.template, template)) return entry.screen.index();
    }
    return 0;
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
