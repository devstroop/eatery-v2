# Enhancements

> **Snapshot:** 2026-10-20. These are improvements, not blockers. Several
> remove whole classes of bugs rather than patching one instance.

| ID | Severity | Enhancement |
|---|---|---|
| [E-001](#e-001--use-a-real-order-sequence-and-an-idempotency-key) | P1 | Database sequence + client request key |
| [E-002](#e-002--make-every-transition-conditional) | P1 | Expected-current-status guard and actor in history |
| [E-003](#e-003--page-and-virtualise-long-lists) | P2 | Orders/menu pagination; virtualised grids |
| [E-004](#e-004--one-loading-and-retry-model) | P2 | Busy per dataset, disabled controls, retry |
| [E-005](#e-005--persist-device-settings) | P2 | Theme, role, window and last screen |
| [E-006](#e-006--fix-light-theme-contrast) | P1 | WCAG AA for primary/success/warning/danger |
| [E-007](#e-007--replace-fast-sha-256-with-a-pin-kdf) | P1 | Argon2id/PBKDF2, per-user salt, lockout |
| [E-008](#e-008--make-ownership-explicit-in-the-data-layer) | P1 | Copy helper; compile-time ownership discipline |
| [E-009](#e-009--add-schema-defaults-and-checks) | P2 | `updated_at` default/trigger, total checks, nullable stock |
| [E-010](#e-010--use-status-tones-and-kds-urgency) | P2 | Colour/badge tone, age, sound, station |
| [E-011](#e-011--one-session-reset-path) | P1 | Clear cart/filters/errors on sign-out and role change |
| [E-012](#e-012--define-the-navigation-stack-policy) | P1 | Dedupe, trim forward, reset on session change |
| [E-013](#e-013--a-typed-error-taxonomy) | P2 | Dataset/operation labels, actionable messages |
| [E-014](#e-014--guard-the-single-instance) | P2 | DB lock / single-instance check |
| [E-015](#e-015--backup-and-integrity-check) | P2 | Periodic backup, WAL policy, restore |
| [E-016](#e-016--centralise-money-and-date-formatting) | P1 | Currency exponent, locale, time zone |
| [E-017](#e-017--action-level-permissions-and-audit) | P2 | Not just screen RBAC; actor on every mutation |
| [E-018](#e-018--complete-the-order-capture-model) | P2 | Table, customer, notes, modifiers, discounts |
| [E-019](#e-019--make-tests-and-docs-checkable) | P1 | Screen coverage, matrix table, link/claim checks |
| [E-020](#e-020--measure-and-cap-the-ui-cost) | P2 | Node budget, menu/order stress fixtures |

---

## E-001 — Use a real order sequence and an idempotency key

**Severity:** P1 · **Addresses:** B-006, B-007, B-026

Use a database sequence (or a row in a counter table) for `order_no`, and
a collision-resistant `id` (ULID/UUIDv7) or an autoincrement primary key.
Give the client a request key generated when the cart is submitted; make
the write `INSERT ... ON CONFLICT(request_key) DO NOTHING` and return the
existing order on retry. Add a test that submits twice and asserts one
order.

---

## E-002 — Make every transition conditional

**Severity:** P1 · **Addresses:** B-008, B-029

Change the status write to
`UPDATE orders SET status=?3, updated_at=?4 WHERE id=?1 AND status=?2`
and only insert history when `changes() = 1`. Pass the expected current
status from the model. Write `changed_by` from the session. Return the
new status to the client and reload or patch it. Add a test that advances
twice and asserts one history row.

---

## E-003 — Page and virtualise long lists

**Severity:** P2 · **Addresses:** B-012, B-025, G-023

Add keyset pagination (`placed_at, id`) to `orders_sql`, a `LIMIT` that
matches the model buffer, and a “load more” action. Use a virtualised list
for orders and the menu if the SDK supports it; otherwise page the
dataset. Cap the dashboard to the latest five orders.

---

## E-004 — One loading and retry model

**Severity:** P2 · **Addresses:** B-020, B-021

Replace the boolean `busy` with a small pending set or a per-dataset
state: `idle | loading | ready | failed(message)`. Bind it to a skeleton
and a Retry button. Disable submit/advance while pending. Distinguish
“empty” from “failed”.

---

## E-005 — Persist device settings

**Severity:** P2 · **Addresses:** B-011, G-014

Persist theme, chosen device role, window size and last screen in
`app_config` or `device`. A kiosk should boot straight to its board after
a restart; the role picker should not be the only entry point. Do not
persist a signed-in employee without an explicit unlock policy.

---

## E-006 — Fix light theme contrast

**Severity:** P1 · **Addresses:** G-020

Measured contrast against white text:

| Token | Ratio | AA normal (4.5) | AA large (3.0) |
|---|---|---|---|
| `accent` #30A8CF | 2.75:1 | fail | fail |
| `success` #2F9E69 | 3.38:1 | fail | pass |
| `warning` #C87A14 | 3.36:1 | fail | pass |
| `danger` #D94335 | 4.37:1 | fail | pass |

The dark palette is fine (7.6–9.3:1). Darken the light primary/success/
warning/danger tokens or use dark text on light fills. Re-measure every
combination actually used, not just white-on-token.

---

## E-007 — Replace fast SHA-256 with a PIN KDF

**Severity:** P1 · **Addresses:** B-027

Use Argon2id (preferred), scrypt or PBKDF2 with a per-employee salt and a
versioned record (`algo$params$salt$hash`). Enforce a minimum length and
reject common PINs; rate-limit and lock out after N failures; audit
attempts. Mask the input. Keep a migration path for existing salted
SHA-256 hashes (rehash on next successful login).

---

## E-008 — Make ownership explicit in the data layer

**Severity:** P1 · **Addresses:** B-004

Add a `dupeText(model.buffer, reader.textOf(...))` helper and use it in
every decoder, including `decodeCompany`. Prefer a decoder signature that
takes the destination buffer so a page slice cannot escape. Add a test
that decodes a row, overwrites the page bytes, and asserts the model still
reads the original text.

---

## E-009 — Add schema defaults and checks

**Severity:** P2 · **Addresses:** B-001, B-005, B-030

- Give `orders.updated_at` a default/trigger or require it in every
  writer.
- Add `CHECK (subtotal_minor >= 0)`, `CHECK (total_minor >= 0)` and a
  consistency check for totals if the business rule allows it.
- Make `product.stock_qty` semantics explicit (`track_stock`, nullable).
- Give `product.tax_slab_id` a valid zero-rate slab or make it nullable.
- Decide `ON DELETE` behaviour for table/customer/employee and test it
  with FKs on.

---

## E-010 — Use status tones and KDS urgency

**Severity:** P2 · **Addresses:** B-012, G-003

`OrderStatus.tone()` exists but no template uses it. Bind a badge tone
per status. On the KDS, colour or sort by age, add a sound/chime, a
station filter and a recall action. Replace the “oldest first” comment
with a query that actually sorts ascending (the current SQL is `DESC`).

---

## E-011 — One session reset path

**Severity:** P1 · **Addresses:** B-011, B-009

Add `resetSession(model)` that clears employee, cart, search, category,
order type, errors and stack, then lands on the right gate. Call it from
sign-out, role change and failed setup. Keep device settings out of it.
Test that no cart line survives a sign-out.

---

## E-012 — Define the navigation stack policy

**Severity:** P1 · **Addresses:** B-009, B-010

Choose one policy and encode it: “stack is only in-shell screens”,
“session transitions reset”, “pushing the current screen is a no-op”,
“forward history is trimmed after Back”. Add tests for login → home →
Back, 40 rail clicks, and repeated shortcut presses.

---

## E-013 — A typed error taxonomy

**Severity:** P2 · **Addresses:** B-020, G-019

Replace free-text `error_text` with a typed error (`dataset`, `operation`,
`outcome`, `retryable`, optional detail) rendered by a single banner.
Map engine outcomes once. Log the same record. Never include PIN/hash
material.

---

## E-014 — Guard the single instance

**Severity:** P2 · **Addresses:** B-028

Use a lock file or a database row claimed at startup; if another instance
owns the database, show a clear message instead of racing. The salt should
be read before any write, and the first-run write should be
insert-if-absent.

---

## E-015 — Backup and integrity check

**Severity:** P2 · **Addresses:** G-022

Document the database path. Enable a durable journal mode (WAL where the
engine allows it), run `PRAGMA integrity_check` on startup or on demand,
and add “Back up now” / “Restore” commands. Keep the last N backups and
never overwrite a backup before the new one is verified.

---

## E-016 — Centralise money and date formatting

**Severity:** P1 · **Addresses:** B-013, G-020

Load `currency.minor_units` and format with it; expose
`formatMoney(minor)` and `formatTime(ms)` as model methods. Use the
company's locale/time zone once it is stored. Remove every `/100` and
`fixed(..., 2)` from markup. Test JPY (0), USD (2) and KWD (3).

---

## E-017 — Action-level permissions and audit

**Severity:** P2 · **Addresses:** B-002, G-019

Screen-level RBAC is necessary but not sufficient. Define action
permissions (take order, discount, void, refund, close shift, edit menu)
and check them in `update` as well as at the screen. Write the actor to
history, payments and voids. Add a test per action per role.

---

## E-018 — Complete the order capture model

**Severity:** P2 · **Addresses:** G-013

Add table, customer, note, modifier and discount capture to the cart,
with nullable FKs. Freeze modifier names/prices on the line. Make
`order_detail` the place to review and edit before payment. Keep the
existing “price frozen at sale” rule.

---

## E-019 — Make tests and docs checkable

**Severity:** P1 · **Addresses:** G-016, G-017, G-018, G-026

- Replace the tautological RBAC matrix test with an explicit expected
  table.
- Add a screen-coverage/ordinal test.
- Add a real DB test per query/write.
- Extend the automation smoke through a sale.
- Add relative-link and claim checks to CI (counts from source, not from
  prose).

---

## E-020 — Measure and cap the UI cost

**Severity:** P2 · **Addresses:** G-023

Build fixtures for a 200-item menu and 200 orders; assert widget count and
layout time. Cap the dashboard at five orders, page the rest, and remove
the “virtualized” claim until it is true. Measure the one-second tick's
cost and stop it outside the KDS.
