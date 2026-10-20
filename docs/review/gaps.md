# Gaps

> **Snapshot:** 2026-10-20. A gap is a flow or feature that does not exist
> in the tree; it is not automatically a bug. Severity reflects product
> impact, not effort.

| ID | Severity | Gap |
|---|---|---|
| [G-001](#g-001--first-run-setup-is-new-and-incomplete) | P1 | First-run setup exists in the working tree but has gaps |
| [G-002](#g-002--no-committed-seed-fixture-or-demo-database) | P2 | Setup has starter data, but no committed fixture/demo database |
| [G-003](#g-003--35-of-43-screens-have-no-template) | P1 | Waiter, display, confirmation and most admin destinations are blank |
| [G-004](#g-004--no-payments-refunds-voids-or-shifts) | P1 | The sale cannot be paid, voided, refunded or reconciled |
| [G-005](#g-005--no-printing) | P1 | No receipt, KOT, printer settings or sidecar |
| [G-006](#g-006--no-sync) | P1 | No op-log writes, no second device, no conflict handling |
| [G-007](#g-007--no-reports-or-compliance) | P1 | No X/Z report, tax report, item mix, export or audit |
| [G-008](#g-008--no-catalog-or-settings-crud) | P1 | Menu, categories, modifiers, discounts and tax are read-only at best |
| [G-009](#g-009--no-customer-workflow) | P2 | Customers are loaded nowhere and have no UI |
| [G-010](#g-010--no-inventory-or-purchasing) | P2 | Tables exist; no stocktake, supplier or purchase flow |
| [G-011](#g-011--no-floor-or-reservation-management) | P2 | Table board is read-only; no seating, transfer or reservations |
| [G-012](#g-012--no-employee-management) | P2 | No employee list, PIN reset, role change or deactivation |
| [G-013](#g-013--no-order-detail-or-capture) | P1 | No table, customer, note, modifier or delivery data on an order |
| [G-014](#g-014--no-multi-window-or-kiosk-windows) | P2 | One window; docs describe role-specific windows that do not exist |
| [G-015](#g-015--no-packaging-backup-or-update-path) | P1 | No signed package, updater, backup/restore or v1 cutover |
| [G-016](#g-016--no-committed-database-integration-tests) | P1 | The committed suite has no real DB test; the in-progress one is red |
| [G-017](#g-017--no-screen-coverage-or-ordinal-test) | P1 | No test mounts every screen or pins the gate ordinals |
| [G-018](#g-018--no-sale-automation-smoke) | P1 | CI smoke asserts a non-blank canvas only |
| [G-019](#g-019--no-observability-or-audit) | P2 | No logs, crash reports, login audit or operational metrics |
| [G-020](#g-020--no-accessibility-or-localisation-pass) | P2 | Contrast fails; no keyboard-only, RTL, locale or currency audit |
| [G-021](#g-021--no-keyboard-or-secure-pin-entry) | P2 | No keypad, focus order or masked PIN |
| [G-022](#g-022--no-backup-offline-or-recovery-story) | P2 | No WAL/backup/integrity policy; a corrupt file is terminal |
| [G-023](#g-023--no-performance-or-node-budget-tests) | P2 | Lists are not virtualised; no assertion on 1024-node budget |
| [G-024](#g-024--no-v1-data-migration) | P1 | The rewrite starts on an empty database; v1 data has no path |
| [G-025](#g-025--no-defined-engine-contract-for-fks-wal-and-queries) | P2 | FK enforcement, journal mode and query limits are undocumented |
| [G-026](#g-026--no-docs-verification-in-ci) | P3 | No link/claim check; docs drift silently |

---

## G-001 — First-run setup is new and incomplete

**Severity:** P1 (was P0) · **Area:** onboarding

The working tree now has `screen-setup.native`, `needs_setup`, a setup
message set and a `setupCompany` transaction that writes the company, the
first admin, a starter menu and six tables. The integration tests cover
the happy path and two validation failures.

Still missing or wrong:

- The currency **symbol** field writes the currency **code** (B-031).
- The submit button is not disabled when the form is incomplete (B-032).
- Setup is detected only by `company_id == 0`; a database with a company
  but no employee still has no way forward.
- The setup PIN is a visible text field (B-027), and the salt may still
  be provisional (B-003).
- There is no tax/currency choice, no table/menu editing, and no way to
  resume a partially created database.

**Impact:** a fresh install is much closer, but the setup path is not yet
trustworthy.

**Next step:** fix B-031/B-032, gate setup on a real “is configured” check,
and commit the fixture/test so the flow is reproducible.

---

## G-002 — No committed seed fixture or demo database

**Severity:** P2 · **Area:** test data / demos

Setup now writes a starter menu and six tables (`starter.zig`), which
serves as the first-run seed. There is still no committed `seed.sql`,
fixture or demo database for tests, and `tests_data.zig` builds its own
seed but is uncommitted. The README's “seeded tables” language is
unreproducible from the repository alone.

**Impact:** no reproducible demo or reliable integration baseline; setup
is the only path to data.

**Next step:** commit a small deterministic fixture (company, one admin,
one waiter, three categories, ten products, four tables, one tax slab) and
use it in tests and `native dev`. Keep production setup separate.

---

## G-003 — 35 of 43 screens have no template

**Severity:** P1 · **Area:** screens

Eight templates exist; five are mounted in the shell, plus setup, the role
picker and login. The waiter home (`waiter_tables`), display home
(`display_board`), order confirmation and every catalog/people/system
destination render an empty content pane. `order_detail` is allowed for
kds/display but has no template.

**Impact:** two of four roles and most of the back office are dead ends.

**Next step:** decide the minimum M1/M2 screen set and build those
templates before adding more enum entries. Add a screen-coverage test
(G-017) so a new enum entry cannot be silently blank.

---

## G-004 — No payments, refunds, voids or shifts

**Severity:** P1 · **Area:** money

`payment`, `void_log_entry`, `shift` and `order_discount` exist; nothing
writes them. There is no payment screen, no cash/card/UPI capture, no
split payment, no change calculation, no refund, no void reason, no cash
drawer and no shift open/close. `nextStatus` completes an order without
payment.

**Impact:** the POS can take an order but cannot close a sale correctly.

**Next step:** model a payment state on the order; add a payment screen,
a void action with a reason, and shift open/close. Decide whether payment
is required before `completed`.

---

## G-005 — No printing

**Severity:** P1 · **Area:** hardware

`printer` and `auto_print` exist. `tools/print-sidecar/` contains a
README only. No receipt/KOT payload, template, queue, retry or printer
settings screen exists.

**Impact:** no paper trail; a kitchen without a screen cannot operate.

**Next step:** define the print-job row/payload, build the sidecar spike
(ESC/POS to a file), then the device transport. Start with a receipt
preview in-app so the data path is testable without hardware.

---

## G-006 — No sync

**Severity:** P1 · **Area:** multi-device

`device`, `op_log` and `sync_state` exist; no operation is written, no
subscription is used and `tools/sync-sidecar/` is a README. The app has no
conflict resolution, logical clock, device identity or host election.

**Impact:** a second till or KDS sees nothing; the multi-device promise is
unimplemented.

**Next step:** write the op-log in the same transaction as each mutation,
add a local logical clock, and prove a two-database convergence test
before building the socket.

---

## G-007 — No reports or compliance

**Severity:** P1 · **Area:** back office

`compliance_report`, `void_log_entry` and `subscription` exist with no
read/write path. There is no sales summary, tax report, item mix, payment
split, X/Z report, CSV export or audit view. `order_status_history` is
written but never read.

**Impact:** an owner cannot reconcile a day or file taxes from the app.

**Next step:** start with a read-only daily summary from `orders`,
`order_line` and `payment`; then add X/Z and CSV export. Make the report
query reproducible from the database alone.

---

## G-008 — No catalog or settings CRUD

**Severity:** P1 · **Area:** admin

Products, categories, tax slabs, modifiers, discounts and settings have
read paths at best (products/categories read; the rest not even that). No
screen creates or edits them. `product_category`, `tax_slab`,
`modifier_group`, `modifier`, `product_modifier` and `discount` are
unused beyond the menu read.

**Impact:** a restaurant cannot configure its own menu or tax.

**Next step:** add the minimum catalog editor (product + price + category
+ tax slab) and a settings screen for company/currency/tax. Do not build
all 43 screens first.

---

## G-009 — No customer workflow

**Severity:** P2 · **Area:** customers

`customer`, `customer_loyalty` and `loyalty_transaction` exist; the
repository and decoder exist but `loadAll` never calls them; no screen
lists, searches, creates or attaches a customer to an order.

**Impact:** dine-in tabs are table-only; loyalty and delivery customer
data cannot be captured.

**Next step:** load customers, add a picker on the POS/order detail, and
attach `customer_id` with a real FK value (B-005).

---

## G-010 — No inventory or purchasing

**Severity:** P2 · **Area:** inventory

`supplier`, `purchase_order`, `purchase_order_item`, `stock_adjustment`
and `product.stock_qty` exist. No supplier/purchase screen, no receiving,
no stocktake, no low-stock warning, no waste entry.

**Impact:** stock cannot be managed; B-016 means sales do not move it
either.

**Next step:** decide whether inventory is in M1 at all; if not, document
it as out of scope and stop implying it works.

---

## G-011 — No floor or reservation management

**Severity:** P2 · **Area:** floor

The tables board is read-only. There is no seat/occupy/free action, no
drag-to-floor-plan editor, no table transfer/merge, no reservation list or
calendar. `reservation` and `dining_table_category` are unused.

**Impact:** the floor board is a dashboard, not a tool.

**Next step:** add table status transitions and attach a table to an
order; then reservations. Keep the first version list-based, not a
drag-and-drop plan.

---

## G-012 — No employee management

**Severity:** P2 · **Area:** people

`employee` is read for login only. There is no list, create, edit, PIN
reset, role change or deactivate. `reset_pin` is an enum entry with no
template. `shift`/`time_entry` are unused.

**Impact:** the owner cannot add a staff member or rotate a PIN without
SQL.

**Next step:** employee CRUD with a PIN reset that writes a new KDF hash
(B-027), plus a role selector constrained to the four app roles.

---

## G-013 — No order detail or capture

**Severity:** P1 · **Area:** orders

The POS captures only product, quantity and order type. There is no table,
customer, note, modifier, discount, delivery address, course or split.
`order_detail` has no template. `dining_table_id`, `customer_id` and
`notes` are written as `0`/empty.

**Impact:** the order is not a restaurant order; it is a list of items.

**Next step:** add table/customer selection and a note field; then
modifiers and discounts. Persist the values with nullable FKs, not zero.

---

## G-014 — No multi-window or kiosk windows

**Severity:** P2 · **Area:** windowing

One window (`main`) is declared. Architecture notes describe kiosk roles
getting their own windows; the code has one canvas and role-swapped
content. Display and KDS cannot run side by side from one process.

**Impact:** a single machine cannot show a customer display and a POS at
once; a second monitor is unused.

**Next step:** decide whether v2 is one-window-per-device (document it) or
multi-window; if multi-window, add a second shell view and route the
display role to it.

---

## G-015 — No packaging, backup or update path

**Severity:** P1 · **Area:** release

No `.app`/MSI/AppImage packaging, signing, notarisation, updater, backup,
restore, integrity check or data directory policy. Phase 8 is planned
only. `native package` is mentioned in the README but not exercised.

**Impact:** the app cannot be installed or updated by a restaurant; a
database loss is unrecoverable.

**Next step:** document the data directory and add a backup/export command
before packaging. Then a signed macOS build; Linux/Windows follow.

---

## G-016 — No committed database integration tests

**Severity:** P1 · **Area:** testing

The committed suite uses the fake effects executor: it never runs the SQL
in `repos.zig`. The working tree now has `tests_data.zig`: 11 integration
tests, 25/25 total passing at the snapshot. It is **uncommitted**, so CI
and a fresh clone still have no database coverage.

**Impact:** every SQL statement is unverified in the committed tree; the
working tree proves the happy paths but not the edge cases.

**Next step:** commit the harness and fixtures, add failure-path and
concurrency tests, and make CI run them. Do not rely on an uncommitted
test file.

---

## G-017 — No screen coverage or ordinal test

**Severity:** P1 · **Area:** testing

No test mounts every allowed screen. The shell gates are hard-coded
ordinals (B-023), and the RBAC “matrix” test is tautological (see the
documentation audit). A screen can be added, allowed, and render blank
without a failure.

**Impact:** blank panes and remapped gates are invisible to CI.

**Next step:** add a table of `Screen` → template/unavailable, assert the
ordinal of every mounted screen, and build each template with a fixture
model.

---

## G-018 — No sale automation smoke

**Severity:** P1 · **Area:** CI

`.github/workflows/ci.yml` builds with automation and asserts
`gpu_nonblank=true` plus a screenshot. It does not choose a role, sign in,
add an item, place an order, advance a ticket or inspect a widget. The
smoke would pass on a blank role picker.

**Impact:** the shell can be entirely broken and CI still passes.

**Next step:** seed a test database, run the role-picker → login → sale →
orders → KDS path under `native automate`, and assert a visible order
number/status. Keep the non-blank screenshot as an extra, not the test.

---

## G-019 — No observability or audit

**Severity:** P2 · **Area:** operations

There is no structured log, crash report, correlation id, login audit,
failed-write audit or metric. The error banner is the only diagnostic and
it is often generic (B-020). `order_status_history.changed_by` is never
written.

**Impact:** a restaurant cannot report what happened; support cannot
reconstruct a failed service.

**Next step:** log effect failures with key/outcome, write actor ids to
history/void/payment rows, and add a local diagnostic export. Do not log
PINs or hashes.

---

## G-020 — No accessibility or localisation pass

**Severity:** P2 · **Area:** UX

The light palette fails WCAG AA on primary/success/warning/danger text
(see [E-006](enhancements.md#e-006--fix-light-theme-contrast)). There is
no keyboard-only test, focus-order audit, screen-reader pass, locale
formatting, RTL support or translated copy. `label`/`accessibility_label`
exist on the canvas only.

**Impact:** the app is hard to use for low-vision/keyboard users and
cannot ship outside an English, 2-decimal currency market.

**Next step:** fix contrast, add a keyboard path through role → login →
sale, and centralise money/date formatting.

---

## G-021 — No keyboard or secure PIN entry

**Severity:** P2 · **Area:** UX / security

The PIN is a plain text field; there is no numeric keypad, no masked
entry, no auto-submit at the expected length and no keyboard shortcuts for
the POS. The role picker and POS are pointer-first.

**Impact:** shoulder-surfing; slow service; inaccessible for keyboard
operators.

**Next step:** a secure PIN control with a keypad, digit-only input and
attempt feedback; add shortcuts for search, add, pay and sign-out.

---

## G-022 — No backup, offline or recovery story

**Severity:** P2 · **Area:** operations

There is no WAL/journal policy, backup command, integrity check, restore
flow or corruption handling beyond a generic “database is damaged”
message. The database path is managed by the engine and undocumented in
the repo.

**Impact:** a power loss or bad disk can end the installation with no
recovery path.

**Next step:** document the path, enable a durable journal mode, add
periodic backup + `PRAGMA integrity_check`, and a restore command.

---

## G-023 — No performance or node-budget tests

**Severity:** P2 · **Area:** performance

The POS and orders screens use `<for>` inside a `<scroll>` with no
virtualisation (despite the POS comment). The dashboard lists up to 200
orders without a scroll container. No test asserts the 1024-node budget
or a large-menu layout.

**Impact:** a real menu or a busy day can exceed the node budget or become
sluggish; the first symptom is a broken screen in service.

**Next step:** measure with a 200-item menu and 200 orders, page/virtualise
the lists, cap the dashboard to the latest five, and assert node counts.

---

## G-024 — No v1 data migration

**Severity:** P1 · **Area:** cutover

The v2 schema is new; there is no importer or mapping from the Flutter
app's SQLite database. Phase 8 mentions cutover, but no field mapping,
validation or dry-run exists.

**Impact:** an existing restaurant cannot adopt v2 without re-entering its
menu and losing history.

**Next step:** write the field mapping and a dry-run importer, then a
validation report (counts, totals, orphans) before any write. This is a
prerequisite for a real pilot.

---

## G-025 — No defined engine contract for FKs, WAL and queries

**Severity:** P2 · **Area:** platform

The app relies on engine behaviour it does not document: whether
`foreign_keys` is on (B-005), the journal mode, how `dbExec` transactions
behave, whether `dbQuery` is synchronous, and the maximum page size. The
tests assume `dbExec` results are immediately drainable; the in-progress
harness suggests that assumption needs care.

**Impact:** fixes for B-005/B-006 can be correct in SQLite and still fail
under the engine; the test harness is hard to stabilise.

**Next step:** record the engine contract (version, FK setting, journal
mode, transaction and drain semantics) in the architecture docs and add a
tiny probe test that asserts each assumption.

---

## G-026 — No docs verification in CI

**Severity:** P3 · **Area:** documentation

Links, counts, test totals and status claims are maintained by hand. This
review already found stale CI claims, a wrong script name, and an
overstated order flow. No link checker or claim test runs in CI.

**Impact:** docs drift from the tree; readers cannot tell which page is
current.

**Next step:** add a relative-link check and a tiny claim check (test
count, screen count, table count) to CI; keep volatile status in
`plan/status.md` only.
