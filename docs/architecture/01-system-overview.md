# System overview

> **Status:** Implemented core (single-window app, SQLite, POS/KDS/dashboard);
> Planned edges (sync, printing, full admin surface).
> **Last verified:** 2026-10-20, by source review.

## What Eatery v2 is

A restaurant operating system in one native binary:

- **Point of sale** — browse a menu, build a cart, place an order.
- **Kitchen display** — a live board of tickets, advanced through the
  order lifecycle.
- **Customer display** — a status board for the customer (target).
- **Back office** — catalog, floor, people, settings and reports (target).

It is a rewrite of the Flutter `eatery` app, not a translation. The rules
of the rewrite live in the [ADRs](../decisions/README.md); the gaps that
forced them live in [`PORT-PLAN.md`](../../../PORT-PLAN.md).

## Design principles

1. **The core is pure.** `update(model, msg, fx)` is a function of state
   and message. It does not read the clock, open files or query the
   database directly. The world is reached through the effects channel,
   and the answer comes back as another message.
2. **The view never mutates.** Markup binds values and dispatches
   messages. There is no widget tree owned by app code, no router, and no
   setState.
3. **Derive, don't store.** Counts, totals, filtered lists and formatted
   strings are methods on the model, computed on rebuild. A stored field
   that could be derived is treated as a bug.
4. **Fixed capacity, no hidden heap.** The model is default-constructible
   and owns fixed byte buffers. It cannot hold an allocator, so its size
   is a compile-time fact.
5. **Money is integer minor units; time is epoch milliseconds, UTC.**
   There is no floating-point money anywhere.
6. **The schema is the contract.** SQLite is engine-owned. Migrations are
   append-only, tables are `STRICT`, and repository SQL lives in one file.

## Runtime topology

```
                       ┌────────────────────────────────────────┐
                       │              Native SDK runtime        │
                       │                                        │
  app.native ─────────▶│  canvas markup  ──bindings──┐          │
  screens/*.native     │  (1024-node budget)         │          │
                       │                             ▼          │
                       │  Model ──▶ build ──▶ widgets ──▶ GPU   │
                       │    ▲                         │          │
                       │    │                         │ events   │
                       │    │                         ▼          │
                       │  update(model, Msg, fx) ◀── Msg        │
                       │    │                                   │
                       │    └── fx.dbQuery / dbExec / timer ───┼──▶ SQLite (engine-owned)
                       │        fx.spawn / fetch / files  ─────┼──▶ OS
                       └────────────────────────────────────────┘
                                     ▲
                                     │ planned: op_log rows, print jobs
                        ┌────────────┴─────────────┐
                        │  sidecars (not built)    │
                        │  sync · ESC/POS printer  │
                        └──────────────────────────┘
```

The app never speaks a network protocol or a printer protocol. Those
transports are designed to live in sidecar processes that share the
database or accept a job (see [08-sync](08-sync.md) and
[09-printing](09-printing-and-hardware.md)).

## Layers and source map

| Layer | Where | Responsibility | Status |
|---|---|---|---|
| Shell / entry | `src/main.zig` | Window, GPU surface, `UiApp` wiring, salt generation | Implemented |
| View | `src/app.native`, `src/screens/*.native` | Declarative markup, template imports, shell gates | Implemented subset |
| View import closure | `src/app_sources.zig` | Embeds every imported template | Implemented |
| Core | `src/core/*.zig` | Model, messages, update, navigation, RBAC, theme, buffers | Implemented |
| Domain | `src/domain/models.zig` | Entity shapes, enums, money/time conventions | Implemented subset |
| Data | `src/data/*.zig` | SQL constants, reads, decoders, writes, PIN hashing, page reader | Partial |
| Schema | `src/schema/0001..0011_*.sql` | 43 STRICT tables, migration lock | Scaffolded beyond core |
| Sidecars | `tools/sync-sidecar`, `tools/print-sidecar` | Intended external transports | Empty directories |
| CI / scripts | `.github/workflows`, `scripts` | Intended build/test/automation | Empty directories |

## The four roles

One binary runs one of four operating modes. The role is model state, not
a build variant.

| Role | Sign-in | Home | Current shell status |
|---|---|---|---|
| Admin | PIN | `admin_dashboard` | Implemented; rail destinations partially rendered |
| Waiter | PIN | `waiter_tables` | Partial; no waiter template is wired |
| Kitchen (KDS) | Device (kiosk) | `kds_board` | Implemented |
| Display | Device (kiosk) | `display_board` | Scaffolded; screen not wired |

Details, including the full permission matrix, are in
[03-navigation-and-rbac](03-navigation-and-rbac.md).

## Primary flows that work today

### Boot

1. `main.zig` creates the `UiApp`, then generates a provisional
   installation salt.
2. The runtime calls `boot`, which sets `now_ms`, starts a 1s repeating
   timer and asks for the PIN salt (`repos.loadConfig`).
3. `config_loaded` either adopts the stored salt or creates one (fresh
   install).
4. The role picker is the first screen (`screen_index = 0`,
   `role_chosen = false`).

### Admin sale

1. Pick **Admin** → PIN screen → hashed PIN checked in SQL → dashboard.
2. Dashboard loads company, categories, products, tables, employees,
   orders and order lines (`repos.loadAll`).
3. Open **Sell** → filter/search menu → add products to cart → choose
   dine-in/take-away/delivery → place order.
4. `repos.saveOrder` writes the order and its lines in one atomic
   `dbExec`, then the app reloads orders and navigates to
   `order_confirmation` (currently a blank pane — no template yet).
5. The order appears on the order list and the kitchen board; **Advance**
   moves it pending → preparing → ready → served → completed and writes
   `order_status_history`.

### Kiosk kitchen

1. Pick **Kitchen** → device is signed in immediately.
2. The board shows pending/preparing/ready tickets, oldest first, with a
   derived summary and waiting time.
3. Advancing a ticket updates both the board and the order list.

## Invariants

These are the rules a change must not break. Each has a test or a code
anchor.

| # | Invariant | Evidence |
|---|---|---|
| I1 | Only `update` changes model state. | `src/core/update.zig:67`; markup has no setter |
| I2 | Navigation is refused for a role that lacks permission. | `go()` at `src/core/update.zig:329`; RBAC test |
| I3 | Money is integer minor units. | `src/domain/models.zig:1`; money test |
| I4 | The view cannot bind a private field. | `view_unbound` in `model.zig` and `msg.zig` |
| I5 | The model never borrows effect scratch memory. | `src/data/page.zig:16`; decode copies into bumps, and a test overwrites the page after decoding |
| I6 | An order and its lines are written atomically. | `repos.saveOrder` single `dbExec` |
| I7 | The `Screen` enum is append-only. | `src/core/navigation.zig:47`; markup compares indices |
| I8 | Every imported template is in `app_sources.zig`. | `src/app_sources.zig`; import fails loudly |
| I9 | A navigation is never refused because the stack is full. | `Stack.push` is a no-op on the current screen and drops the oldest entry at depth 32 ([ADR-0015](../decisions/0015-session-scoped-navigation.md)) |
| I10 | Every text pair in both palettes clears WCAG AA. | the contrast test in `src/tests.zig`; token table in [ui-components](ui-components.md) |

## Current boundary of the system

Implemented end to end today:

- role picker, PIN sign-in, kiosk sign-in, sign-out, theme toggle;
- dashboard counts and recent orders;
- POS menu, filters, cart, order types, order placement;
- order list and status advance;
- floor table board (read-only);
- kitchen board with lifecycle advance;
- 43-table schema, 11 migrations, core repositories;
- 80 authored headless tests, of which 47 run against an in-memory database.

Not implemented, despite appearing as types or tables:

- 14 of the 45 screens have no template;
- customers, employees, catalog and settings administration;
- payments, reports, discounts, modifiers, inventory in the UI;
- display board, waiter shell;
- sync sidecar and op-log writes;
- printing sidecar and printer settings;
- CI, packaging, data migration.

See [`plan/status.md`](../plan/status.md) for the screen-by-screen view.

## What this app deliberately does not have

- A router or deep links.
- A reactive widget tree or provider graph.
- A custom paint hook, Lottie, or a pie-chart series.
- Bluetooth, WebSocket, mDNS or ESC/POS in-process.
- A mobile-first layout (desktop is the target; tablet is an open question).
- Multi-company data. One database holds one company.

## Where to go next

- The contract: [02-app-model-and-effects](02-app-model-and-effects.md)
- The as-built picture: [plan/status](../plan/status.md)
- The unknowns: [plan/open-questions](../plan/open-questions.md)
