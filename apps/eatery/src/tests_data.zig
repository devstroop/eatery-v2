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
};

const migration_names = [_][]const u8{
    "core", "catalog", "floor", "customers", "orders",
    "inventory", "ops", "compliance", "printing", "sync", "default_tax_slab",
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

        return .{
            .database = database,
            .fx = fx,
            .model = main.initialModel(),
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
        var guard: usize = 0;
        while (self.fx.takeMsg()) |msg| {
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
        .{ .id = 1, .category_id = 1, .name = "Paneer Tikka", .price_minor = 24500, .product_type = .dish, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
        .{ .id = 2, .category_id = 2, .name = "Masala Chai", .price_minor = 4000, .product_type = .beverage, .food_type = .veg, .tax_slab_id = 0, .stock_qty = 0, .active = true },
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

test "a PIN only matches the hash of the salted PIN" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    const salt = "a1b2c3d4";
    var hash: [auth.hex_len]u8 = undefined;
    auth.hashPin(salt, "4821", &hash);

    harness.fx.dbExec(.{
        .key = 901,
        .statements = &.{.{
            .sql = "INSERT INTO employee (id, name, role, pin_hash, active, created_at) VALUES (1, 'Anita', 0, ?1, 1, 0);",
            .params = &.{.{ .text = &hash }},
        }},
        .on_result = Effects.dbMsg(.company_loaded),
    });
    harness.drain();

    // The right PIN finds the operator.
    @memcpy(harness.model.pin_salt_buf[0..salt.len], salt);
    harness.model.pin_salt_len = salt.len;
    harness.model.pin.set("4821");
    harness.send(Msg{ .submit_login = {} });
    try testing.expect(harness.model.signed_in);
    try testing.expectEqual(@as(i64, 1), harness.model.employee_id);
    try testing.expectEqualStrings("Anita", harness.model.employee_name);

    // The wrong PIN does not.
    var other = try Harness.start(testing.allocator);
    defer other.deinit();
    @memcpy(other.model.pin_salt_buf[0..salt.len], salt);
    other.model.pin_salt_len = salt.len;
    other.model.pin.set("9999");
    other.send(Msg{ .submit_login = {} });
    try testing.expect(!other.model.signed_in);
    try testing.expect(other.model.login_failed());
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

    // The boot flow reads the settings. A fresh database has no salt
    // yet, so the provisional one is stored.
    repos.loadConfig(harness.fx);
    harness.drain();
    try testing.expect(harness.model.pin_salt().len > 0);
    try testing.expect(!harness.model.salt_is_provisional);
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
    harness.model.salt_is_provisional = true;
    repos.loadConfig(harness.fx);
    harness.drain();
    try testing.expectEqualStrings(made, harness.model.pin_salt());
    try testing.expect(!harness.model.salt_is_provisional);
}

/// The product with this name, or null.
fn findProduct(model: *const Model, name: []const u8) ?domain.Product {
    for (model.products) |product| {
        if (std.mem.eql(u8, product.name, name)) return product;
    }
    return null;
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

test "the setup writes the company, the operator and the starter menu" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    const salt = "a1b2c3d4";
    @memcpy(harness.model.pin_salt_buf[0..salt.len], salt);
    harness.model.pin_salt_len = salt.len;

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("4821");
    harness.model.setup_pin2.set("4821");
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
    // database holds the salted hash, never the plaintext.
    harness.model.signed_in = false;
    harness.model.employee_id = 0;
    harness.model.pin.set("4821");
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
}

test "the setup refuses a PIN that does not match" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.setup_company_name.set("Sharma Restaurant");
    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("4821");
    harness.model.setup_pin2.set("9999");
    try testing.expect(!harness.model.setup_can_submit());

    harness.send(Msg{ .setup_submit = {} });
    try testing.expect(harness.model.setup_failed());
    try testing.expect(!harness.model.signed_in);
}

test "the setup refuses an empty restaurant name" {
    var harness = try Harness.start(testing.allocator);
    defer harness.deinit();

    harness.model.setup_admin_name.set("Anita");
    harness.model.setup_pin.set("4821");
    harness.model.setup_pin2.set("4821");
    harness.send(Msg{ .setup_submit = {} });
    try testing.expect(harness.model.setup_failed());
    try testing.expect(!harness.model.signed_in);
}
