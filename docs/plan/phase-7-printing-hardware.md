# Phase 7 — Printing and hardware

> **Status:** Scaffolded — tables exist, no code, no sidecar
> **Estimate:** 8 engineer-days, depends on the BLE decision
> **Depends on:** Phase 3, ADR-0008 accepted
> **Exit criterion:** a receipt and a KOT print from the native app on real
> hardware.

## Goal

Paper. A POS that cannot print a receipt or a kitchen ticket is a demo.

## What exists

- `printer` and `auto_print` tables with kind, transport, address, job and
  width.
- Empty `tools/print-sidecar/`.
- The port plan's option analysis.

## What is missing

| Item | Detail |
|---|---|
| Sidecar | No binary, no build, no protocol |
| ESC/POS | No encoder, no code pages, no cut/drawer/logo |
| BLE | No discovery, pairing or write path |
| TCP | No :9100 transport |
| USB | No transport |
| System print | No `lp`/`lpr` path |
| Job model | No job row or in-memory job |
| Routing UI | `settings_printers` has no template |
| Receipt layout | Not designed |
| KOT layout | Not designed |
| Report layout | Not designed |
| Retry/idempotency | Not designed |
| Status surface | No success/failure feedback |

## Tasks

1. **Accept or reject ADR-0008.** Decide BLE vs LAN-only vs defer.
2. **Choose the sidecar language and packaging.** It must ship with the app.
3. **Define the job protocol**: bytes on stdin, a job file, or a job table.
4. **Implement the ESC/POS encoder** with the target code page and a width
   policy for 58/80 mm.
5. **Design the receipt**: header, items, modifiers, tax, discount, total,
   payment, footer, logo, QR.
6. **Design the KOT**: table/order, time, items with qty and notes,
   station, course.
7. **Implement one transport first** (TCP is easiest to test, BLE is the
   real target).
8. **Add `settings_printers`**: list, add, test print, enable by job.
9. **Wire automatic printing** on order placement and on KOT-relevant
   status changes.
10. **Add retry/idempotency** so a retry does not double-print.
11. **Add failure copy** and a retry action that never blocks a committed
    sale.
12. **Test on the actual hardware** the target customers use.

## Exit criterion

- A cashier places an order and a receipt prints without leaving the POS.
- The kitchen receives a KOT with the right items.
- A printer offline produces a visible, retryable warning, not a lost sale
  or a duplicate.
- The printer configuration survives a restart.

## Risks

| Risk | Mitigation |
|---|---|
| No target hardware available | Buy one of each supported model before starting |
| BLE permissions differ per OS | Test on each platform; document pairing |
| Code page renders the currency symbol as `?` | Choose a code page per locale and test |
| Sidecar signing/packaging | Treat as part of this phase, not Phase 8 |
| Duplicate prints after a retry | Idempotency key per job |
| Receipt legal requirements | Get the required fields per jurisdiction |

## Unknowns

- Which printer models are the supported matrix?
- Is BLE required, or will LAN printers satisfy the market?
- What are the legal receipt fields and numbering rules?
- Does the kitchen need one KOT per station?
- Is a cash drawer attached to the printer?
- Should printing be automatic or a deliberate action?

See [`../open-questions.md`](open-questions.md) and
[`../architecture/09-printing-and-hardware.md`](../architecture/09-printing-and-hardware.md).
