# Phase 8 — Packaging, migration and cutover

> **Status:** Planned
> **Estimate:** 5 engineer-days
> **Depends on:** Phases 0–7 as scoped
> **Exit criterion:** a signed app runs on a clean machine with imported
> data, and CI proves it.

## Goal

Ship it: a signed application, a supportable install, and a path from v1.

## What exists

- `app.json` with platforms, permissions, capabilities and a window.
- `assets/icon.png`.
- A 0.1.0 version.
- No packaging and no migration path. CI exists (`verify` + a non-blank
  smoke) but does not exercise a sale.

## What is missing

| Item | Detail |
|---|---|
| Signed macOS app | `native package --target macos`, signing, notarisation |
| Linux/Windows packaging | Untested |
| App icon set | One PNG; platform icon requirements differ |
| Version policy | `0.1.0` only; no build number |
| Update mechanism | None |
| CI | Exists (`verify` plus an automation smoke); no package or migration job |
| Automation smoke | Non-blank only; no sale flow (#42) |
| Legacy migration | None |
| Backup/restore | No UI, no schedule |
| Diagnostics | No log export, no crash report path |
| Support mode | DB inspector exists as a screen name only |
| Documentation for operators | None |
| Rollback plan | None |

## Tasks

1. **Package macOS first** and run the result on a clean machine.
2. **Add the CI pipeline**: check, test, automation smoke, package.
3. **Add the automation smoke** (role picker → login → sale → KDS →
   screenshot, assert non-blank and node budget).
4. **Decide the legacy migration**:
   - in-place: transform a v1 database to the Restaurant OS schema; or
   - fresh install: export/import products, customers and open orders.
   Validate with a real database copy and a per-table row count.
5. **Build the setup flow** if a fresh install is the answer. It is a
   prerequisite, not optional.
6. **Add backup/restore** to a file and optionally to cloud storage via
   `fx.fetch` + `credentials`.
7. **Add diagnostics**: a log file, an export action, a support bundle.
8. **Write the operator runbook**: install, first-run setup, printer
   setup, device role, backup, upgrade, rollback.
9. **Define versioning and upgrade** (schema migration + app update).
10. **Run a pilot service** in a real restaurant; record failures.

## Exit criterion

- A signed app installs on a clean machine.
- It creates a company and an admin through setup, or imports real data
  without loss.
- It prints a receipt and a KOT on the pilot hardware.
- Two devices converge.
- CI reproduces the build and the smoke test.
- A rollback is documented and tested.

## Risks

| Risk | Mitigation |
|---|---|
| Silent data loss in migration | Row counts, checksums, dry run, backup first |
| Notarisation/signing surprises | Do it in Phase 0/8 early, not the last day |
| Pilot reveals a usability blocker | Pilot before declaring release, not after |
| No rollback | Keep the v1 app installable until sign-off |
| Update mechanism absent | Ship a manual update path first; automate later |
| Operator setup is too complex | Observe a real operator doing it |

## Unknowns

- Is a fresh install acceptable, or is in-place migration mandatory?
- Which platforms ship first?
- Is there an update server or app-store distribution?
- What does support need to diagnose a device?
- What is the rollback story if the Restaurant OS build is bad?

See [`../open-questions.md`](open-questions.md).
