# As-built status

> **Status:** Snapshot. Regenerate by reading the source, not by trusting
> this page. The detailed counts below describe the admin app; the
> service and kiosk mount their role's subsets of the same core.
> **Last verified:** 2026-10-24, by source review and the split suites.
> `scripts/verify-all.sh` is green for ros-core, admin, kiosk, net-spike
> and service; the admin suite is 138/138 and the service suite 8/8.
> `native build` produces ReleaseFast binaries.
> The money and back-office tracks are merged. The three apps share
> `packages/ros-core`; the session and setup screens are copied into
> each app by the package split. The screens the roadmap's phase two
> names are built.
> See the [full audit](../review/archive/2026-10-20-audit.md).
> **Screen-by-screen table:** [`architecture/03`](../architecture/03-navigation-and-rbac.md#the-45-screens).

## Scoreboard

| Measure | Value | Evidence |
|---|---|---|
| `Screen` variants | 53 | `packages/ros-core/src/core/navigation.zig` |
| Screen templates | 53 in the admin app | `apps/admin/src/screens/*.native` (ten area files); the service and kiosk copies carry their subsets |
| Templates mounted in the shell | 53 in the admin (46 on the screen ordinal, seven session screens on their own condition); the service and kiosk mount their role's subset | `apps/{admin,service,kiosk}/src/app.native` |
| Screens that render at all | 53 in the admin | every mounted template builds; a test asserts it |
| Templates with a render test | 53 in the admin | `apps/admin/src/tests.zig` (the screen-coverage test builds each one, and finds a landmark of its own) |
| `Msg` variants | 201 | `packages/ros-core/src/core/msg.zig` |
| Tables | 44 | `apps/admin/src/schema/*.sql` |
| Migrations | 15 | `apps/admin/migrations.lock.json` version 15 |
| Read queries | 16 named constants | `packages/ros-core/src/data/repos.zig` (one named constant each, and one place that says the app is loading) |
| Write paths | setup, order + lines, status + history, config, currency, product, employee, employee PIN, employee removal, customer, category, tax slab, discount, modifier group, dish station, stock count, payment, op log, reference version | `repos.zig` |
| Effect keys | 62, each used once | `packages/ros-core/src/data/repos.zig`; a test asserts the uniqueness |
| Headless tests | admin 138/138, service 8/8; every target green | `apps/*/src/tests*.zig`, `scripts/verify-all.sh` |
| Database integration tests | 95, green | `apps/admin/src/tests_data.zig` |
| Sidecar binaries | 0 | `tools/*` contain READMEs only |
| CI workflows | 1 (verify + smoke) | `.github/workflows/ci.yml` |
| Reusable component templates | 0 | `src/components/` empty |

## Subsystems

| Subsystem | Status | Notes |
|---|---|---|
| Build and manifest | Partial | `app.json`, scripts and CI exist; no clean-machine proof; the smoke is shallow |
| App model | Implemented | Model, Msg, update, boot, effects keys |
| Role picker and login | Partial | bcrypt PIN hashes, kiosk sign-in and the admin's first-run setup exist; the sign-in checks the employee's stored role (B-002) and waits for the database to confirm the salt (B-003). A service or kiosk waits for the admin's reference data instead of setting up. The PIN field is still typed in the clear (B-027, #96) |
| RBAC and navigation | Implemented core | 53 screens, 4 roles, one guard, a session-scoped stack ([ADR-0015](../decisions/0015-session-scoped-navigation.md)) |
| Screen coverage | Implemented | 53 screens in the admin app; every one is mounted, renders, and has a landmark of its own. The seven session screens are mounted on their own condition, the other forty-six on their ordinal gate. The service and kiosk mount their role's subset |
| Theming | Implemented | Light/dark semantic tokens; every text pair is asserted against WCAG AA |
| Shell layout | Partial | Fixed rail + content; no responsive mode. The shell says "Loading..." while a read is on its way, and a failed read replaces the screen with the reason and a way to try again |
| Dashboard | Implemented | Counts, recent orders, shortcuts; amounts use the company's currency decimals |
| POS | Partial | Menu, filter, cart, order types and discounts work; the order write succeeds; a sale happens once, the number is a sequence and a retry is the same sale; the tax is worked out line by line from each product's slab. No modifiers; the price parser is still two-decimal (#66) |
| Orders | Partial | Lists non-voided orders including completed; status advance is conditional (D19); the header badge still disagrees with the list (D5, #7) |
| Kitchen board | Implemented | Tickets, summary, wait time, advance |
| Floor board | Partial | The table board shows what is true about each table; a guest cannot be moved to another table |
| Customers | Partial | The list, the count, the load and the form all work - a customer can be written and edited. A customer still cannot be attached to an order, so the loyalty points are only ever earned by hand |
| Employees | Partial | The list and the form work; a PIN can be reset by a manager, and an employee who has left can be removed - the row stays, so the orders they took still name them, and the last admin cannot be removed |
| Catalog admin | Partial | The catalogue list, the product form, the categories, the tax slabs, the discounts and the modifier groups all work. The CHOICES inside a modifier group, and which dishes a group applies to, do not |
| Settings / setup | Partial | The admin's first run is the walk-through: the company's record, then the owner and their PIN, written in one transaction with the starter menu, the salt and six tables. The quick setup stays for an owner who wants to start serving sooner. A service or kiosk that starts first waits for the admin's reference data and cannot set up a second restaurant |
| Payments | Partial | Cash/card/UPI mode, confirmation and one payment write; a payment is taken once, and an order can still be closed without one |
| Reports / compliance | Partial | The owner's read of the day exists: the takings, the orders, the tax, the discounts, and the way the money was paid. The X report, the Z report and the day close are the reports track's |
| Printing | Scaffolded | Tables and README-only sidecar; no code |
| Sync | Implemented core | Op log in the same transaction, per-device Lamport clock and vector cursor, beacon or manual peers, reference snapshot. The event stream (#110), late join/compaction (#111) and order identity across devices (#87) remain |
| Display board | Partial | The board renders and shows the order cards |
| Waiter shell | Partial | The floor, the menu, the cart and the order list render |
| Testing | Partial | The split suites are green via `scripts/verify-all.sh` (admin 138/138, service 8/8); no sale smoke through the UI (#42) |
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
7. The admin's setup creates a starter menu, six tables, the operator
   and the installation salt; the operator signs in with the PIN they
   chose. The service and kiosk copy the menu and the people from the
   admin's reference document.

The POS order write is committed and read back by the integration test
(`placing an order writes one op row and a durable clock`); the earlier
B-001/B-005 failures are history.

## Flows that do not work

1. ~~**Fresh install.**~~ FIXED for the admin: the admin app opens on
   the setup screen when the database has no company, and its setup
   writes the company, the operator, the installation salt, a 13-dish
   starter menu and six tables in one transaction. A service or kiosk
   that starts first waits for the admin's reference data.
2. ~~**Place order (committed HEAD).**~~ FIXED: the insert writes
   `orders.updated_at` and writes `NULL` for absent table/customer ids
   (B-001, B-005); the integration test reads the order back.
3. **Sign-in with the wrong role.** FIXED: the sign-in query is scoped to
   the session's role and the returned row is checked against it, so a
   waiter's PIN no longer opens an admin session (B-002).
4. **Sign-in before the salt is confirmed.** FIXED: the sign-in waits
   until the database has confirmed the salt, and the setup writes the
   salt with the operator's hash (B-003).
5. **Payment edge cases.** FIXED: the payment write is idempotent (B-035).
   Closing a ticket without a payment is still possible (D23), and
   "Another order" is unhandled (B-033).
6. **Printing.** No receipt, no KOT.
7. ~~**Sync.** No second device sees the first.~~ FIXED: a second device
   pulls the ops above its vector cursor, and the reference document
   gives it the menu, people and tables. A late joiner still replays the
   whole log (#111).
8. ~~**Customers.** The list renders, but the data is never loaded.~~ FIXED: the
   customers load, and the owner can write one.
9. **A customer on an order.** The column is there and the order's
   `customer_id` is written, but the selling flow does not let the
   cashier pick the customer, so the loyalty points are never earned by
   a sale.
10. **The trading day.** The report's day is the calendar day. An order
    has no accounting date of its own, and the policy for a trading
    day is not settled (B-036, V1-G-027).
11. ~~**Loading and retry.**~~ FIXED: every read goes through one
    place, the shell says "Loading..." while one is on its way, and a
    read that failed is remembered with the screen it failed for. The
    screen is replaced with the reason and a "Try again" button, so a
    failed read never leaves a screen saying there is nothing there
    (B-021, E-004).

## Known source defects

These are facts about the current tree. Fixing them is engineering work, not
a docs change.

| # | Defect | Where | Impact |
|---|---|---|---|
| D1 | ~~Provisional salt installed before the database confirms it; a failed save was marked confirmed~~ | `src/core/update.zig` (`submit_login`, `createSalt`, `config_loaded`) | FIXED: the salt is a four-state lifecycle (`unknown`, `installing`, `verifying`, `confirmed`), the sign-in waits for `confirmed`, and the setup writes the salt with the operator's hash (B-003) |
| D2 | ~~Order `id` = wall ms, `order_no` = wall seconds~~ | `src/core/update.zig` (`placeOrder`, `nextOrderId`), `src/data/repos.zig` (`saveOrder`) | FIXED: the number is a sequence the database assigns, the id keeps a per-device floor, and a request key makes a retry the same sale (B-006, [ADR-0014](../decisions/0014-order-identity.md)) |
| D3 | ~~`loadAll` omits `loadCustomers`~~ | `packages/ros-core/src/data/repos.zig` (`loadAll`) | FIXED: `loadAll` calls `loadCustomers`; the list and the form load (B-015) |
| D4 | Shell gates are hard-coded ordinals | `src/app.native` | A test now pins the gated ordinals against the enum, so inserting a screen fails the suite instead of remapping the UI (B-023) |
| D5 | `orders` header badge says "open" but uses `order_count` (non-voided, including completed) | `src/screens/screen-orders.native` | Misleading count (B-012) |
| D6 | `auth.equal` is tested but unused by the login path | `src/data/auth.zig` | Constant-time compare is not actually protecting login (B-027) |
| D7 | `app.json` declares a 960×600 minimum and restore policy; `main.zig` shell config does not | `app.json`, `src/main.zig` | `native dev` can open an unsupported window (B-024) |
| D8 | ~~`busy` is set on write, not on read~~ | `src/core/update.zig` | FIXED: every read goes through `repos.query`, so the app knows it is loading, and a failed read is remembered with the screen it failed for (B-021, E-004) |
| D9 | ~~No screen-coverage test~~ | `src/tests.zig` | FIXED: a test builds every gated screen and every screen in the enum, and asserts the widget budget. It found four screens that could never render (D20) |
| D10 | CI smoke asserts only a non-blank canvas | `.github/workflows/ci.yml` | A blank or broken shell can still pass (G-018) |
| D11 | No `build.zig` / `build.zig.zon` in the app | app root | Fine while managed; blocks linking a C library until `native eject` |
| D12 | ~~`view_unbound` lists `pending_screen`, which is not a field~~ | `src/core/model.zig` | FIXED: the stale entry is gone and the salt state is listed |
| D13 | ~~Order insert omitted `orders.updated_at`, which is `NOT NULL` with no default~~ | `packages/ros-core/src/data/repos.zig` (`saveOrder`), `apps/admin/src/schema/0005_orders.sql` | FIXED: the insert writes `updated_at`; the integration test reads the order back (B-001) |
| D14 | ~~Login query ignores `employee.role`; the chosen role decides the session~~ | `src/core/update.zig` (`login_checked`), `src/data/repos.zig` (`login_sql`) | FIXED: the query asks for the session's role and the returned row is checked against it (B-002) |
| D15 | ~~Order table/customer ids were written as `0`, not `NULL`~~ | `packages/ros-core/src/core/update.zig` (`placeOrder`) | FIXED: absent ids are written as `NULL` (B-005) |
| D16 | ~~`decodeCompany` kept slices into page drain memory~~ | `src/data/repos.zig` (`decodeCompany`) | FIXED: every decoder copies text into the model's bump buffer, and a regression test overwrites the page after decoding to prove it (B-004) |
| D17 | ~~PIN is a fast SHA-256 over four digits, with no lockout or masking~~ | `src/data/auth.zig`, `src/screens/screen-login.native` | FIXED: bcrypt at 2^10 rounds, six digits, and the till stops after five wrong PINs. The PIN field is still typed in the clear: the SDK has no masked text field (B-027, [ADR-0016](../decisions/0016-what-a-pin-is.md)) |
| D18 | ~~Setup exists but has gaps (currency symbol field, no disabled submit)~~ | `apps/admin/src/screens/screen-session.native`, `packages/ros-core/src/core/update.zig` | FIXED: the setup carries the currency symbol and refuses an incomplete form; the admin owns the first run |
| D19 | ~~Status advance is not conditional; history can duplicate~~ | `src/core/update.zig` (`advance_order`), `src/data/repos.zig` (`setOrderStatus`) | FIXED: the move happens only from the status the order is in, and the history is written only when it did (B-008) |
| D20 | Four screens bound counts the model does not have (`customer_count`, `reservation_count`, `supplier_count`, `purchase_order_count`) | `src/screens/screen-customers.native`, `screen-reservations.native`, `screen-suppliers.native`, `screen-purchase-orders.native` | FIXED: those rail destinations could never render at all. The counts are model methods now |
| D21 | Three effect keys were used by two effects each (20, 21, 22) | `src/data/repos.zig` (the key table) | FIXED: a second live effect with the same key is REFUSED, so a company save could refuse an order write. Every key is used once, and a test says so |
| D22 | ~~The amounts are shown with two decimals whatever the currency is~~ | `packages/ros-core/src/core/model.zig` (`currency_divisor`), `apps/{admin,service,kiosk}/src/screens/*.native` | FIXED: the company carries its currency's decimals, the divisor comes from the model, and no amount divides by a hundred in the markup (B-013) |
| D23 | An order can be closed without a payment | `src/core/update.zig` (`nextStatus`) | The kitchen can advance a ticket straight to closed and the money is never taken (B-014) |
| D24 | ~~Back from home exposed the login screen; the stack froze at depth 32; cart/search/filters survived sign-out and role change~~ | `src/core/update.zig` (`resetSession`, `go`), `src/core/navigation.zig` (`Stack.push`) | FIXED: one session reset path, session gates are roots, pushing the current screen is a no-op and a full stack drops its oldest entry ([ADR-0015](../decisions/0015-session-scoped-navigation.md); B-009, B-010, B-011) |
| D25 | The PIN salt is per installation, not per employee | `src/data/auth.zig` | A database that is cracked gives up every PIN, not one ([ADR-0016](../decisions/0016-what-a-pin-is.md)) |
| D26 | A table with an order on it still said "Free" | `src/data/repos.zig` (`openOrderForTable`, `takePayment`) | FIXED: the table is occupied when the order opens and free when it is paid for, in the same transaction as each |
| D27 | The lists showed what the restaurant had finished with | `src/data/repos.zig` (the list queries) | FIXED: the categories, tables, customers and suppliers are filtered on `active` |
| D28 | The shell's import closure was full | `apps/admin/src/screens/` | FIXED: the screens of one area share one file, so the ceiling is no longer the reason the forms had to share |
| D29 | An empty pane and a working screen looked the same | `src/tests.zig` | FIXED: every screen has a landmark of its own, and the test finds it |
| D26 | The failed-PIN counter is per session | `src/core/model.zig` | A restart clears it, so a determined guesser restarts (B-027) |
| D27 | ~~A second instance could confirm its own salt after a no-op write~~ | `src/core/update.zig` (`config_saved`) | FIXED: a successful salt write is read back; the model adopts the stored salt and only confirms that one (B-028) |
| D30 | The first run was one form with six fields on it, and it asked for nothing an invoice needs | `src/screens/screen-session.native`, `src/core/update.zig` | FIXED: the first run is the walk-through the roadmap names - the company's record, then the owner and their PIN - and the restaurant is written whole or not at all |
| D31 | A manager could not reset a PIN without SQL, and could not remove somebody who had left | `src/screens/screen-people.native`, `src/data/repos.zig` | FIXED: the reset writes a new hash and the old PIN stops working; the removal keeps the row and takes the person off the team, and the last admin is protected |
| D32 | The owner could not see what the restaurant took, and could not count the stock | `src/screens/screen-overview.native`, `src/screens/screen-catalog.native` | FIXED: the payments, the report, the stock count and the dishes' stations are all screens the owner can write to |
| D33 | An owner could not write a customer or a modifier group | `src/screens/screen-floor.native`, `src/screens/screen-settings.native` | FIXED: both have a form, and a group with no name is refused |
| D34 | The database inspector counted the tables in a list the app kept, and the list could drift from the schema | `src/data/repos.zig` (`table_counts_sql`) | FIXED: a test compares the list with what SQLite says, so a table the schema adds and the inspector forgets is a failing test |
| D35 | The walk-through was mounted inside the shell, which is only drawn when somebody is signed in | `src/app.native` | FIXED: the walk-through is a session screen, mounted beside the setup rather than inside the shell. It was never on the pane at all, and the tests drove the model, not the view |
| D36 | A failed read left a screen saying there was nothing there | `src/app.native`, `src/core/update.zig` | FIXED: a failed read replaces the screen with the reason and a way to try again, and the failure belongs to the screen that asked for the data |

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
transition is conditional. What is left of the money is the price
parser and rounding (#66), an order that can close without a payment
(D23), and the PIN's strength (B-027). The full order is in the
[audit](../review/archive/2026-10-20-audit.md).

The compile-time `makeSalt` mismatch and the invisible-error-banner gap
were fixed earlier; they are no longer current defects. This status page
now defers detailed evidence to the [review set](../review/README.md).

## Test inventory

The inventory below is the pre-split core; the authoritative counts are
the suites themselves, and `scripts/verify-all.sh` runs all of them.

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
| The walk-through takes a restaurant from nothing to a POS | Setup |
| A fresh database asks to be set up | Setup |
| A manager can reset an employee's PIN | People |
| An employee who has left is not on the team and cannot sign in | People |
| The last admin cannot be removed | People |
| The payments screen shows the money the restaurant took | Money |
| The report says what the day came to | Money |
| The owner counts the stock, and the count says why it moved | Catalog |
| A count without a reason is refused | Catalog |
| The owner says which station cooks which dish | Kitchen |
| A dish with no station chosen is refused | Kitchen |
| The inspector counts every table the schema creates | Data |
| The inspector counts the rows that are really there | Data |
| The control centre shows the devices and the sync state | Data |
| The owner writes a customer | Customers |
| A customer with no name is refused | Customers |
| The owner writes a modifier group | Catalog |
| A modifier group with no name is refused | Catalog |
| The app says it is loading while a read is on its way | Shell |
| A read that fails is something the operator can try again | Shell |
| A failure belongs to the screen that asked, not to the pane | Shell |
| Every session screen renders, inside the widget budget | Markup |
| A fresh installation shows the walk-through, not the quick setup | Setup |

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
