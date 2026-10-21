# ADR-0012: CSV first for import and export

> **Status:** Proposed
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers, product
> **Related:** [`architecture/11`](../architecture/11-capability-gaps.md)

## Context

v1 used the `excel` package for XLSX import and export. The Native SDK has
no spreadsheet reader or writer. It can read and write files through the
effects channel.

Restaurant operators use spreadsheets for menu setup, price updates,
customer lists and accounting exports.

## Decision

**Proposed: support CSV natively as the interchange format; add XLSX only
through a sidecar if real demand appears.**

- Export writes CSV with a header row and UTF-8 encoding.
- Import accepts CSV with a header row, validates columns, and shows a
  preview before committing.
- Excel users can open and save CSV without extra tooling.
- XLSX is not a v2 requirement; a sidecar can convert if needed.

## Consequences

### Positive

- No spreadsheet dependency.
- Human-readable, diffable files.
- Works with every spreadsheet and accounting tool.
- Small implementation: `fx.readFile` / `writeFile`.

### Negative

- Loses multiple sheets, formatting, formulas and typed cells.
- CSV has encoding, delimiter and quoting pitfalls.
- Some accounting imports expect XLSX.
- A sidecar conversion is another moving part if demand appears.

### Follow-ups

- Define the export set (products, customers, orders, payments, reports).
- Define import validation and error reporting per row.
- Decide delimiter/encoding policy (UTF-8, comma, quoted).
- Decide whether import is transactional or row-by-row with a report.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Port an XLSX writer | Large dependency for a secondary feature. |
| Sidecar conversion now | Premature without a confirmed need. |
| JSON export only | Less accessible to operators and accountants. |
| PDF only | Not editable; wrong for data interchange. |

## Evidence

- `PORT-PLAN.md` §7 rows 45–46 (XLSX gap).
- `app.json`: filesystem capability; no spreadsheet capability.
- `data_management` and import/export screens are Planned.
