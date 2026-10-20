# Data layer

> **Status:** Partial — core reads and order writes work; most entities have
> no write path or UI.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/data/repos.zig`, `src/data/page.zig`, `src/data/auth.zig`,
> `src/core/update.zig`, `src/domain/models.zig`.

## Principles

1. **SQL lives in one file.** Every statement is a named constant in
   `repos.zig`. A schema change is one edit, not a grep.
2. **Reads copy; writes are atomic.** A read lands in the model's bump
   buffer because page bytes are drain scratch. A write is one `dbExec`
   whose statements the engine runs as a single transaction.
3. **The model never holds a database handle.** The engine owns the
   connection; the app asks for effects.
4. **Keys are explicit.** Every effect slot has a `u64` key, namespaced so
   a read and a write cannot collide.
5. **Decoding is defensive.** An out-of-range enum falls back to the first
   variant; a NULL reads as the caller's fallback, not zero. A database is
   allowed to be wrong; the app is not allowed to crash because of it.

## Read path

```
update / boot
   └── repos.loadProducts(fx)
          └── fx.dbQuery({ key, sql, on_result: .products_loaded })
                 │  (engine runs SQL on the host side, off the UI loop)
                 ▼
          Msg.products_loaded(EffectDbResult)
                 └── update arm
                        └── repos.decodeProducts(model, result.bytes)
                               ├── page.Reader streams the page
                               ├── model.products_buf.reset()
                               ├── allocSlice(Product, row_count)
                               └── dupe every text field into the bump
```

Key points:

- **No allocator in `update`.** The reader streams the page; the caller
  copies each row into fixed storage as it goes.
- **Column names, not positions.** Decoders call
  `reader.intOf(&values, "id", 0)`, so a column reorder in SQL cannot
  silently swap two fields.
- **Text ownership transfers at decode.** A model row's `[]const u8`
  points into the bump, never into the page.
- **A read failure leaves the old rows in place** and sets `error_text`.

## Page wire format

The engine delivers one encoded page per result. Little-endian:

| Part | Encoding |
|---|---|
| Header | `u32 column_count`, `u32 row_count` |
| Column names | Per column: `u32 byte_len`, then UTF-8 bytes |
| Rows | Row-major; per column one tagged value |

| Tag | Type | Payload |
|---|---|---|
| 0 | NULL | none |
| 1 | INTEGER | `i64` |
| 2 | REAL | `f64` bit pattern |
| 3 | TEXT | `u32 len` + bytes |
| 4 | BLOB | `u32 len` + bytes |

Limits and safety:

- Maximum 64 columns per query (`page.max_columns`); the reader is a
  stack allocation.
- Invalid UTF-8 in a text column reads as empty text.
- A truncated page fails the read rather than returning partial garbage.
- `Reader.rows_left` is decremented per row; `nextRow` returns false at
  the end.

The decoder is unit-tested by hand-building a page (two columns, two
rows, NULL + INTEGER + TEXT).

## Write path

Writes are `fx.dbExec` with one or more statements. The engine runs them
atomically.

### Place an order

`repos.saveOrder` builds a statement array on the stack:

1. `INSERT INTO orders ... ON CONFLICT(id) DO UPDATE SET status, notes, updated_at`
2. one `INSERT INTO order_line ... ON CONFLICT(id) DO UPDATE SET qty, unit_price` per line

- Capacity: 1 + 64 statements (`max_order_lines = 64`).
- Parameters live on the stack because `dbExec` executes synchronously.
- The order and its lines are either both present or both absent.
- The model's cart is cleared only after `order_placed` reports success.

### Advance an order

`repos.setOrderStatus` runs two statements in one transaction:

1. `UPDATE orders SET status, updated_at WHERE id`
2. `INSERT INTO order_status_history (order_id, status, changed_at)`

The history and the current status can never disagree.

### Settings

`repos.saveConfigValue` upserts `app_config(key, value, updated_at)`.
This is used for the PIN salt today; the target also uses it for the
device role and the current shift.

### Not implemented

There is no write path for products, categories, tables, employees,
customers, payments, discounts, modifiers, taxes, suppliers, purchase
orders, reservations, printers or devices. The schema exists; the
repositories do not.

## Effect keys

| Key | Value | Family |
|---|---|---|
| `key_products` | 1 | read |
| `key_tables` | 2 | read |
| `key_employees` | 3 | read |
| `key_orders` | 4 | read |
| `key_customers` | 5 | read |
| `key_categories` | 6 | read |
| `key_company` | 7 | read |
| `key_login` | 8 | read |
| `key_order_lines` | 9 | read |
| `key_config` | 10 | read |
| `key_write_order` | 20 | write |
| `key_write_product` | 21 | write (unused) |
| `key_write_table` | 22 | write (unused) |
| `clock_timer_key` | 100 | timer |

A key identifies an effect slot for cancellation/replacement. Reusing a
key across a query and a write is a bug that the table above is meant to
prevent.

## Repository coverage

| Entity | Read | Decode | Write | UI |
|---|---|---|---|---|
| company | Yes | Yes | No | Dashboard header / labels |
| app_config | Yes (salt) | Yes | Yes (upsert) | Login |
| product | Yes | Yes | No | POS menu |
| product_category | Yes | Yes | No | POS filters |
| dining_table | Yes | Yes | No | Floor board |
| employee | Yes | Yes | No | Login (SQL), not a list |
| customer | Yes | Yes | No | None |
| orders | Yes | Yes | Yes (insert/update) | Orders, KDS, dashboard |
| order_line | Yes | Yes | Yes (insert) | KDS summary |
| order_status_history | No read | No | Yes (insert) | None |
| auth | — | — | — | Login (SHA-256) |
| everything else | No | No | No | None |

### Query behaviour

- `orders_sql` selects `status <> 5` (not voided), newest first, limit
  200. Completed orders remain in the list.
- `order_lines_sql` selects lines for non-voided orders, so the kitchen
  summary has data without a second round trip.
- `products_sql` selects active products ordered by name; the POS filters
  by category and search in the model, not in SQL.
- `config_sql` is hard-coded to `key = 'pin_salt'`. A generic config read
  is a small future refactor.
- `company_sql` has `LIMIT 1`; one company per database is a schema rule,
  not just a UI choice.
- `loadAll` omits `loadCustomers` and `loadConfig`. Customers are loaded
  by no caller today.

## Boot and migrations

The app declares the `sqlite` capability in `app.json`. The SDK compiles
its SQLite engine into the app, generates a migrations module from
`src/schema/*.sql`, and opens the database migrated at boot. The
append-only authority is `src/schema/migrations.lock.json` (version 10,
10 hashes).

The app does not open the database, set PRAGMAs, or run migrations
itself. That is deliberate: the engine owns the connection.

## IDs and time

| Value | Shape | Rule |
|---|---|---|
| Order `id` | `i64` wall clock ms | Not a sequence; two orders in the same millisecond collide |
| Order `order_no` | wall clock seconds as text | `UNIQUE`; two orders in the same second collide |
| Order line `id` | order id + line index | Collides if an order is rewritten in the same ms |
| `placed_at`, `created_at`, `updated_at` | epoch ms UTC | Integer, never a string |
| `pin_salt` | 64 hex chars in `app_config` | Per installation |

The ID scheme is documented as **provisional** in
[ADR-0013](../decisions/0013-clock-based-order-ids.md). A dedicated
sequence or UUID is the target.

## Error taxonomy

`EffectDbResult.outcome` drives operator copy:

| Outcome | Copy |
|---|---|
| `busy` | The database is busy - try again |
| `io_failed` | Storage error |
| `corrupt` | The database is damaged |
| anything else | The database refused the request |

Read arms generally set a specific message (`Could not load the menu`,
`Could not load the tables`) and keep the previous data. There is no
retry, backoff, or queued write.

## Testing the data layer

Current tests cover:

- page decoding (NULL fallback, INTEGER, TEXT, end-of-page);
- integer money in the cart;
- PIN hashing determinism and salt divergence.

Target tests (from the port plan) use
`native_sdk.relational_store.Database.openMemoryMigrated(allocator, migrations)`
and `fx.bindRelationalStore(db.binding())` to drive real SQL headlessly.
That is how each repository should be tested: migrate an in-memory
database, insert fixtures, run the query, assert the decoded rows, and
assert the write's atomicity.

See [10-testing-and-quality](10-testing-and-quality.md) and
[phase 2](../plan/phase-2-schema-and-repositories.md).

## Known weak points

1. **No paging.** Orders are capped at 200 and there is no "load more".
2. **No live queries.** `dbSubscribe` is available but unused; every
   refresh is an explicit `load*` call. The KDS does not update itself
   when another window writes.
3. **`busy` is not set on reads.** The UI cannot show a loading state.
4. **Customer data is loaded by no one.** Repository and buffer exist.
5. **No write validation.** The model can build an order with a zero
   total or a negative quantity if a bug lets it; SQL `CHECK`s catch some
   cases, not all.
6. **No optimistic concurrency.** Two devices writing the same row is not
   handled in the app; that is deferred to the sync design.
7. **No transaction spanning multiple effects.** A business operation
   that needs two `dbExec` calls is not atomic. Today's order write avoids
   this by using one call.
