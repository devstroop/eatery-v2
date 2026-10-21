# As-built status

> **Status:** Snapshot. Regenerate by reading the source, not by trusting
> this page.
> **Last verified:** 2026-10-21, by source review plus the toolchain on
> `PATH`. `native check` passes, `native test` runs 81/81 (80 authored,
> one generated) and `native build` produces a ReleaseFast binary.
> Setup, the order-write fix, the payment flow, the waiter, the kitchen
> stations, the customer display, the settings screens and the catalogue
> and people forms are committed; the sign-in and salt work of
> 2026-10-21 (B-002, B-003) is in the working tree. See the
> [full audit](../review/archive/2026-10-20-audit.md).
> **Screen-by-screen table:** [`architecture/03`](../architecture/03-navigation-and-rbac.md#the-45-screens).

## Scoreboard

| Measure | Value | Evidence |
|---|---|---|
| `Screen` variants | 45 | `src/core/navigation.zig` |
| Screen templates | 31 | `src/screens/*.native` |
| Templates mounted in the shell | 31 (28 gated on the screen ordinal, 3 on their own condition) | `src/app.native` |
| Screens that render at all | 31 | every mounted template builds; a test asserts it |
| Templates with a render test | 31 | `src/tests.zig` (the screen-coverage test builds each one) |
| `Msg` variants | 72 | `src/core/msg.zig` |
| Tables | 43 | `src/schema/*.sql` |
| Migrations | 11 | `migrations.lock.json` version 11 |
| Read queries | 9 (including config) + login SQL | `src/data/repos.zig` |
| Write paths | setup, order + lines, status + history, config, currency, product, employee, payment | `repos.zig` |
| Effect keys | 36, each used once | `src/data/repos.zig`; a test asserts the uniqueness |
| Headless tests | 80 authored (81 reported with the generated one) | `src/tests.zig`, `src/tests_data.zig` |
| Database integration tests | 47, green | `src/tests_data.zig` |
| Sidecar binaries | 0 | `tools/*` contain READMEs only |
| CI workflows | 1 (verify + smoke) | `.github/workflows/ci.yml` |
| Reusable component templates | 0 | `src/components/` empty |

## Subsystems

| Subsystem | Status | Notes |
|---|---|---|
| Build and manifest | Partial | `app.json`, scripts and CI exist; no clean-machine proof; the smoke is shallow |
| App model | Implemented | Model, Msg, update, boot, effects keys |
| Role picker and login | Partial | Salted SHA-256, kiosk sign-in and first-run setup exist; the sign-in now checks the employee's stored role (B-002) and waits for the database to confirm the salt (B-003); the PIN is still a fast digest with no lockout (B-027) |
| RBAC and navigation | Implemented core | 45 screens, 4 roles, one guard, a session-scoped stack ([ADR-0015](../decisions/0015-session-scoped-navigation.md)) |
| Screen coverage | Partial | 31 of 45 screens are mounted and render; 14 have no template yet |
| Theming | Implemented | Light/dark semantic tokens; every text pair is asserted against WCAG AA |
| Shell layout | Partial | Fixed rail + content; no responsive mode |
| Dashboard | Implemented | Counts, recent orders, shortcuts; money is hard-coded to 2 decimals (B-013) |
| POS | Partial | Menu, filter, cart, order types and discounts work; the order write succeeds; a sale happens once, the number is a sequence and a retry is the same sale; the tax is worked out line by line from each product's slab. No modifiers, and the currency's decimals are still two |
| Orders | Partial | Lists non-voided orders including completed; status advance is not conditional (B-008/B-012) |
| Kitchen board | Implemented | Tickets, summary, wait time, advance |
| Floor board | Partial | The table board shows what is true about each table; a guest cannot be moved to another table |
| Customers | Partial | The list, the count and the load all work; a customer cannot be added or attached to an order |
| Employees | Partial | The list and the form work; a PIN cannot be reset and an employee cannot be deactivated |
| Catalog admin | Partial | The catalogue list, the product form, the categories, the tax slabs and the discounts all work; the modifier groups do not |
| Settings / setup | Partial | First-run setup writes company/operator/starter menu/salt; currency-symbol and disabled-submit gaps (B-031/B-032) |
| Payments | Partial | Cash/card/UPI mode, confirmation and one payment write; a payment is taken once, and an order can still be closed without one |
| Reports / compliance | Scaffolded | Tables only |
| Printing | Scaffolded | Tables and README-only sidecar; no code |
| Sync | Scaffolded | Tables and README-only sidecar; no op writes |
| Display board | Partial | The board renders and shows the order cards |
| Waiter shell | Partial | The floor, the menu, the cart and the order list render |
| Testing | Partial | 80 authored + 47 DB tests pass; no sale smoke |
| Packaging | Planned | No packaging/signing workflow; no signed build |

## Flows that work

1. Choose Admin → PIN → dashboard (given an externally seeded employee
   whose stored role is admin).
2. Orders → advance status → `orders.status` + `order_status_history`
   (given an externally seeded order).
3. Choose Kitchen → board → advance tickets.
4. Choose Waiter → tables → menu → cart → order; the order is joined to
   an open order on the table.
5. Choose Display → the customer board shows the order cards.
6. Title-bar **Theme** toggles light/dark.
7. Setup creates a starter menu, six tables, the operator and the
   installation salt; the operator signs in with the PIN they chose.

The POS places an order in the **working tree**; the committed `HEAD`
still omits `orders.updated_at` (B-001). The integration test reads the
order back and advances it. Until the fix and test are committed, do not
cite the committed build as able to sell.

## Flows that do not work

1. ~~**Fresh install.**~~ FIXED: the app opens on the setup screen when
   the database has no company, and the setup writes the company, the
   operator, the installation salt, a 13-dish starter menu and six
   tables in one transaction. The operator can then sign in with the PIN
   they chose.
2. **Place order (committed HEAD).** The insert fails before reaching the
   database: `orders.updated_at` is required and never written (B-001).
   The working tree fixes it and writes `NULL` for absent table/customer
   ids (B-005); the fix is not committed.
3. **Sign-in with the wrong role.** FIXED: the sign-in query is scoped to
   the session's role and the returned row is checked against it, so a
   waiter's PIN no longer opens an admin session (B-002).
4. **Sign-in before the salt is confirmed.** FIXED: the sign-in waits
   until the database has confirmed the salt, and the setup writes the
   salt with the operator's hash (B-003).
5. **Payment edge cases.** A payment screen exists, but it can be taken twice (B-035) and “Another order” is unhandled (B-033).
6. **Printing.** No receipt, no KOT.
7. **Sync.** No second device sees the first.
8. **Customers.** The list renders, but the data is never loaded.

## Known source defects

These are facts about the current tree. Fixing them is engineering work, not
a docs change.

| # | Defect | Where | Impact |
|---|---|---|---|
| D1 | ~~Provisional salt installed before the database confirms it; a failed save was marked confirmed~~ | `src/core/update.zig` (`submit_login`, `createSalt`, `config_loaded`) | FIXED: the salt is a four-state lifecycle (`unknown`, `installing`, `verifying`, `confirmed`), the sign-in waits for `confirmed`, and the setup writes the salt with the operator's hash (B-003) |
| D2 | ~~Order `id` = wall ms, `order_no` = wall seconds~~ | `src/core/update.zig` (`placeOrder`, `nextOrderId`), `src/data/repos.zig` (`saveOrder`) | FIXED: the number is a sequence the database assigns, the id keeps a per-device floor, and a request key makes a retry the same sale (B-006, [ADR-0014](../decisions/0014-order-identity.md)) |
| D3 | `loadAll` omits `loadCustomers` | `src/data/repos.zig` (`loadAll`) | Customer data never appears (B-015) |
| D4 | Shell gates are hard-coded ordinals | `src/app.native` | A test now pins the gated ordinals against the enum, so inserting a screen fails the suite instead of remapping the UI (B-023) |
| D5 | `orders` header badge says "open" but uses `order_count` (non-voided, including completed) | `src/screens/screen-orders.native` | Misleading count (B-012) |
| D6 | `auth.equal` is tested but unused by the login path | `src/data/auth.zig` | Constant-time compare is not actually protecting login (B-027) |
| D7 | `app.json` declares a 960×600 minimum and restore policy; `main.zig` shell config does not | `app.json`, `src/main.zig` | `native dev` can open an unsupported window (B-024) |
| D8 | `busy` is set on write, not on read | `src/core/update.zig` | No loading state (B-021) |
| D9 | ~~No screen-coverage test~~ | `src/tests.zig` | FIXED: a test builds every gated screen and every screen in the enum, and asserts the widget budget. It found four screens that could never render (D20) |
| D10 | CI smoke asserts only a non-blank canvas | `.github/workflows/ci.yml` | A blank or broken shell can still pass (G-018) |
| D11 | No `build.zig` / `build.zig.zon` in the app | app root | Fine while managed; blocks linking a C library until `native eject` |
| D12 | ~~`view_unbound` lists `pending_screen`, which is not a field~~ | `src/core/model.zig` | FIXED: the stale entry is gone and the salt state is listed |
| D13 | Order insert omitted `orders.updated_at`, which is `NOT NULL` with no default | `src/data/repos.zig` (`saveOrder`), `src/schema/0005_orders.sql` | Every order write failed (B-001); fixed in the working tree, not committed |
| D14 | ~~Login query ignores `employee.role`; the chosen role decides the session~~ | `src/core/update.zig` (`login_checked`), `src/data/repos.zig` (`login_sql`) | FIXED: the query asks for the session's role and the returned row is checked against it (B-002) |
| D15 | Order table/customer ids were written as `0`, not `NULL` | `src/core/update.zig` (`placeOrder`) | Failed with FKs on; fixed in the working tree (B-005) |
| D16 | ~~`decodeCompany` kept slices into page drain memory~~ | `src/data/repos.zig` (`decodeCompany`) | FIXED: every decoder copies text into the model's bump buffer, and a regression test overwrites the page after decoding to prove it (B-004) |
| D17 | ~~PIN is a fast SHA-256 over four digits, with no lockout or masking~~ | `src/data/auth.zig`, `src/screens/screen-login.native` | FIXED: bcrypt at 2^10 rounds, six digits, and the till stops after five wrong PINs. The PIN field is still typed in the clear: the SDK has no masked text field (B-027, [ADR-0016](../decisions/0016-what-a-pin-is.md)) |
| D18 | Setup exists but has gaps (currency symbol field, no disabled submit) | `src/screens/screen-setup.native`, `src/core/update.zig` | A fresh install can start, but setup is not trustworthy (G-001) |
| D19 | ~~Status advance is not conditional; history can duplicate~~ | `src/core/update.zig` (`advance_order`), `src/data/repos.zig` (`setOrderStatus`) | FIXED: the move happens only from the status the order is in, and the history is written only when it did (B-008) |
| D20 | Four screens bound counts the model does not have (`customer_count`, `reservation_count`, `supplier_count`, `purchase_order_count`) | `src/screens/screen-customers.native`, `screen-reservations.native`, `screen-suppliers.native`, `screen-purchase-orders.native` | FIXED: those rail destinations could never render at all. The counts are model methods now |
| D21 | Three effect keys were used by two effects each (20, 21, 22) | `src/data/repos.zig` (the key table) | FIXED: a second live effect with the same key is REFUSED, so a company save could refuse an order write. Every key is used once, and a test says so |
| D22 | ~~The amounts are shown with two decimals whatever the currency is~~ | `apps/eatery/src/core/model.zig` (`currency_divisor`), `apps/eatery/src/screens/*.native` | FIXED: the company carries its currency's decimals, the divisor comes from the model, and no amount divides by a hundred in the markup (B-013) |
| D23 | An order can be closed without a payment | `src/core/update.zig` (`nextStatus`) | The kitchen can advance a ticket straight to closed and the money is never taken (B-014) |
| D24 | ~~Back from home exposed the login screen; the stack froze at depth 32; cart/search/filters survived sign-out and role change~~ | `src/core/update.zig` (`resetSession`, `go`), `src/core/navigation.zig` (`Stack.push`) | FIXED: one session reset path, session gates are roots, pushing the current screen is a no-op and a full stack drops its oldest entry ([ADR-0015](../decisions/0015-session-scoped-navigation.md); B-009, B-010, B-011) |
| D25 | The PIN salt is per installation, not per employee | `src/data/auth.zig` | A database that is cracked gives up every PIN, not one ([ADR-0016](../decisions/0016-what-a-pin-is.md)) |
| D26 | A table with an order on it still said "Free" | `src/data/repos.zig` (`openOrderForTable`, `takePayment`) | FIXED: the table is occupied when the order opens and free when it is paid for, in the same transaction as each |
| D27 | The lists showed what the restaurant had finished with | `src/data/repos.zig` (the list queries) | FIXED: the categories, tables, customers and suppliers are filtered on `active` |
| D28 | The shell's import closure was full | `apps/eatery/src/screens/` | FIXED: the screens of one area share one file, so the ceiling is no longer the reason the forms had to share |
| D29 | An empty pane and a working screen looked the same | `src/tests.zig` | FIXED: every screen has a landmark of its own, and the test finds it |
| D26 | The failed-PIN counter is per session | `src/core/model.zig` | A restart clears it, so a determined guesser restarts (B-027) |
| D27 | ~~A second instance could confirm its own salt after a no-op write~~ | `src/core/update.zig` (`config_saved`) | FIXED: a successful salt write is read back; the model adopts the stored salt and only confirms that one (B-028) |

B-002 and B-003 are fixed in the working tree of 2026-10-21, with the
effect-key collision (D21) and the four unrenderable screens (D20) found
alongside them. The order identity was settled the same day: the number
is a sequence the database assigns, the id keeps a per-device floor, and
a request key makes a retry the same sale
([ADR-0014](../decisions/0014-order-identity.md), which supersedes
[ADR-0013](../decisions/0013-clock-based-order-ids.md)).

The money track has since closed the amount: the tax is worked out line
by line from each product's own slab, a discount is spread across the
lines and the tax follows it, a payment is taken once, and every
transition is conditional. What is left of the money is the currency's
decimals (D22), an order that can close without a payment (D23), and
the PIN's strength (B-027). The full order is in the
[audit](../review/archive/2026-10-20-audit.md).

The compile-time `makeSalt` mismatch and the invisible-error-banner gap
were fixed earlier; they are no longer current defects. This status page
now defers detailed evidence to the [review set](../review/README.md).

## Test inventory

| Test | Area |
|---|---|
| Role picker first, four roles | Navigation |
| PIN role → login | Session |
| Kiosk role → board | Session |
| Back from home after a sign-in stays home | Session / Stack |
| Signing out clears the cart, filters and operator | Session |
| Changing role ends the previous session | Session |
| Role cannot open forbidden screen | RBAC |
| Matrix is total (tautological; see D-007) | RBAC |
| Back returns | Stack |
| A full history drops its oldest entry, so navigation never freezes | Stack |
| Pressing the current destination does not grow the history | Stack |
| Cart arithmetic | POS |
| A second tap in flight does not place a second order | POS |
| Two sales in the same millisecond are two sales | POS |
| The order number is a sequence | POS |
| A failed sale does not consume an order number | POS |
| A retried write is the same sale | POS |
| The tax is worked out line by line, from the product's own slab | POS |
| An inclusive price already carries its tax | POS |
| The tax is rounded half up | POS |
| A discount comes off the bill, and the tax follows it | POS |
| A fixed discount is spread over the lines | POS |
| Advancing an order twice writes one history row | Orders |
| A move that does not apply leaves the order where it is | Orders |
| A payment is taken once | Payment |
| Integer money | Domain |
| PIN hashing | Auth |
| A waiter's PIN does not open an admin session | Session |
| A sign-in waits for the database to confirm the salt | Auth |
| A failed salt write is not a confirmed salt | Auth |
| A second instance adopts the salt that is already stored | Auth |
| The page decoder | Data |
| A decoded company does not point at the page bytes | Data |
| Derived counts | Model |
| Layout survives resize | Markup |
| The shell gates the screens the enum says it does | Navigation |
| Every gated screen renders, inside the widget budget | Markup |
| Every screen builds a view inside the budget | Markup |
| Every effect key names one effect and no two | Data |
| Every light and dark text pair clears WCAG AA | Theme |

Not covered: every decoder except the generic page reader and the
company decoder, timer, error arms, the sidecars, and a sale through the
UI.

## What "done" would add

- An automation smoke for the sale flow.
- A CI workflow that exercises a sale (one exists, but only a non-blank smoke).
- A test per screen that asserts what the operator sees, not only that
  it builds.

## Related

- [architecture/03](../architecture/03-navigation-and-rbac.md) — screen and role detail
- [architecture/04](../architecture/04-data-layer.md) — repository coverage
- [risks](risks.md) — what could go wrong next
- [open questions](open-questions.md) — what we still do not know
