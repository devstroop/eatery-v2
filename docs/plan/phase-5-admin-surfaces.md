# Phase 5 — Admin surfaces

> **Status:** Planned (dashboard, orders and floor board are partial)
> **Estimate:** 10 engineer-days
> **Depends on:** Phase 2, Phase 3
> **Exit criterion:** every remaining `Screen` has a native template and a
> screenshot, or is explicitly removed.

## Goal

The back office: everything an owner needs to set up and run the
restaurant.

## What exists

- Dashboard: open orders, busy tables, menu size, table count, recent
  orders, shortcuts.
- Orders list + advance.
- Dining table board.
- Shell rail with Overview, Sell, Orders, Floor, Catalog, People, System.
- 43-table schema covering catalog, floor, customers, inventory, ops,
  compliance and printing.

## What is missing

| Group | Screens | State |
|---|---|---|
| Setup | `setup`, `wizard`, `create_company`, `reset_pin`, `upgrade` | No templates, no data path |
| Dashboard extras | `control_center`, `reports` | No templates |
| Orders | `order_detail`, `payments` | No templates |
| Floor | `customers`, `table_categories`, `floor_plan`, `reservations` | No templates |
| Catalog | `kitchen_dishes`, `inventory_items`, `product_categories`, `suppliers`, `purchase_orders` | No templates, no writes |
| People | `employees` | No template, no writes |
| System | `settings` tree (company, printers, tax, currency, modifiers, discounts), `data_management`, `db_inspector` | No templates |
| Waiter | four screens | Phase 4 |

## The generic list/form strategy

The port plan's strongest leverage: 26 routes for eight read-mostly
entities collapse into one list template and one form template
parameterised by an entity descriptor.

Recommendation (from the port plan, retained here):

- **Generic** for customers, product categories, dining tables, table
  categories, employees, suppliers, reservations, tax slabs, discounts.
- **Bespoke** for products, payments, printers, modifiers and inventory
  (real behaviour), plus POS, floor plan, KDS, display, dashboard and the
  wizard.

The cost is a runtime-typed field descriptor in Zig instead of explicit
forms. The benefit is 2 templates instead of ~26.

## Tasks

1. **Setup first.** Without `create_company` and an admin employee, a
   fresh install cannot log in. This blocks every demo on a clean machine.
2. **Build the generic list + form templates** and the entity descriptor.
3. **Wire the generic entities** (read and write) and add them to the rail
   sections.
4. **Build the settings tree** and its sub-pages; start with company,
   tax, currency, modifiers and discounts.
5. **Build order detail** with the status timeline and payments.
6. **Build the payment screens** (list/add/view) on top of Phase 2's write
   path.
7. **Build the back-office catalog** (products, categories, inventory,
   suppliers, purchase orders) with image handling or a documented
   placeholder.
8. **Build reports** with line/bar/stacked bar charts; decide the metrics.
9. **Build data management** (CSV import/export, backup) and the DB
   inspector.
10. **Add screenshots and a render test per screen.**

## Exit criterion

- Every `Screen` value is either rendered or removed from the enum.
- The admin rail has no dead ends.
- A fresh install can create a company, an admin, tables and a menu.
- Every list/form screen has a render test and a repository test.
- Reports render from real aggregate queries.

## Risks

| Risk | Mitigation |
|---|---|
| The generic form becomes a mini-framework | Keep the descriptor small; fall back to bespoke for real behaviour |
| 10 days is optimistic for ~30 screens | Reuse aggressively; accept read-only v1 screens |
| Reports need aggregates that do not exist | Design the queries in Phase 2 |
| Image upload has no file picker | Use a known app directory or defer with a placeholder |
| Setup is skipped because demos use seeded data | Make setup the first task, not the last |

## Unknowns

- Which admin screens are required for the first release?
- Does image upload need a real file picker?
- Which report metrics matter (sales, tax, item mix, shift, voids)?
- Is multi-company ever needed?
- Does the DB inspector ship to end users or only to support?

See [`../open-questions.md`](open-questions.md).
