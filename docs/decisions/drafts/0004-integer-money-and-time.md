# ADR-0004: Money is i64 minor units; time is epoch milliseconds

**Status:** Accepted (2026-10)
**Applies to:** `apps/ros/src/schema/**`, `apps/ros/src/domain/models.zig`,
`apps/ros/src/core/model.zig`
**Related:** [`architecture/data-model.md`](../../architecture/data-model.md)

## Context

v1 kept money in floating-point columns. `../eatery/assets/db/schema.sql`
declares `subTotal REAL NOT NULL`, `discountTotal REAL NOT NULL`,
`taxTotal REAL NOT NULL`, `grandTotal REAL NOT NULL`, `roundOff REAL NOT
NULL` on `orders`; `amount REAL NOT NULL` on `payment`; `rate REAL NOT
NULL` on `tax_slab`. Binary floating point cannot represent most decimal
fractions exactly, so a restaurant that adds a thousand line items in floats
ends the day with a total that is off by a fraction of a currency unit. The
discrepancy has to be reconciled by hand against the drawer, and the report
cannot be reproduced from the stored numbers alone — which is what
`src/schema/0008_compliance.sql` says an X/Z report has to be able to do.

v1 also mixed time shapes: `orders.createdAt INTEGER` and `orders.updatedAt
INTEGER` alongside `payment.date INTEGER`, while other records carried
formatted strings. Sorting then depended on every writer agreeing on the
format.

Restaurant OS has one answer for both. Every money column is an `INTEGER` count of the
smallest unit of the currency; every rate is an integer number of basis
points; every timestamp is an `INTEGER` count of milliseconds since the Unix
epoch, in UTC.

## Decision

**Money is `i64` minor units. Time is `i64` epoch milliseconds, UTC.**

In the schema the convention is visible in the column names:
`price_minor`, `subtotal_minor`, `tax_minor`, `total_minor`,
`discount_minor`, `unit_price_minor`, `amount_minor`, `price_delta_minor`,
`opening_cash_minor`, `closing_cash_minor`, `expected_cash_minor`,
`gross_minor`, `net_minor`. Percentages are basis points, so `5%` is `500`
and `100%` is `10000`: `rate_bps INTEGER NOT NULL DEFAULT 0 CHECK (rate_bps
BETWEEN 0 AND 10000)` on `tax_slab` and `percent_bps` on `discount`.

The scale is data, not code. `currency.minor_units` declares it —
`INTEGER NOT NULL DEFAULT 2 CHECK (minor_units BETWEEN 0 AND 4)` — so a
currency with 0 or 3 decimal places is a row, not a build.

Two corollaries are enforced by the schema rather than by convention. A
negative price is a data error, not a discount: `price_minor INTEGER NOT
NULL DEFAULT 0 CHECK (price_minor >= 0)`, and discounts live in their own
table (`discount`, `order_discount`). And a price change tomorrow cannot
rewrite yesterday's bill, because `order_line` freezes `product_name` and
`unit_price_minor` at the moment of the sale.

Not every time-like column is an epoch. `business_hours.opens_min` and
`closes_min` are minutes from midnight, and `holiday_hours.holiday_date` is
a `TEXT` calendar date. Those are recurring wall-clock quantities, not
instants, and storing them as epochs would be wrong.

The Zig side mirrors the schema exactly. `src/domain/models.zig` declares
`price_minor: i64` on `Product` and `CartLine`, `subtotal_minor`,
`tax_minor`, `discount_minor` and `total_minor` on `Order`.
`src/core/model.zig` computes `cart_total_minor(model: *const Model) i64`
as the sum of `line.price_minor * line.qty` — an integer sum of integers.
The only float in the money path is in the markup expression
`fixed(product.price_minor / 100, 2)`, which is presentation and never
storage.

## Consequences

- A day's takings can be reconstructed exactly from the stored integers.
  The compliance report in `src/schema/0008_compliance.sql` records
  `gross_minor`, `discount_minor`, `tax_minor` and `net_minor` as integers
  and `payment_split_json` as the per-mode split.
- The rule is a test, not a comment: `apps/ros/src/tests.zig` has
  "money stays integer: two hundred and fifty cents is never a float".
- **Cost:** every column name carries the unit. A reader of the schema has
  to know that "minor" means the smallest unit of the company's currency,
  and a developer has to remember the suffix on every new column.
- **Cost:** the currency scale is not yet honoured in the view. The
  templates format money as `fixed(x / 100, 2)`, which hard-codes a
  two-decimal currency. A currency with `minor_units = 0` or `3` needs a
  model method that formats from `currency.minor_units`, and that method
  does not exist yet. It is owed by Phase 2.
- **Cost:** mixing currencies is impossible by construction. One company
  per database, one `currency_code` on the company row, and `currency` is a
  reference table for a picker rather than a multi-currency ledger. v1 had
  a per-company currency plus a `currency` table and a multi-company
  story that was never used.
- **Cost:** the arithmetic crosses a boundary at the display edge. Every
  screen that shows a price divides by 100 and formats. A single mistake
  produces a visibly wrong total, so the money format needs one model
  method and one markup expression, not one per screen.
- **Cost:** epoch milliseconds is not human-readable in a raw database
  dump. `0001..0010_*.sql` columns read as large integers, and every
  display path has to format them; the `date`, `time` and `datetime`
  functions in the markup grammar are the intended tools.
- **Cost:** epoch milliseconds assumes a correct wall clock. A device whose
  clock is wrong writes wrong timestamps, and the ordering of `orders` by
  `placed_at` follows that clock. The logical clock in `op_log` exists for
  the sync conflict rule, not for the sale timeline.
- **Cost:** the order id and order number are currently derived from the
  wall clock in `src/core/update.zig` (`id` = milliseconds, `order_no` =
  seconds, with `order_no` `UNIQUE`), so two orders in the same second
  collide. That is a separate defect, tracked by the existing ADR on
  clock-based order ids, but it is a direct consequence of choosing a
  clock-shaped identifier.
- **Cost:** basis points are a second unit to hold in the head. A tax slab
  is `500`, not `5`. The `CHECK` bounds it, and the name says what it is,
  but every rate the UI edits has to convert.

## Alternatives considered

- **Keep `REAL` money, as v1 did.** Loses because binary floats cannot
  represent most decimal fractions exactly, so the day's total cannot be
  reconstructed from the stored values and the discrepancy has to be
  reconciled by hand. It is the single most expensive defect v1 carried.
- **Store money as an integer count of the major unit (rupees, dollars).**
  Loses because it throws away the sub-unit: 10% tax on 199.50 is not an
  integer number of major units, so the tax calculation needs a float
  again.
- **Store money as a `NUMERIC` or fixed-point decimal.** Loses because
  SQLite has no fixed-point type — `NUMERIC` has `REAL` affinity, so it
  stores a float. A `TEXT` column holding "199.50" moves all arithmetic
  into the application and turns every comparison into a string comparison.
- **Store money as a float but round at the display edge.** Loses for the
  same reason as the first option, only with the rounding moved: the stored
  values still do not add up, so the report is still not reproducible.
- **Store time as ISO-8601 text.** Loses because sorting only works if
  every writer agrees on the format and the timezone suffix. A mix of
  `2026-10-20` and `2026-10-20T14:03:00Z` sorts wrongly, and `ORDER BY
  placed_at DESC` needs no per-column knowledge to be correct.
- **Store time as epoch seconds.** Loses because the kitchen board shows
  elapsed minutes and the receipt prints a second; milliseconds cost one
  more byte and remove a rounding step from every comparison.
- **Store time in the device's local zone.** Loses because a local-time
  string needs a timezone database to convert, and a restaurant that moves
  or a device that travels produces inconsistent rows.

## Checklist

Before a schema or model change is treated as done:

- [ ] Every new money column is `INTEGER` and its name ends in `_minor`;
      no `REAL` money column exists anywhere in `src/schema/`.
- [ ] Every new rate is an integer in basis points, bounded by a `CHECK`.
- [ ] Every new timestamp is `INTEGER` epoch milliseconds UTC; recurring
      wall-clock values use minutes-from-midnight or a calendar date.
- [ ] No negative price can be written; discounts use the `discount` and
      `order_discount` tables.
- [ ] Money formatting goes through one model method that honours
      `currency.minor_units`, not a `/100` written into a template.
- [ ] The money test in `apps/ros/src/tests.zig` still passes, and a
      new test covers any new arithmetic.
- [ ] `native check` is clean and `native test` is green.
