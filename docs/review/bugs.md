# Bugs

> **Snapshot:** 2026-10-20. Evidence is from source review, `native check`,
> `native test`, and a throwaway SQLite database built from
> `src/schema/*.sql`. Line numbers drift; use the named symbol.

Severity: **P0** blocker · **P1** high · **P2** medium · **P3** low.

| ID | Severity | Summary |
|---|---|---|
| [B-001](#b-001--order-insert-omits-ordersupdated_at) | P0 | Every order insert fails: `orders.updated_at` is required but never written. **Fixed in the working tree; uncommitted.** |
| [B-002](#b-002--login-ignores-the-employees-stored-role) | P0 | Any PIN signs in under any chosen role (privilege escalation) |
| [B-003](#b-003--the-boot-salt-is-accepted-before-the-database-confirms-it) | P0 | Login can hash against a provisional salt; a failed save is marked confirmed |
| [B-004](#b-004--company-strings-point-into-dead-page-bytes) | P1 | Company name and currency dangle after the update returns. **Fixed in the working tree.** |
| [B-005](#b-005--order-foreign-keys-are-written-as-0) | P1 | Table and customer IDs are `0`, not `NULL` or real rows. **Fixed in the working tree.** |
| [B-006](#b-006--clock-shaped-order-ids-collide) | P1 | Same-ms IDs merge orders; same-second `order_no` fails `UNIQUE` |
| [B-007](#b-007--place-order-can-be-submitted-twice) | P1 | `busy` is set but never checked or bound; double-click can duplicate |
| [B-008](#b-008--status-advance-is-not-idempotent) | P1 | Double-advance writes duplicate history and repeats terminal states |
| [B-009](#b-009--back-from-home-lands-on-the-login-screen) | P1 | Login success pushes home on top of login; Back shows a blank shell |
| [B-010](#b-010--the-navigation-stack-fills-and-silently-freezes) | P1 | Repeating a rail/shortcut push fills 32 slots; navigation then stops |
| [B-011](#b-011--session-state-survives-sign-out-and-role-change) | P1 | Cart, search, filter and errors leak between operators |
| [B-012](#b-012--the-orders-list-and-badge-disagree-with-the-model) | P1 | Completed orders are listed as “open”; no pagination; lines query mismatched |
| [B-013](#b-013--currency-is-hard-coded-to-two-decimals) | P1 | JPY, KWD and every non-2-decimal currency display wrong |
| [B-014](#b-014--tax-discount-and-payment-are-not-implemented) | P1 | Totals are subtotal-only; an order can complete without payment |
| [B-015](#b-015--customers-are-never-loaded) | P1 | `loadAll` omits `loadCustomers`; the customer dataset is always empty |
| [B-016](#b-016--stock-is-ignored) | P1 | `track_stock` is not read; nullable stock becomes zero; sales never decrement |
| [B-017](#b-017--inactive-categories-tables-and-customers-are-shown) | P2 | Only products and employees filter `active` |
| [B-018](#b-018--orderstatusfromcode-is-a-latent-compile-error) | P2 | `catch` on an optional; unused today, breaks on first call |
| [B-019](#b-019--db_ready-is-set-without-a-company) | P2 | An empty company is treated as ready; no setup detection |
| [B-020](#b-020--most-load-failures-are-silent) | P2 | Seven result arms ignore errors; the screen stays blank |
| [B-021](#b-021--busy-never-covers-reads-and-is-not-rendered) | P2 | No loading state; controls stay enabled |
| [B-022](#b-022--a-one-second-timer-rebuilds-the-whole-app) | P2 | The clock tick fires on every screen, not just the KDS |
| [B-023](#b-023--shell-gates-use-hard-coded-screen-ordinals) | P2 | Inserting a screen silently remaps the shell |
| [B-024](#b-024--manifest-and-zig-shell-disagree) | P2 | Minimum size, restore policy and some capabilities differ |
| [B-025](#b-025--fixed-bump-buffers-truncate-datasets-silently) | P2 | A large menu or order log becomes an empty or partial list |
| [B-026](#b-026--order-number-allocation-can-return-0) | P2 | A full cart bump buffer returns the literal `"0"` |
| [B-027](#b-027--pin-authentication-is-too-weak-for-a-pos) | P1 | Fast SHA-256, four digits, no lockout, unmasked entry, unused constant-time compare |
| [B-028](#b-028--two-app-instances-can-fight-over-the-salt) | P2 | No single-instance lock; last writer wins and old PINs stop matching |
| [B-029](#b-029--status-updates-ignore-a-missing-row) | P2 | History is written even when the order update matched nothing |
| [B-030](#b-030--the-seedable-schema-has-invalid-default-references) | P2 | `product.tax_slab_id` defaulted to `0` with no row. **Fixed by migration 0011.** |
| [B-031](#b-031--the-setup-currency-symbol-field-writes-the-code) | P2 | The setup screen binds both currency fields to the code handler |
| [B-032](#b-032--the-setup-submit-button-is-never-disabled) | P2 | `setup_can_submit` exists but the markup does not bind it |
| [B-033](#b-033--another-order-does-nothing) | P1 | The confirmation screen dispatches an unhandled `back_to_pos` |
| [B-034](#b-034--the-confirmation-screen-shows-raw-epoch-milliseconds) | P2 | `last_order_time` is an `i64` timestamp bound as text |
| [B-035](#b-035--payment-can-be-taken-twice) | P1 | No paid/status guard or disabled button; each tap inserts a payment |

---

## B-001 — Order insert omits `orders.updated_at`

**Severity:** P0 · **Area:** data / POS · **Status:** confirmed by reproduction

**Evidence**

- `src/schema/0005_orders.sql` declares `updated_at INTEGER NOT NULL`
  with no default (line 22).
- `src/data/repos.zig` `saveOrder` inserts fourteen columns and supplies
  thirteen parameters. `created_at` is supplied; `updated_at` is not
  (`INSERT INTO orders ...`).
- The generated `.native/cache/sqlite/migrations.zig` contains the same
  table definition, without a trigger or default.
- Reproduction: applying the ten migrations to a temporary SQLite
  database and running the exact `saveOrder` column list fails with
  `NOT NULL constraint failed: orders.updated_at`.
- The working-tree integration test “an order is written, read back, and
  its status advances” fails at `cart_len` (expected 0, found 2): the
  write did not succeed, so the cart was not cleared.

**Impact**

`place_order` could not write an order on any fresh database. The
operator saw “Could not save the order”; the sale flow was non-functional.

**Disposition:** fixed in the working tree — `saveOrder` now supplies
`updated_at`, and the in-memory integration test places and reads back an
order (25/25 tests pass). The committed `HEAD` still has the defect; do
not describe the committed build as able to sell until that fix lands.

**Fix**

Keep the column in the insert and keep the DB read-back test. Consider a
schema trigger or default only if every writer should share it.

---

## B-002 — Login ignores the employee's stored role

**Severity:** P0 · **Area:** security / session · **Status:** confirmed by inspection

**Evidence**

- `src/core/update.zig` `login_sql` selects `id, name, role` but filters
  only on `pin_hash` and `active`.
- `login_checked` copies `id` and `name`, sets `signed_in = true`, and
  navigates to `rbac.home(model.role)`. The `role` column in the result
  is never read or compared.
- `model.role` is whatever the operator picked on the previous screen.

**Impact**

An employee whose stored role is `waiter` can choose **Admin**, enter
their own PIN, and receive the full admin session. The database role is
decorative. A shared PIN (two employees with the same PIN) also selects
an arbitrary row because of `LIMIT 1`.

**Fix**

Add `AND role = ?2` to the login query, filter by the chosen role, and
assert the returned role matches before signing in. Treat a role
mismatch as a normal failed login. Add tests for waiter-PIN-as-admin and
admin-PIN-as-waiter.

---

## B-003 — The boot salt is accepted before the database confirms it

**Severity:** P0 · **Area:** security / startup · **Status:** confirmed by inspection

**Evidence**

- `src/main.zig` generates a random salt on every launch and sets
  `pin_salt_len = 64` immediately. `salt_is_provisional` starts `true`.
- `boot` asks for the config asynchronously. Until `config_loaded`
  returns, the model contains the boot salt but no database confirmation.
- `submit_login` checks only `model.pin_salt().len == 0`; it never checks
  `salt_is_provisional`.
- `createSalt` sets `salt_is_provisional = false` **before**
  `saveConfigValue` completes. `config_saved` is ignored.
- A failed config write therefore leaves the model claiming the salt is
  confirmed while the database has no salt (or an older one).

**Impact**

A fast sign-in can hash a PIN against the boot salt, which is then
replaced by the stored salt; that PIN never matches again. A failed first
write can make an entire installation's PINs unusable after restart. The
salt is also regenerated on every launch even when the database already
has one, widening the race. Setup hashes the first admin PIN with the same
unconfirmed salt.

**Fix**

Generate the salt only when the config read proves there is none;
otherwise load the stored salt. Keep `salt_is_provisional = true` until a
`config_saved` result for the salt key confirms the write, and refuse
login while it is provisional. Clear the boot salt on failure and surface
a retryable error.

---

## B-004 — Company strings point into dead page bytes

**Severity:** P1 · **Area:** data / memory · **Status:** confirmed by inspection

**Evidence**

- `src/data/repos.zig` `decodeCompany` assigns
  `model.company_name = reader.textOf(...)`,
  `model.currency_code = ...`, and `model.currency_symbol = ...`.
- `src/data/page.zig` states that page bytes are drain scratch, valid only
  through the update that received them; every other decoder copies text
  into a bump buffer.
- `decodeCompany` has no company buffer and performs no copy.

**Impact**

After `company_loaded` returned, the slices pointed at memory the runtime
may reuse. The title bar, currency symbol and receipts could show
garbage, or the app could crash.

**Disposition:** fixed in the working tree — a `company_buf` copies the
name and currency strings, and the integration test reads them back.

**Fix**

Keep the copy and the test. Any future decoder must follow the same
ownership rule.

---

## B-005 — Order foreign keys are written as `0`

**Severity:** P1 · **Area:** schema / data integrity · **Status:** conditional on engine FK enforcement

**Evidence**

- `orders.dining_table_id` and `orders.customer_id` are nullable foreign
  keys (`0005_orders.sql`, lines 12–13).
- `placeOrder` sets both to `0` (`src/core/update.zig`).
- Reproduction with `PRAGMA foreign_keys=ON`:
  `FOREIGN KEY constraint failed` for an order with `dining_table_id=0`
  and `customer_id=0`.
- The engine's foreign-key setting is not visible in app code; SQLite's
  default is off, so the write may “succeed” while storing dangling
  references.

**Impact**

If the engine enforced FKs, order placement failed even after B-001 was
fixed. With FKs off, every take-away/delivery order referenced
nonexistent table and customer rows.

**Disposition:** fixed in the working tree — `idParam` sends
`.null_value` for zero, and the model still has to choose a real table for
dine-in (G-011). The engine's FK setting remains unknown (G-025).

**Fix**

Keep the nullable write, verify FKs on, and attach a real table for
dine-in once the floor is interactive.

---

## B-006 — Clock-shaped order IDs collide

**Severity:** P1 · **Area:** data / POS · **Status:** confirmed by inspection

**Evidence**

- `placeOrder` uses `fx.wallMs()` as `orders.id` and as the base for
  `order_line.id` (`now + index`).
- `allocOrderNo` uses `floor(wallMs / 1000)`; `orders.order_no` is
  `UNIQUE`.
- `saveOrder` uses `ON CONFLICT(id) DO UPDATE`, so an ID collision
  silently updates the earlier order instead of failing.
- Two orders in the same second produce the same `order_no`; the second
  insert fails `UNIQUE`, regardless of the ID.

**Impact**

Two tills, a double-click, or an order and a quick re-ring can merge
orders, overwrite lines, or fail with a generic error. The order number is
not a reliable human identifier.

**Fix**

Use a database sequence or a collision-resistant ID (ULID/UUIDv7) for
`id`, and a separate monotonic, human-readable sequence for `order_no`.
Make the write idempotent with a client-generated request key.

---

## B-007 — Place order can be submitted twice

**Severity:** P1 · **Area:** POS · **Status:** confirmed by inspection

**Evidence**

- `placeOrder` sets `model.busy = true` only after building the order and
  does not check it on entry.
- The POS button binds `place_order` unconditionally; `busy` is not in
  `view_unbound` as a visible binding and no template reads it.
- The cart is cleared only when `order_placed` succeeds.

**Impact**

A double-click (or a slow write) submits the same cart again. Depending
on timing, B-006 merges the two writes or creates two orders.

**Fix**

Check `busy` in `placeOrder`, disable the button while busy, and clear or
lock the cart at submit time. Keep a request key so a retry is
idempotent.

---

## B-008 — Status advance is not idempotent

**Severity:** P1 · **Area:** orders / KDS

**Evidence**

- `advance_order` reads the status from the in-memory model, computes the
  next status, and writes immediately.
- `busy` is not checked or set; the button is always enabled.
- `setOrderStatus` writes an `order_status_history` row on every call, with
  no unique constraint or expected-current-status guard.
- `nextStatus(.completed)` returns `.completed`; a second advance rewrites
  the same terminal status and adds another history row.

**Impact**

Two quick taps (or two devices) write the same transition twice, or skip
a state if the model is stale. The audit trail becomes wrong, and a
completed order can be “advanced” repeatedly.

**Fix**

Make the transition conditional: `UPDATE ... WHERE id=? AND status=?`,
check rows affected, write history only on a real change, and coalesce
in-flight requests. Return the new status to the model instead of
recomputing from stale data.

---

## B-009 — Back from home lands on the login screen

**Severity:** P1 · **Area:** navigation / session

**Evidence**

- `pick_role` calls `go(model, .login)`, which pushes `login` onto the
  stack.
- `login_checked` calls `go(model, home)`, which pushes `home` on top; it
  does not reset the stack.
- `app.native` renders the shell whenever `signed_in` is true; the content
  pane has gates only for dashboard/POS/orders/tables/kitchen.
- `go_back` pops to `login`, sets `screen_index=1`, and the shell renders
  an empty content pane.

**Impact**

The first Back after signing in shows a blank screen with no way to
return except another navigation. The shell's history contains a
pre-session screen it should never expose.

**Fix**

Reset the stack on session transitions (`pick_role`, successful login,
sign-out), or mark session screens as non-history entries. Add a test
that signs in and goes back.

---

## B-010 — The navigation stack fills and silently freezes

**Severity:** P1 · **Area:** navigation

**Evidence**

- `Stack.push` refuses at `max_depth = 32`; `go` returns without an error
  when the push fails.
- `open_section`, `open_pos`, `open_orders`, `open_tables` and
  `open_screen` all push, even when the target is already current.
- Nothing deduplicates or trims the stack except a full reset.

**Impact**

After 32 rail clicks or shortcut presses, every navigation attempt is
silently ignored; the app appears frozen until sign-out (which resets).
This is easy to hit in a busy service.

**Fix**

Do not push when the target equals the current screen; trim forward
history; or use a bounded stack with a clear “cannot go back further”
policy. Surface the refusal instead of doing nothing.

---

## B-011 — Session state survives sign-out and role change

**Severity:** P1 · **Area:** session / privacy

**Evidence**

- `sign_out` clears `employee_id` and `employee_name` only. The cart,
  search text, category filter, order type and errors remain.
- `pick_role_again` clears the PIN and stack but not the cart or filters.
- `pick_role` does not clear them either.

**Impact**

The next operator inherits the previous operator's cart and search. On a
shared till this can produce a wrong order or expose a customer's items.

**Fix**

Add a single `resetSession` that clears cart, search, filters, errors and
employee fields on sign-out and role change. Keep only device-level
settings (theme, window size) if desired.

---

## B-012 — The orders list and badge disagree with the model

**Severity:** P1 · **Area:** orders / UI

**Evidence**

- `orders_sql` selects `WHERE status <> 5` (non-voided), ordered by
  `placed_at DESC`, `LIMIT 200`; completed orders are included.
- `screen-orders.native` labels the badge `{order_count} open`, but
  `order_count` counts every loaded order.
- `order_lines_sql` selects lines for **all** non-voided orders, not the
  200 loaded by `orders_sql`.
- The list has no status filter, pagination or “load more”, and the
  Advance button is shown on completed orders.

**Impact**

The “open” number includes completed orders; the list is not an open-order
board. Lines for orders outside the 200-row window consume the buffer,
and completed orders offer a no-op button.

**Fix**

Use `open_order_count` for the badge or relabel it; decide whether the
screen is “orders” or “open orders”. Scope the lines query to the same
order set and add paging/filtering.

---

## B-013 — Currency is hard-coded to two decimals

**Severity:** P1 · **Area:** money / UI

**Evidence**

- `currency` supports `minor_units BETWEEN 0 AND 4` (`0001_core.sql`).
- `decodeCompany` loads a currency code and symbol, but not `minor_units`.
- Every amount is rendered as `{currency_symbol}{fixed(total_minor / 100, 2)}`
  in the dashboard, POS, orders and kitchen templates.

**Impact**

JPY (0 decimals) shows cents; KWD/BHD (3 decimals) show one tenth of the
amount. A restaurant outside a 2-decimal currency cannot use the totals.

**Fix**

Load the currency's minor-unit exponent and expose a derived formatter
(or a model method returning a formatted string). Never divide by 100 in
markup.

---

## B-014 — Tax, discount and payment are not implemented

**Severity:** P1 · **Area:** money / workflow

**Evidence**

- `placeOrder` writes `tax_minor = 0`, `discount_minor = 0`,
  `total_minor = subtotal`, and each line's `tax_bps = 0`.
- `tax_slab`, `discount`, `order_discount` and `payment` exist in the
  schema with no read or write path.
- `nextStatus` allows `served -> completed` with no payment check.

**Impact**

Bills are wrong for any taxed restaurant; orders can be closed without
money changing hands. The payment table and tax slabs are decorative.

**Fix**

Compute line tax from the slab (respecting `tax_inclusive`), apply order
discounts, and require a payment or an explicit “pay later” action before
completion. Add calculation tests against the v1 oracle.

---

## B-015 — Customers are never loaded

**Severity:** P1 · **Area:** data

**Evidence**

- `repos.loadAll` calls seven loaders; `loadCustomers` is not one of them.
- `customers_loaded` and `decodeCustomers` exist, so the path is wired
  except for the call.
- The `customers` screen is allowed for admin/waiter but has no template.

**Impact**

The customer dataset is always empty; any future customer picker or
loyalty feature has nothing to show.

**Fix**

Add `loadCustomers` to `loadAll`, add a model test, and decide whether the
dataset belongs in the boot aggregate (it may be large).

---

## B-016 — Stock is ignored

**Severity:** P1 · **Area:** inventory / POS

**Evidence**

- `products_sql` selects `stock_qty` but not `track_stock`.
- `Product.stock_qty` is `i64`; the schema column is nullable (“not stock
  controlled”), and `intOf` maps `NULL` to `0`.
- `add_to_cart` checks only the product list; `placeOrder` never
  decrements stock and `stock_adjustment` is never written.

**Impact**

“Not tracked” and “out of stock” are indistinguishable, sold items do not
reduce stock, and inventory data drifts from reality.

**Fix**

Model stock as optional plus `track_stock`; block or warn on zero when
tracked; decrement in the order transaction and write an adjustment row.
Decide whether stock is enforced at add-to-cart or at payment.

---

## B-017 — Inactive categories, tables and customers are shown

**Severity:** P2 · **Area:** data / UI

**Evidence**

- `categories_sql`, `tables_sql` and `customers_sql` have no `active = 1`
  filter.
- `products_sql` and `employees_sql` do.
- The category rail therefore offers archived categories; the floor shows
  retired tables.

**Impact**

Disabled data appears in operational screens and can be selected.

**Fix**

Filter consistently by `active`, or add an explicit “show archived”
setting for admin screens.

---

## B-018 — `OrderStatus.fromCode` is a latent compile error

**Severity:** P2 · **Area:** domain

**Evidence**

- `src/domain/models.zig` `fromCode` uses
  `std.enums.fromInt(...) catch .pending`.
- `std.enums.fromInt` returns an optional, so the correct form is
  `orelse`.
- No caller exists, so Zig's lazy analysis has not compiled it.
- The doc comment points at `domain/orders.zig`, which does not exist.

**Impact**

The first caller breaks the build with a type error unrelated to the
feature being added.

**Fix**

Use `orelse .pending` (or return an error/optional) and delete the stale
comment. Consider using it in the decoders instead of the duplicate
`enumFromInt` helper.

---

## B-019 — `db_ready` is set without a company

**Severity:** P2 · **Area:** startup / setup

**Evidence**

- `company_loaded` sets `model.db_ready = true` even when the page has no
  row (`decodeCompany` returns early).
- `company_label` falls back to “Eatery”, so an unconfigured database
  looks like a configured one.
- There is no `has_company` / setup-required state.

**Impact**

A fresh database silently proceeds to the role picker and login, where
sign-in cannot succeed; the operator has no explanation or setup path.

**Fix**

Track “company exists” explicitly and route a fresh install to setup
(G-001). Show a clear message if the database is empty or unreadable.

---

## B-020 — Most load failures are silent

**Severity:** P2 · **Area:** data / UX

**Evidence**

`products_loaded`, `tables_loaded`, `orders_loaded`, `customers_loaded`,
`categories_loaded`, `employees_loaded`, `order_lines_loaded` and
`company_loaded` return without setting `error_text` when
`result.outcome != .ok` (some also ignore non-page results). Only products
and tables set an error.

**Impact**

A failed query leaves an empty screen with no explanation; the operator
cannot tell “no data” from “database failed”.

**Fix**

Use one error helper with a dataset label; set `error_text` for every
failure and offer retry. Distinguish “empty” from “failed” in the UI.

---

## B-021 — `busy` never covers reads and is not rendered

**Severity:** P2 · **Area:** UX / data

**Evidence**

- `busy` is set in `place_order` and `advance_order` only.
- No template binds `busy`; `view_unbound` includes it, but nothing reads
  it.
- `loadAll` fires seven queries with no loading state.

**Impact**

Slow reads show blank or stale screens; slow writes leave buttons
enabled (see B-007/B-008).

**Fix**

Set a loading flag for the boot aggregate and for each long read; bind it
to a skeleton/disabled state. Consider a small `pending` count instead of
a boolean.

---

## B-022 — A one-second timer rebuilds the whole app

**Severity:** P2 · **Area:** performance

**Evidence**

- `boot` starts a repeating 1000 ms timer regardless of role/screen.
- `tick` writes `model.now_ms` every second.
- The only consumer is the kitchen board's `waiting_label`.

**Impact**

Every screen rebuilds/repaints once a second, including the POS and
orders screens. On a low-power till this is wasted work and may cause
visible churn.

**Fix**

Start the timer when entering the KDS and stop it when leaving; or store
the last tick and rebuild only if a visible screen needs it.

---

## B-023 — Shell gates use hard-coded screen ordinals

**Severity:** P2 · **Area:** navigation / maintenance

**Evidence**

- `src/app.native` gates on `screen_index == 8`, `10`, `13`, `17`, `41`.
- `Screen` is append-only by contract; inserting a variant before an
  existing one silently remaps every gate.

**Impact**

A routine enum insertion produces a blank or wrong screen with no test
failure.

**Fix**

Use a derived binding or a generated gate table, and add a test that
asserts the ordinal of every mounted screen (B-023 is also documented as
D5/D10 in the plan).

---

## B-024 — Manifest and Zig shell disagree

**Severity:** P2 · **Area:** windowing / packaging

**Evidence**

- `app.json` declares `min_width: 960`, `min_height: 600` and
  `restore_policy: center_on_primary`.
- `main.zig` `shell_windows` sets only label, title, width, height and
  views; no minimum or restore policy.
- The manifest also declares `network`, `notifications`, `credentials`,
  `open_url`, `clipboard` and `menus` capabilities that no code uses.

**Impact**

The dev runner can open a window below the declared minimum; the two
shells can drift further. Over-declared permissions increase review and
privacy risk.

**Fix**

Set the same fields in Zig (or generate the shell config from the
manifest) and trim unused permissions/capabilities.

---

## B-025 — Fixed bump buffers truncate datasets silently

**Severity:** P2 · **Area:** data / limits

**Evidence**

- `decodeProducts` allocates `count` rows plus each name in a 96 KiB
  buffer; `decodeOrders` has 48 KiB; `decodeOrderLines` 48 KiB.
- `allocSlice`/`dupe` return `null` on exhaustion; decoders `return`
  without setting `model.products`/`orders` or an error.
- `orders_sql` caps at 200, but `order_lines_sql` loads lines for all
  non-voided orders.
- There is no “load more” for the 200-row cap.

**Impact**

A large menu or a busy service silently shows an empty/partial list with
no diagnostic, and lines may be missing from kitchen tickets.

**Fix**

Surface allocation failure as an error, log the dataset and count, and
add pagination. Size the buffers from the query limits or page instead of
using a single fixed buffer.

---

## B-026 — Order number allocation can return `"0"`

**Severity:** P2 · **Area:** data

**Evidence**

`allocOrderNo` returns the string literal `"0"` when the cart bump buffer
has no room; `order_no` is `UNIQUE`.

**Impact**

The first fallback writes order `"0"`; the next collision fails. Two
unrelated failures collapse into one opaque error.

**Fix**

Make the allocation fallible and fail the sale with a clear error, or
reserve the order-number bytes before filling the cart buffer.

---

## B-027 — PIN authentication is too weak for a POS

**Severity:** P1 · **Area:** security

**Evidence**

- `auth.hashPin` is a single SHA-256 over `salt || pin`; the salt is
  per-installation, not per-user.
- A four-digit PIN has 10,000 possibilities; the hash and salt are local,
  so an offline attacker can enumerate them instantly.
- There is no attempt counter, lockout, delay or audit row.
- `screen-login.native` uses a plain `text-field`, so the PIN is visible
  on screen; it is not a numeric/secure entry.
- `auth.equal` is tested but never used by the login path.

**Impact**

Anyone with a copy of the database can recover a PIN; shoulder-surfing
and brute force are easy. The constant-time comparison gives a false sense
of security.

**Fix**

Use a slow KDF (Argon2id/PBKDF2/scrypt) with a per-employee salt and a
versioned hash format; enforce a minimum PIN policy; rate-limit and lock
out after failures; mask the field or use a keypad; write login/audit
events. Keep `equal` if it is used, otherwise remove the claim.

---

## B-028 — Two app instances can fight over the salt

**Severity:** P2 · **Area:** startup / concurrency

**Evidence**

- `main.zig` generates a salt on every launch before reading `app_config`.
- Two instances on the same database can both see “no salt”, both write,
  and the last write wins; PINs hashed against the first salt stop
  matching.

**Impact**

A support person opening the app while the till is running can break
sign-in.

**Fix**

Read the salt first and generate only under a database-level
insert-if-absent; add a single-instance lock or a documented “close the
other window” check.

---

## B-029 — Status updates ignore a missing row

**Severity:** P2 · **Area:** data integrity

**Evidence**

`setOrderStatus` runs the `UPDATE` and then always inserts history; it
does not check rows affected or the order's existence. With FKs on, the
history insert fails and the transaction rolls back; with FKs off, it
leaves an orphan history row.

**Impact**

A stale order id (deleted/reset database) produces a generic error or
orphan audit data.

**Fix**

Use a conditional update and only insert history when it matched; return a
typed “order gone” result to the UI.

---

## B-030 — The seedable schema has invalid default references

**Severity:** P2 · **Area:** schema / seed

**Evidence**

- `product.tax_slab_id` is `NOT NULL DEFAULT 0 REFERENCES tax_slab(id)`.
- The working-tree integration seed inserts products with
  `tax_slab_id = 0` and no `tax_slab` row.
- With FKs on, that seed fails; with FKs off, products reference a
  nonexistent slab.

**Impact**

A seed that omitted a tax slab could create invalid data or fail when FK
enforcement is enabled.

**Disposition:** fixed by migration `0011_default_tax_slab.sql`, which
inserts the zero-rate slab; setup products reference it. A seed with FKs
on is still not tested.

---

## B-031 — The setup currency symbol field writes the code

**Severity:** P2 · **Area:** setup · **Status:** confirmed by inspection

**Evidence**

`src/screens/screen-setup.native` binds both the “Currency code” and
“Symbol” fields to `on-input="setup_currency_edit"`. There is no
`setup_symbol_edit` message or update arm, so typing a symbol overwrites
`setup_currency_code`.

**Impact**

The operator cannot set a symbol independently; a two-field form behaves
as one. Setup writes the wrong currency code.

**Fix**

Add `setup_symbol_edit` (or a single currency picker) and a handler for
`setup_currency_symbol`; add a render/model test that sets both fields.

---

## B-032 — The setup submit button is never disabled

**Severity:** P2 · **Area:** setup / UX

**Evidence**

The setup template comment says the button stays disabled until the form
is complete, and the model has `setup_can_submit`. The button has no
`disabled` binding, and the function is unused.

**Impact**

An incomplete form is submittable; the operator gets an error instead of
a disabled control. The comment and code disagree.

**Fix**

Bind `disabled="{!setup_can_submit}"` (if the markup supports negation
via a derived helper) and test the incomplete/complete states.

---

## B-033 — “Another order” does nothing

**Severity:** P1 · **Area:** confirmation / navigation

`screen-order-confirmation.native` dispatches `on-press="back_to_pos"`, but
the `Msg` union and `update` have no `back_to_pos` arm. `native check`
does not reject the unknown message, and no test builds this template.

**Impact:** the only escape from the confirmation screen (other than taking
payment) is Back, which may land on the login bug (B-009). A cashier can
be stuck after placing an order.

**Fix**

Add the message and arm (`go(.pos)` or reset the cart flow), include the
screen in the render/screen-coverage test, and make `native check` (or a
test) reject message tags that are not in the union.

---

## B-034 — The confirmation screen shows raw epoch milliseconds

**Severity:** P2 · **Area:** display

`Model.last_order_time` returns `last_order_at` (`i64` epoch ms), and the
template interpolates `{last_order_time}` directly. The operator sees
`1750432101234` instead of a time.

**Impact:** unreadable confirmation; looks broken.

**Fix**

Return a formatted string (or use the SDK's date/time helper on seconds)
and add a render test that asserts a time-like string.

---

## B-035 — Payment can be taken twice

**Severity:** P1 · **Area:** payment / data integrity

`take_payment` sets `busy` but never checks it; the button is not disabled.
The transaction inserts a `payment` and sets `completed` with no
`WHERE status <> completed` guard and no unique constraint on `order_id`.
Each tap adds another payment row and another history row.

**Impact**

Double-charging or a duplicated payment record; the till's totals drift.

**Fix**

Guard in the update and in SQL (`WHERE status <> 4`), check rows affected,
and make one payment per order unique (or explicitly support split
payments with a sum check). Add a test that pays twice.

---

## Cross-cutting note

The working tree now fixes the order write, nullable FKs and company
ownership, and adds a first-run setup. The remaining sale blockers are
identity (B-002), the salt race (B-003), PIN strength (B-027), clock IDs
(B-006) and money (B-014). The committed `HEAD` still has B-001/B-004/
B-005; treat the working tree as the candidate, not the release.
