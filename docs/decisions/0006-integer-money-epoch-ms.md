# ADR-0006: Integer minor-unit money and epoch-ms time

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/05`](../architecture/05-schema.md),
> [`architecture/04`](../architecture/04-data-layer.md)

## Context

v1 stored money in `REAL` columns and lost cents to rounding. It also
mixed date representations: ISO text in some tables, numbers in others.
Both problems are silent: they surface as a one-cent discrepancy or a
mis-sorted report, not as an exception.

## Decision

**Money is `i64` minor units. Time is `i64` epoch milliseconds, UTC.**

- A currency's minor-unit count decides the scale (2 for USD/EUR/INR, 0
  for JPY).
- No float money in the schema, the domain, the model or the view.
- The view formats with `fixed(amount_minor / 100, 2)`; the currency
  symbol comes from the company.
- Every timestamp column is the same shape, so range queries and ordering
  need no per-column knowledge.
- Tax rates are basis points (`rate_bps`), not floats.

## Consequences

### Positive

- Exact arithmetic for cart totals, payments and reports.
- One time representation; ordering and ranges are trivial.
- Cross-currency changes require a scale, not a type change.
- Tests can assert exact integers.

### Negative

- Every display site must divide by the currency scale; a hard-coded 100
  is wrong for JPY and for 3-decimal currencies.
- Some SQL aggregates and external exports must convert.
- Existing v1 REAL data needs a rounding-aware migration.
- Epoch ms is UTC only; local-day reports need a timezone decision.

### Follow-ups

- Replace the hard-coded `/ 100` in markup with a currency-aware method.
- Decide how a tax-inclusive price is broken down (the `tax_inclusive`
  flag exists; the arithmetic does not).
- Decide the reporting timezone and day boundary.
- Add a migration test that proves no cent is lost converting v1 data.

## Alternatives considered

| Alternative | Why not |
|---|---|
| `REAL` money | The v1 bug; rejected outright. |
| Decimal strings | Correct but slower and awkward in SQL/Zig; integer is simpler. |
| SQLite `NUMERIC` | Affinity is not exact decimal; still a float under the hood for fractions. |
| ISO text timestamps | Lexicographic ordering works, but arithmetic and timezone handling do not. |

## Evidence

- `src/domain/models.zig:1` states the rule.
- `src/schema/*.sql`: every money and time column is `INTEGER`.
- `src/core/model.zig:287`: `cart_total_minor`.
- Test: "money stays integer".
