# Phase 3 — POS vertical slice

> **Status:** Partial
> **Estimate:** 7 engineer-days
> **Depends on:** Phase 2
> **Exit criterion:** an order is created end to end, read back from SQLite
> by a test, and the POS stays under the node budget.

## Goal

Prove every subsystem on the most important flow: a cashier takes an order.

## What exists

- POS template: search, category filters, product grid, inline cart,
  order-type selector, total, clear, place order.
- Cart model: add/increment, remove/decrement, totals in minor units,
  max 50 lines.
- `placeOrder` builds an order and lines; `saveOrder` writes them in one
  atomic `dbExec`.
- `order_placed` clears the cart and navigates to `order_confirmation`.
- Orders list renders non-voided orders; advance works.

## What is missing

| Item | Detail |
|---|---|
| Order confirmation screen | `order_confirmation` has no template; the flow ends on a blank pane |
| Modifiers | Schema exists; no sheet, no model, no write |
| Tax | `tax_bps` and `tax_minor` are written as 0 |
| Discounts | Not selectable, not written |
| Customer attach | No picker; `customer_id` is always 0 |
| Table attach | `dining_table_id` is always 0; POS cannot start from a table |
| Payment | No payment step; an order is placed, never paid |
| Order number | Clock-based; same-second collision |
| Read-back test | None |
| Node budget | No assertion; the product grid is not virtualized |
| Item notes | `notes` is always empty |
| Quantity edit | Only increment/decrement buttons; no direct entry |
| Void | No UI or write |
| Price override | Not supported |
| Keyboard flow | No shortcuts for a busy counter |

## Tasks

1. **Render `order_confirmation`** with the order number, total, and next
   actions (print, new order, view order).
2. **Add a modifier sheet** driven by `modifier_group` / `modifier`;
   persist `order_line_modifier`.
3. **Compute tax** from the product's tax slab and the company's
   inclusive flag; write `tax_bps` and `tax_minor`.
4. **Add discounts** (line or order), persist `order_discount`.
5. **Add table selection** so a dine-in order carries `dining_table_id`
   and a floor table can open the POS with that table.
6. **Add a payment step** (cash/card/UPI/…) and write `payment`.
7. **Replace clock ids** with a sequence or UUIDv7; keep a readable
   invoice number if required.
8. **Add a read-back test**: place, then query `orders` + `order_line` +
   `payment` and assert the totals and rows.
9. **Assert the node budget** for the POS with a 100-product menu; add
   virtualization if needed.
10. **Add line notes and a quantity entry** (text field or stepper).
11. **Add a void path** with a reason and a `void_log_entry`.

## Exit criterion

- A test can seed a menu, place an order with a modifier, compute tax,
  apply a discount, take a payment, and read the whole graph back.
- The POS renders a 100-item menu and a 20-line cart without exceeding
  the node budget.
- Two orders placed in the same second both succeed.
- The cashier can complete the flow with the keyboard only.

## Risks

| Risk | Mitigation |
|---|---|
| Tax rules differ by jurisdiction | Make the rule explicit in the calculation module; test each mode |
| Modifier UI blows the node budget | Sheet, not inline expansion; virtualize the product grid |
| Clock ids bite in production | Fix in Phase 2, before the slice ships |
| Payment scope creep (splits, tips, refunds) | Decide the v1 payment scope explicitly |
| The confirmation screen becomes a second cart | Keep it a receipt summary, not an editor |

## Unknowns

- What is the tax model: per product, per category, inclusive/exclusive,
  multiple slabs?
- Are discounts percentage, fixed, happy-hour, or coupon-based?
- Are split payments and tips in scope for v1?
- Is a payment required to advance an order?
- What does the confirmed order show to the customer?

See [`../open-questions.md`](open-questions.md).
