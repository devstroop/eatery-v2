# As-built status

> **Status:** Snapshot. Regenerate by reading the source, not by trusting
> this page.
> **Last verified:** 2026-10-20, by source review. The CLI is not on this
> shell's PATH, so the tests were not re-run. A binary built at 22:27
> exists at `apps/eatery/zig-out/bin/eatery`.
> **Screen-by-screen table:** [`architecture/03`](../architecture/03-navigation-and-rbac.md#the-43-screens).

## Scoreboard

| Measure | Value | Evidence |
|---|---|---|
| `Screen` variants | 43 | `src/core/navigation.zig` |
| Screen templates | 7 | `src/screens/*.native` |
| Templates mounted in the shell | 5 | `src/app.native` gates at 8, 10, 13, 17, 41 |
| Screens that render at all | 7 | 5 shell gates + role picker + login |
| Templates with a render test | 2 (role picker, login indirectly) | `src/tests.zig` |
| `Msg` variants | 39 | `src/core/msg.zig` |
| Tables | 43 | `src/schema/*.sql` |
| Migrations | 10 | `migrations.lock.json` version 10 |
| Read queries | 9 (including config) + login SQL | `src/data/repos.zig` |
| Write paths | order + lines, status + history, config | `repos.zig` |
| Headless tests | 12 | `src/tests.zig` |
| Sidecar binaries | 0 | `tools/*` empty |
| CI workflows | 0 | `.github/workflows/` empty |
| Reusable component templates | 0 | `src/components/` empty |

## Subsystems

| Subsystem | Status | Notes |
|---|---|---|
| Build and manifest | Partial | `app.json` and `main.zig` exist; environment not pinned in repo; no CI |
| App model | Implemented | Model, Msg, update, boot, effects keys |
| Role picker and login | Implemented | PIN hashed with a salted SHA-256; kiosk sign-in |
| RBAC and navigation | Implemented core | 43 screens, 4 roles, one guard, stack |
| Screen coverage | Partial | 5 mounted of 43 |
| Theming | Implemented | Light/dark semantic tokens |
| Shell layout | Partial | Fixed rail + content; no responsive mode |
| Dashboard | Implemented | Counts, recent orders, shortcuts |
| POS | Partial | Menu, filter, cart, order types, place order; no modifiers, tax, discounts, payment |
| Orders | Implemented | List all non-voided, advance status |
| Kitchen board | Implemented | Tickets, summary, wait time, advance |
| Floor board | Partial | Read-only table cards |
| Customers | Scaffolded | Repository and buffer; no load call, no UI |
| Employees | Partial | Login only; no list/admin |
| Catalog admin | Planned | Schema, no write path, no templates |
| Settings / setup | Planned | Enum entries only; no company creation |
| Payments | Scaffolded | Table only |
| Reports / compliance | Scaffolded | Tables only |
| Printing | Scaffolded | Tables and empty sidecar dir |
| Sync | Scaffolded | Tables and empty sidecar dir; no op writes |
| Display board | Scaffolded | Enum entry, no template |
| Waiter shell | Partial | Role and rail exist; no templates |
| Testing | Partial | 12 tests; no DB integration, no automation |
| Packaging | Planned | No workflow, no signed build |

## Flows that work

1. Choose Admin → PIN → dashboard (if an employee with a PIN exists).
2. Dashboard → POS → search/filter → add to cart → set order type →
   place order → row written to `orders` + `order_line`.
3. Orders → advance status → `orders.status` + `order_status_history`.
4. Choose Kitchen → board → advance tickets.
5. Title-bar **Theme** toggles light/dark.
6. Dining tables board renders seeded tables.

## Flows that do not work

1. **Fresh install.** There is no setup flow. There is no company row and
   no employee, so login cannot succeed unless the database was seeded
   externally.
2. **Waiter.** Signs in, lands on a blank content pane.
3. **Display.** Signs in, lands on a blank content pane.
4. **Order confirmation.** Navigation lands on a screen with no template.
5. **Catalog / People / System.** Rail destinations render nothing.
6. **Payments.** No way to pay or close an order with money.
7. **Printing.** No receipt, no KOT.
8. **Sync.** No second device sees the first.
9. **Customers.** Data is never loaded.

## Known source defects

These are facts about the current tree. Fixing them is engineering work, not
a docs change.

| # | Defect | Where | Impact |
|---|---|---|---|
| D1 | Provisional salt is installed and `pin_salt_len` set before the database confirms it; `submit_login` checks only that the salt is non-empty, not `salt_is_provisional` | `src/main.zig`, `src/core/update.zig` (`submit_login`) | A fast sign-in can hash against a salt that is then replaced |
| D2 | Order `id` = wall ms, `order_no` = wall seconds | `src/core/update.zig` (`placeOrder`, `allocOrderNo`) | Same-second orders collide on a `UNIQUE` column |
| D3 | `loadAll` omits `loadCustomers` | `src/data/repos.zig` (`loadAll`) | Customer data never appears |
| D4 | Shell gates are hard-coded ordinals | `src/app.native` | Inserting a screen silently remaps the UI |
| D5 | `orders` header badge says "open" but uses `order_count` (non-voided, including completed) | `src/screens/screen-orders.native` | Misleading count |
| D6 | `auth.equal` is tested but unused by the login path | `src/data/auth.zig` | Constant-time compare is not actually protecting login |
| D7 | `app.json` declares a 960×600 minimum and restore policy; `main.zig` shell config does not | `app.json`, `src/main.zig` | `native dev` can open an unsupported window |
| D8 | `busy` is set on write, not on read | `src/core/update.zig` | No loading state |
| D9 | No screen-coverage test | `src/tests.zig` | Blank panes are invisible to CI |
| D10 | No CI at all | `.github/workflows/` | Nothing prevents a regression |
| D11 | No `build.zig` / `build.zig.zon` in the app | app root | Fine while managed; blocks linking a C library until `native eject` |
| D12 | `view_unbound` lists `pending_screen`, which is not a field | `src/core/model.zig` | Stale lint entry; harmless today |

D1 is the first correctness fix. D2 is the first thing to design away
(see [ADR-0013](../decisions/0013-clock-based-order-ids.md)). D3 is a
one-line omission with a visible product effect.

The compile-time `makeSalt` mismatch and the invisible-error-banner gap
were fixed during this documentation pass; they are no longer current
defects.

## Test inventory

| Test | Area |
|---|---|
| Role picker first, four roles | Navigation |
| PIN role → login | Session |
| Kiosk role → board | Session |
| Role cannot open forbidden screen | RBAC |
| Matrix is total | RBAC |
| Back returns | Stack |
| Cart arithmetic | POS |
| Integer money | Domain |
| PIN hashing | Auth |
| Page decoder | Data |
| Derived counts | Model |
| Layout survives resize | Markup |

Not covered: login success/failure with a real database, order write and
read-back, every decoder except the generic page reader, every screen
template except the role picker/login, node budget, theme tokens, timer,
error arms, the salt lifecycle, sidecars.

## What "done" would add

- A seeded in-memory database fixture and repository tests.
- A test per screen that builds its tree.
- A screen-coverage assertion.
- An automation smoke for the sale flow.
- A CI workflow.
- A setup flow so a fresh install can log in.

## Related

- [architecture/03](../architecture/03-navigation-and-rbac.md) — screen and role detail
- [architecture/04](../architecture/04-data-layer.md) — repository coverage
- [risks](risks.md) — what could go wrong next
- [open questions](open-questions.md) — what we still do not know
