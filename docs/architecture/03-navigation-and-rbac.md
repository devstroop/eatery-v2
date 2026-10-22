# Navigation, roles and access control

> **Status:** Implemented core; screen coverage is Partial.
> **Last verified:** 2026-10-21, by source review and the headless suite.
> **Source:** `src/core/navigation.zig`, `src/core/rbac.zig`,
> `src/core/update.zig` (`go`, `resetSession`), `src/app.native`,
> `src/screens/*.native`.

## There is no router

Navigation is model state. There is no route table, no URL, no deep link
and no transition. A "navigation" is:

1. a `Screen` enum value,
2. a push onto a fixed-capacity stack,
3. a `screen_index` that markup compares against.

This is a deliberate simplification for a kiosk-style app: the entry
point is always the role picker, and there is nothing external to link
into. See [ADR-0003](../decisions/0003-no-router-screen-enum-and-stack.md)
and, for the session/history boundary,
[ADR-0015](../decisions/0015-session-scoped-navigation.md).

## Roles

`Role` has four variants. One binary runs one role at a time.

| Role | Label | Sign-in | Home | Rail |
|---|---|---|---|---|
| `admin` | Admin | PIN | `admin_dashboard` | Overview, Sell, Orders, Floor, Catalog, People, System |
| `waiter` | Waiter | PIN | `waiter_tables` | Service |
| `kds` | Kitchen | Device (kiosk) | `kds_board` | Kitchen |
| `display` | Display | Device (kiosk) | `display_board` | Display |

Kiosk roles are signed in by device: choosing the role sets
`signed_in = true` and loads the shell data. There is no PIN, no lockout
and no operator identity for them. This is intentional for a wall-mounted
board, but it means a kiosk cannot attribute an action to a person. That
is an open question in [`plan/open-questions.md`](../plan/open-questions.md).

## The 53 screens

`Screen` is the product's destination vocabulary. It is **append-only**:
markup compares `screen_index` against fixed ordinals, so reordering the
enum silently breaks the shell.

| # | Screen | Section | In shell today |
| 0 | `role_picker` | — | Yes (top-level gate) |
| 1 | `login` | — | Yes (top-level gate) |
| 2 | `landing` | — | Yes (top-level gate) |
| 3 | `setup` | — | Yes (top-level gate) |
| 4 | `wizard` | — | Yes (top-level gate) |
| 5 | `create_company` | — | Yes (top-level gate) |
| 6 | `reset_pin` | — | Yes (ordinal gate) |
| 7 | `upgrade` | — | Yes (top-level gate) |
| 8 | `admin_dashboard` | overview | Yes (ordinal gate) |
| 9 | `control_center` | — | Yes (ordinal gate) |
| 10 | `pos` | sell | Yes (ordinal gate) |
| 11 | `pos_cart` | — | Yes (ordinal gate) |
| 12 | `order_confirmation` | — | Yes (ordinal gate) |
| 13 | `orders` | orders | Yes (ordinal gate) |
| 14 | `order_detail` | — | Yes (ordinal gate) |
| 15 | `payments` | — | Yes (ordinal gate) |
| 16 | `customers` | floor | Yes (ordinal gate) |
| 17 | `dining_tables` | — | Yes (ordinal gate) |
| 18 | `table_categories` | — | Yes (ordinal gate) |
| 19 | `floor_plan` | — | Yes (ordinal gate) |
| 20 | `reservations` | — | Yes (ordinal gate) |
| 21 | `kitchen_dishes` | catalog | Yes (ordinal gate) |
| 22 | `inventory_items` | — | Yes (ordinal gate) |
| 23 | `product_categories` | — | Yes (ordinal gate) |
| 24 | `suppliers` | — | Yes (ordinal gate) |
| 25 | `purchase_orders` | — | Yes (ordinal gate) |
| 26 | `employees` | people | Yes (ordinal gate) |
| 27 | `reports` | — | Yes (ordinal gate) |
| 28 | `settings` | system | Yes (ordinal gate) |
| 29 | `settings_company` | system | Yes (ordinal gate) |
| 30 | `settings_printers` | system | Yes (ordinal gate) |
| 31 | `settings_tax` | system | Yes (ordinal gate) |
| 32 | `settings_currency` | system | Yes (ordinal gate) |
| 33 | `settings_modifiers` | system | Yes (ordinal gate) |
| 34 | `settings_discounts` | system | Yes (ordinal gate) |
| 35 | `data_management` | system | Yes (ordinal gate) |
| 36 | `db_inspector` | system | Yes (ordinal gate) |
| 37 | `waiter_tables` | service | Yes (ordinal gate) |
| 38 | `waiter_menu` | — | Yes (ordinal gate) |
| 39 | `waiter_cart` | — | Yes (ordinal gate) |
| 40 | `waiter_orders` | — | Yes (ordinal gate) |
| 41 | `kds_board` | kitchen | Yes (ordinal gate) |
| 42 | `display_board` | display | Yes (ordinal gate) |
| 43 | `product_form` | — | Yes (ordinal gate) |
| 44 | `employee_form` | — | Yes (ordinal gate) |
| 45 | `tax_slab_form` | — | Yes (ordinal gate) |
| 46 | `discount_form` | — | Yes (ordinal gate) |
| 47 | `category_form` | — | Yes (ordinal gate) |
| 48 | `categories` | — | Yes (ordinal gate) |
| 49 | `stock_count` | — | Yes (ordinal gate) |
| 50 | `modifier_group_form` | — | Yes (ordinal gate) |
| 51 | `customer_form` | — | Yes (ordinal gate) |
| 52 | `table_category_form` | — | Yes (ordinal gate) |

"In shell" means `app.native` has an `<if test="{screen_index == N}">`
gate that mounts a template. Thirty-one screens render at all: the
confirmation, the two session gates (role picker and login), the setup
screen, and the twenty-eight shell gates. The remaining fourteen enum
values exist, and many are reachable through `open_section`, but no
template mounts. That is the single largest as-built gap in the app.

## Navigation stack

`Stack` is a fixed `[32]Screen` with `len`. It is the **session's
history**, not a log of every press (ADR-0015).

| Operation | Behaviour |
|---|---|
| `push` | No-op when the target is already on top; at depth 32 drops the oldest entry and appends the new one |
| `pop` | Returns null at a root; caller stays put |
| `resetTo` | Discards history and lands on one screen |
| `current` / `peek` | Top / one below top |

A full stack is not a refusal: navigation keeps working, and `go()`
cannot fail because of depth. Permission is still the only reason `go()`
refuses a destination. `go()` pushes and then updates `screen_index`, so
the stack and the index always agree.

Session transitions do not push the gate and then the home screen. They
call `resetSession`, which clears the session's state and calls
`resetTo(gate)`. The gate - or the role's home after a sign-in - is the
only history entry, so Back from the first screen of a session stays
there.

## Permission matrix

`rbac.allows(role, screen)` is a total pure function. Admin is a wildcard.

| Role | Allowed screens |
|---|---|
| `admin` | Every screen (43/43) |
| `waiter` | `role_picker`, `login`, `landing`, `waiter_tables`, `waiter_menu`, `waiter_cart`, `waiter_orders`, `orders`, `order_detail`, `order_confirmation`, `customers`, `reset_pin` |
| `kds` | `role_picker`, `login`, `kds_board`, `order_detail` |
| `display` | `role_picker`, `login`, `display_board`, `order_detail` |

Guarantees:

- **No role is ever locked out.** Every role can reach the role picker
  and the sign-in screen.
- **Kiosk roles exclude money surfaces.** KDS and display cannot open
  payments, settings or the POS.
- **The guard is in one place.** Every navigation arm calls `go`; there is
  no second path that writes `screen_index` except session setup and
  `go_back`.

Waiter can reach `customers` and `order_confirmation`, but neither has a
wired template. Waiter can also reach `reset_pin`, which has no template.
The permission matrix is broader than the rendered surface.

## Nav sections and the rail

`Screen.nav_section()` maps a screen to a rail section, or `null` when the
screen is reached by drilling in rather than by a tab.

| Section | Screens | Section opens |
|---|---|---|
| `overview` | dashboard, control center, reports | `admin_dashboard` |
| `sell` | pos, pos_cart, order confirmation | `pos` |
| `orders` | orders, order detail, payments | `orders` |
| `floor` | customers, dining tables, table categories, floor plan, reservations | `dining_tables` |
| `catalog` | kitchen dishes, inventory, product categories, suppliers, purchase orders | `product_categories` |
| `people` | employees | `employees` |
| `system` | settings tree, data management, db inspector | `settings` |
| `service` | waiter tables, menu, cart, orders | `waiter_tables` |
| `kitchen` | kds board | `kds_board` |
| `display` | display board | `display_board` |

The rail is `rbac.nav_sections(role)`, a file-scope constant table, so it
can never show a destination the role may not open. The markup dispatches
`open_section:{section.id}` — the `NavSection` ordinal, not a row index.
`update` checks that the ordinal belongs to the role's rail, then calls
`section_screen`. Keeping the payload and the lookup agreeing on what the
number means is a real bug class; see the note below.

Because the rail tables and role cards are file-scope constants, a
returned slice points at static memory, not a dead stack frame. Building
a table inside a function and returning `&.{ ... }` is a known crash
pattern in this SDK; see the comment in `rbac.zig`.

## Session transitions

```
role picker
   │ pick_role(admin|waiter)        pick_role(kds|display)
   ▼                                      ▼
 login (PIN)                          signed in by device
   │ submit_login                         │
   ▼                                      ▼
 signed in ──▶ home ──▶ loadAll ────────▶ home
   │                                      │
   ├── sign_out ──▶ login (session reset) │
   │                                      └── sign_out ──▶ role picker
   └── pick_role_again ──▶ role picker (session reset)
```

Every arrow that ends a session goes through `resetSession(model, gate)`
in `src/core/update.zig`. It clears the operator, cart, search, filters,
waiter table and lines, last sale, forms, errors and history, then lands
on `gate`. Device settings (theme, splits, station filter, salt, device
token) are kept. The reset is called from `pick_role`, a successful
`login_checked`, `sign_out`, `pick_role_again`, and setup's success and
failure paths.

### `open_section`: a fixed bug worth remembering

The rail used to dispatch the section ordinal, while `update` treated the
payload as an index into the role's rail array. Those coincide only for
admin (seven sections, ids 0–6). For waiter, KDS and display the ordinal
is 7–9 while the rail has one row, so the request was silently refused.

This is fixed: `update` now resolves the ordinal and checks membership in
the role's rail. The lesson stays in the docs because it is the kind of
bug a table-shaped UI invites: **the number a control sends and the number
the handler indexes must mean the same thing.**

## As-built navigation defects

The three p1 session/navigation defects - Back from home landing on the
sign-in screen, the stack freezing at 32 entries, and session state
surviving sign-out - are fixed. See
[ADR-0015](../decisions/0015-session-scoped-navigation.md).

1. ~~**Thirty-one templates, 45 screens.** The other fourteen screens
   are a blank content pane.~~ FIXED: every screen in the enum is
   mounted, every one of them renders, and every one of them has a
   landmark of its own.
2. **The waiter's rail leads to a working floor, but the waiter cannot
   pay for a table.** The floor, the menu, the cart and the order list
   render; the money does not. The waiter takes the order and the
   payment is taken at the till.
3. ~~**`pos_cart` is unused.** The POS uses an inline cart pane, not the
   `pos_cart` screen.~~ FIXED: the cart is ONE template, used both as
   the pane beside the menu and as the `pos_cart` screen, so the two
   cannot drift from each other.
4. **No responsive layout mode.** The target calls for a model-computed
   layout mode; the shell is a fixed split with a 200 px rail. The split
   fraction is resizable but the structure does not adapt.
5. **The stack is not surfaced.** `go_back` exists, but no visible
   affordance dispatches it. A kiosk cannot go back today.
6. **The error banner is implemented, but it is the only feedback path.**
   Denials and failures are visible now; there is no toast, inline field
   error or per-panel state. The shell now also says "Loading..." while
   a read is on its way, and a failed read replaces the screen with the
   reason and a way to try again.

## Target state

- Every `Screen` has a template or is explicitly removed from the enum.
- The shell renders a generic list/form template for the read-mostly
  entities, which covers most of the fourteen unmounted screens.
- A layout-mode method (wide/narrow) chooses rail vs tabs and table vs
  card list.
- Back is an explicit affordance (button or keyboard) on screens that can
  be drilled into.
- A screen-coverage test asserts that every allowed screen is either
  rendered or listed as intentionally unavailable. (The suite now builds
  every mounted screen; the "either rendered or unavailable" half is
  still to come.)

## Tests

- Every role can reach the role picker and login.
- A kiosk asking for `settings` stays on its board and sets an error.
- The permission matrix is walked for every role × every screen.
- Back returns to the previous screen, and Back at a session root stays
  put.
- A full history drops its oldest entry instead of freezing navigation.
- Pressing the current destination does not grow the history.
- Picking a role routes to the right gate.
- A role change and a sign-out clear the previous operator's cart,
  search, filters and identity.
- The shell's gates name the screens the enum says they do.
- Every gated screen builds a view and stays inside the widget budget.

The matrix test is currently weaker than its name: it asserts only the
two lock-out guarantees and re-asserts `allows` for permitted pairs. It
does not yet assert the exact allowed set per role. Tightening it is part
of [phase 1](../plan/phase-1-foundation.md).
