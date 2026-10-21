# Screen backlog

**Status:** Living document. 45 screens, tracked one by one.
**Source of truth:** `apps/eatery/src/core/navigation.zig` (the `Screen`
enum), `apps/eatery/src/app.native` (the mount gates) and
`apps/eatery/src/screens/` (the templates).

## How to read this page

**Route-ish identity.** v2 has no router, so there is no URL. The third
column is a documentation slug, built from the screen's nav section
(`Screen.nav_section()` in `apps/eatery/src/core/navigation.zig`) and the
screen name in kebab-case. A screen with no nav section — the onboarding
and session screens, which are reached by drilling in rather than by a tab
— uses `session/` instead. The slug is for talking about a screen; the
runtime never sees it.

**Ordinal.** `Screen.index()` is `@intFromEnum`, so the declaration order in
the enum *is* the number the markup compares against. `src/app.native`
gates on literal ordinals, which is why the enum is append-only. The
ordinal is in this table so nobody has to count by hand.

**Status.**

| Status | Meaning |
|---|---|
| **Done** | A template exists, it is mounted in `src/app.native`, and a headless test builds its tree. |
| **Foundation** | The enum variant, the title, the nav section and the permission grant exist, and the data the screen needs already has a read path in `apps/eatery/src/data/repos.zig`. The remaining work is the template. |
| **Planned** | The enum variant exists and the schema table exists, but the data path or the screen itself has not been written. |

**Roles.** The role that opens the screen, from `rbac.allows` in
`apps/eatery/src/core/rbac.zig`. Admin may open all 43.

**Platform elements.** The SDK elements the template will need, from the
grammar the seven existing templates use. Colour and radius attributes take
token names as literals, so dynamic status colouring is not available and a
status is a `badge`.

**Data source.** The tables the screen reads and writes.

---

## The nine templates that exist

| Template | Mounted at | Ordinal | Screen | Test |
|---|---|---|---|---|
| `src/screens/screen-setup.native` | `show_setup` gate | 3 | `setup` | `expectByText(tree.root, .text, "Set up your restaurant")` |
| `src/screens/screen-role-picker.native` | `show_role_picker` gate | 0 | `role_picker` | `expectByText(tree.root, .text, "Eatery")` |
| `src/screens/screen-login.native` | `show_login` gate | 1 | `login` | `expectByText(tree.root, .text, "Sign in")` |
| `src/screens/screen-dashboard.native` | `screen_index == 8` | 8 | `admin_dashboard` | none |
| `src/screens/screen-pos.native` | `screen_index == 10` | 10 | `pos` | `expectByText(tree.root, .text, "Paneer Tikka")` |
| `src/screens/screen-orders.native` | `screen_index == 13` | 13 | `orders` | none |
| `src/screens/screen-tables.native` | `screen_index == 17` | 17 | `dining_tables` | none |
| `src/screens/screen-order-confirmation.native` | `screen_index == 12` | 12 | `order_confirmation` | `expectByText(tree.root, .text, "Order 1700000000")` |
| `src/screens/screen-kitchen.native` | `screen_index == 41` | 41 | `kds_board` | none |

All nine are listed in `apps/eatery/src/app_sources.zig` and imported at
the top of `src/app.native`. A template that is not in both places does
not exist: the import closure is embedded, and a missing entry fails
loudly at the import site.

Six of the nine are mounted in the shell's `<if>` gates. The other three —
setup, the role picker and the login screen — are mounted by top-level
session gates, so they are on screen without a shell ordinal.

---

## Onboarding and session

No nav section. These are reached by drilling in, not by a tab.

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `setup` | 3 | `onboarding/setup` | first run | Partial (working tree; B-031/B-032) | `column`, `card`, `text-field`, `text`, `button` | `company`, `employee`, `product`, `dining_table` (one `setupCompany` transaction) |
| `role_picker` | 0 | `session/role-picker` | all four | Done | `column`, `card`, `text`, `badge`, `button` | none — the four role cards are a file-scope constant in `core/navigation.zig` |
| `login` | 1 | `session/login` | admin, waiter | Done | `column`, `card`, `text-field`, `text`, `button` | `employee` (the check is the SQL in `core/update.zig`), `app_config` (the PIN salt) |
| `landing` | 2 | `session/landing` | all four | Planned | `column`, `text`, `button` | `company`, `app_config` |
| `setup` | 3 | `session/setup` | admin | Planned | `column`, `row`, `text-field`, `button` | `app_config`, `company` |
| `wizard` | 4 | `session/wizard` | admin | Planned | `column`, `row`, `text-field`, `select`, `button` | `company`, `employee`, `dining_table_category`, `dining_table`, `product_category`, `product` |
| `create_company` | 5 | `session/create-company` | admin | Planned | `column`, `text-field`, `select`, `dropdown-menu`, `button` | `company`, `currency` |
| `reset_pin` | 6 | `session/reset-pin` | admin, waiter | Planned | `column`, `text-field`, `button`, `alert` | `employee`, `app_config` |
| `upgrade` | 7 | `session/upgrade` | admin | Planned | `column`, `text`, `button` | `subscription` |

## Admin

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `admin_dashboard` | 8 | `overview/dashboard` | admin | Done | `column`, `row`, `card`, `text`, `badge`, `button` | `orders`, `dining_table`, `product`, `company` |
| `control_center` | 9 | `overview/control-center` | admin | Planned | `column`, `row`, `card`, `text`, `badge`, `button` | `app_config`, `device`, `sync_state`, `orders` |

## Sell

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `pos` | 10 | `sell/pos` | admin | Done | `split`, `column`, `row`, `search-field`, `toggle-button`, `scroll`, `grid`, `card`, `text`, `button` | `product`, `product_category` |
| `pos_cart` | 11 | `sell/cart` | admin | Planned | `column`, `row`, `card`, `text`, `text-field`, `badge`, `button` | `product`, `modifier_group`, `modifier`, `discount` |
| `order_confirmation` | 12 | `sell/order-confirmation` | admin | Partial | `column`, `row`, `card`, `text`, `badge`, `button` | `orders`, `order_line`, `payment` |

## Orders and money

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `orders` | 13 | `orders/orders` | admin, waiter | Done | `column`, `row`, `card`, `text`, `badge`, `button`, `scroll` | `orders` |
| `order_detail` | 14 | `orders/order-detail` | admin, waiter, kds, display | Foundation | `column`, `drawer`, `timeline`, `timeline-item`, `table`, `table-row`, `table-cell`, `badge`, `text`, `button` | `orders`, `order_line`, `order_line_modifier`, `order_status_history`, `payment` |
| `payments` | 15 | `orders/payments` | admin | Planned | `grid`, `button`, `text-field`, `badge`, `dialog` | `payment`, `orders`, `order_discount` |

## Floor

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `customers` | 16 | `floor/customers` | admin, waiter | Foundation | `search-field`, `list`, `list-item`, `card`, `text`, `button`, `drawer` | `customer`, `customer_loyalty`, `loyalty_transaction` |
| `dining_tables` | 17 | `floor/dining-tables` | admin | Done | `scroll`, `grid`, `card`, `text`, `badge` | `dining_table`, `dining_table_category` |
| `table_categories` | 18 | `floor/table-categories` | admin | Planned | `list`, `list-item`, `text-field`, `button` | `dining_table_category` |
| `floor_plan` | 19 | `floor/floor-plan` | admin | Planned | `grid`, `card`, `text`, `badge` — a grid of positioned cells, not custom paint | `dining_table`, `dining_table_category` |
| `reservations` | 20 | `floor/reservations` | admin | Planned | `list`, `card`, `text-field`, `badge`, `button` | `reservation`, `customer`, `dining_table` |

## Catalogue

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `kitchen_dishes` | 21 | `catalog/kitchen-dishes` | admin | Planned | `list`, `card`, `text-field`, `select`, `button` | `product`, `kds_station`, `product_station` |
| `inventory_items` | 22 | `catalog/inventory-items` | admin | Planned | `list`, `card`, `text-field`, `badge`, `button` | `product`, `stock_adjustment` |
| `product_categories` | 23 | `catalog/product-categories` | admin | Foundation | `list`, `list-item`, `text-field`, `button` | `product_category`, `product` |
| `suppliers` | 24 | `catalog/suppliers` | admin | Planned | `list`, `card`, `text-field`, `button` | `supplier` |
| `purchase_orders` | 25 | `catalog/purchase-orders` | admin | Planned | `list`, `card`, `table`, `table-row`, `table-cell`, `button` | `purchase_order`, `purchase_order_item`, `supplier` |

## Back office

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `employees` | 26 | `people/employees` | admin | Foundation | `list`, `card`, `text-field`, `toggle`, `button` | `employee` |
| `reports` | 27 | `overview/reports` | admin | Planned | `chart`, `series`, `code`, `table`, `select`, `text`, `button` | `compliance_report`, `orders`, `payment`, `expense`, `shift` |
| `settings` | 28 | `system/settings` | admin | Planned | `tree`, `treeitem`, `row`, `text`, `toggle`, `switch` | `app_config` |
| `settings_company` | 29 | `system/settings-company` | admin | Planned | `column`, `text-field`, `button` | `company` |
| `settings_printers` | 30 | `system/settings-printers` | admin | Planned | `list`, `card`, `select`, `text-field`, `toggle`, `button` | `printer`, `auto_print` |
| `settings_tax` | 31 | `system/settings-tax` | admin | Planned | `list`, `card`, `text-field`, `button` | `tax_slab` |
| `settings_currency` | 32 | `system/settings-currency` | admin | Planned | `select`, `dropdown-menu`, `menu-item`, `text-field`, `button` | `currency`, `company` |
| `settings_modifiers` | 33 | `system/settings-modifiers` | admin | Planned | `list`, `card`, `text-field`, `button` | `modifier_group`, `modifier`, `product_modifier` |
| `settings_discounts` | 34 | `system/settings-disciscounts` | admin | Planned | `list`, `card`, `text-field`, `button` | `discount` |
| `data_management` | 35 | `system/data-management` | admin | Planned | `column`, `row`, `card`, `button`, `alert` | `app_config`, `company` |
| `db_inspector` | 36 | `system/db-inspector` | admin | Planned | `code`, `table`, `table-row`, `table-cell`, `select`, `search-field` | every table |

## Waiter

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `waiter_tables` | 37 | `service/waiter-tables` | waiter | Foundation | `grid`, `card`, `text`, `badge`, `button` | `dining_table`, `dining_table_category`, `orders` |
| `waiter_menu` | 38 | `service/waiter-menu` | waiter | Foundation | `search-field`, `scroll`, `grid`, `card`, `text`, `button` | `product`, `product_category` |
| `waiter_cart` | 39 | `service/waiter-cart` | waiter | Foundation | `column`, `row`, `card`, `text`, `badge`, `button` | `product`, `modifier_group`, `modifier` |
| `waiter_orders` | 40 | `service/waiter-orders` | waiter | Foundation | `list`, `card`, `text`, `badge`, `button` | `orders`, `order_line` |

## Kiosk

| Screen | Ord | Route-ish id | Role | Status | Platform elements | Data source |
|---|---|---|---|---|---|---|
| `kds_board` | 41 | `kitchen/kds-board` | kds | Done | `scroll`, `grid`, `card`, `text`, `badge`, `button` | `orders`, `order_line`, `kds_station`, `product_station` |
| `display_board` | 42 | `display/display-board` | display | Foundation | `column`, `row`, `card`, `text`, `badge` | `orders`, `order_line` |

---

## Scoreboard

| Measure | Count |
|---|---|
| Screens named in the `Screen` enum | 43 |
| Templates that exist | 7 |
| Templates mounted in the shell | 5, plus the two session gates |
| **Done** | 7 |
| **Foundation** | 10 |
| **Planned** | 26 |
| Screens with a read path in `repos.zig` today | 9 read paths: products, categories, tables, employees, customers, orders, order lines, config, company |

## Where the gaps are

| Gap | Where | Phase |
|---|---|---|
| Three admin rail entries open an empty pane: Catalog (`product_categories`), People (`employees`), System (`settings`) | `src/core/rbac.zig` `section_screen` | 2 |
| The waiter signs in and lands on a blank content pane | `waiter_tables` | 3 |
| The display role lands on a blank content pane | `display_board` | 3 |
| The customer dataset is decoded but never loaded — `loadAll` omits it | `loadAll` in `data/repos.zig` | 1 |
| `order_status_history` is written but never read | `order_detail` | 1 |
| The tax and discount paths exist in the schema but the order write hard-codes both to zero | `placeOrder` in `core/update.zig` | 1 |
| The KDS board does not refresh when another window advances a ticket, because every read is a one-shot `dbQuery` | `data/repos.zig` | 1 |

---

## Definition of done — every screen

A screen is done when all of these are true. None of them is optional and
none of them is "later".

- [ ] The `Screen` variant exists in `apps/eatery/src/core/navigation.zig`
      with a `title` and a `nav_section` (or an explicit `null`), and it was
      **appended** — no variant was inserted, reordered or removed.
- [ ] The ordinal was read off the enum, not counted by hand, and it is
      recorded in this table.
- [ ] `rbac.allows` in `apps/eatery/src/core/rbac.zig` grants the screen to
      every role that may open it and denies it to every role that may not.
      The matrix test still walks every pair.
- [ ] If it is a rail destination, it appears in the right role's rail
      table in `src/core/rbac.zig` **and** in `rbac.section_screen`.
- [ ] The data it needs has a named SQL constant, a loader and a decoder in
      `apps/eatery/src/data/repos.zig`, each with its own `key_*` effect
      constant, and every write is one `dbExec` with all of its statements.
- [ ] Every value the model keeps is copied into a bump buffer; nothing
      holds a slice into the page bytes.
- [ ] A template exists at `apps/eatery/src/screens/screen-<name>.native`
      with exactly one `<template name="screen-<name>">` and exactly one
      element child.
- [ ] The file is imported in `src/app.native` **and** listed in
      `apps/eatery/src/app_sources.zig`.
- [ ] The shell has an `<if test="{screen_index == N}">` gate for it, and
      the gate is inside the `show_shell` block.
- [ ] Every binding in the template is a model field, a zero-argument
      method inside the `Model` struct body, or a field of a `for`
      variable. No file-scope helper next to the struct.
- [ ] Every conditional is an `<if>` with an explicit boolean predicate
      method. There is no `else` and no else-if chain.
- [ ] Every message payload is a binding path. A constant has its own
      message.
- [ ] Every colour and radius is a token name written as a literal, in
      both `light()` and `dark()` in `apps/eatery/src/core/theme.zig` if the
      token is new.
- [ ] Every `card`, `panel`, `stack`, `dialog`, `drawer`, `sheet`, `alert`
      and `bubble` puts its children in a `column` or a `row`.
- [ ] Every row uses one control size register.
- [ ] Every interactive control has text content, `text=` or `label=`;
      icon-only controls carry a `label`.
- [ ] Every `for` names a `key` field that exists on the row type.
- [ ] The mounted node count is inside the budget — `native automate
      snapshot` reports `widget_nodes=N/1024` and N is comfortably under
      1024. An unbounded collection is `virtualized` or bounded in the
      model.
- [ ] A headless test builds the tree for the screen and finds a landmark
      text in it.
- [ ] The screen's status in this table is **Done**, and the count in the
      scoreboard is updated.
- [ ] `cd apps/eatery && native check` is clean and `native test` is green.
