# Delivery plan

> **Status:** Living document.
> **Last verified:** 2026-10-21, by source review and by running the suite.
> **Upstream:** [`PORT-PLAN.md`](../../../PORT-PLAN.md) §11, adapted to the
> as-built state.

## The goal

A native Eatery that a restaurant can run for a service:

1. an operator can set up a company and a menu;
2. a cashier can take an order and take payment;
3. the kitchen sees the ticket and advances it;
4. the customer display reflects the order;
5. the receipt prints;
6. a second device converges;
7. the app installs on a clean machine with real data.

That is the release definition. Everything else is either a prerequisite or
a later phase.

## Where we are

The current tree is a **vertical slice in progress**, not a release.

| Measure | Count |
|---|---|
| Screens named in the `Screen` enum | 45 |
| Screen templates that compile | 31 |
| Screens mounted in the shell | 31 (28 gated on the screen ordinal, 3 on their own condition) |
| Screens that render at all | 31 (a test builds every one of them) |
| Screen templates with a render test | 31 |
| Tables in the schema | 43 |
| Migrations | 11 |
| Entities with a read + decode path | 8 |
| Entities with a write path | 6 (order, lines, history, config, setup, payment) |
| Headless tests | 49 authored (50 reported with the generated one) |
| Sidecars | 0 (two README-only directories) |
| CI workflows | 1 (verify + smoke) |

Full matrix: [`status.md`](status.md).

## Milestones

| Milestone | Phases | Outcome |
|---|---|---|
| **M1 — Usable sale** | 0–4 | Role picker → login → POS → order → KDS, on one machine, with the four roles reachable |
| **M2 — Back office** | 5 | Every remaining screen has a template; setup, catalog, payments, reports |
| **M3 — Fabric** | 6–7 | Two devices converge; receipts and KOTs print |
| **M4 — Release** | 8 | Signed package, migrated data, CI sale smoke |

M1 is the only milestone that can be demoed to a restaurant. Do not start
M3 before M1 is honest. The role check (B-002) and the salt race (B-003)
were closed on 2026-10-21; what still blocks M1 is the money: tax,
discount and payment are not implemented (B-014), the order identifier
scheme collides (B-006), and the setup gaps remain (G-001).

## Phase board

| Phase | Title | Estimate | Status | Exit criterion met? |
|---|---|---|---|---|
| [0](phase-0-toolchain.md) | Toolchain & skeleton | 2 d | Partial | No (scripts and CI exist; no clean-machine proof) |
| [1](phase-1-foundation.md) | Model, navigation, theme, shell | 4 d | Partial | No (the shell is there; no responsive layout mode) |
| [2](phase-2-schema-and-repositories.md) | Schema & repositories | 8 d | Partial | No (28 in-memory database tests exist; the read paths are not all written) |
| [3](phase-3-pos-slice.md) | POS vertical slice | 7 d | Partial | No (the order writes and reads back; no modifiers, no tax, no discount) |
| [4](phase-4-kds-display-waiter.md) | KDS, display, waiter | 6 d | Partial | No (all three render and the waiter joins a table's order; the waiter cannot pay) |
| [5](phase-5-admin-surfaces.md) | Admin surfaces | 10 d | Partial | No (the settings screens, the catalogue and the people forms exist; reports do not) |
| [6](phase-6-sync-sidecar.md) | Sync sidecar | 10 d | Scaffolded | No |
| [7](phase-7-printing-hardware.md) | Printing & hardware | 8 d | Scaffolded | No |
| [8](phase-8-packaging-cutover.md) | Packaging & cutover | 5 d | Planned | No |

Estimates are engineer-days for one developer familiar with Zig but new to
the Native SDK, carried from the port plan. They do not include the
unknowns in [`open-questions.md`](open-questions.md), which can move them.

## Sequencing rules

1. **Fix the build before adding features.** The suite is green today;
   no phase exit is meaningful until `native check` and `native test` are.
2. **One owner per claim.** A screen is "done" only when it is mounted,
   tested and listed in `status.md`.
3. **Data before UI.** A screen without a repository is a mock. Prefer
   finishing the write path for an entity before its form.
4. **One sidecar at a time.** Sync and printing are independent; do not
   interleave them.
5. **The Flutter app is the oracle.** Where behaviour is unclear, capture
   it from v1 rather than inventing it.
6. **No new screens until coverage is honest.** The enum has 45 values
   and 14 of them still have no template. Shrink the gap before widening
   it.

## Definition of done (per phase)

A phase is done when:

- its exit criterion is demonstrated, not asserted;
- `native check` is clean;
- `native test` is green and includes the new rules;
- every new screen is mounted, has a landmark test, and is listed in
  `status.md`;
- every new table has a migration and an in-memory test;
- the owning docs pages are updated;
- the open questions raised by the phase are recorded, not forgotten.

## Definition of release

- All four roles usable end to end on a clean machine.
- Every `Screen` rendered or removed.
- Order → payment → receipt → KOT → status history complete.
- Setup creates a company, an admin, tables and a menu.
- A signed macOS app installs and runs.
- A copy of a real v1 database migrates without loss (or a fresh install
  is the explicit decision).
- CI runs check, test and an automation smoke.
- Printing and sync are either shipped or explicitly out of scope for the
  release.

## Documents

- [`roadmap.md`](roadmap.md) — product-ordered delivery view
- [`backlog.md`](backlog.md) — all 43 screens, one row each
- [`gaps-from-v1.md`](gaps-from-v1.md) — what v2 drops, fixes and still owes v1
- [`status.md`](status.md) — as-built matrix and known defects
- [`risks.md`](risks.md) — risk register
- [`open-questions.md`](open-questions.md) — what we do not know
- Phase pages 0–8
