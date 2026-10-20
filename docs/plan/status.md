# As-built status

> **Status:** Snapshot. Regenerate by reading the source, not by trusting
> this page.
> **Last verified:** 2026-10-20 23:45, by source review plus the
> toolchain on `PATH`. `native check` passes. The working tree runs
> 25/25 tests: 13 authored headless, 11 in-memory database tests, and one
> generated test. The database tests are **uncommitted**; the committed
> `HEAD` still has the order-write defect and runs 13/13. See the
> [full audit](../review/2026-10-20-audit.md).
> **Screen-by-screen table:** [`architecture/03`](../architecture/03-navigation-and-rbac.md#the-43-screens).

## Scoreboard

| Measure | Value | Evidence |
|---|---|---|
| `Screen` variants | 43 | `src/core/navigation.zig` |
| Screen templates | 8 | `src/screens/*.native` |
| Templates mounted in the shell | 5 | `src/app.native` gates at 8, 10, 13, 17, 41 |
| Screens that render at all | 8 | 5 shell gates + setup + role picker + login |
| Templates with a render test | 3 (setup, role picker, login indirectly) | `src/tests.zig` |
| `Msg` variants | 46 | `src/core/msg.zig` |
| Tables | 43 | `src/schema/*.sql` |
| Migrations | 11 | `migrations.lock.json` version 11 |
| Read queries | 9 (including config) + login SQL | `src/data/repos.zig` |
| Write paths | order + lines, status + history, config | `repos.zig` |
| Headless tests | 13 authored (25 reported with the DB suite + one generated) | `src/tests.zig`, `src/tests_data.zig` |
| Database integration tests | 11, green but uncommitted | `src/tests_data.zig` |
| Sidecar binaries | 0 | `tools/*` contain READMEs only |
| CI workflows | 1 (verify + smoke) | `.github/workflows/ci.yml` |
| Reusable component templates | 0 | `src/components/` empty |

## Subsystems

| Subsystem | Status | Notes |
|---|---|---|
| Build and manifest | Partial | `app.json`, scripts and CI exist; no clean-machine proof; the smoke is shallow |
| App model | Implemented | Model, Msg, update, boot, effects keys |
| Role picker and login | Partial | Salted SHA-256, kiosk sign-in and first-run setup exist; login ignores the employee role (B-002) and the salt race is open (B-003) |
| RBAC and navigation | Implemented core | 43 screens, 4 roles, one guard, stack |
| Screen coverage | Partial | 5 mounted of 43 |
| Theming | Implemented | Light/dark semantic tokens |
| Shell layout | Partial | Fixed rail + content; no responsive mode |
| Dashboard | Implemented | Counts, recent orders, shortcuts; money is hard-coded to 2 decimals (B-013) |
| POS | Partial | Menu, filter, cart and order types work; the order write now succeeds in the working tree (B-001 fixed, uncommitted); no modifiers, tax, discount or payment |
| Orders | Partial | Lists non-voided orders including completed; status advance is not conditional (B-008/B-012) |
| Kitchen board | Implemented | Tickets, summary, wait time, advance |
| Floor board | Partial | Read-only table cards |
| Customers | Scaffolded | Repository and buffer; no load call, no UI |
| Employees | Partial | Login only; no list/admin |
| Catalog admin | Planned | Schema, no write path, no templates |
| Settings / setup | Partial | First-run setup writes company/operator/starter menu; no settings editors |
| Payments | Scaffolded | Table only |
| Reports / compliance | Scaffolded | Tables only |
| Printing | Scaffolded | Tables and README-only sidecar; no code |
| Sync | Scaffolded | Tables and README-only sidecar; no op writes |
| Display board | Scaffolded | Enum entry, no template |
| Waiter shell | Partial | Role and rail exist; no templates |
| Testing | Partial | 13 authored + 11 DB tests pass in the working tree; the DB suite is uncommitted; no sale smoke |
| Packaging | Planned | No packaging/signing workflow; no signed build |

## Flows that work

1. Choose Admin → PIN → dashboard (given an externally seeded employee).
2. Orders → advance status → `orders.status` + `order_status_history`
   (given an externally seeded order).
3. Choose Kitchen → board → advance tickets.
4. Title-bar **Theme** toggles light/dark.
5. Dining tables board renders seeded tables.

The POS places an order in the **working tree**; the committed `HEAD`
still omits `orders.updated_at` (B-001). The integration test reads the
order back and advances it. Until the fix and test are committed, do not
cite the committed build as able to sell.

## Flows that do not work

1. ~~**Fresh install.**~~ FIXED: the app opens on the setup screen when
   the database has no company, and the setup writes the company, the
   operator, a 13-dish starter menu and six tables in one transaction.
   The operator can then sign in with the PIN they chose.
2. **Place order (committed HEAD).** The insert fails before reaching the
   database: `orders.updated_at` is required and never written (B-001).
   The working tree fixes it and writes `NULL` for absent table/customer
   ids (B-005); the fix is not committed.
3. **Waiter.** Signs in, lands on a blank content pane.
4. **Display.** Signs in, lands on a blank content pane.
5. **Order confirmation.** Navigation lands on a screen with no template.
6. **Catalog / People / System.** Rail destinations render nothing.
7. **Payments.** No way to pay or close an order with money.
8. **Printing.** No receipt, no KOT.
9. **Sync.** No second device sees the first.
10. **Customers.** Data is never loaded.

## Known source defects

These are facts about the current tree. Fixing them is engineering work, not
a docs change.

| # | Defect | Where | Impact |
|---|---|---|---|
| D1 | Provisional salt is installed and `pin_salt_len` set before the database confirms it; `submit_login` checks only that the salt is non-empty, not `salt_is_provisional`; `createSalt` clears the flag before the write completes | `src/main.zig`, `src/core/update.zig` (`submit_login`, `createSalt`) | A fast sign-in can hash against a salt that is then replaced; a failed save is marked confirmed (B-003) |
| D2 | Order `id` = wall ms, `order_no` = wall seconds | `src/core/update.zig` (`placeOrder`, `allocOrderNo`) | Same-second orders collide on a `UNIQUE` column (B-006) |
| D3 | `loadAll` omits `loadCustomers` | `src/data/repos.zig` (`loadAll`) | Customer data never appears (B-015) |
| D4 | Shell gates are hard-coded ordinals | `src/app.native` | Inserting a screen silently remaps the UI (B-023) |
| D5 | `orders` header badge says "open" but uses `order_count` (non-voided, including completed) | `src/screens/screen-orders.native` | Misleading count (B-012) |
| D6 | `auth.equal` is tested but unused by the login path | `src/data/auth.zig` | Constant-time compare is not actually protecting login (B-027) |
| D7 | `app.json` declares a 960×600 minimum and restore policy; `main.zig` shell config does not | `app.json`, `src/main.zig` | `native dev` can open an unsupported window (B-024) |
| D8 | `busy` is set on write, not on read | `src/core/update.zig` | No loading state (B-021) |
| D9 | No screen-coverage test | `src/tests.zig` | Blank panes are invisible to the suite (G-017) |
| D10 | CI smoke asserts only a non-blank canvas | `.github/workflows/ci.yml` | A blank or broken shell can still pass (G-018) |
| D11 | No `build.zig` / `build.zig.zon` in the app | app root | Fine while managed; blocks linking a C library until `native eject` |
| D12 | `view_unbound` lists `pending_screen`, which is not a field | `src/core/model.zig` | Stale lint entry; harmless today |
| D13 | Order insert omitted `orders.updated_at`, which is `NOT NULL` with no default | `src/data/repos.zig` (`saveOrder`), `src/schema/0005_orders.sql` | Every order write failed (B-001); fixed in the working tree, not committed |
| D14 | Login query ignores `employee.role`; the chosen role decides the session | `src/core/update.zig` (`login_sql`, `login_checked`) | Any employee PIN can open Admin (B-002) |
| D15 | Order table/customer ids were written as `0`, not `NULL` | `src/core/update.zig` (`placeOrder`) | Failed with FKs on; fixed in the working tree (B-005) |
| D16 | `decodeCompany` kept slices into page drain memory | `src/data/repos.zig` (`decodeCompany`) | Company name/currency dangled; fixed in the working tree (B-004) |
| D17 | PIN is a fast SHA-256 over four digits, with no lockout or masking | `src/data/auth.zig`, `src/screens/screen-login.native` | Offline brute force and shoulder-surfing (B-027) |
| D18 | Setup exists but has gaps (currency symbol field, no disabled submit, salt race) | `src/screens/screen-setup.native`, `src/core/update.zig` | A fresh install can start, but setup is not trustworthy (G-001) |
| D19 | Status advance is not conditional; history can duplicate | `src/core/update.zig` (`advance_order`), `src/data/repos.zig` (`setOrderStatus`) | Double taps produce duplicate transitions (B-008) |

B-001/B-004/B-005 are fixed in the working tree but uncommitted. The
first remaining fixes are B-002 (role check) and B-003 (salt); the full
order is in the [audit](../review/2026-10-20-audit.md). D2 is still the
first identifier scheme to design away
(see [ADR-0013](../decisions/0013-clock-based-order-ids.md)).

The compile-time `makeSalt` mismatch and the invisible-error-banner gap
were fixed earlier; they are no longer current defects. This status page
now defers detailed evidence to the [review set](../review/README.md).

## Test inventory

| Test | Area |
|---|---|
| Role picker first, four roles | Navigation |
| PIN role → login | Session |
| Kiosk role → board | Session |
| Role cannot open forbidden screen | RBAC |
| Matrix is total (tautological; see D-007) | RBAC |
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
- A CI workflow that exercises a sale (one exists, but only a non-blank smoke).
- A setup flow so a fresh install can log in.

## Related

- [architecture/03](../architecture/03-navigation-and-rbac.md) — screen and role detail
- [architecture/04](../architecture/04-data-layer.md) — repository coverage
- [risks](risks.md) — what could go wrong next
- [open questions](open-questions.md) — what we still do not know
