# Roadmap

**Status:** Living document.
**Scope:** how Restaurant OS gets from the current vertical slice to a product a
restaurant can run a service with.
**Method:** every deliverable below names a file that exists in the tree
today or a file that is explicitly marked PLANNED. Nothing is invented
silently.

> **Relationship to the per-phase pages.** This roadmap is the delivery
> order for the whole product. The narrower pages in this directory
> (`phase-0-toolchain.md` .. `phase-8-packaging-cutover.md`) describe the
> engineering slices in more detail and use a different numbering. The
> mapping is at the end of this page.

---

## The release definition

A restaurant runs a service on Restaurant OS when:

1. an owner installs it, creates a company, an admin PIN, a menu and a
   floor;
2. a cashier takes an order, takes payment and prints a receipt;
3. the kitchen sees the ticket and advances it;
4. the customer display shows the order;
5. a second device converges on the same state;
6. the app survives a reboot and a power cut without losing a sale.

Everything else is a prerequisite for one of those six, or it is later.

## Phase summary

| Phase | Title | Goal in one line | State | Long pole |
|---|---|---|---|---|
| [0](#phase-0--foundation) | Foundation | The app model, the schema, the shell and the first sale exist | **Done** | — |
| [1](#phase-1--data-layer-completion) | Data layer completion | Every entity has a read, a write and a test; the screens refresh themselves | Started | — |
| [2](#phase-2--the-admin-back-office) | The admin back office | Every admin screen renders, and the operator can set the restaurant up | Not started | — |
| [3](#phase-3--the-waiter-and-kiosk-surfaces) | The waiter and kiosk surfaces | The waiter and the two kiosks are usable on their own | Not started | — |
| [4](#phase-4--sync-sidecar) | Sync sidecar | Two devices converge over a LAN with no cloud | Scaffolded | **Long pole** |
| [5](#phase-5--printing-sidecar) | Printing sidecar | Receipts and kitchen tickets print on a real device | Scaffolded | **Long pole** |
| [6](#phase-6--packaging-and-cutover) | Packaging and cutover | A signed build installs on a clean machine and runs a service | Not started | — |

Phase 4 and Phase 5 are the long poles: each needs a second program, a
device integration the SDK does not have, and a packaging story that does
not exist yet. They must be *started* inside Phase 1, not scheduled after
Phase 3. The detail is in the dependency graph below.

## Dependency graph

```
Phase 0  foundation                          [done]
   |
   +--> Phase 1  data layer completion
   |      |      |
   |      |      +--> Phase 2  admin back office
   |      |      |         |
   |      |      |         +--> Phase 3  waiter and kiosk surfaces
   |      |      |                |
   |      |      +--> Phase 4  sync sidecar  (spike starts in Phase 1)
   |      |
   |      +--> Phase 5  printing sidecar (spike starts in Phase 1)
   |                 |
   |                 +--> Phase 6  packaging and cutover
   |                                   ^
   +-----------------------------------+
                Phase 4 (sync) ---------|
```

Read it as three tracks that start together and finish together:

```
                 Phase 1                Phase 2              Phase 3
track A (app)   data layer    -->      admin back office --> waiter + kiosks
                 |                          |                     |
                 |  dbSubscribe              | live orders          | kiosk boot
                 |  op_log writes            | floor edits          | path
track B (sync)  sidecar spike -->         sidecar v1     -->     sidecar v2
                 |                          |                     |
                 |  print spike              | receipt format      | BLE transport
track C (print) |                          |                     |
                 +--> print sidecar v1 ----> print sidecar v2 --> packaging
```

Track B and track C must both have a working spike by the end of Phase 1.
A spike means: a program that opens the database, does the one thing the
sidecar has to do, and exits. If the spike is not written in Phase 1, the
sidecars will not exist in Phase 4 and Phase 5, and Phase 6 will ship an
app that cannot print or sync.

---

## Phase 0 — Foundation

**Status:** Done.

**Goal.** A running native app with the app model, the schema, the shell
and one complete sale path, and a headless test suite that guards the
rules.

**Delivered.**

| Area | What exists |
|---|---|
| App model | `apps/admin/src/core/model.zig`, `msg.zig`, `update.zig`, `navigation.zig`, `rbac.zig`, `theme.zig`, `bump.zig` |
| View | `apps/admin/src/app.native` plus nine templates in `apps/admin/src/screens/` |
| Data | `apps/admin/src/data/repos.zig`, `page.zig`, `auth.zig`; ten migrations in `apps/admin/src/schema/` (43 `STRICT` tables) |
| Manifest | `apps/admin/app.json`, `apps/admin/src/main.zig` |
| Rules | `apps/admin/src/tests.zig` + `tests_data.zig` — 15 authored headless tests and 12 in-memory DB tests |

**Exit criteria — met.**

- [x] `cd apps/admin && native check` is clean.
- [x] `cd apps/admin && native test` is green.
- [x] A role can be picked, a PIN accepted, a dashboard rendered.
- [x] An order can be placed and lands in `orders` and `order_line` in one
      transaction.
- [x] A ticket can be advanced and `order_status_history` is written in the
      same transaction.
- [x] The permission matrix is walked over every `(role, screen)` pair by a
      test.

**Risks carried forward.**

| Risk | Where it bites |
|---|---|
| The installed Zig is 0.17 and shadows the pinned 0.16 | `scripts/env.sh` puts 0.16 first; a shell that ignores it fails to parse the SDK |
| CI exists but its smoke is non-blank only | A regression can land unnoticed; the sale path needs an automation test |
| `scripts/` is macOS-centric | `setup.sh`/`env.sh` assume Homebrew paths; Linux and Windows are unproven |
| Defect D2: the provisional PIN salt is installed before the database confirms it, and `salt_is_provisional` is never read | A fast sign-in can hash against a salt that is then replaced — fixed in Phase 1 |

---

## Phase 1 — Data layer completion

**Goal.** Every entity in the schema can be read and written by the app,
every write is atomic, every read is testable against an in-memory
database, and the screens that exist refresh themselves when the data
changes underneath them.

**Why it comes before the UI.** The v1 audit is full of defects that are
data-layer defects: **DB5** (order and lines written without a
transaction), **R2** (`getAll*()` with no limit), **CS1** (customer list
re-queried three times per frame), **PR2** (no pagination on product
lists). Restaurant OS already avoids most of them by construction; the remaining work
is to close the read paths and prove them.

**Deliverables — data.**

| File | Work |
|---|---|
| `apps/admin/src/data/repos.zig` | Read, decode and write paths for `customer`, `tax_slab`, `modifier_group`, `modifier`, `product_modifier`, `discount`, `payment`, `shift`, `time_entry`, `expense`, `reservation`, `supplier`, `purchase_order`, `purchase_order_item`, `stock_adjustment`, `kds_station`, `product_station`, `printer`, `auto_print`, `compliance_report`, `void_log_entry`, `device`, `op_log`, `sync_state` |
| `apps/admin/src/core/model.zig` | One bump buffer and one row slice per dataset; derived methods for the new sets |
| `apps/admin/src/core/msg.zig` | One message arm per loaded dataset |
| `apps/admin/src/core/update.zig` | The decode arm per dataset; the tax and discount arithmetic; the `op_log` write on every mutation |
| `apps/admin/src/data/page.zig` | Unchanged unless a column limit is hit — the reader addresses columns by name |

**Deliverables — schema.**

| File | Work |
|---|---|
| `apps/admin/src/schema/0011_*.sql` | Anything the repositories need that is not there yet (PLANNED) |
| `apps/admin/src/schema/migrations.lock.json` | Advanced to the new version |

**Deliverables — live queries.**

`fx.dbSubscribe` for the four screens whose data changes underneath them:
the kitchen board, the order list, the floor board and the `op_log` watch.
The migration is mechanical: a `dbSubscribe` variant of the loader in
`repos.zig`, the same decoder, the same `Msg` arm.

**Deliverables — the two sidecar spikes.** Both start here, in this phase,
because they are the long poles.

| Deliverable | What "working" means at the end of Phase 1 |
|---|---|
| `tools/sync-sidecar/spike.zig` (PLANNED) | Opens the app's database in WAL mode, reads `op_log` rows newer than a given clock, and prints them. No socket yet. |
| `tools/print-sidecar/spike.zig` (PLANNED) | Takes a receipt payload on stdin and writes ESC/POS bytes to a file. No device yet. |

**Deliverables — the fix list.**

| Defect | Fix |
|---|---|
| D2 (provisional salt) | The salt is confirmed before any PIN is hashed; `salt_is_provisional` is read |
| D4 (`loadAll` omits `loadCustomers`) | `loadAll` is the single boot aggregate and includes every dataset the shell needs |
| D3 (order id = wall ms, order no = wall seconds, `order_no` is `UNIQUE`) | A dedicated order sequence; the clock-shaped identifiers are replaced |
| D5 (shell gates are hard-coded ordinals) | A test that pins the ordinal of every mounted screen |
| D9 (`busy` is set on write, not on read) | `busy` is set for reads too, and the shell renders a loading state |
| D10 (no screen-coverage test) | A test that every allowed screen is mounted or explicitly listed as unavailable |
| `decodeCompany` points into dead page bytes | The company strings are copied into a bump buffer |
| Order tax and discount are hard-coded to zero | The tax slab and the discount are applied from the cart |

**Exit criteria — verifiable.**

- [ ] `cd apps/admin && native check` is clean, including no `NS1405`
      diagnostic.
- [ ] `cd apps/admin && native test` is green, and the suite includes an
      in-memory database test per new repository, using
      `native_sdk.relational_store.Database.openMemoryMigrated`.
- [ ] Every table in `apps/admin/src/schema/` is either read or written by
      the app, or is listed in `docs/plan/backlog.md` with the screen that
      owes it.
- [ ] A test asserts that an order write and its line writes land in one
      transaction and that a failed write leaves no partial order.
- [ ] A test asserts that two orders placed in the same second get
      different order numbers.
- [ ] `native automate wait` followed by `native automate assert
      'gpu_nonblank=true'` succeeds with the app running.
- [ ] `tools/sync-sidecar/spike.zig` reads the `op_log` of a database the
      app has written to, and prints the rows.
- [ ] `tools/print-sidecar/spike.zig` turns a receipt payload into an
      ESC/POS byte stream that can be checked by length.

**Risks.**

| Risk | Mitigation |
|---|---|
| The sidecar spikes turn into a platform rabbit hole (BLE pairing on three desktops, WAL locking on macOS) | A spike has a deadline and a fallback: LAN TCP printing instead of BLE, and a polling reader instead of the update hook if WAL misbehaves |
| Live queries change the rebuild shape and break the widget budget | The subscription reuses the same decoder; the node count is asserted with `native automate snapshot` |
| The repository layer grows past one readable file | Split `repos.zig` into one module per area when it passes roughly 1,000 lines; the effect keys stay in one namespace |

---

## Phase 2 — The admin back office

**Goal.** The admin can set the restaurant up and run it: company, staff,
menu, floor, payments, reports and settings all render and all write.

**Why here.** Most of the `Screen` variants are admin surfaces, and the
admin rail entries — Catalog, People, System — each open a list or a form
now. What is still missing is the money: the catalogue and the people
forms write, but nothing takes a payment properly (see [status](status.md)).

**Deliverables — setup.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `setup` | `screens/screen-setup.native` | `app_config` |
| `wizard` | `screens/screen-wizard.native` | `company`, `employee`, `dining_table_category`, `dining_table`, `product_category`, `product` |
| `create_company` | `screens/screen-create-company.native` | `company`, `currency` |
| `reset_pin` | `screens/screen-reset-pin.native` | `employee`, `app_config` |

**Deliverables — catalogue.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `product_categories` | `screens/screen-product-categories.native` | `product_category`, `product` |
| `kitchen_dishes` | `screens/screen-kitchen-dishes.native` | `product`, `kds_station`, `product_station` |
| `inventory_items` | `screens/screen-inventory-items.native` | `product`, `stock_adjustment` |
| `suppliers` | `screens/screen-suppliers.native` | `supplier` |
| `purchase_orders` | `screens/screen-purchase-orders.native` | `purchase_order`, `purchase_order_item`, `supplier` |

**Deliverables — people and money.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `employees` | `screens/screen-employees.native` | `employee` |
| `payments` | `screens/screen-payments.native` | `payment`, `orders` |
| `order_detail` | `screens/screen-order-detail.native` | `orders`, `order_line`, `order_line_modifier`, `order_status_history`, `payment` |
| `order_confirmation` | `screens/screen-order-confirmation.native` | `orders`, `order_line`, `payment` |
| `reports` | `screens/screen-reports.native` | `compliance_report`, `orders`, `payment`, `expense`, `shift` |
| `control_center` | `screens/screen-control-center.native` | `app_config`, `sync_state`, `device` |

**Deliverables — settings.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `settings` | `screens/screen-settings.native` | `app_config` |
| `settings_company` | `screens/screen-settings-company.native` | `company` |
| `settings_currency` | `screens/screen-settings-currency.native` | `currency`, `company` |
| `settings_tax` | `screens/screen-settings-tax.native` | `tax_slab` |
| `settings_modifiers` | `screens/screen-settings-modifiers.native` | `modifier_group`, `modifier`, `product_modifier` |
| `settings_discounts` | `screens/screen-settings-discounts.native` | `discount` |
| `settings_printers` | `screens/screen-settings-printers.native` | `printer`, `auto_print` |
| `data_management` | `screens/screen-data-management.native` | `app_config`, `company` |
| `db_inspector` | `screens/screen-db-inspector.native` | every table |

**Deliverables — shared components.**

`apps/admin/src/components/` is empty today and nine templates repeat
the same patterns inline: the empty state appears in four screens, the
screen header in five, the row-with-badge in three. This phase builds the
component files the admin screens need — `empty-state.native`,
`screen-header.native`, `stat-tile.native`, `form-group.native`,
`notice-banner.native`, `settings-row.native`, `data-table.native` (all
PLANNED), each imported by the screens that use it and listed in
`apps/admin/src/app_sources.zig`.

**Exit criteria — verifiable.**

- [x] `cd apps/admin && native check` is clean and `native test` is green.
- [x] Every admin screen listed above is mounted in `src/app.native` with
      its ordinal gate, imported, and listed in `src/app_sources.zig`. The
      four SESSION screens — the setup, the role picker, the login and the
      two steps of the walk-through — are mounted on their own condition
      instead, because they are shown before anybody is signed in and the
      shell is not drawn yet.
- [x] A fresh install can be driven from the role picker to a signed-in
      admin with a company, an admin PIN, one category, one product and one
      table — all created through the app, with no external seeding. The
      walk-through is the way in now, and the quick setup is the other.
- [x] Every admin screen is inside the 1024-widget budget. The criterion
      says `native automate snapshot`, which needs a running app; the
      headless suite builds the same tree and counts the same widgets.
- [x] A test builds the tree for every admin screen and finds a landmark
      text in it.
- [x] The screen-coverage test passes: every screen `rbac.allows` for the
      admin is mounted. All fifty-three are: forty-six on their ordinal
      gate, and the seven session screens - the role picker, the sign-in,
      the landing, the quick setup, the walk-through's two steps and the
      upgrade - on their own condition, because they are shown before
      anybody is signed in and the shell is not drawn yet.
- [ ] A new product price appears in the POS without a restart, and the
      old order lines still show the price they were sold at.
- [ ] An X report can be generated from the database alone and matches the
      sum of the `payment` rows for the shift. The reports track's.

**Risks.**

| Risk | Mitigation |
|---|---|
| This phase is the largest in the plan — 21 screens | Ship it in vertical slices: setup first (a restaurant cannot be used without it), then catalogue, then people and money, then settings |
| The widget budget is exceeded by a settings tree or a report table | Bound the list in the model or mark the container `virtualized`; assert the node count per screen |
| The component library is designed twice | Write the component file first and mount two screens with it; a component that serves one screen stays inline |
| Formatting money per currency is deferred and every screen writes its own `/100` | One model method, added in Phase 1, used by every template |

---

## Phase 3 — The waiter and kiosk surfaces

**Goal.** The waiter, the kitchen and the customer display are usable on
their own, and the kiosk roles boot into their own board without a
keypad.

**Deliverables — waiter.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `waiter_tables` | `screens/screen-waiter-tables.native` | `dining_table`, `dining_table_category`, `orders` |
| `waiter_menu` | `screens/screen-waiter-menu.native` | `product`, `product_category` |
| `waiter_cart` | `screens/screen-waiter-cart.native` | `product`, `modifier_group`, `modifier` |
| `waiter_orders` | `screens/screen-waiter-orders.native` | `orders`, `order_line` |

**Deliverables — kiosk.**

| Screen | Template (PLANNED) | Data |
|---|---|---|
| `display_board` | `screens/screen-display-board.native` | `orders`, `order_line` |
| `kds_board` (extend the existing template) | `screens/screen-kitchen.native` | `orders`, `order_line`, `kds_station`, `product_station` |

**Deliverables — the kiosk boot path.**

- The device role is remembered in `app_config` (or `device.role`) and the
  app starts straight into the board for a kiosk.
- An escape gesture — a long press or a corner control — returns to the
  role picker, so a kiosk is never locked out.
- The kiosk layout drops the rail and the title bar and shows only the
  board, at the resolution the device actually has.
- `order_line.station_id` drives the KDS grouping, so a kitchen sees its
  own tickets and not the bar's.

**Deliverables — the multi-window question, answered in writing.**

The SDK can declare secondary windows over one model. Phase 3 does not
build them; it decides them: which role opens which window, what a close
means (a display window hides, it does not quit), how a shared cart is
avoided, and how a shared session is scoped. The answers go into
`docs/architecture/navigation-and-roles.md`.

**Exit criteria — verifiable.**

- [ ] `cd apps/admin && native check` is clean and `native test` is green.
- [ ] The waiter can open a table, add a product with a modifier, place the
      order, and see it on the order list.
- [ ] The customer display shows the placed order and its status without a
      PIN.
- [ ] The kitchen board shows a ticket, advances it, and the customer
      display reflects the new status on the next rebuild.
- [ ] A kiosk device restarts and comes up on its own board, not on the
      role picker.
- [ ] The escape gesture returns a kiosk to the role picker, and the
      permission matrix test still passes for every role.
- [ ] A test asserts that a waiter cannot open `pos`, `settings` or
      `employees`.

**Risks.**

| Risk | Mitigation |
|---|---|
| A kiosk with no PIN is unattended and can be walked up to | The kiosk permission list is narrow by construction; the display board shows nothing an attacker would want, and the KDS shows no money |
| The waiter and the admin want different cart semantics from the same `Model.cart` | The cart is session state in the model and one machine runs one session at a time; the multi-window decision in this phase has to say what happens when it does not |
| The display board has to be readable from across a room | A dedicated template with a large type size, and a widget budget that leaves room for a 4-column grid at 1920x1080 |

---

## Phase 4 — Sync sidecar

**Goal.** Two devices on the same LAN converge on the same state, with no
cloud and no account.

**Deliverables.**

| File (PLANNED) | Contents |
|---|---|
| `tools/sync-sidecar/build.zig`, `build.zig.zon` | The sidecar's build |
| `tools/sync-sidecar/src/main.zig` | The sidecar's entry point |
| `tools/sync-sidecar/src/protocol.zig` | The wire messages: `oplog_push`, `oplog_pull`, `oplog_broadcast`, `heartbeat`, `ack`, `host_vote`, `host_claim` — the same set v1 used, minus `host_announce` if the mDNS announcement carries it |
| `tools/sync-sidecar/src/discovery.zig` | mDNS announcement and browse |
| `tools/sync-sidecar/src/election.zig` | The host election |
| `tools/sync-sidecar/src/store.zig` | The `op_log` reader and writer against the app's database in WAL mode |
| `apps/admin/src/data/repos.zig` | The `op_log` write on every mutation, inside the mutation's transaction |
| `apps/admin/src/core/update.zig` | The apply-incoming-operation arm |

**Exit criteria — verifiable.**

- [ ] Two devices with the app running and a sidecar on each converge
      within five seconds of a change on either side.
- [ ] An order placed on device A appears on device B without a restart,
      and the kitchen board on device B shows it.
- [ ] A test asserts the conflict rule: two devices edit the same row, the
      higher `(logical_clock, device_id)` wins, and the outcome is the same
      on both devices.
- [ ] A device that is offline for ten minutes, makes three changes and
      reconnects syncs them exactly once.
- [ ] Killing the sidecar does not stop the app: the sale still places, the
      order is still written, and the ops queue in `op_log`.
- [ ] `op_log` does not grow without bound: a pruning policy runs, and the
      rows it keeps are the ones a peer still needs.
- [ ] The peer authentication decision is written down and either
      implemented or recorded as an accepted risk with an owner.

**Risks.**

| Risk | Mitigation |
|---|---|
| The sidecar has to open the app's database concurrently, and WAL locking is wrong on one platform | The Phase 1 spike proves the lock behaviour before Phase 4 starts; if it fails, the sidecar talks to the app through a job table instead of the database file |
| A second program doubles the packaging and signing work | Package the sidecar inside the app bundle from the start; Phase 5 needs the same machinery |
| The op-log write touches every write path and could be forgotten | One helper in `repos.zig` that every writer calls, plus a test that asserts a mutation produced an `op_log` row |
| Nobody owns the sidecar's security | The authentication decision is a Phase 4 exit criterion, not an afterthought |

---

## Phase 5 — Printing sidecar

**Goal.** A receipt and a kitchen ticket print on a real device.

**Deliverables.**

| File (PLANNED) | Contents |
|---|---|
| `tools/print-sidecar/build.zig`, `build.zig.zon` | The sidecar's build |
| `tools/print-sidecar/src/main.zig` | Reads a print job, encodes it, sends it, reports the result |
| `tools/print-sidecar/src/escpos.zig` | The ESC/POS encoder: alignment, emphasis, cut, cash-drawer kick, code page, raster logo |
| `tools/print-sidecar/src/transports/ble.zig` | Bluetooth LE transport |
| `tools/print-sidecar/src/transports/tcp.zig` | ESC/POS over TCP on port 9100 |
| `tools/print-sidecar/src/transports/system.zig` | The OS print queue |
| `tools/print-sidecar/src/receipt.zig` | The receipt and the KOT layouts |
| `apps/admin/src/schema/0011_print_jobs.sql` (PLANNED) | The print job table, if the spawn-per-job route is not enough |
| `apps/admin/src/screens/screen-settings-printers.native` (Phase 2) | The printer configuration screen |

**Exit criteria — verifiable.**

- [ ] A receipt prints on a real ESC/POS thermal printer and the totals on
      the paper match `orders.total_minor` exactly.
- [ ] A kitchen ticket prints with the items, the quantities and the notes.
- [ ] A cash payment kicks the cash drawer.
- [ ] A printer that is offline does not block the sale: the order is
      committed, and the failure is visible afterwards.
- [ ] A retried print does not print twice: the job carries an idempotency
      key.
- [ ] The printer configuration screen can add a printer, set its
      transport and its job type, and the sidecar picks the change up
      without a restart.

**Risks.**

| Risk | Mitigation |
|---|---|
| BLE pairing behaves differently on each desktop platform | LAN TCP on port 9100 is the fallback and is enough for a pilot; the BLE transport is a second target, not a blocker |
| The receipt format depends on the paper width and the device's code page | One receipt renderer with a paper-width parameter, tested against a captured byte stream |
| Printing is a side effect and can fail after the sale is committed | The order is always committed first; printing is best-effort with a visible status, which is the Restaurant OS rule |
| The sidecar needs the same packaging treatment as the sync sidecar | Both are packaged in Phase 6; if only one exists by then, Phase 6 packages that one |

---

## Phase 6 — Packaging and cutover

**Goal.** A signed build installs on a clean machine, survives a reboot, and
runs a service without a developer in the room.

**Deliverables.**

| Area | Deliverable (PLANNED) |
|---|---|
| Packaging | `native package --target macos` for macOS, and the Windows and Linux equivalents; the sidecars shipped inside the bundle |
| Signing | A signed and notarised macOS build; a Windows signing story if Windows is in the release |
| Migrations | A decision on v1 data: either a migration from a v1 database file, or an explicit "fresh install only" decision recorded in the release notes |
| CI | A workflow that runs `native check`, `native test` and an automation smoke on every change |
| Scripts | `scripts/setup.sh`, `scripts/env.sh`, `scripts/verify.sh`, `scripts/build.sh`, `scripts/dev.sh` — the five the README already advertises |
| Documentation | The operator guide: install, first-run setup, daily use, backup |
| Support | A `db_inspector` that can dump the schema and the data for a diagnosis, and a diagnostic log the app can export |

**Exit criteria — verifiable.**

- [ ] On a clean macOS machine with no development tools installed, the
      packaged app launches, creates a company, takes an order, prints a
      receipt and restarts with the order still there.
- [ ] The app survives a force quit mid-sale and comes back with no partial
      order.
- [ ] The CI workflow is green on a fresh clone, having installed the
      pinned toolchain itself.
- [ ] A v1 database either migrates into Restaurant OS without loss of orders,
      payments or employees, or the release notes say plainly that Restaurant OS
      starts empty.
- [ ] `scripts/verify.sh` runs `native check` and `native test` for every
      app and exits non-zero on failure.
- [ ] The v1 app and the Restaurant OS app have been run side by side through one
      service, and the orders agree.

**Risks.**

| Risk | Mitigation |
|---|---|
| Packaging blocks on signing or notarisation | Throw away a signed build early in Phase 1, not in Phase 6; the risk register already flags this |
| The v1 database does not migrate cleanly, because v1's money was `REAL` and its PINs were plaintext | Decide early whether v1 data is migrated at all. A fresh install with a re-keyed menu is a defensible answer; converting `REAL` money to minor units is a rounding decision that has to be made on purpose |
| The sidecars are not signed or not bundled | Packaging and signing are one deliverable in this phase, not two |
| The operator has no way to back up the restaurant's data | A backup is a file copy of the database; the operator guide has to say which file and when |

---

## Mapping to the per-phase pages

| This roadmap | Existing page in this directory |
|---|---|
| Phase 0 | [`phase-0-toolchain.md`](phase-0-toolchain.md), [`phase-1-foundation.md`](phase-1-foundation.md) |
| Phase 1 | [`phase-2-schema-and-repositories.md`](phase-2-schema-and-repositories.md) |
| Phase 2 | [`phase-5-admin-surfaces.md`](phase-5-admin-surfaces.md) |
| Phase 3 | [`phase-4-kds-display-waiter.md`](phase-4-kds-display-waiter.md), [`phase-3-pos-slice.md`](phase-3-pos-slice.md) |
| Phase 4 | [`phase-6-sync-sidecar.md`](phase-6-sync-sidecar.md) |
| Phase 5 | [`phase-7-printing-hardware.md`](phase-7-printing-hardware.md) |
| Phase 6 | [`phase-8-packaging-cutover.md`](phase-8-packaging-cutover.md) |

The pages are the engineering detail for one slice each; this page is the
delivery order for the product, and it disagrees with the page numbering
deliberately, because the product order is not the same as the engineering
order: the two sidecars start in Phase 1 and finish in Phases 4 and 5.

## Checklist

Before the next phase starts:

- [ ] The previous phase's exit criteria are demonstrated, not asserted.
- [ ] `cd apps/admin && native check` is clean.
- [ ] `cd apps/admin && native test` is green, and the new rules are in
      the suite.
- [ ] Every new screen is mounted in `src/app.native`, imported, listed in
      `src/app_sources.zig`, and covered by a landmark test.
- [ ] Every new table has a migration and an in-memory database test.
- [ ] `docs/plan/backlog.md` and `docs/plan/status.md` reflect the new
      state.
- [ ] The open questions raised by the phase are recorded in
      [`open-questions.md`](open-questions.md), not forgotten.
- [ ] The sidecar spikes have moved: one of them is a working program, not
      a design note.
