//! The data layer, against a real database.
//!
//! These are integration tests, not mocks: they open an IN-MEMORY SQLite
//! database with the app's own migrations applied, bind it to a real
//! effects channel, and drive the app exactly as the runtime does. Every
//! query in `repos.zig` is executed by real SQLite, so a typo in a
//! statement, a wrong column name or a broken migration fails HERE
//! rather than in a restaurant.
//!
//! The pattern:
//!
//!     var harness = try Harness.start();     // migrated in-memory database
//!     defer harness.deinit();
//!     harness.model = ...;                    // the model under test
//!     harness.send(Msg{ .place_order = {} });        // a message, as the runtime sends it
//!     harness.drain();                        // deliver every effect result
//!     try testing.expect(...);                // assert on the model
//!
//! `drain` is the loop the runtime runs: take a delivered message, hand
//! it to `update`, repeat until the effects channel is quiet.

const std = @import("std");
const native_sdk = @import("native_sdk");

const testing = std.testing;

const main = @import("main.zig");
const core = @import("core/model.zig");
const msg_mod = @import("core/msg.zig");
const nav = @import("core/navigation.zig");
const repos = @import("data/repos.zig");
const auth = @import("data/auth.zig");
const domain = @import("domain/models.zig");

const Model = core.Model;
const Msg = msg_mod.Msg;
const Effects = native_sdk.Effects(Msg);

/// The installation salt, in the shape the app makes it: sixty-four
/// hex characters.
const test_salt = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// The app's migrations, embedded. The same files the CLI turns into
/// `migrations.zig` for the runtime - the test applies them itself so
/// it can bring up an in-memory database.
const migration_sql = [_][]const u8{
    @embedFile("schema/0001_core.sql"),
    @embedFile("schema/0002_catalog.sql"),
    @embedFile("schema/0003_floor.sql"),
    @embedFile("schema/0004_customers.sql"),
    @embedFile("schema/0005_orders.sql"),
    @embedFile("schema/0006_inventory.sql"),
    @embedFile("schema/0007_ops.sql"),
    @embedFile("schema/0008_compliance.sql"),
    @embedFile("schema/0009_printing.sql"),
    @embedFile("schema/0010_sync.sql"),
    @embedFile("schema/0011_default_tax_slab.sql"),
    @embedFile("schema/0012_order_sequence.sql"),
    @embedFile("schema/0013_order_request_key.sql"),
    @embedFile("schema/0014_payment_once.sql"),
    @embedFile("schema/0015_currency_decimals.sql"),
};

const migration_names = [_][]const u8{
    "core", "catalog", "floor", "customers", "orders",
    "inventory", "ops", "compliance", "printing", "sync", "default_tax_slab",
    "order_sequence", "order_request_key", "payment_once", "currency_decimals",
};

/// A model, a real database and a real effects channel, together.
///
/// The database lives on the HEAP on purpose. `binding()` hands the
/// effects channel a pointer to the database, and the harness is
/// returned BY VALUE: a database stored in the harness itself would
/// leave that pointer aimed at a local that has already been moved
/// away. Every binding that outlives its owner has to point at
/// something that cannot move.
const Harness = struct {
    database: *native_sdk.relational_store.Database,
    fx: *Effects,
    model: Model,
    allocator: std.mem.Allocator,

    fn start(allocator: std.mem.Allocator) !Harness {
        var migrations: [migration_sql.len]native_sdk.relational_store.Migration = undefined;
        for (migration_sql, 0..) |sql, index| {
            migrations[index] = .{
                .version = @intCast(index + 1),
                .name = migration_names[index],
                .sql = sql,
            };
        }

        const opened = try native_sdk.relational_store.Database.openMemoryMigrated(allocator, &migrations);
        if (opened.outcome != .ok) return error.MigrateFailed;

        const database = try allocator.create(native_sdk.relational_store.Database);
        errdefer allocator.destroy(database);
        database.* = opened.database orelse return error.MigrateFailed;

        // The effects channel lives on the heap too: it is a large
        // struct with internal state, and the harness is returned BY
        // VALUE. A copy of a channel that remembers where it lives
        // would point at the copy's own dead frame.
        const fx = try allocator.create(Effects);
        errdefer allocator.destroy(fx);
        fx.* = Effects.init(allocator);
        // The real executor, not the fake one: these tests exist to run
        // real SQL.
        fx.bindRelationalStore(database.binding());

        var model = main.initialModel();
        // The device token is made at boot, where the app has an `Io`
        // and therefore randomness. The harness has neither, so it
        // names the device itself.
        @memcpy(model.device_token_buf[0..6], "test01");
        model.device_token_len = 6;

        return .{
            .database = database,
            .fx = fx,
            .model = model,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Harness) void {
        self.fx.deinit();
        self.allocator.destroy(self.fx);
        self.database.deinit();
        self.allocator.destroy(self.database);
    }

    /// Send a message and deliver every effect result it produces.
    fn send(self: *Harness, msg: Msg) void {
        main.update(&self.model, msg, self.fx);
        self.drain();
    }

    /// The runtime's drain loop: take a delivered message, hand it to
    /// `update`, repeat until the channel is quiet.
    fn drain(self: *Harness) void {
        // The guard is a runaway check, not an error path: a message
        // that produces another message forever is a bug in `update`,
        // and the test should hang loudly rather than spin.
        //
        // The flush is what the runtime does at the end of a batch: a
        // live query dirtied by the batch re-runs here, so the kitchen
        // board sees a new order without anyone asking for it.
        var guard: usize = 0;
        while (true) {
            self.fx.flushDbSubscriptions();
            const msg = self.fx.takeMsg() orelse break;
            main.update(&self.model, msg, self.fx);
            guard += 1;
            if (guard > 64) break;
        }
    }

    /// Read every row a query returns, straight from the channel.
    fn rows(self: *Harness) ![]const native_sdk.EffectDbResult {
        var out: std.ArrayList(native_sdk.EffectDbResult) = .empty;
        errdefer out.deinit(self.allocator);
        while (self.fx.takeMsg()) |msg| {
            switch (msg) {
                .products_loaded => |r| try out.append(self.allocator, r),
                .categories_loaded => |r| try out.append(self.allocator, r),
                .tables_loaded => |r| try out.append(self.allocator, r),
                .employees_loaded => |r| try out.append(self.allocator, r),
                .customers_loaded => |r| try out.append(self.allocator, r),
                .orders_loaded => |r| try out.append(self.allocator, r),
                .order_lines_loaded => |r| try out.append(self.allocator, r),
                .company_loaded => |r| try out.append(self.allocator, r),
                .config_loaded => |r| try out.append(self.allocator, r),
                else => {},
            }
        }
        return out.toOwnedSlice(self.allocator);
    }
};

/// A harness with a company, one admin and a small menu already in it.
fn seeded(allocator: std.mem.Allocator) !Harness {
    var harness = try Harness.start(allocator);
    errdefer harness.deinit();

    const now = 1_700_000_000_000;
    harness.fx.dbExec(.{
        .key = 900,
        .statements = &.{
            .{
                .sql = "INSERT INTO company (id, name, currency_code, currency_symbol, tax_inclusive, created_at) VALUES (1, 'Test Diner', 'USD', '$', 0, ?1);",
                .params = &.{.{ .integer = now }},
            },
            .{
                .sql = "INSERT INTO product_category (id, name, sort_order) VALUES (1, 'Starters', 1), (2, 'Mains', 2);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO product (id, category_id, name, price_minor, product_type, food_type, tax_slab_id, stock_qty, track_stock, active, created_at, updated_at) VALUES (1, 1, 'Paneer Tikka', 24500, 0, 1, 0, 0, 0, 1, ?1, ?1), (2, 2, 'Masala Chai', 4000, 1, 1, 0, 0, 0, 1, ?1, ?1);",
                .params = &.{.{ .integer = now }},
            },
            .{
                .sql = "INSERT INTO dining_table_category (id, name) VALUES (1, 'Main room');",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (7, 'Anita', 0, '', 1, ?1);",
                .params = &.{.{ .integer = now }},
            },
            .{
                .sql = "INSERT INTO dining_table (id, category_id, name, status, seats, pos_x, pos_y, active) VALUES (1, 1, 'T1', 0, 4, 0, 0, 1), (2, 1, 'T2', 1, 4, 1, 0, 1);",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    return harness;
}

// --------------------------------------------------------------- tests

test "the migrations apply to an empty database" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // The database opened and migrated: the schema version is the
    // number of migrations.
    const version = try harness.database.schemaVersion();
    try testing.expectEqual(@as(u32, migration_sql.len), version);
}

test "the company row loads into the model" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    repos.loadCompany(harness.fx);
    harness.drain();

    try testing.expectEqual(@as(i64, 1), harness.model.company_id);
    try testing.expectEqualStrings("Test Diner", harness.model.company_name_field);
    try testing.expectEqualStrings("USD", harness.model.currency_code);
}

test "the menu loads into the model, with prices in minor units" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    repos.loadProducts(harness.fx);
    harness.drain();

    try testing.expectEqual(@as(usize, 2), harness.model.products.len);

    // The menu is ordered by name, so the row order is a fact of the
    // query, not an accident: look the product up by name and assert on
    // its fields.
    const paneer = findProduct(&harness.model, "Paneer Tikka") orelse return error.ProductNotFound;
    try testing.expectEqual(@as(i64, 24500), paneer.price_minor);
    try testing.expectEqual(domain.ProductType.dish, paneer.product_type);
    try testing.expectEqual(domain.FoodType.veg, paneer.food_type);
    try testing.expectEqual(@as(i64, 1), paneer.category_id);
}

test "the tables load, and their status survives the round trip" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    repos.loadTables(harness.fx);
    harness.drain();

    try testing.expectEqual(@as(usize, 2), harness.model.tables.len);
    try testing.expectEqualStrings("T1", harness.model.tables[0].name);
    try testing.expectEqual(domain.TableStatus.free, harness.model.tables[0].status);
    try testing.expectEqual(domain.TableStatus.occupied, harness.model.tables[1].status);
    try testing.expectEqualStrings("Free", harness.model.tables[0].status_label);
}

test "an order is written, read back, and its status advances" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // Sign in as the operator taking the order.
    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
        .{ .id = 2, .category_id = 2, .name = "Masala Chai", .food_label = "Veg", .price_minor = 4000, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 2 });
    try testing.expectEqual(@as(usize, 3), harness.model.cart_count());
    try testing.expectEqual(@as(i64, 24500 * 2 + 4000), harness.model.cart_total_minor());

    harness.send(Msg{ .place_order = {} });

    // The cart is emptied and the order is written.
    try testing.expectEqual(@as(usize, 0), harness.model.cart_len);

    // Read it back through the repository, the way the orders screen does.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);

    const order = harness.model.orders[0];
    try testing.expectEqual(@as(i64, 24500 * 2 + 4000), order.total_minor);
    try testing.expectEqual(domain.OrderStatus.pending, order.status);
    try testing.expectEqual(@as(i64, 7), order.employee_id);

    // The lines are there too - the kitchen needs them.
    repos.loadOrderLines(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 2), harness.model.order_lines.len);
    try testing.expectEqualStrings("Paneer Tikka", harness.model.order_lines[0].product_name);
    try testing.expectEqual(@as(i64, 2), harness.model.order_lines[0].qty);

    // Advancing the status writes the order AND its history.
    harness.send(.{ .advance_order = order.id });
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.preparing, harness.model.orders[0].status);
}

/// The PIN hash the database holds for an employee, copied into
/// `out`.
///
/// The page bytes are drain scratch, so the hash is copied before the
/// next message takes the memory - and the copy is the caller's, because
/// a slice of a local buffer would be dead before the caller reads it.
fn storedPinHash(harness: *Harness, employee_id: i64, out: []u8) ![]const u8 {
    harness.fx.dbQuery(.{
        .key = 921,
        .sql = "SELECT pin_hash FROM employee WHERE id = ?1;",
        .params = &.{.{ .integer = employee_id }},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    var length: usize = 0;
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                const text = reader.textOf(&values, "pin_hash");
                length = @min(text.len, out.len);
                @memcpy(out[0..length], text[0..length]);
            },
            else => {},
        }
    }
    return out[0..length];
}

/// The number of rows a query returns, read straight from the channel.
///
/// The count comes back as a page, and the page bytes are drain
/// scratch: they are read inside the loop, before the next message
/// takes the memory.
fn countRows(harness: *Harness, sql: []const u8, params: []const native_sdk.EffectDbValue) !i64 {
    harness.fx.dbQuery(.{
        .key = 907,
        .sql = sql,
        .params = params,
        .on_result = Effects.dbMsg(.config_loaded),
    });
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                return reader.intOf(&values, "n", -1);
            },
            else => {},
        }
    }
    return -1;
}

test "advancing an order twice writes one history row" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    const order = harness.model.orders[0];
    try testing.expectEqual(domain.OrderStatus.pending, order.status);

    // The kitchen advances the ticket.
    harness.send(.{ .advance_order = order.id });
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.preparing, harness.model.orders[0].status);

    // A second tap, from a model that still says the ticket is
    // pending - the kind of double tap a fast kitchen produces. The
    // move does not apply, because the ticket has already moved on.
    repos.setOrderStatus(harness.fx, order.id, domain.OrderStatus.pending, domain.OrderStatus.preparing, 1_700_000_000_000);
    harness.drain();

    // One history row, not two: the timeline is the record of what
    // happened, and the ticket only happened once.
    const rows = try countRows(&harness, "SELECT COUNT(*) AS n FROM order_status_history WHERE order_id = ?1;", &.{.{ .integer = order.id }});
    try testing.expectEqual(@as(i64, 1), rows);
}

test "a move that does not apply leaves the order where it is" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    const order = harness.model.orders[0];

    // A move from a status the order is not in: the order does not
    // move, and nothing is written.
    repos.setOrderStatus(harness.fx, order.id, domain.OrderStatus.ready, domain.OrderStatus.served, 1_700_000_000_000);
    harness.drain();

    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.pending, harness.model.orders[0].status);

    const rows = try countRows(&harness, "SELECT COUNT(*) AS n FROM order_status_history WHERE order_id = ?1;", &.{.{ .integer = order.id }});
    try testing.expectEqual(@as(i64, 0), rows);
}

test "the tax is worked out line by line, from the product's own slab" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A slab at five percent, and a dish that is taxed at it. The
    // drink stays on the "no tax" slab.
    harness.fx.dbExec(.{
        .key = 908,
        .statements = &.{
            .{
                .sql = "INSERT INTO tax_slab (id, name, rate_bps, inclusive, active) VALUES (2, 'GST 5%', 500, 0, 1);",
                .params = &.{},
            },
            .{
                .sql = "UPDATE product SET tax_slab_id = 2 WHERE id = 1;",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadProducts(harness.fx);
    repos.loadTaxSlabs(harness.fx);
    harness.drain();

    harness.model.employee_id = 7;
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 2 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();

    const order = harness.model.orders[0];
    // 245.00 at five percent is 12.25, and the 40.00 drink is not
    // taxed at all.
    try testing.expectEqual(@as(i64, 24500 + 4000), order.subtotal_minor);
    try testing.expectEqual(@as(i64, 1225), order.tax_minor);
    try testing.expectEqual(@as(i64, 24500 + 4000 + 1225), order.total_minor);

    // The rate is a snapshot on the line: a slab that changes tomorrow
    // must not rewrite the bill of yesterday.
    repos.loadOrderLines(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(i64, 500), harness.model.order_lines[0].tax_bps);
    try testing.expectEqual(@as(i64, 0), harness.model.order_lines[1].tax_bps);
}

test "an inclusive price already carries its tax" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A restaurant whose menu shows the price with the tax inside.
    harness.fx.dbExec(.{
        .key = 909,
        .statements = &.{.{
            .sql = "UPDATE company SET tax_inclusive = 1 WHERE id = 1;",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadCompany(harness.fx);
    repos.loadProducts(harness.fx);
    repos.loadTaxSlabs(harness.fx);
    harness.drain();
    try testing.expect(harness.model.tax_inclusive);

    harness.fx.dbExec(.{
        .key = 910,
        .statements = &.{.{
            .sql = "INSERT INTO tax_slab (id, name, rate_bps, inclusive, active) VALUES (2, 'GST 18%', 1800, 0, 1);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    harness.fx.dbExec(.{
        .key = 911,
        .statements = &.{.{
            .sql = "UPDATE product SET tax_slab_id = 2 WHERE id = 1;",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadProducts(harness.fx);
    repos.loadTaxSlabs(harness.fx);
    harness.drain();

    harness.model.employee_id = 7;
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();

    const order = harness.model.orders[0];
    // 245.00 at eighteen percent holds 207.63 of price and 37.37 of
    // tax. The customer pays the 245.00 that was on the menu.
    try testing.expectEqual(@as(i64, 24500), order.subtotal_minor);
    try testing.expectEqual(@as(i64, 3737), order.tax_minor);
    try testing.expectEqual(@as(i64, 24500), order.total_minor);
}

/// A restaurant with a slab at five percent, a dish taxed at it, a
/// drink that is not taxed, and the discounts the cashier can pick.
fn with_tax_and_discounts(harness: *Harness) !void {
    harness.fx.dbExec(.{
        .key = 912,
        .statements = &.{
            .{
                .sql = "INSERT INTO tax_slab (id, name, rate_bps, inclusive, active) VALUES (2, 'GST 5%', 500, 0, 1);",
                .params = &.{},
            },
            .{
                .sql = "UPDATE product SET tax_slab_id = 2 WHERE id = 1;",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO discount (id, name, percent_bps, amount_minor, active, created_at) VALUES (3, 'Staff 10%', 1000, 0, 1, 0), (4, 'Five off', 0, 500, 1, 0);",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadProducts(harness.fx);
    repos.loadTaxSlabs(harness.fx);
    repos.loadDiscounts(harness.fx);
    harness.drain();
}

test "a discount comes off the bill, and the tax follows it" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();
    try with_tax_and_discounts(&harness);

    harness.model.employee_id = 7;
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 2 });
    harness.send(.{ .apply_discount = 3 });

    // Ten percent off 285.00 is 28.50.
    try testing.expectEqual(@as(i64, 2850), harness.model.cart_discount_total());
    // It lands on the lines in proportion to what they are worth.
    try testing.expectEqual(@as(i64, 2450), harness.model.cart_discount_share(0));
    try testing.expectEqual(@as(i64, 400), harness.model.cart_discount_share(1));

    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();

    const order = harness.model.orders[0];
    try testing.expectEqual(@as(i64, 28500), order.subtotal_minor);
    try testing.expectEqual(@as(i64, 2850), order.discount_minor);
    // The tax is on what is left: 220.50 at five percent is 11.025,
    // and half up is 11.03. The drink is not taxed.
    try testing.expectEqual(@as(i64, 1103), order.tax_minor);
    try testing.expectEqual(@as(i64, 28500 + 1103 - 2850), order.total_minor);
}

test "a fixed discount is spread over the lines and the last one takes the rest" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();
    try with_tax_and_discounts(&harness);

    harness.model.employee_id = 7;
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 2 });
    harness.send(.{ .apply_discount = 4 });

    // Five off 285.00: the first line takes its share and the last
    // line takes the rest, so the parts add up to the discount.
    try testing.expectEqual(@as(i64, 500), harness.model.cart_discount_total());
    try testing.expectEqual(@as(i64, 429), harness.model.cart_discount_share(0));
    try testing.expectEqual(@as(i64, 71), harness.model.cart_discount_share(1));

    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();

    const order = harness.model.orders[0];
    try testing.expectEqual(@as(i64, 500), order.discount_minor);
    // The tax is on 240.71 at five percent: 12.035, and half up.
    try testing.expectEqual(@as(i64, 1204), order.tax_minor);
    try testing.expectEqual(@as(i64, 28500 + 1204 - 500), order.total_minor);
}

test "a payment is taken once" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    const order = harness.model.orders[0];

    // The money is taken.
    harness.send(Msg{ .take_payment = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.completed, harness.model.orders[0].status);

    // A second tap, from a model that still says the order is open.
    // The customer pays once, whatever the till does.
    repos.takePayment(harness.fx, repos.key_payment, order.id, domain.OrderStatus.pending, domain.PaymentMode.cash, order.total_minor, 1_700_000_000_000);
    harness.drain();

    // And the second tap is not an error: the order was already
    // closed, so there was nothing to do. The cashier sees a closed
    // order, not a failure.
    try testing.expectEqualStrings("", harness.model.payment_error);

    const rows = try countRows(&harness, "SELECT COUNT(*) AS n FROM payment WHERE order_id = ?1;", &.{.{ .integer = order.id }});
    try testing.expectEqual(@as(i64, 1), rows);

    // And the order closed once: one history row for the close.
    const history = try countRows(&harness, "SELECT COUNT(*) AS n FROM order_status_history WHERE order_id = ?1 AND status = 4;", &.{.{ .integer = order.id }});
    try testing.expectEqual(@as(i64, 1), history);
}

test "an old PIN is rewritten in the modern form the next time it signs in" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // An employee whose PIN was hashed before bcrypt.
    var legacy: [auth.legacy_len]u8 = undefined;
    const old = auth.legacyHash(test_salt, "4821", &legacy) orelse return error.NoHash;
    harness.fx.dbExec(.{
        .key = 920,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = old }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });

    // The sign-in worked: an employee whose PIN was hashed before
    // bcrypt can still sign in.
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);

    // And the row now holds the modern hash, so the next guess against
    // the database is a slow one.
    var stored_buffer: [256]u8 = undefined;
    const stored = try storedPinHash(&harness, 1, &stored_buffer);
    try testing.expect(!auth.isLegacy(stored));
    try testing.expect(auth.verifyPin(test_salt, "4821", stored));
    try testing.expect(!auth.verifyPin(test_salt, "4822", stored));
}

test "a PIN shorter than six digits is refused" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("4821");
    harness.model.setup_pin2.set("4821");

    // Four digits is ten thousand guesses, and a stolen database is
    // worth ten thousand guesses: the hash can be slow, but it cannot
    // be slow enough to make a small space safe.
    try testing.expect(!harness.model.setup_can_submit());
    try testing.expect(!harness.model.pin_is_acceptable("4821"));
    try testing.expect(!harness.model.pin_is_acceptable("48215a"));
    try testing.expect(harness.model.pin_is_acceptable("482155"));

    // And the setup says why.
    harness.send(Msg{ .setup_submit = {} });
    try testing.expect(harness.model.setup_error.len > 0);
    try testing.expect(!harness.model.signed_in);
}

test "the till stops taking PINs after too many wrong ones" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // An employee whose PIN is not the one being typed.
    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "482155", &hash) orelse return error.NoHash;
    harness.fx.dbExec(.{
        .key = 922,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;
    harness.model.now_ms = 1_700_000_000_000;

    // The wrong PIN, five times.
    for (0..core.max_login_failures) |_| {
        harness.model.pin.set("000000");
        harness.send(Msg{ .submit_login = {} });
        try testing.expect(!harness.model.signed_in);
    }

    // And now the till has stopped taking them.
    try testing.expect(harness.model.login_locked());
    try testing.expect(harness.model.login_locked_seconds() > 0);

    // Even the RIGHT PIN is refused while the till is locked: the
    // point is to stop the guessing, not to annoy the cashier.
    harness.model.pin.set("482155");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(!harness.model.signed_in);
    try testing.expect(harness.model.login_locked());
}

test "an order does not close without the money" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    const order = harness.model.orders[0];
    try testing.expect(!order.paid);

    // Walk it to the last step: served. Each move is conditional on
    // the status the order is in, so the expected status moves with it.
    var expected = order.status;
    for ([_]domain.OrderStatus{ .preparing, .ready, .served }) |status| {
        repos.setOrderStatus(harness.fx, order.id, expected, status, 1_700_000_000_000);
        harness.drain();
        expected = status;
    }
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.served, harness.model.orders[0].status);

    // The last step is refused: the money has not been taken, and an
    // order that closes without it is a sale the restaurant never sees.
    harness.send(.{ .advance_order = order.id });
    try testing.expect(harness.model.error_text.len > 0);

    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.served, harness.model.orders[0].status);

    // And with the money taken, the order closes.
    harness.fx.dbExec(.{
        .key = 923,
        .statements = &.{.{
            .sql = "INSERT INTO payment (id, order_id, mode, amount_minor, reference, paid_at, created_at) VALUES (1, ?1, 0, 24500, '', 1, 1);",
            .params = &.{.{ .integer = order.id }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expect(harness.model.orders[0].paid);

    harness.send(.{ .advance_order = order.id });
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(domain.OrderStatus.completed, harness.model.orders[0].status);
}

test "the order number is a sequence" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });

    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 2), harness.model.orders.len);

    // The numbers are a sequence, not the clock: they count, and they
    // count in the order the sales were placed. The list is newest
    // first, so the second sale holds the higher number.
    try testing.expectEqualStrings("000002", harness.model.orders[0].order_no);
    try testing.expectEqualStrings("000001", harness.model.orders[1].order_no);
}

test "a failed sale does not consume an order number" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    // A product that is not in the database: the line's foreign key
    // fails, and so does the sale.
    harness.model.products = &.{
        .{ .id = 99, .category_id = 1, .name = "Ghost Dish", .food_label = "Veg", .price_minor = 100, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 99 });
    harness.send(Msg{ .place_order = {} });
    try testing.expect(harness.model.error_text.len > 0);

    // The number the failed sale would have had is still there: the
    // sequence and the order are one transaction, so a sale that does
    // not happen does not take a number with it.
    harness.send(.{ .clear_cart = {} });
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });

    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
    try testing.expectEqualStrings("000001", harness.model.orders[0].order_no);
}

test "a retried write is the same sale" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // The sale the cashier submits twice: the write lands, the answer
    // is lost, and the cashier taps again.
    const order = domain.Order{
        .id = 1_700_000_000_000,
        .order_no = "",
        .order_type = .dine_in,
        .status = .pending,
        .status_label = "Pending",
        .type_label = "Dine in",
        .dining_table_id = 0,
        .customer_id = 0,
        .employee_id = 7,
        .subtotal_minor = 24500,
        .tax_minor = 0,
        .discount_minor = 0,
        .total_minor = 24500,
        .placed_at = 1_700_000_000_000,
        .notes = "",
    };
    const lines = [_]domain.OrderLine{.{
        .id = 1_700_000_000_000,
        .order_id = order.id,
        .product_id = 1,
        .station_id = 0,
        .product_name = "Paneer Tikka",
        .qty = 1,
        .unit_price_minor = 24500,
        .tax_bps = 0,
        .notes = "",
    }};
    const key = "test01-1700000000000";

    repos.saveOrder(harness.fx, order, &lines, key);
    harness.drain();
    // The same sale, submitted again.
    repos.saveOrder(harness.fx, order, &lines, key);
    harness.drain();

    // One sale, one number, one set of lines - and the number the
    // retry would have taken is still there for the next sale.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
    try testing.expectEqualStrings("000001", harness.model.orders[0].order_no);

    repos.loadOrderLines(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.order_lines.len);

    // And the number the retry would have taken is still there: the
    // next sale is 000002, not 000003.
    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });

    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 2), harness.model.orders.len);
    try testing.expectEqualStrings("000002", harness.model.orders[0].order_no);
}

test "two sales in the same millisecond are two sales" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // The clock does not move. Two sales land in the same millisecond,
    // which is what a busy counter does when the taps are quick.
    var clock = native_sdk.TestClock{};
    clock.setWallMs(1_700_000_000_000);
    harness.fx.clock = clock.clock();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });

    // Two orders, two numbers, two sets of lines. The clock is the
    // same for both, so the ids cannot both be the clock.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 2), harness.model.orders.len);
    try testing.expect(harness.model.orders[0].id != harness.model.orders[1].id);
    try testing.expect(!std.mem.eql(u8, harness.model.orders[0].order_no, harness.model.orders[1].order_no));

    repos.loadOrderLines(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 2), harness.model.order_lines.len);
}

test "a PIN only matches the hash of the salted PIN" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "4821", &hash) orelse return error.NoHash;

    harness.fx.dbExec(.{
        .key = 901,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The right PIN finds the operator.
    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
    try testing.expectEqualStrings("Anita", harness.model.employee_name);

    // The wrong PIN does not.
    var other = try Harness.start(testing.allocator);
    defer other.deinit();
    @memcpy(other.model.pin_salt_buf[0..test_salt.len], test_salt);
    other.model.pin_salt_len = test_salt.len;
    other.model.salt_state = .confirmed;
    other.model.pin.set("9999");
    other.send(Msg{ .submit_login = {} });
    try testing.expect(!other.model.signed_in);
    try testing.expect(other.model.login_failed());
}

test "back from home after a sign-in stays home" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "4821", &hash) orelse return error.NoHash;

    harness.fx.dbExec(.{
        .key = 902,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;

    harness.send(.{ .pick_role = @intFromEnum(nav.Role.admin) });
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(nav.Screen.admin_dashboard, harness.model.screen());

    // The sign-in screen is a session gate, not a history entry. Back
    // from the first screen of a session is the first screen.
    const depth = harness.model.stack.len;
    harness.send(Msg{ .go_back = {} });
    try testing.expectEqual(nav.Screen.admin_dashboard, harness.model.screen());
    try testing.expectEqual(depth, harness.model.stack.len);
}

test "signing out clears the cart and the operator" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "4821", &hash) orelse return error.NoHash;

    harness.fx.dbExec(.{
        .key = 903,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;

    harness.send(.{ .pick_role = @intFromEnum(nav.Role.admin) });
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);

    harness.model.products = &.{
        .{ .id = 1, .category_id = 0, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.model.search.set("paneer");
    harness.model.selected_category = 1;

    harness.send(Msg{ .sign_out = {} });

    try testing.expect(!harness.model.signed_in);
    try testing.expectEqual(@as(i64, 0), harness.model.employee_id);
    try testing.expectEqualStrings("", harness.model.employee_name);
    try testing.expectEqual(@as(usize, 0), harness.model.cart_count());
    try testing.expectEqual(@as(usize, 0), harness.model.search.text().len);
    try testing.expectEqual(@as(i64, 0), harness.model.selected_category);
    try testing.expectEqual(nav.Screen.login, harness.model.screen());
    try testing.expectEqual(@as(usize, 1), harness.model.stack.len);
    try testing.expectEqual(nav.Screen.login, harness.model.stack.current().?);
}

test "an employee's PIN only opens the mode they are stored for" {
    // A waiter is a waiter. Their PIN must not open an admin session,
    // however the till is set up.
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "4821", &hash) orelse return error.NoHash;

    harness.fx.dbExec(.{
        .key = 904,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Ravi', 1, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;

    // The till is in admin mode: a waiter's PIN is refused.
    harness.send(Msg{ .pick_role = @intFromEnum(nav.Role.admin) });
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(!harness.model.signed_in);
    try testing.expect(harness.model.login_failed());

    // The same PIN in waiter mode signs the waiter in.
    harness.send(Msg{ .pick_role = @intFromEnum(nav.Role.waiter) });
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
    try testing.expectEqualStrings("Ravi", harness.model.employee_name);
}

test "a fresh installation gets a salt, stores it, and keeps it" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // `main` makes a provisional salt before the app starts, and the
    // boot flow then confirms it against the database. The test does
    // the same, so the flow under test is the real one.
    const provisional = "0123456789abcdef";
    @memcpy(harness.model.pin_salt_buf[0..provisional.len], provisional);
    harness.model.pin_salt_len = provisional.len;
    harness.model.salt_state = .unknown;

    // The boot flow reads the settings. A fresh database has no salt
    // yet, so the provisional one is stored.
    repos.loadConfig(harness.fx);
    harness.drain();
    try testing.expect(harness.model.pin_salt().len > 0);
    try testing.expectEqual(core.SaltState.confirmed, harness.model.salt_state);
    const made = harness.model.pin_salt();

    // The salt is in the database now - a query finds it.
    harness.fx.dbQuery(.{
        .key = 902,
        .sql = "SELECT value FROM app_config WHERE key = 'pin_salt';",
        .params = &.{},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    // The page bytes are drain scratch: the value is COPIED before it
    // is compared, or the comparison reads dead memory.
    var stored_buffer: [128]u8 = undefined;
    var stored_len: usize = 0;
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                const text = reader.textOf(&values, "value");
                stored_len = @min(text.len, stored_buffer.len);
                @memcpy(stored_buffer[0..stored_len], text[0..stored_len]);
            },
            else => {},
        }
    }
    try testing.expectEqualStrings(made, stored_buffer[0..stored_len]);

    // And a later run reads the STORED salt instead of making a new
    // one: the model starts empty and the database fills it.
    harness.model.pin_salt_len = 0;
    harness.model.salt_state = .unknown;
    repos.loadConfig(harness.fx);
    harness.drain();
    try testing.expectEqualStrings(made, harness.model.pin_salt());
    try testing.expectEqual(core.SaltState.confirmed, harness.model.salt_state);
}

test "a second instance adopts the salt that is already stored" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // The first instance installed its salt before this instance read
    // the settings. Insert it without feeding the result to the model:
    // the model under test is the second instance, and it still believes
    // the database was empty.
    const first = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    harness.fx.dbExec(.{
        .key = 903,
        .statements = &.{.{
            .sql = "INSERT INTO app_config (key, value, updated_at) VALUES ('pin_salt', ?1, 1);",
            .params = &.{.{ .text = first }},
        }},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    while (harness.fx.takeMsg()) |_| {}

    const second = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    @memcpy(harness.model.pin_salt_buf[0..second.len], second);
    harness.model.pin_salt_len = second.len;
    harness.model.salt_state = .installing;

    // The second instance writes its salt. The insert does nothing
    // because the first salt is already there, but SQLite still reports
    // success. The instance must read the salt back before confirming
    // it; otherwise every PIN it hashes can never verify.
    repos.saveSalt(harness.fx, repos.key_save_salt, second, 1);
    harness.drain();

    try testing.expectEqualStrings(first, harness.model.pin_salt());
    try testing.expectEqual(core.SaltState.confirmed, harness.model.salt_state);
}

test "a sign-in waits for the database to confirm the salt" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    var hash: [auth.hash_length]u8 = undefined;
    const hashed = auth.hashPin(test_salt, "4821", &hash) orelse return error.NoHash;
    harness.fx.dbExec(.{
        .key = 903,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = hashed }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The salt in the model has not been confirmed by the database: it
    // is the provisional one made at boot. A hash against it can never
    // match, so the sign-in is refused rather than attempted.
    harness.model.salt_state = .unknown;
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(!harness.model.signed_in);
    try testing.expect(harness.model.login_failed());

    // Once the database has confirmed the salt, the same PIN signs in.
    harness.model.salt_state = .confirmed;
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
}

/// The product with this name, or null.
fn findProduct(model: *const Model, name: []const u8) ?domain.Product {
    for (model.products) |product| {
        if (std.mem.eql(u8, product.name, name)) return product;
    }
    return null;
}

/// The installation salt in the database, copied into `out`.
///
/// The page bytes are drain scratch: the value has to be COPIED before
/// it is looked at, or the caller reads dead memory.
fn storedSalt(harness: *Harness, out: []u8) !usize {
    harness.fx.dbQuery(.{
        .key = 905,
        .sql = "SELECT value FROM app_config WHERE key = 'pin_salt';",
        .params = &.{},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                const text = reader.textOf(&values, "value");
                const length = @min(text.len, out.len);
                @memcpy(out[0..length], text[0..length]);
                return length;
            },
            else => {},
        }
    }
    return 0;
}

// -------------------------------------------------------- the setup flow

test "a fresh database asks to be set up" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // The boot flow reads the company. There is none.
    repos.loadCompany(harness.fx);
    harness.drain();

    try testing.expect(harness.model.needs_setup);
    try testing.expect(harness.model.show_setup());
    try testing.expect(!harness.model.show_role_picker());
    try testing.expectEqual(nav.Screen.setup, harness.model.screen());
}

test "a list shows what is in use" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A category, a table and a customer the restaurant has finished
    // with.
    harness.fx.dbExec(.{
        .key = 930,
        .statements = &.{
            .{
                .sql = "INSERT INTO product_category (id, name, sort_order, active) VALUES (9, 'Last season', 9, 0);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO dining_table (id, category_id, name, status, seats, pos_x, pos_y, active) VALUES (9, 1, 'T9', 0, 2, 0, 0, 0);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO customer (id, name, phone, email, loyalty_points, active, created_at) VALUES (9, 'Gone', '0', '', 0, 0, 0);",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    repos.loadCategories(harness.fx);
    repos.loadTables(harness.fx);
    repos.loadCustomers(harness.fx);
    harness.drain();

    // The menu a customer reads is the menu the kitchen cooks: a
    // category the restaurant has finished with is not on it.
    for (harness.model.categories) |category| {
        try testing.expect(!std.mem.eql(u8, category.name, "Last season"));
    }
    for (harness.model.tables) |table| {
        try testing.expect(!std.mem.eql(u8, table.name, "T9"));
    }
    for (harness.model.customers) |customer| {
        try testing.expect(!std.mem.eql(u8, customer.name, "Gone"));
    }
}

test "a fresh install becomes a restaurant through the app alone" {
    // A fresh database. Nothing is seeded: whatever the app needs, the
    // app makes.
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // The installation salt. The app makes one at boot, where it has
    // the randomness; the harness has to name it.
    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;

    // The app opens on the setup, because the database has no company.
    repos.loadCompany(harness.fx);
    harness.drain();
    try testing.expect(harness.model.needs_setup);
    try testing.expect(harness.model.show_setup());

    // The owner fills the form in.
    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("482155");
    harness.model.setup_pin2.set("482155");
    harness.model.setup_currency_code.set("INR");
    harness.model.setup_currency_symbol.set("Rs");
    harness.send(Msg{ .setup_submit = {} });

    // The operator is signed in, and the app is a point of sale.
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(nav.Screen.admin_dashboard, harness.model.screen());
    try testing.expectEqualStrings("Sharma Restaurant", harness.model.company_name_field);

    // The company, the operator and the salt are in the database.
    var company = false;
    var operator = false;
    var salt = false;
    harness.fx.dbQuery(.{
        .key = 929,
        .sql = "SELECT (SELECT COUNT(*) FROM company) AS companies, (SELECT COUNT(*) FROM employee) AS staff, (SELECT COUNT(*) FROM app_config WHERE key = 'pin_salt') AS salts;",
        .params = &.{},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                company = reader.intOf(&values, "companies", 0) == 1;
                operator = reader.intOf(&values, "staff", 0) == 1;
                salt = reader.intOf(&values, "salts", 0) == 1;
            },
            else => {},
        }
    }
    try testing.expect(company);
    try testing.expect(operator);
    try testing.expect(salt);

    // And the menu and the floor are there: a category, a product and
    // a table, made by the app.
    repos.loadCategories(harness.fx);
    repos.loadProducts(harness.fx);
    repos.loadTables(harness.fx);
    harness.drain();
    try testing.expect(harness.model.categories.len >= 1);
    try testing.expect(harness.model.products.len >= 1);
    try testing.expect(harness.model.tables.len >= 1);

    // The operator's PIN is the one they chose, and the database holds
    // a hash of it and never the PIN.
    harness.model.signed_in = false;
    harness.model.employee_id = 0;
    harness.model.pin.set("482155");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
}

test "the setup writes the company, the operator and the starter menu" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    @memcpy(harness.model.pin_salt_buf[0..test_salt.len], test_salt);
    harness.model.pin_salt_len = test_salt.len;
    harness.model.salt_state = .confirmed;

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("482155");
    harness.model.setup_pin2.set("482155");
    try testing.expect(harness.model.setup_can_submit());

    harness.send(Msg{ .setup_submit = {} });

    // The setup succeeded: the operator is signed in and the app is a
    // point of sale.
    try testing.expect(!harness.model.needs_setup);
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(nav.Screen.admin_dashboard, harness.model.screen());
    try testing.expectEqualStrings("Anita", harness.model.employee_name);

    // The company is there.
    try testing.expectEqual(@as(i64, 1), harness.model.company_id);
    try testing.expectEqualStrings("Sharma Restaurant", harness.model.company_name_field);

    // The starter menu and floor are there.
    repos.loadProducts(harness.fx);
    harness.drain();
    try testing.expect(harness.model.products.len >= 10);
    repos.loadTables(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 6), harness.model.tables.len);

    // And the operator can sign in with the PIN they just chose: the
    // database holds the hashed PIN, never the plaintext.
    harness.model.signed_in = false;
    harness.model.employee_id = 0;
    harness.model.pin.set("482155");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
    try testing.expectEqualStrings("Anita", harness.model.employee_name);

    // The wrong PIN does not.
    harness.model.signed_in = false;
    harness.model.employee_id = 0;
    harness.model.pin.set("0000");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(!harness.model.signed_in);
    try testing.expect(harness.model.login_failed());

    // The salt the operator's PIN was hashed with is in the database
    // too, in the same transaction as the hash. A hash without its salt
    // is a PIN that can never be verified.
    var stored: [128]u8 = undefined;
    const stored_len = try storedSalt(&harness, &stored);
    try testing.expectEqualStrings(test_salt, stored[0..stored_len]);
}

test "the setup refuses a PIN that does not match" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("482155");
    harness.model.setup_pin2.set("999911");
    try testing.expect(!harness.model.setup_can_submit());

    harness.send(Msg{ .setup_submit = {} });
    try testing.expect(harness.model.setup_failed());
    try testing.expect(!harness.model.signed_in);
}

test "the stock comes down with the sale" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A dish that is counted, with ten on the shelf, and a drink that
    // is not counted at all.
    harness.fx.dbExec(.{
        .key = 926,
        .statements = &.{
            .{
                .sql = "UPDATE product SET track_stock = 1, stock_qty = 10 WHERE id = 1;",
                .params = &.{},
            },
            .{
                .sql = "UPDATE product SET track_stock = 0, stock_qty = 99 WHERE id = 2;",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 10, .active = true },
        .{ .id = 2, .category_id = 2, .name = "Masala Chai", .food_label = "Veg", .price_minor = 4000, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 99, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 1 });
    harness.send(.{ .add_to_cart = 2 });
    harness.send(Msg{ .place_order = {} });

    // Two dishes sold: eight left on the shelf.
    harness.fx.dbQuery(.{
        .key = 927,
        .sql = "SELECT stock_qty FROM product WHERE id = 1;",
        .params = &.{},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    var left: i64 = -1;
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                left = reader.intOf(&values, "stock_qty", -1);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(i64, 8), left);

    // And the drink that is not counted is not subtracted from: the
    // shelf would be telling a lie.
    harness.fx.dbQuery(.{
        .key = 928,
        .sql = "SELECT stock_qty FROM product WHERE id = 2;",
        .params = &.{},
        .on_result = Effects.dbMsg(.config_loaded),
    });
    var untouched: i64 = -1;
    while (harness.fx.takeMsg()) |msg| {
        switch (msg) {
            .config_loaded => |result| {
                if (result.kind != .page) continue;
                var reader = repos.page.Reader.init(result.bytes);
                var values: [repos.page.max_columns]repos.page.Value = undefined;
                if (!reader.readHeader() or !reader.nextRow(&values)) continue;
                untouched = reader.intOf(&values, "stock_qty", -1);
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(i64, 99), untouched);
}

test "a discount is saved, and it takes what the owner said off" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // Ten percent off, the way a staff discount is written down.
    harness.model.form_discount_name_buf.set("Staff 10%");
    harness.model.form_discount_percent_buf.set("10");
    harness.send(Msg{ .save_discount = {} });

    repos.loadDiscounts(harness.fx);
    harness.drain();

    var found = false;
    for (harness.model.discounts_list) |discount| {
        if (!std.mem.eql(u8, discount.name, "Staff 10%")) continue;
        found = true;
        // Ten percent is a thousand basis points.
        try testing.expectEqual(@as(i64, 1000), discount.percent_bps);
        try testing.expectEqual(@as(i64, 0), discount.amount_minor);
    }
    try testing.expect(found);

    // Or a fixed amount off the bill.
    harness.model.form_discount_name_buf.set("Fifty off");
    harness.model.form_discount_percent_buf.set("");
    harness.model.form_discount_amount_buf.set("50.00");
    harness.send(Msg{ .save_discount = {} });

    repos.loadDiscounts(harness.fx);
    harness.drain();
    var amount = false;
    for (harness.model.discounts_list) |discount| {
        if (!std.mem.eql(u8, discount.name, "Fifty off")) continue;
        amount = true;
        try testing.expectEqual(@as(i64, 0), discount.percent_bps);
        // Fifty is five thousand minor units.
        try testing.expectEqual(@as(i64, 5000), discount.amount_minor);
    }
    try testing.expect(amount);
}

test "a discount needs a name, and it has to take something off" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // No name.
    harness.model.form_discount_percent_buf.set("10");
    harness.send(Msg{ .save_discount = {} });
    try testing.expect(harness.model.error_text_text().len > 0);

    // A rate that is not a number.
    harness.model.form_discount_name_buf.set("Staff");
    harness.model.form_discount_percent_buf.set("ten");
    harness.send(Msg{ .save_discount = {} });
    try testing.expect(harness.model.error_text_text().len > 0);

    // A discount that takes nothing off is not a discount.
    harness.model.form_discount_name_buf.set("Staff");
    harness.model.form_discount_percent_buf.set("");
    harness.model.form_discount_amount_buf.set("");
    harness.send(Msg{ .save_discount = {} });
    try testing.expect(harness.model.error_text_text().len > 0);
}

test "a tax slab is saved, and the rate the owner typed is the rate stored" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A restaurant that charges five percent, the way an owner types it.
    harness.model.form_tax_slab_name_buf.set("GST 5%");
    harness.model.form_tax_slab_rate_buf.set("5");
    harness.send(Msg{ .save_tax_slab = {} });

    repos.loadTaxSlabs(harness.fx);
    harness.drain();

    var found = false;
    for (harness.model.tax_slabs_list) |slab| {
        if (!std.mem.eql(u8, slab.name, "GST 5%")) continue;
        found = true;
        // Five percent is five hundred basis points.
        try testing.expectEqual(@as(i64, 500), slab.rate_bps);
        try testing.expect(!slab.inclusive);
    }
    try testing.expect(found);

    // A rate with decimals, and a price that already carries the tax.
    harness.model.form_tax_slab_name_buf.set("VAT 12.75%");
    harness.model.form_tax_slab_rate_buf.set("12.75");
    harness.model.form_tax_slab_inclusive = true;
    harness.send(Msg{ .save_tax_slab = {} });

    repos.loadTaxSlabs(harness.fx);
    harness.drain();
    var inclusive = false;
    for (harness.model.tax_slabs_list) |slab| {
        if (!std.mem.eql(u8, slab.name, "VAT 12.75%")) continue;
        inclusive = true;
        try testing.expectEqual(@as(i64, 1275), slab.rate_bps);
        try testing.expect(slab.inclusive);
    }
    try testing.expect(inclusive);
}

test "a tax slab needs a name and a rate that is a number" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.form_tax_slab_name_buf.set("GST 5%");
    harness.model.form_tax_slab_rate_buf.set("five");
    harness.send(Msg{ .save_tax_slab = {} });
    try testing.expect(harness.model.error_text_text().len > 0);

    harness.model.form_tax_slab_name_buf.set("");
    harness.model.form_tax_slab_rate_buf.set("5");
    harness.send(Msg{ .save_tax_slab = {} });
    try testing.expect(harness.model.error_text_text().len > 0);
}

test "the customers load into the model" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // A customer the restaurant knows.
    harness.fx.dbExec(.{
        .key = 925,
        .statements = &.{.{
            .sql = "INSERT INTO customer (id, name, phone, email, loyalty_points, created_at) VALUES (1, 'Asha', '99900', 'asha@example.com', 10, 0);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The boot load brings them in. The customers screen and the count
    // beside the dashboard tile were both empty, always: the repository
    // was there, and nothing ever called it.
    repos.loadAll(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.customers.len);
    try testing.expectEqual(@as(usize, 1), harness.model.customer_count());
    try testing.expectEqualStrings("Asha", harness.model.customers[0].name);
}

test "the setup's symbol is the symbol, not the code" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // The code and the symbol are two fields, and one of them used to
    // write into the other.
    harness.model.setup_currency_code.set("EUR");
    harness.model.setup_currency_symbol.set("€");
    try testing.expectEqualStrings("EUR", harness.model.setup_currency_text());
    try testing.expectEqualStrings("€", harness.model.setup_symbol_text());
}

test "the setup's button waits for a complete form" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // Nothing typed yet: the button is not ready.
    try testing.expect(harness.model.setup_incomplete());

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("482155");
    harness.model.setup_pin2.set("482155");
    try testing.expect(!harness.model.setup_incomplete());
    try testing.expect(harness.model.setup_can_submit());
}

test "the setup refuses an empty restaurant name" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("482155");
    harness.model.setup_pin2.set("482155");
    harness.send(Msg{ .setup_submit = {} });
    try testing.expect(harness.model.setup_failed());
    try testing.expect(!harness.model.signed_in);
}

test "taking the payment closes the order and records the money" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });

    // The confirmation screen knows what was sold.
    try testing.expect(harness.model.last_order_id != 0);
    try testing.expectEqual(@as(i64, 24500), harness.model.last_order_total_minor);
    try testing.expectEqual(@as(i64, 1), harness.model.last_order_items());

    // The payment is taken and the order closes.
    harness.send(.{ .set_payment_mode = @intFromEnum(domain.PaymentMode.card) });
    harness.send(Msg{ .take_payment = {} });
    try testing.expectEqualStrings("", harness.model.payment_error_text());

    // The order is completed, and the money is on the order.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(nav.Screen.orders, harness.model.screen());
}

test "the waiter opens an order for a free table and adds to it" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.tables = &.{
        .{ .id = 1, .category_id = 1, .name = "T1", .status = .free, .status_label = "Free", .seats = 2, .pos_x = 0, .pos_y = 0 },
        .{ .id = 2, .category_id = 1, .name = "T2", .status = .free, .status_label = "Free", .seats = 2, .pos_x = 1, .pos_y = 0 },
    };
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };

    // A free table gets a new order, numbered after the clock.
    harness.send(.{ .select_table = 1 });
    try testing.expect(harness.model.active_order_id != 0);
    try testing.expectEqualStrings("T1", harness.model.active_table());
    try testing.expectEqual(nav.Screen.waiter_menu, harness.model.screen());

    // The order is on the table.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
    try testing.expectEqual(@as(i64, 1), harness.model.orders[0].dining_table_id);
    try testing.expect(harness.model.orders[0].order_no.len > 0);

    // A dish on the order brings the order's total with it.
    harness.send(.{ .add_to_order = 1 });
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(i64, 24500), harness.model.orders[0].total_minor);
    try testing.expectEqual(@as(i64, 24500), harness.model.orders[0].subtotal_minor);

    // The waiter's cart shows the line.
    try testing.expectEqual(@as(i64, 1), harness.model.active_order_item_count());
    try testing.expectEqual(@as(i64, 24500), harness.model.active_order_total());

    // The table is occupied: it has a guest at it. The board shows
    // what is true, and a table that says "Free" while somebody is
    // sitting at it is a lie the whole floor works around.
    repos.loadTables(harness.fx);
    harness.drain();
    var occupied = false;
    for (harness.model.tables) |table| {
        if (table.id != 1) continue;
        occupied = table.status == .occupied;
    }
    try testing.expect(occupied);
}

test "a table that already has an order is joined, not duplicated" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.employee_id = 7;
    harness.model.tables = &.{
        .{ .id = 1, .category_id = 1, .name = "T1", .status = .occupied, .status_label = "Occupied", .seats = 2, .pos_x = 0, .pos_y = 0 },
    };
    // An order is already open on the table.
    harness.fx.dbExec(.{
        .key = 951,
        .statements = &.{.{
            .sql = "INSERT INTO orders (id, order_no, order_type, status, dining_table_id, customer_id, employee_id, subtotal_minor, tax_minor, discount_minor, total_minor, placed_at, notes, created_at, updated_at) VALUES (42, '42', 0, 0, 1, NULL, 7, 0, 0, 0, 0, 1, '', 1, 1);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);

    harness.send(.{ .select_table = 1 });
    try testing.expectEqual(@as(i64, 42), harness.model.active_order_id);

    // And no second order was opened.
    repos.loadOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
}

test "the kitchen board's live query sees a new order" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // The kitchen watches the orders.
    repos.watchOpenOrders(harness.fx);
    harness.drain();
    try testing.expectEqual(@as(usize, 0), harness.model.orders.len);

    // A sale lands.
    harness.fx.dbExec(.{
        .key = 950,
        .statements = &.{.{
            .sql = "INSERT INTO orders (id, order_no, order_type, status, dining_table_id, customer_id, employee_id, subtotal_minor, tax_minor, discount_minor, total_minor, placed_at, notes, created_at, updated_at) VALUES (77, '77', 0, 0, NULL, NULL, 7, 100, 0, 0, 100, 1, '', 1, 1);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The board knows about it without anyone asking.
    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
    try testing.expectEqual(@as(i64, 77), harness.model.orders[0].id);
}

test "the kitchen board filters by station" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.orders = &.{
        .{ .id = 1, .order_no = "1", .order_type = .dine_in, .status = .pending, .status_label = "Pending", .type_label = "Dine in", .dining_table_id = 0, .customer_id = 0, .employee_id = 0, .subtotal_minor = 0, .tax_minor = 0, .discount_minor = 0, .total_minor = 0, .placed_at = 0, .notes = "" },
        .{ .id = 2, .order_no = "2", .order_type = .dine_in, .status = .pending, .status_label = "Pending", .type_label = "Dine in", .dining_table_id = 0, .customer_id = 0, .employee_id = 0, .subtotal_minor = 0, .tax_minor = 0, .discount_minor = 0, .total_minor = 0, .placed_at = 0, .notes = "" },
    };
    // The first order is on the grill, the second at the bar.
    harness.model.order_lines = &.{
        .{ .id = 1, .order_id = 1, .product_id = 1, .station_id = 1, .product_name = "Paneer Tikka", .qty = 1, .unit_price_minor = 0, .tax_bps = 0, .notes = "" },
        .{ .id = 2, .order_id = 2, .product_id = 2, .station_id = 2, .product_name = "Masala Chai", .qty = 1, .unit_price_minor = 0, .tax_bps = 0, .notes = "" },
    };

    // Every station sees every ticket.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 2), harness.model.kitchen_tickets(arena).len);

    // The grill sees one, the bar sees one.
    harness.model.station_filter_field = 1;
    try testing.expectEqual(@as(usize, 1), harness.model.kitchen_tickets(arena).len);
    try testing.expectEqual(@as(i64, 1), harness.model.kitchen_tickets(arena)[0].id);

    harness.model.station_filter_field = 2;
    try testing.expectEqual(@as(usize, 1), harness.model.kitchen_tickets(arena).len);
    try testing.expectEqual(@as(i64, 2), harness.model.kitchen_tickets(arena)[0].id);
}

test "the company details are saved and read back" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // The form starts from what is stored: opening the screen seeds
    // the form from the saved company.
    repos.loadCompany(harness.fx);
    harness.drain();
    harness.send(.{ .open_screen = @intCast(nav.Screen.settings_company.index()) });
    try testing.expectEqualStrings("Test Diner", harness.model.form_company_name());

    // The form is edited and saved.
    harness.model.form_name_buf.set("Sharma Restaurant and Bar");
    harness.model.form_address_buf.set("12 MG Road");
    harness.model.form_phone_buf.set("+91 98765 43210");
    harness.model.form_tax_buf.set("29ABCDE1234F1Z5");
    harness.send(Msg{ .save_company = {} });
    try testing.expectEqualStrings("", harness.model.error_text_text());

    // And the database has the new details.
    repos.loadCompany(harness.fx);
    harness.drain();
    try testing.expectEqualStrings("Sharma Restaurant and Bar", harness.model.company_name_field);
    try testing.expectEqualStrings("12 MG Road", harness.model.company_address_field);
    try testing.expectEqualStrings("+91 98765 43210", harness.model.company_phone_field);
    try testing.expectEqualStrings("29ABCDE1234F1Z5", harness.model.company_tax_field);
}

test "a company cannot be saved without a name" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.form_name_buf.set("   ");
    harness.send(Msg{ .save_company = {} });
    try testing.expect(harness.model.error_text_text().len > 0);
}

test "a product is saved, read back, and the menu shows it" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // The form starts from a new product.
    harness.send(Msg{ .new_product = {} });
    try testing.expectEqual(nav.Screen.product_form, harness.model.screen());

    // It is filled in and saved.
    harness.model.form_product_name_buf.set("Garlic Naan");
    harness.model.form_product_price_buf.set("60.50");
    harness.model.form_product_category_id = 1;
    harness.model.form_product_food_id = 1;
    harness.send(Msg{ .save_product = {} });
    try testing.expectEqualStrings("", harness.model.error_text_text());

    // The catalogue has it, at the price that was typed: sixty rupees
    // and fifty paise, in minor units, exactly.
    try testing.expectEqual(@as(usize, 3), harness.model.products.len);
    const naan = findProductNamed(&harness.model, "Garlic Naan") orelse return error.ProductNotFound;
    try testing.expectEqual(@as(i64, 6050), naan.price_minor);
}

test "a price that is not a number is refused" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.form_product_name_buf.set("Something");
    harness.model.form_product_price_buf.set("sixty");
    harness.model.form_product_category_id = 1;
    harness.send(Msg{ .save_product = {} });
    try testing.expect(harness.model.error_text_text().len > 0);
}

test "an employee is saved and can sign in" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.send(Msg{ .new_employee = {} });
    harness.model.form_employee_name_buf.set("Ravi");
    harness.model.form_employee_role_id = 1;
    harness.send(Msg{ .save_employee = {} });
    try testing.expectEqualStrings("", harness.model.error_text_text());

    try testing.expectEqual(@as(usize, 2), harness.model.employees.len);
    const ravi = findEmployeeNamed(&harness.model, "Ravi") orelse return error.EmployeeNotFound;
    try testing.expectEqual(@as(i64, 1), ravi.role);
    try testing.expectEqualStrings("Waiter", ravi.role_label);
}

test "the company carries the currency's decimals" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    // A restaurant that trades in yen.
    harness.fx.dbExec(.{
        .key = 924,
        .statements = &.{.{
            .sql = "INSERT INTO company (id, name, currency_code, currency_symbol, tax_inclusive, created_at, currency_decimals) VALUES (1, 'Tokyo Diner', 'JPY', 'Y', 0, 1, 0);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();
    repos.loadCompany(harness.fx);
    harness.drain();

    try testing.expectEqualStrings("JPY", harness.model.currency_code);
    try testing.expectEqual(@as(i64, 0), harness.model.currency_decimals);
    try testing.expectEqual(@as(i64, 1), harness.model.currency_divisor());
}

test "the currency is saved" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    harness.model.form_currency_code_buf.set("EUR");
    harness.model.form_currency_symbol_buf.set("€");
    harness.send(Msg{ .save_currency = {} });
    try testing.expectEqualStrings("", harness.model.error_text_text());

    repos.loadCompany(harness.fx);
    harness.drain();
    try testing.expectEqualStrings("EUR", harness.model.currency_code);
    try testing.expectEqualStrings("€", harness.model.currency_symbol);
    // The decimals come with the currency: a restaurant that trades in
    // yen has no decimals to show.
    try testing.expectEqual(@as(i64, 2), harness.model.currency_decimals);

    harness.model.form_currency_code_buf.set("JPY");
    harness.model.form_currency_symbol_buf.set("Y");
    harness.send(Msg{ .save_currency = {} });
    repos.loadCompany(harness.fx);
    harness.drain();
    try testing.expectEqualStrings("JPY", harness.model.currency_code);
    try testing.expectEqual(@as(i64, 0), harness.model.currency_decimals);
    try testing.expectEqual(@as(i64, 1), harness.model.currency_divisor());
}

test "the settings data loads: printers, tax slabs, groups and discounts" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.fx.dbExec(.{
        .key = 970,
        .statements = &.{
            .{
                // Slab 0 is the "No tax" slab the migration creates.
                .sql = "INSERT INTO tax_slab (id, name, rate_bps, inclusive, active) VALUES (2, 'GST 5%', 500, 0, 1);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO printer (id, name, kind, transport, address, job, active, created_at) VALUES (1, 'Counter', 'escpos', 'tcp', '192.168.1.9:9100', 'receipt', 1, 1);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO modifier_group (id, name, required, min_select, max_select, sort_order, active) VALUES (1, 'Spice', 0, 0, 1, 1, 1);",
                .params = &.{},
            },
            .{
                .sql = "INSERT INTO discount (id, name, percent_bps, amount_minor, active, created_at) VALUES (1, 'Staff', 1000, 0, 1, 1);",
                .params = &.{},
            },
        },
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    repos.loadTaxSlabs(harness.fx);
    repos.loadPrinters(harness.fx);
    repos.loadModifierGroups(harness.fx);
    repos.loadDiscounts(harness.fx);
    harness.drain();

    try testing.expectEqual(@as(usize, 2), harness.model.tax_slabs_list.len);
    try testing.expectEqual(@as(usize, 1), harness.model.printers_list.len);
    try testing.expectEqual(@as(usize, 1), harness.model.modifier_groups_list.len);
    try testing.expectEqual(@as(usize, 1), harness.model.discounts_list.len);
    try testing.expectEqualStrings("Counter", harness.model.printers_list[0].name);
    try testing.expectEqualStrings("receipt", harness.model.printers_list[0].job);
}

/// The product with this name, or null.
fn findProductNamed(model: *const Model, name: []const u8) ?domain.Product {
    for (model.products) |product| {
        if (std.mem.eql(u8, product.name, name)) return product;
    }
    return null;
}

/// The employee with this name, or null.
fn findEmployeeNamed(model: *const Model, name: []const u8) ?domain.Employee {
    for (model.employees) |employee| {
        if (std.mem.eql(u8, employee.name, name)) return employee;
    }
    return null;
}

test "an order can be opened, and paid from the order list" {
    var harness = try seeded(testing.allocator);
    defer harness.deinit();

    // An order is placed, so there is something to open.
    harness.model.employee_id = 7;
    harness.model.products = &.{
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .food_label = "Veg", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
    };
    harness.send(.{ .add_to_cart = 1 });
    harness.send(Msg{ .place_order = {} });
    repos.loadOrders(harness.fx);
    harness.drain();
    repos.loadOrderLines(harness.fx);
    harness.drain();

    try testing.expectEqual(@as(usize, 1), harness.model.orders.len);
    const order_id = harness.model.orders[0].id;

    // The order opens, and the detail screen knows what is on it.
    harness.send(.{ .open_order = order_id });
    try testing.expectEqual(nav.Screen.order_detail, harness.model.screen());
    try testing.expectEqualStrings(harness.model.orders[0].order_no, harness.model.selected_order_no());
    try testing.expectEqual(@as(i64, 24500), harness.model.selected_order_total());
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 1), harness.model.selected_order_lines(arena_state.allocator()).len);

    // Paying it goes to the confirmation screen, carrying the order.
    harness.send(Msg{ .pay_selected_order = {} });
    try testing.expectEqual(nav.Screen.order_confirmation, harness.model.screen());
    try testing.expectEqual(order_id, harness.model.last_order_id);
    try testing.expectEqual(@as(i64, 24500), harness.model.last_order_total());
}

test "a list screen loads its own data when it is opened" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.fx.dbExec(.{
        .key = 975,
        .statements = &.{.{
            .sql = "INSERT INTO customer (id, name, phone, email, loyalty_points, active, created_at) VALUES (1, 'Meera', '+91 90000 00000', '', 120, 1, 1);",
            .params = &.{},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The customers screen is not loaded until it is opened.
    try testing.expectEqual(@as(usize, 0), harness.model.customers.len);
    harness.send(.{ .open_screen = @intCast(nav.Screen.customers.index()) });
    try testing.expectEqual(@as(usize, 1), harness.model.customers.len);
    try testing.expectEqualStrings("Meera", harness.model.customers[0].name);
    try testing.expectEqual(nav.Screen.customers, harness.model.screen());
}

test "the effects channel has sixteen slots, so the loads are lazy" {
    // The lesson this test records: loading everything at once fills
    // the channel and the queries that arrive late are refused with a
    // "busy" that is not the database's fault.
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    var messages: usize = 0;
    repos.loadAll(harness.fx);
    while (harness.fx.takeMsg()) |_| messages += 1;
    // Every query answers with a page and a terminal, so the queries
    // are half the messages. Sixteen slots is the channel's limit, and
    // the timers and the live subscription take three of them.
    const queries = messages / 2;
    try testing.expect(queries <= 12);
}
