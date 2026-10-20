# Navigation, roles and access control

> **Status:** Implemented core; screen coverage is Partial.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/core/navigation.zig`, `src/core/rbac.zig`,
> `src/core/update.zig` (`go`), `src/app.native`, `src/screens/*.native`.

## There is no router

Navigation is model state. There is no route table, no URL, no deep link
and no transition. A "navigation" is:

1. a `Screen` enum value,
2. a push onto a fixed-capacity stack,
3. a `screen_index` that markup compares against.

This is a deliberate simplification for a kiosk-style app: the entry
point is always the role picker, and there is nothing external to link
into. See [ADR-0003](../decisions/0003-no-router-screen-enum-and-stack.md).

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

## The 43 screens

`Screen` is the product's destination vocabulary. It is **append-only**:
markup compares `screen_index` against fixed ordinals, so reordering the
enum silently breaks the shell.

| # | Screen | Section | In shell today |
|---|---|---|---|
| 0 | `role_picker` | — | Yes (top-level gate) |
| 1 | `login` | — | Yes (top-level gate) |
| 2 | `landing` | — | No |
| 3 | `setup` | — | No |
| 4 | `wizard` | — | No |
| 5 | `create_company` | — | No |
| 6 | `reset_pin` | — | No |
| 7 | `upgrade` | — | No |
| 8 | `admin_dashboard` | overview | Yes |
| 9 | `control_center` | overview | No |
| 10 | `pos` | sell | Yes |
| 11 | `pos_cart` | sell | No |
| 12 | `order_confirmation` | sell | No |
| 13 | `orders` | orders | Yes |
| 14 | `order_detail` | orders | No |
| 15 | `payments` | orders | No |
| 16 | `customers` | floor | No |
| 17 | `dining_tables` | floor | Yes |
| 18 | `table_categories` | floor | No |
| 19 | `floor_plan` | floor | No |
| 20 | `reservations` | floor | No |
| 21 | `kitchen_dishes` | catalog | No |
| 22 | `inventory_items` | catalog | No |
| 23 | `product_categories` | catalog | No |
| 24 | `suppliers` | catalog | No |
| 25 | `purchase_orders` | catalog | No |
| 26 | `employees` | people | No |
| 27 | `reports` | overview | No |
| 28 | `settings` | system | No |
| 29 | `settings_company` | system | No |
| 30 | `settings_printers` | system | No |
| 31 | `settings_tax` | system | No |
| 32 | `settings_currency` | system | No |
| 33 | `settings_modifiers` | system | No |
| 34 | `settings_discounts` | system | No |
| 35 | `data_management` | system | No |
| 36 | `db_inspector` | system | No |
| 37 | `waiter_tables` | service | No |
| 38 | `waiter_menu` | service | No |
| 39 | `waiter_cart` | service | No |
| 40 | `waiter_orders` | service | No |
| 41 | `kds_board` | kitchen | Yes |
| 42 | `display_board` | display | No |

"In shell" means `app.native` has an `<if test="{screen_index == N}">`
gate that mounts a template. Nine screens render at all: setup, the confirmation plus the two session
gates (role picker and login) plus the five shell gates. The remaining 35
enum values exist, and many are reachable through `open_section`, but no
template mounts. That is the single largest as-built gap in the app.

## Navigation stack

`Stack` is a fixed `[32]Screen` with `len`.

| Operation | Behaviour |
|---|---|
| `push` | Refuses at depth 32 and returns false; caller keeps the current screen rather than losing history |
| `pop` | Returns null at a root; caller stays put |
| `resetTo` | Discards history and lands on one screen |
| `current` / `peek` | Top / one below top |

`go()` pushes first and only then updates `screen_index`, so a refused
push cannot leave the index and stack disagreeing.

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
   │
   ├── sign_out  ──▶ login (history reset)
   └── pick_role_again ──▶ role picker (history reset)
```

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

1. **Nine templates, 43 screens.** Setup, role picker, login, Dashboard, POS,
   Orders, Dining tables and KDS render. The other 36 screens are a blank
   content pane.
2. **The waiter shell is effectively broken.** Waiter signs in, lands on
   `waiter_tables`, and no template mounts. The rail's only entry is
   Service, which also lands on `waiter_tables`.
3. **Display signs in to a blank board.** `display_board` has no
   template, so a display device shows only the shell chrome.
4. **Admin rail dead ends.** Catalog opens `product_categories`, People
   opens `employees`, System opens `settings`; none are rendered.
5. **`pos_cart` is unused.** The POS uses an inline cart pane, not the
   `pos_cart` screen.
6. **`order_confirmation` is a navigation target without a template.**
   After an order is placed, `update` goes there and the content is
   blank.
7. **No responsive layout mode.** The target calls for a model-computed
   layout mode; the shell is a fixed split with a 200 px rail. The split
   fraction is resizable but the structure does not adapt.
8. **The stack is not surfaced.** `go_back` exists, but no visible
   affordance dispatches it. A kiosk cannot go back today.
9. **The error banner is implemented, but it is the only feedback path.**
   Denials and failures are visible now; there is no toast, inline field
   error or per-panel state.

## Target state

- Every `Screen` has a template or is explicitly removed from the enum.
- The shell renders a generic list/form template for the read-mostly
  entities, which covers most of the 36 unmounted screens.
- Waiter gets its four templates; display gets its board.
- A layout-mode method (wide/narrow) chooses rail vs tabs and table vs
  card list.
- Back is an explicit affordance (button or keyboard) on screens that can
  be drilled into.
- A screen-coverage test asserts that every allowed screen is either
  rendered or listed as intentionally unavailable.

## Tests

- Every role can reach the role picker and login.
- A kiosk asking for `settings` stays on its board and sets an error.
- The permission matrix is walked for every role × every screen.
- Back returns to the previous screen.
- Picking a role routes to the right gate.

The matrix test is currently weaker than its name: it asserts only the
two lock-out guarantees and re-asserts `allows` for permitted pairs. It
does not yet assert the exact allowed set per role. Tightening it is part
of [phase 1](../plan/phase-1-foundation.md).
