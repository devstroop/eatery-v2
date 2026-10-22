# Data model and storage

> **Scope:** the database schema in `apps/ros/src/schema/`, the
> repository layer in `apps/ros/src/data/`, and the rules that connect
> the two.
> **Source:** `apps/ros/src/schema/0001..0010_*.sql`,
> `apps/ros/src/schema/migrations.lock.json`, `apps/ros/src/data/*.zig`,
> `apps/ros/src/core/update.zig`.
> **Method:** read from source. The Native SDK CLI (`native`) is not on the
> PATH in this workspace, so no migration run backs the claims here.

---

## 1. The three schema rules

Every table in `apps/ros/src/schema/` obeys three rules. They are
stated at the top of the first migration and repeated nowhere else,
because they are the only three that matter:

```sql
-- 0001_core.sql - the company, its currency, its people and its settings.
--
-- House rules for every table in this schema:
--   * STRICT tables only. The schema checker refuses anything else, and
--     it is right: STRICT is what makes a column's declared type mean
--     something. Eatery v1 learned this the expensive way.
--   * Money is INTEGER minor units. No REAL money, ever.
--   * Time is INTEGER epoch milliseconds, UTC.
```

### Rule 1 — `STRICT` tables only

**What it means.** A table declared `STRICT` accepts a value in a column
only if that value is convertible to the column's declared type. Without
it, SQLite applies *type affinity*: a column declared `INTEGER` will
happily store the text `'12'`, and a column declared `REAL` will store
`'abc'` as the string `'abc'`.

**Why it exists.** Because in v1 the schema had no type discipline and
the app paid for it. Eatery v1's `assets/db/schema.sql` declares 39
tables with loose affinity and no `STRICT` keyword, and money columns
typed `REAL`:

```sql
CREATE TABLE IF NOT EXISTS employee (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  name           TEXT NOT NULL,
  email          TEXT,
  ...
  pin            TEXT,
```

Nothing stops a value of the wrong shape from landing in a column, and
the mistake surfaces three layers away — in a total, on a receipt, or in
a report. `STRICT` moves the failure to the write, where the engine can
name the table and the column.

**How it is enforced.** `native check` validates every migration against
real SQLite at build time and rejects a table that is not `STRICT` with
a diagnostic of the form `NS1405 Table 'product' is not STRICT`. The
failure lands in the check, not in production.

### Rule 2 — Money is `INTEGER` minor units

**What it means.** A price is an integer count of the smallest unit of
the currency. Cents, paise, yen. The column is named accordingly:
`price_minor`, `subtotal_minor`, `tax_minor`, `total_minor`,
`discount_minor`, `unit_price_minor`, `amount_minor`,
`opening_cash_minor`, `rate_bps` for percentages.

**Why it exists.** Binary floating point cannot represent most decimal
fractions exactly. `0.1 + 0.2` is not `0.3` in IEEE 754, and a
restaurant that adds a thousand line items in floats ends the day with a
total that is off by a fraction of a currency unit — the kind of
discrepancy that has to be reconciled by hand against the drawer.

v1 kept money in `REAL` columns throughout:

```sql
  subTotal      REAL NOT NULL,
  discountTotal REAL NOT NULL,
  taxTotal      REAL NOT NULL,
  grandTotal    REAL NOT NULL,
```

Integer minor units are exact. The currency's scale is data, not code:
the `currency` table declares it.

```sql
CREATE TABLE currency (
    code        TEXT    PRIMARY KEY,
    symbol      TEXT    NOT NULL,
    name        TEXT    NOT NULL,
    minor_units INTEGER NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4)
) STRICT;
```

**Two corollaries the schema enforces.**

* A negative price is a data error, not a discount — discounts have their
  own table:

  ```sql
  -- Minor units. A negative price is a data error, not a discount:
  -- discounts live in their own table.
  price_minor   INTEGER NOT NULL DEFAULT 0 CHECK (price_minor >= 0),
  ```

* Percentages are integers in basis points, so `5%` is `500` and `100%`
  is `10000` — no float rate anywhere:

  ```sql
  -- Basis points: 5% is 500. 10000 = 100%.
  rate_bps    INTEGER NOT NULL DEFAULT 0 CHECK (rate_bps BETWEEN 0 AND 10000),
  ```

The model mirrors the same convention on the Zig side, in
`src/domain/models.zig`:

```zig
/// Price in minor units (cents, paise, yen...).
price_minor: i64,
```

### Rule 3 — Time is `INTEGER` epoch milliseconds, UTC

**What it means.** Every timestamp column in the schema — `created_at`,
`updated_at`, `placed_at`, `paid_at`, `opened_at`, `reserved_at`,
`changed_at`, `generated_at` — is an `INTEGER` count of milliseconds since
the Unix epoch, in UTC.

**Why it exists.** Three reasons, in order of how often they bite.

1. **One comparison rule.** `ORDER BY placed_at DESC` sorts correctly
   with no per-column knowledge. With ISO-8601 strings it also happens
   to sort correctly, but only if every writer agrees on the format and
   the timezone suffix; with a mix of `2026-10-20` and
   `2026-10-20T14:03:00Z` it does not.
2. **No timezone arithmetic.** A local-time string needs a timezone
   database to convert. An epoch integer is already UTC; the device's
   locale is a display concern, applied at the edge.
3. **Cheap and exact.** Eight bytes, and it never loses a millisecond to
   a formatting round trip.

Note what is *not* a timestamp: `business_hours.opens_min` and
`closes_min` are minutes from midnight (0–1440), and
`holiday_hours.holiday_date` is a `TEXT` calendar date. Those are
recurring wall-clock quantities, not instants, and they are not stored
as epochs.

---

## 2. The migration workflow

### The files

`apps/ros/src/schema/` holds numbered migrations, applied in order by
the platform when the database opens:

```
0001_core.sql        0006_inventory.sql
0002_catalog.sql     0007_ops.sql
0003_floor.sql       0008_compliance.sql
0004_customers.sql   0009_printing.sql
0005_orders.sql      0010_sync.sql
```

### Creating one

```sh
cd apps/ros
native db new-migration add_promotions   # appends src/schema/000N_add_promotions.sql
```

The CLI generates the file, generates the migrations module from
`src/schema/`, and updates the lock file.

### The lock file

`apps/ros/src/schema/migrations.lock.json` is the append-only
authority on what has shipped:

```json
{
  "version": 10,
  "hashes": [
    "67a2b24c455e923d11520555649bf369408a2b43920e7baf61836aab6c1e230b",
    "9b59ec3868b0cbd712d9738b0753e0f500dc38f0191aed4a00cae391ffefec02",
    "b678a92d2f7d922a543c629328ecb6bff399068ccc85e0547fbf07214bebd4f4",
    "1907a2e378a225a3b2454ac30a3919d248457719839182b347908e17f81e777b",
    "769eccc09a5687349fa54600698f3bdcd0d07a587ca001310a731504a8dce51a",
    "244e39ee03d06fac0892f47ffe4d322f9afcca73611befa7536ce36161f56be5",
    "dc66e13cd19e7ad798c3c5020f5477bea277dd5d0ed85ee6d351ab4192772e7f",
    "41d3f920fc0f90b9cbb2e8d47c966d4c2b6efaf857dc6a7720456874a5dae4e9",
    "5f740d8d3b1321f34c45426fc586d8ab4a0387c577a7070c2e6aba1695d4d370",
    "be27f5053ddc2bb79125137a28f2a80e82b73f8eef89f44f0375904fb5bc7ad1"
  ],
  "schema_hash": "c4a4e65ae64780c512c53bba046386c7f9e5dade159304d44a974dd5ae887925"
}
```

`version` is the migration count; `hashes` is one SHA-256 per migration
file, in order; `schema_hash` covers the whole set. A shipped migration
is never edited — a change is a new file with the next number, and the
lock moves forward.

### What `native check` enforces

`native check` prepares the schema with real SQLite and reports
`file:line:col` diagnostics. It fails the build on:

| Failure | Diagnostic |
|---|---|
| A table that is not `STRICT` | `NS1405 Table 'product' is not STRICT` |
| A foreign key that does not resolve | The broken reference, with the position |
| SQL that does not parse against the real engine | The parser error, with the position |
| A migration that does not match the lock | The hash mismatch |

### Who runs the migrations

Not the app. The SDK generates a migrations module from `src/schema/` and
wires it into the runner, so the database is opened **already migrated**
at boot. The app never opens a connection, never sets a PRAGMA, and
never runs migration code. This is the "engine-owned SQLite" decision
recorded in `docs/decisions/0005-engine-owned-sqlite-strict-schema.md`.

### Changing the schema

1. Read `apps/ros/src/schema/` and `apps/ros/src/data/repos.zig`.
2. Add `src/schema/NNNN_name.sql`. Never edit an earlier file.
3. Keep `STRICT`, the `CHECK` constraints, integer minor-unit money and
   epoch-millisecond time.
4. Run `native db new-migration` (or regenerate the lock through the SDK
   tooling) so `migrations.lock.json` moves to the new version.
5. Add or update the SQL constant and its decoder in
   `apps/ros/src/data/repos.zig`.
6. `native check`, then `native test`.

There is no installed Restaurant OS base yet, so a correction to an existing
migration can still be folded into a new migration without a data
migration. Once a release ships, that stops.

---

## 3. Table inventory

43 tables across ten migrations, every one `STRICT`. One line each.

### 0001 — `core.sql` (4 tables)

The company, its currency, its people and its settings.

| Table | Holds | Key columns |
|---|---|---|
| `company` | The one company this database belongs to | `id`, `name`, `currency_code`, `currency_symbol`, `tax_inclusive`, `created_at` |
| `currency` | One row per supported currency, so the picker has a list | `code` (PK), `symbol`, `minor_units` |
| `employee` | Staff; the PIN is a salted SHA-256 hex digest | `id`, `name`, `role` (0–3), `pin_hash`, `active`, `created_at` |
| `app_config` | Key/value settings — schema version, device role, PIN salt, current shift | `key` (PK), `value`, `updated_at` |

### 0002 — `catalog.sql` (7 tables)

What the restaurant sells.

| Table | Holds | Key columns |
|---|---|---|
| `product_category` | Menu sections | `id`, `name`, `sort_order`, `active` |
| `tax_slab` | A tax rate, inclusive or exclusive | `id`, `name`, `rate_bps` (0–10000), `inclusive`, `active` |
| `product` | One menu item | `id`, `category_id` → `product_category`, `name`, `price_minor`, `product_type`, `food_type`, `tax_slab_id`, `stock_qty`, `track_stock`, `active` |
| `modifier_group` | A choice set attached to products ("size", "spice level") | `id`, `name`, `required`, `min_select`, `max_select`, `sort_order`, `active` |
| `modifier` | One choice inside a group, with a price delta | `id`, `group_id` → `modifier_group` (CASCADE), `name`, `price_delta_minor`, `sort_order`, `active` |
| `product_modifier` | Which groups apply to which product | `product_id` + `modifier_group_id` (composite PK) |
| `discount` | A percentage (bps) or a fixed amount; at most one of the two | `id`, `name`, `percent_bps`, `amount_minor`, `active`, `created_at` |

### 0003 — `floor.sql` (4 tables)

The dining room, and the kitchen stations behind it.

| Table | Holds | Key columns |
|---|---|---|
| `dining_table_category` | Room or zone grouping | `id`, `name`, `sort_order`, `active` |
| `dining_table` | One table: its status, seats and grid position | `id`, `category_id` → `dining_table_category`, `name`, `status` (0–3), `seats`, `pos_x`, `pos_y`, `width_cells`, `height_cells`, `active` |
| `kds_station` | A kitchen station ("Grill", "Tandoor", "Bar") | `id`, `name`, `sort_order`, `active` |
| `product_station` | Which station serves which product | `product_id` + `station_id` (composite PK) |

### 0004 — `customers.sql` (3 tables)

Who the food is for. A customer is optional on an order: most
restaurants run a tab against a table, not a person.

| Table | Holds | Key columns |
|---|---|---|
| `customer` | Name, contact details and the loyalty balance | `id`, `name`, `phone`, `email`, `address`, `loyalty_points`, `notes`, `active`, `created_at` |
| `customer_loyalty` | The points ledger | `id`, `customer_id` → `customer`, `points`, `reason`, `created_at` |
| `loyalty_transaction` | A points delta tied to an order | `id`, `customer_id` → `customer`, `order_id`, `points_delta`, `reason`, `created_at` |

### 0005 — `orders.sql` (7 tables)

The sale. An order is immutable once paid except for its status: the
lines carry the price that was charged, so a price change tomorrow cannot
rewrite yesterday's bill.

| Table | Holds | Key columns |
|---|---|---|
| `orders` | The order header | `id`, `order_no` (UNIQUE), `order_type` (0–2), `status` (0–5), `dining_table_id`, `customer_id`, `employee_id`, `subtotal_minor`, `tax_minor`, `discount_minor`, `total_minor`, `placed_at`, `created_at`, `updated_at` |
| `order_line` | One line of an order, with the name and price frozen at the sale | `id`, `order_id` → `orders` (CASCADE), `product_id`, `product_name`, `qty`, `unit_price_minor`, `tax_bps`, `discount_minor`, `station_id`, `created_at` |
| `order_line_modifier` | The frozen modifier choice on a line | `id`, `order_line_id` → `order_line` (CASCADE), `modifier_id`, `modifier_name`, `price_delta_minor` |
| `order_discount` | A discount applied to an order | `id`, `order_id` → `orders` (CASCADE), `discount_id`, `name`, `amount_minor` |
| `order_status_history` | The lifecycle ledger, written in the same transaction as the status change | `id`, `order_id` → `orders` (CASCADE), `status` (0–5), `changed_at`, `changed_by` |
| `payment` | One payment against an order | `id`, `order_id` → `orders` (CASCADE), `mode` (0–4), `amount_minor`, `reference`, `paid_at` |
| `reservation` | A booking | `id`, `customer_id`, `dining_table_id`, `name`, `phone`, `guests`, `reserved_at`, `status` (0–2), `notes` |

### 0006 — `inventory.sql` (4 tables)

What the restaurant buys and what it owes. Stock lives on the product
(`stock_qty`) and moves through `stock_adjustment`, which is the ledger
of why the number changed.

| Table | Holds | Key columns |
|---|---|---|
| `supplier` | Vendor master | `id`, `name`, `phone`, `email`, `address`, `gstin`, `active`, `created_at` |
| `purchase_order` | A purchase header | `id`, `supplier_id` → `supplier`, `order_no` (UNIQUE), `status` (0–3), `total_minor`, `ordered_at`, `expected_at`, `received_at` |
| `purchase_order_item` | One purchased line, with what has actually arrived | `id`, `purchase_order_id` → `purchase_order` (CASCADE), `product_id`, `name`, `qty`, `unit_cost_minor`, `received_qty` |
| `stock_adjustment` | Why stock changed: a signed delta plus a reason | `id`, `product_id` → `product` (CASCADE), `delta`, `reason`, `reference`, `created_at` |

### 0007 — `ops.sql` (6 tables)

The shift, the hours, the money that is not a sale.

| Table | Holds | Key columns |
|---|---|---|
| `shift` | A cash drawer session | `id`, `employee_id` → `employee`, `opened_at`, `closed_at`, `opening_cash_minor`, `closing_cash_minor`, `expected_cash_minor`, `notes` |
| `time_entry` | Clock in / clock out | `id`, `employee_id` → `employee` (CASCADE), `shift_id`, `clocked_at`, `clocked_out` |
| `business_hours` | Weekly opening minutes, per weekday | `id`, `weekday` (0–6), `opens_min`, `closes_min`, `is_closed` |
| `holiday_hours` | Date-specific hours | `id`, `holiday_date` (TEXT), `opens_min`, `closes_min`, `is_closed` |
| `expense_category` | Expense grouping | `id`, `name`, `active` |
| `expense` | Money out | `id`, `category_id`, `amount_minor`, `note`, `spent_at`, `created_at` |

### 0008 — `compliance.sql` (3 tables)

The records a tax authority can ask for. These tables are the reason Restaurant OS
keeps money in integer minor units and every void with a reason: an X/Z
report has to be reconstructible from the database alone, months later.

| Table | Holds | Key columns |
|---|---|---|
| `compliance_report` | An X or Z report snapshot with the payment split | `id`, `report_type` ('X' or 'Z'), `shift_id`, `employee_id`, `gross_minor`, `discount_minor`, `tax_minor`, `net_minor`, `payment_split_json`, `generated_at` |
| `void_log_entry` | A voided order with its reason | `id`, `order_id`, `employee_id`, `reason`, `amount_minor`, `voided_at` |
| `subscription` | Plan and expiry | `id`, `plan`, `started_at`, `expires_at`, `active` |

### 0009 — `printing.sql` (2 tables)

Receipt printers. The app never talks to a printer directly: it writes a
print job and a sidecar process owns the device.

| Table | Holds | Key columns |
|---|---|---|
| `printer` | One printer and how to reach it | `id`, `name`, `kind` ('escpos' or 'system'), `transport` ('ble', 'tcp', 'usb', 'file'), `address`, `job` ('receipt', 'kot', 'report'), `paper_width_mm`, `active` |
| `auto_print` | Which printer takes which job | `id`, `printer_id` → `printer` (CASCADE), `job`, `enabled` |

### 0010 — `sync.sql` (3 tables)

The operation log. v1 spoke WebSocket to a sync host from inside the
app. Restaurant OS does not: the app writes its changes here and watches this
table; a sidecar process owns the socket and the mDNS announcement.

| Table | Holds | Key columns |
|---|---|---|
| `device` | This device's identity and role | `id` (TEXT PK), `name`, `role` ('admin', 'waiter', 'kds', 'display'), `last_seen_at`, `created_at` |
| `op_log` | The append-only mutation log | `id` (TEXT PK), `entity_table`, `entity_id`, `operation` ('create', 'update', 'delete'), `data_json`, `previous_json`, `logical_clock`, `device_id`, `host_id`, `parent_id`, `created_at` |
| `sync_state` | The local logical clock and sync metadata | `key` (PK), `value` |

The conflict rule is last-writer-wins on `(logical_clock, device_id)`.
The sidecar bumps the local clock to `max(local, highest seen) + 1`.

### Indexes

Twenty-six indexes exist, at the columns the current queries touch:
`employee(active)`, `product(category_id)`, `product(active)`,
`modifier(group_id)`, `dining_table(category_id)`, `customer(name)`,
`customer_loyalty(customer_id)`, `orders(status)`, `orders(placed_at)`,
`orders(dining_table_id)`, `order_line(order_id)`,
`order_line_modifier(order_line_id)`, `order_status_history(order_id)`,
`payment(order_id)`, `reservation(reserved_at)`,
`purchase_order(supplier_id)`, `purchase_order_item(purchase_order_id)`,
`stock_adjustment(product_id)`, `shift(employee_id)`,
`expense(spent_at)`, `compliance_report(generated_at)`,
`void_log_entry(order_id)`, `auto_print(printer_id)`,
`op_log(entity_table, entity_id)`, `op_log(logical_clock)`,
`op_log(device_id)`.

Not yet indexed, and needed later: order lines by `product_id` for
sales-by-item reports, payments by `paid_at` for shift reconciliation,
reservations by `status`, and `op_log` by `created_at` for pruning.

---

## 4. The repository layer

`apps/ros/src/data/` holds three files with three distinct jobs.

| File | Job |
|---|---|
| `repos.zig` | The SQL, the effect keys, the loaders, the decoders, the writers. |
| `page.zig` | The reader for the engine's row format. |
| `auth.zig` | PIN hashing. Pure — no clock, no allocation, no effects. |

### How `repos.zig` is organised

Six sections, in this order:

1. **Effect keys.** A `u64` per effect slot, in their own namespace so a
   query and a write can never collide.
2. **Query constants.** One named `pub const` per statement, so a schema
   change is one edit rather than a grep:

   ```zig
   pub const products_sql =
       \\SELECT id, category_id, name, price_minor, product_type, food_type,
       \\       tax_slab_id, stock_qty, active
       \\FROM product
       \\WHERE active = 1
       \\ORDER BY name;
   ;
   ```

3. **Readers.** One function per query, each issuing one `fx.dbQuery`
   with a key and a result message:

   ```zig
   /// Ask for the menu. The result arrives as a `.products_loaded` message.
   pub fn loadProducts(fx: *Effects) void {
       fx.dbQuery(.{
           .key = key_products,
           .sql = products_sql,
           .on_result = Effects.dbMsg(.products_loaded),
       });
   }
   ```

   `loadAll` is the boot-and-sign-in aggregate:

   ```zig
   /// Load everything the shell needs on boot. One arm, one place.
   pub fn loadAll(fx: *Effects) void {
       loadCompany(fx);
       loadCategories(fx);
       loadProducts(fx);
       loadTables(fx);
       loadEmployees(fx);
       loadOrders(fx);
       loadOrderLines(fx);
   }
   ```

4. **Decoders.** One per dataset. Each resets the model's bump buffer,
   allocates the row slice, and copies every text field into the bump.
5. **Writers.** `dbExec` calls, each one transaction.
6. **Helpers.** `enumFromInt`, the safe enum cast:

   ```zig
   /// A safe enum cast: an out-of-range database value falls back to the
   /// default instead of trapping. A database is allowed to be wrong; the
   /// app is not allowed to crash because of it.
   fn enumFromInt(comptime T: type, value: i64) T {
   ```

### Effect keys

| Key | Value | Family | Used by |
|---|---|---|---|
| `key_products` | 1 | read | `loadProducts` |
| `key_tables` | 2 | read | `loadTables` |
| `key_employees` | 3 | read | `loadEmployees` |
| `key_orders` | 4 | read | `loadOrders` |
| `key_customers` | 5 | read | `loadCustomers` |
| `key_categories` | 6 | read | `loadCategories` |
| `key_company` | 7 | read | `loadCompany` |
| `key_login` | 8 | read | the sign-in query in `core/update.zig` |
| `key_order_lines` | 9 | read | `loadOrderLines` |
| `key_config` | 10 | read | `loadConfig` |
| `key_write_order` | 20 | write | `saveOrder`, `setOrderStatus` |
| `key_write_product` | 21 | write | reserved; no caller |
| `key_write_table` | 22 | write | reserved; no caller |
| `clock_timer_key` | 100 | timer | the repeating clock tick in `core/update.zig` |

A key identifies an effect slot for cancellation and replacement. Reusing
one across a query and a write is a bug; the numbering keeps the read
family in 1–10, the write family in 20–22 and the timer at 100, so a
collision is visible at a glance.

### The page reader dialect

The engine delivers one encoded page per delivery. The format is fixed
and little-endian, and `data/page.zig` documents it in full:

```zig
//!   u32 column count
//!   u32 row count
//!   per column:  u32 byte length, then the column name
//!   per row, per column, row-major:
//!     tag 0        NULL
//!     tag 1 + i64  INTEGER
//!     tag 2 + f64  REAL (bit pattern)
//!     tag 3 + u32 length, then bytes   TEXT
//!     tag 4 + u32 length, then bytes   BLOB
```

| Tag | Type | Payload |
|---|---|---|
| 0 | NULL | none |
| 1 | INTEGER | `i64` |
| 2 | REAL | `f64` bit pattern |
| 3 | TEXT | `u32` length + bytes |
| 4 | BLOB | `u32` length + bytes |

The reader is a streaming reader, not a materialiser. It reads the
header, then one row at a time into a caller-supplied array of
`Value`:

```zig
/// Read the next row into `out`, which must be at least as long as the
/// column count. Returns false at the end of the page.
pub fn nextRow(self: *Reader, out: []Value) bool {
```

Columns are addressed **by name**, not by position:

```zig
/// The index of a selected column, or null when the query did not
/// select it. Repos use this so a column reorder in SQL cannot
/// silently swap two fields in a decoder.
pub fn indexOf(self: *const Reader, name: []const u8) ?usize {
```

That is what lets `decodeProducts` ask for `"price_minor"` and get the
price, whatever order the SQL happens to list the columns in. A NULL
reads as the caller's fallback, not as zero:

```zig
/// The integer value of one column of the row in `out`.
pub fn intOf(self: *const Reader, out: []const Value, name: []const u8, fallback: i64) i64 {
```

Limits and safety: at most 64 columns per query (`page.max_columns`, a
stack allocation); invalid UTF-8 in a text column reads as empty text; a
truncated page fails the read rather than returning partial garbage.

### Why reads copy into the model's bump buffers

Two facts, stated in `data/page.zig`, force the copy:

```zig
//!   * The page bytes are **drain scratch**. They are valid through the
//!     update that receives them and dead after it, so every value the
//!     model keeps has to be COPIED (into the model's bump buffer).
//!   * `update` has **no allocator**. So the reader streams: it never
//!     materialises the whole page, and the caller copies each row into
//!     its own storage as it goes.
```

So the copy is not a style choice; it is the only way the value survives.
The destination is `core/bump.zig`:

```zig
/// A bump allocator over a fixed buffer.
//!
//! The model must be default-constructible (`UiApp.create` builds it as
//! `.{}` and the model-contract checker does the same), so it cannot own
//! a heap allocator.
```

A decoder therefore looks like this — reset the buffer, allocate the row
slice, copy each text field:

```zig
pub fn decodeProducts(model: *Model, bytes: []const u8) void {
    var reader = page.Reader.init(bytes);
    if (!reader.readHeader()) return;
    model.products_buf.reset();
    const count = reader.rows_left;
    const list = model.products_buf.allocSlice(domain.Product, count) orelse return;
    var values: [page.max_columns]page.Value = undefined;
    var index: usize = 0;
    while (index < count and reader.nextRow(&values)) : (index += 1) {
        list[index] = .{
            .id = reader.intOf(&values, "id", 0),
            .category_id = reader.intOf(&values, "category_id", 0),
            .name = model.products_buf.dupe(reader.textOf(&values, "name")) orelse "",
            .price_minor = reader.intOf(&values, "price_minor", 0),
            // ...
        };
    }
    model.products = list[0..index];
}
```

The buffers are fixed-size and named in `core/model.zig`:

```zig
pub const products_buffer = 96 * 1024;
pub const tables_buffer = 24 * 1024;
pub const employees_buffer = 16 * 1024;
pub const orders_buffer = 48 * 1024;
pub const customers_buffer = 32 * 1024;
pub const categories_buffer = 16 * 1024;
pub const order_lines_buffer = 48 * 1024;
```

A row that does not fit is dropped, not fatal: `alloc` returns `null`
and the decoder writes `""`. The bound is the compiler's, not a runtime
check.

### Writes

A write is one `fx.dbExec`, and the engine runs the statements as a
single transaction. `saveOrder` builds the order statement and one
statement per line on the stack — no allocator needed, because `dbExec`
executes synchronously:

```zig
pub const max_order_lines = 64;

pub fn saveOrder(fx: *Effects, order: domain.Order, lines: []const domain.OrderLine) void {
```

`setOrderStatus` runs two statements in one transaction — the status
update and the history row — so the timeline can never disagree with the
order's current status:

```zig
/// Move an order along its lifecycle. The status history is written in
/// the same transaction, so the timeline can never disagree with the
/// order's current status.
pub fn setOrderStatus(fx: *Effects, order_id: i64, status: domain.OrderStatus, at: i64) void {
```

`saveConfigValue` upserts a single `app_config` row:

```sql
INSERT INTO app_config (key, value, updated_at) VALUES (?1, ?2, ?3)
ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3;
```

### Repository coverage today

| Entity | Read | Decode | Write | Screen |
|---|---|---|---|---|
| `company` | yes | yes | no | dashboard header, labels |
| `app_config` | yes (salt) | yes | yes (upsert) | sign-in |
| `product` | yes | yes | no | POS menu |
| `product_category` | yes | yes | no | POS filters |
| `dining_table` | yes | yes | no | floor board |
| `employee` | yes | yes | no | sign-in (the check is in SQL) |
| `customer` | yes | yes | no | none |
| `orders` | yes | yes | yes | orders, KDS, dashboard |
| `order_line` | yes | yes | yes | KDS summary |
| `order_status_history` | no | no | yes | none |
| everything else | no | no | no | none |

---

## 5. Live queries

### The two verbs

| Verb | Behaviour | Result |
|---|---|---|
| `fx.dbQuery` | One shot. The engine runs the statement and delivers one page. | Exactly one `Msg` carrying `EffectDbResult`. |
| `fx.dbSubscribe` | A live read query. The initial pages arrive immediately, and after each successful transaction the engine re-runs the query **only when SQLite's update hook named one of the subscribed tables**. | The same `Msg` type, delivered again on every matching change. |

`dbSubscribe` is the direct replacement for v1's `ref.invalidate` /
`FutureProvider` invalidation: the store decides when the view's data is
stale, and the app does not have to guess.

### Where Restaurant OS will use each

**`dbQuery` — one-shot reads.** Anything the app fetches once and holds:

| Use | Why a one-shot is right |
|---|---|
| The sign-in check | `SELECT id, name, role FROM employee WHERE pin_hash = ?1 AND active = 1 LIMIT 1;` — a point lookup, not a stream |
| The menu and categories | The catalogue changes on an admin screen, not continuously |
| The company row | `LIMIT 1`; one company per database |
| `app_config` | The PIN salt is fetched once at boot |
| Reports and exports | A bounded range read |
| A page of the order history | Paging, not a subscription |

**`dbSubscribe` — live reads.** Anything another window, another device
or the sync sidecar can change underneath the view:

| Use | What changes it |
|---|---|
| The kitchen board (`orders`, `order_line`) | Another window advances a ticket; the sync sidecar applies an incoming order |
| The order list | Same |
| The floor board (`dining_table.status`) | A waiter seats or clears a table on another device |
| The `op_log` watch | The sync sidecar writes incoming operations into the log |
| The dashboard counts | Derived from the same live order set |

### What it means for the code today

Every read in `repos.zig` is a `dbQuery`, and every refresh is an
explicit `load*` call. The consequence is visible in the KDS: the board
does not update itself when another window writes, because nothing
subscribes.

The migration is mechanical rather than structural. A subscription
reuses the same decoder — the result payload is the same page format —
so the work is:

1. Add a `dbSubscribe` variant of the loader in `repos.zig`, keyed with
   its own `key_*` constant.
2. Point `on_result` at the same `Msg` arm the query uses.
3. Subscribe when the screen that needs it mounts, unsubscribe when it
   unmounts (`fx.dbUnsubscribe`).

The model side does not change: the subscriber's result lands in the
same `Msg`, the same `update` arm decodes it into the same bump buffer,
and the same rebuild renders it. That is the payoff of keeping every
read on the same path.

---

## 6. The PIN and salt design

### The shape of it

| Piece | Where | Detail |
|---|---|---|
| Hash of the PIN | `employee.pin_hash` | `TEXT NOT NULL DEFAULT ''` — a 64-character hex digest |
| Salt | `app_config` where `key = 'pin_salt'` | 64 hex characters, generated once per installation |
| Hashing | `data/auth.zig` → `hashPin(salt, pin, out)` | SHA-256 over `salt || pin`, hex-encoded |
| Salt generation | `data/auth.zig` → `makeSalt(io, out)` | 32 random bytes, hex-encoded, written once |
| Comparison | `data/auth.zig` → `equal(a, b)` | Constant-time, no early exit |

### Why salted SHA-256, and why per installation

A PIN is a password, and PINs are short: four to six digits, so a
million candidates at most, which a modern GPU exhausts in seconds
against an unsalted digest. Two things follow.

**The salt defeats the precomputed table.** Every installation has its
own salt, so the same PIN produces a different digest on every device:

```zig
/// Hash a PIN with the installation salt, hex-encoded.
///
/// The salt is stored in `app_config` (see the schema) and never leaves
/// the device.
pub fn hashPin(salt: []const u8, pin: []const u8, out: *[hex_len]u8) void {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(salt);
    hasher.update(pin);
    hasher.final(&digest);
```

**The salt is not a secret.** It lives in `app_config` in the same
database as the hashes. Its job is to make the digests unlinkable across
installations, not to be secret. Two restaurants with the same PIN do
not share a digest, so one database's hash table tells an attacker
nothing about another's.

### The plaintext never reaches the database

The check happens in SQL, and the candidate hash is a query parameter:

```zig
/// The SQL behind a sign-in attempt. The PIN is hashed before it gets
/// here - the database never sees a plaintext PIN.
pub const login_sql =
    \\SELECT id, name, role FROM employee
    \\WHERE pin_hash = ?1 AND active = 1
    \\LIMIT 1;
;
```

The plaintext lives in the model only for the duration of the attempt, in
a `canvas.TextBuffer(8)`, and is cleared whether the attempt succeeds or
fails:

```zig
.pin_edit => |event| model.pin.apply(event),
```

```zig
model.login_error = "Sign-in failed - try again";
model.pin.set("");
```

The digest being checked lives in `model.login_hash` — "the hash of the
PIN being checked. Lives in the model so the query parameter has a
stable home" — and it never enters the `Employee` domain struct:

```zig
/// A staff member. The PIN hash never enters this struct: the login
/// check happens in SQL, and only the id and display name come back.
pub const Employee = struct {
    id: i64,
    name: []const u8,
    role: i64,
    active: bool,
};
```

### The salt lifecycle

The salt is a **provisional** value at boot and becomes real when the
database confirms it.

1. `main.zig` generates a provisional salt, because this is the only
   place with an `Io`:

   ```zig
   auth.makeSalt(init.io, &app_state.model.pin_salt_buf);
   app_state.model.pin_salt_len = app_state.model.pin_salt_buf.len;
   ```

   `model.salt_is_provisional` starts `true`.

2. `boot` asks the database for the stored salt
   (`repos.loadConfig` → `fx.dbQuery` → `Msg.config_loaded`).

3. The `config_loaded` arm takes one of three paths:

   ```zig
   .config_loaded => |result| {
       if (result.outcome != .ok) return;
       if (result.kind != .page) return;
       var reader = page.Reader.init(result.bytes);
       var values: [page.max_columns]page.Value = undefined;
       if (!reader.readHeader() or !reader.nextRow(&values)) {
           // No salt yet: this is a fresh installation. Make one.
           createSalt(model, fx);
           return;
       }
       const salt = reader.textOf(&values, "value");
       if (salt.len == 0) {
           createSalt(model, fx);
           return;
       }
       const copied = model.pin_salt_buf[0..];
       const length = @min(salt.len, copied.len);
       @memcpy(copied[0..length], salt[0..length]);
       model.pin_salt_len = length;
       model.salt_is_provisional = false;
   },
   ```

   * No row, or an empty value → fresh installation → `createSalt`
     writes the provisional salt to the database.
   * A row with a value → adopt the stored salt, overwriting the
     provisional one, and clear the provisional flag.

   ```zig
   /// A fresh installation keeps the salt made at boot and writes it once.
   /// The PIN hashes are useless without it, so it is persisted before the
   /// first sign-in is possible.
   fn createSalt(model: *Model, fx: *Effects) void {
       model.salt_is_provisional = false;
       repos.saveConfigValue(fx, repos.key_config, "pin_salt", model.pin_salt(), fx.wallMs());
   }
   ```

4. Sign-in currently refuses only an **empty** salt. It does not yet
   check `salt_is_provisional`, so a very fast sign-in can still race the
   first config read. This is a known defect (see `plan/status.md`, D1),
   not the intended design:

   ```zig
   .submit_login => {
       if (model.pin_salt().len == 0) {
           model.login_error = "Still starting up - try again in a moment";
           return;
       }
   ```

### The comparison helper

```zig
/// Compare two hashes without an early exit - a constant-time compare
/// keeps the check honest even though the attacker controls neither
/// side's timing in a meaningful way here.
pub fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |x, y| difference |= x ^ y;
    return difference == 0;
}
```

The sign-in path compares in SQL (`pin_hash = ?1`), so `equal` is not on
that path today. It exists for the paths where two digests meet in Zig:
a PIN change that re-hashes against the stored hash, and the reset-PIN
flow.

### The test

```zig
test "a PIN is hashed, never stored" {
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
```

---

## 7. What v1 got wrong that this schema fixes

Grounded in the v1 schema at `eatery/assets/db/schema.sql` and in the
comments the Restaurant OS code carries about its predecessor.

| v1 | Restaurant OS | Why it matters |
|---|---|---|
| Money in `REAL` columns — `grandTotal REAL`, `mrpPrice REAL`, `discountRate REAL` | Money in `INTEGER` minor units; rates in basis points | Binary floats lose cents. A day's total cannot be reconstructed exactly from them. |
| `employee.pin TEXT` — the PIN in the clear | `employee.pin_hash TEXT` — a salted SHA-256 digest | A curious operator with a database file could read any PIN, and a stolen file leaked every PIN at once. |
| `company.password TEXT` | Removed; the company row carries no credential | One credential, one place, one algorithm. |
| 39 tables with loose affinity, no `STRICT` | 43 tables, every one `STRICT`, every enum constrained by a `CHECK` | A declared type has to mean something, or the mistake surfaces three layers away. |
| No type discipline on enums — `productType INTEGER`, `type INTEGER` with no allowed set | `CHECK (product_type IN (0, 1, 2, 3, 4))`, `CHECK (status IN (0, 1, 2, 3, 4, 5))`, `CHECK (role IN (0, 1, 2, 3))` | The database refuses an impossible state, not the app. |
| Order lines referenced the product, so a price change rewrote history | `order_line.product_name` and `unit_price_minor` are frozen at the sale | "A price change tomorrow must not rewrite yesterday's bills." |
| No lifecycle ledger | `order_status_history`, written in the same transaction as the status change | The kitchen board and the receipt both read it, and it cannot disagree with the order's current status. |
| No record of a void | `void_log_entry` with a reason, an employee and an amount | An X/Z report has to be reconstructible from the database alone, months later. |
| No tax, discount or modifier model | `tax_slab`, `discount`, `order_discount`, `modifier_group`, `modifier`, `product_modifier`, `order_line_modifier` | The sale's arithmetic was implicit in v1; it is now data, and it is frozen into the order. |
| A stock number with no reason attached | `stock_adjustment` — a signed delta, a reason and a reference | "Why is this number 40 instead of 50" has an answer. |
| The sync transport lived inside the app | `op_log` and `device` tables; a sidecar owns the socket and the mDNS announcement | The app never speaks a network protocol; it only reads and writes rows. |
| Multi-company, with `nextInvoiceNo` and a per-company currency | One company per database; `currency` is a reference table | The multi-company story was never used and cost real time. |
| No device identity | `device` table, with the role and `last_seen_at` | Sync identity is first-class. |
| Local-time strings and epoch mixes | One time shape everywhere: `INTEGER` epoch milliseconds, UTC | Ordering and range queries need no per-column knowledge. |

---

## 8. Checklist: changing the schema

1. Read `apps/ros/src/schema/` and `apps/ros/src/data/repos.zig`.
2. Add `apps/ros/src/schema/NNNN_name.sql`. Never edit an earlier file.
3. Keep `STRICT`, the `CHECK` constraints, integer minor-unit money and
   epoch-millisecond time.
4. Add the SQL constant, the loader and the decoder in
   `apps/ros/src/data/repos.zig`. Give the effect its own `key_*`.
5. Regenerate `apps/ros/src/schema/migrations.lock.json` through the
   SDK tooling, or run `native db new-migration`.
6. Run `native check` — it prepares the schema with real SQLite and
   reports `file:line:col`.
7. Run `native test`. Add a migration test on an in-memory database:

   ```zig
   var db = try native_sdk.relational_store.Database.openMemoryMigrated(
       testing.allocator,
       migrations,
   );
   defer db.deinit();

   var fx = Effects.init(testing.allocator);
   fx.executor = .fake;
   fx.bindRelationalStore(db.binding());
   ```

8. Update `apps/ros/src/domain/models.zig` if a new entity or enum
   appears, and `docs/architecture/05-schema.md`.

### Gotchas

| Gotcha | Detail |
|---|---|
| The order id is the wall clock in milliseconds | Two orders in the same millisecond collide. `order_no` is the wall clock in seconds and is `UNIQUE`, so two orders in the same second collide too. The scheme is provisional — see [ADR-0013](../decisions/0013-clock-based-order-ids.md). |
| `config_sql` is hard-coded | `SELECT key, value FROM app_config WHERE key = 'pin_salt' LIMIT 1;` — a generic config read is a small future refactor. |
| `orders_sql` caps at 200 | `WHERE status <> 5 ORDER BY placed_at DESC LIMIT 200`. There is no "load more". |
| `loadAll` does not load customers | `repos.loadCustomers` has no caller today. |
| `decodeCompany` does not copy its strings | `model.company_name = reader.textOf(&values, "name")` points into the page bytes. The company row is read once at boot and the page is dead after that update — this is a latent defect, not a pattern to copy. |
| `order_status_history` has no read path | It is written but never queried; no repository decodes it. |
| The tax path is not wired | `order_line.tax_bps` and `orders.tax_minor` exist; `placeOrder` writes `tax_bps = 0` and `tax_minor = 0`. |
| No seed data | A fresh install has no company, no employee and no products. Sign-in cannot succeed until setup exists. |
