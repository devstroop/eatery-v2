# Phase 2 — Schema and repositories

> **Status:** Partial
> **Estimate:** 8 engineer-days
> **Depends on:** Phase 1
> **Exit criterion:** every repository has a headless test against a
> migrated in-memory database, and `native check` is green.

## Goal

Make the data layer trustworthy. The schema is written; most repositories
and all calculation ports are not.

## What exists

- 43 STRICT tables across 10 migrations; lock file at version 10.
- Read + decode for company, products, categories, tables, employees,
  customers, orders, order lines, config.
- Writes for orders + lines, order status + history, config upsert.
- Page reader for the engine's wire format.
- SHA-256 PIN hashing.
- Defensive enum decoding and NULL fallbacks.

## What is missing

| Area | Detail |
|---|---|
| Write paths | products, categories, tables, employees, customers, payments, discounts, modifiers, taxes, suppliers, purchase orders, reservations, printers, devices |
| Read paths | payments, tax slabs, modifiers, discounts, stations, reservations, shifts, expenses, compliance reports, printers, devices, op log |
| Order semantics | tax is hard-coded to 0; discounts are hard-coded to 0; modifiers are not persisted; payments are not recorded |
| Order identity | clock-based ids collide; see ADR-0013 |
| Loading state | reads do not set `busy`; errors are per-arm |
| Live queries | `dbSubscribe` is unused |
| Database tests | none |
| Calculation oracle | v1 `OrderFunction` (tax, roundoff, payable) and validators are not ported |
| Setup data | no seed or setup path for a fresh install |
| Legacy migration | no path from a v1 database |

## Tasks

1. **Port the calculations first.** Bring v1 `order.function.dart` (tax,
   discount, roundoff, payable) into a Zig module with the v1 tests as the
   oracle. Do this before any payment or receipt UI.
2. **Introduce a durable order number** (sequence row or device-prefixed
   counter) and make the write retry on conflict.
3. **Add repository tests**: `openMemoryMigrated`, seed, execute, assert.
   Cover read, decode and write for each entity.
4. **Persist modifiers and tax** when an order is placed.
5. **Add a payment write path** and decide whether an order can close
   without one.
6. **Add the missing read paths**, beginning with tax slabs and payments
   (needed by the POS and shift report).
7. **Set `busy` on reads** or introduce a per-dataset loading flag.
8. **Decide the refresh model**: explicit reloads or `dbSubscribe`.
9. **Add the missing indexes** for reports, shift reconciliation and
   `op_log` pruning.
10. **Define a seed/setup fixture** for tests and for a fresh install.
11. **Decide the legacy migration** (in-place vs fresh install) and write
    the validation script.

## Exit criterion

- A test creates a company, an employee, a category, a product and a table
  in a migrated in-memory database, then reads each back through its
  repository and asserts the decoded values.
- A test places two orders in the same millisecond and both succeed.
- A test proves an order with a line and a payment is atomic.
- The tax/roundoff port passes the v1 oracle tests unchanged.

## Risks

| Risk | Mitigation |
|---|---|
| Calculation drift from v1 | Port with the v1 tests, not from memory |
| STRICT migration surfaces bad legacy types | Validate on a real database copy; fail with a per-row report |
| Multi-statement business operations are not atomic | Keep one `dbExec` per operation, or design a transaction seam |
| `dbSubscribe` changes the update flow | Prototype it on one dataset before adopting broadly |
| Schema churn while UI is being built | Freeze the core tables once POS and KDS ship |

## Unknowns

- Is a fresh install acceptable, or must v1 data migrate in place?
- What are the exact tax/discount/rounding rules, including inclusive tax?
- Are split payments, tips, service charge or refunds supported?
- Which currency scales are in scope?
- Does a completed order require a payment row?

See [`../open-questions.md`](open-questions.md).
