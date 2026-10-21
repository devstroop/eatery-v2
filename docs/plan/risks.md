# Risk register

> **Status:** Living.
> **Last reviewed:** 2026-10-21.
> **Legend:** L = likelihood, I = impact, both low / med / high.

The register is ordered by current priority, not by ID. An item with no
owner is not being managed.

## Top risks right now

| # | Risk | L | I | Why now | Mitigation | Owner |
|---|---|---|---|---|---|---|
| B0 | Every order write fails | certain | high | `orders.updated_at` is required and never inserted | Add the column to the insert and a DB read-back test (B-001) | Eng |
| C1 | Only 31 of 45 screens render | certain | high | The app looks complete in the enum and is blank in use | Render every screen or remove it from the enum | Eng/Product |
| R2 | CI smoke is non-blank only | certain | high | A broken sale path still passes | Extend the smoke through a seeded sale | Eng |
| P1 | BLE printing has no native path | certain | high | Receipts are core | Accept the sidecar or restrict to LAN (ADR-0008) | Product |
| S1 | Sync has no transport in-process | certain | high | Multi-device is a product promise | Op-log + sidecar (ADR-0009) | Product/Eng |
| I1 | Clock-based order IDs collide | high | med | A busy counter can place two orders in a second | Sequence/UUID (ADR-0013) | Eng |
| M1 | No legacy migration path or decision | high | high | Cutover can lose real data | Decide in-place vs fresh; dry-run on a copy | Product/Eng |
| SEC2 | A PIN is a fast digest over four digits | certain | med | The database is enough to recover every PIN | Slow hash, per-employee salt, lockout (B-027) | Eng |
| R1 | Zig/Node/SDK toolchain drift | high | high | 0.17 Zig and Node 22 both fail; scripts assume macOS paths | Pin versions; CI; cross-platform bootstrap | Eng |

### Closed since the last review

| # | Risk | Was | Now |
|---|---|---|---|
| SEC1 | Any employee PIN can open Admin | certain / high | FIXED: the sign-in query is scoped to the session's role and the returned row is checked against it (B-002) |
| SEC0 | Provisional-salt race weakens login correctness | med / high | FIXED: the sign-in waits for the database to confirm the salt, and the setup writes the salt with the operator's hash (B-003) |
| C2 | Waiter and display roles are unusable | certain / high | The waiter floor, menu, cart and order list render, and the display board shows the order cards. What the waiter still cannot do is pay for a table |
| C3 | A fresh install cannot log in | certain / high | FIXED: the setup writes the company, the operator, the salt and a starter menu in one transaction |
| C4 | Two effects shared an effect key | certain / high | FIXED: a second live effect with the same key is refused, so a write could silently never happen. Every key is used once, and a test says so |

## Delivery and environment

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| R3 | SDK v0.11.0 behaviour changes or is abandoned | med | high | Pin the version; keep the wrapper surface small; track upstream | Eng |
| R4 | `native package` signing/notarisation blocks release | med | high | Do a throwaway signed build early | Eng |
| R5 | The app needs a C library and must `native eject` late | med | med | Decide early whether sidecars or in-process links are needed | Eng |
| R6 | CI cost/time from building the SDK and `npm ci` every run | med | med | Cache CLI and `node_modules`; prebuilt CLI if available | Eng |
| R7 | `.native/build` or other generated files get committed | med | low | Ignore generated dirs; document ownership | Eng |

## Product and scope

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| P2 | Scope creep across 43 screens delays a usable sale | high | high | M1 is the milestone; freeze admin scope until it is honest | Product |
| P3 | Tax/discount/rounding behaviour diverges from v1 | high | high | Port calculations with the v1 tests as oracle | Eng |
| P4 | Payments, refunds and voids are under-specified | high | high | Decide v1 scope explicitly; write ADRs | Product |
| P5 | Setup is treated as a demo fixture | high | high | Make setup the first admin task | Product |
| P6 | Brand fidelity loss is rejected by stakeholders | med | med | Get design sign-off on tokens before Phase 5 | Design |
| P7 | Reports cannot be built because aggregates are missing | med | med | Design report queries in Phase 2 | Eng |
| P8 | Mobile/tablet is required after all | med | high | Decide desktop-first explicitly (ADR-0011) | Product |
| P9 | Multi-company appears late | low | med | Keep the one-company rule explicit in schema and copy | Product |

## Data

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| DAT1 | STRICT migration surfaces bad v1 types | high | med | Validate on a real database copy; per-row error report | Eng |
| DAT2 | Money/time conversion loses a cent or a day | med | high | Migration tests with checksums; timezone decision | Eng |
| DAT3 | Multi-effect operations are not atomic | med | high | Keep one `dbExec` per business op, or design a seam | Eng |
| DAT4 | `op_log` grows without bound | high | med | Retention policy before sync ships | Eng |
| DAT5 | Foreign-key deletion cascades lose history | med | med | Review `ON DELETE` per table; prefer `SET NULL` for history | Eng |
| DAT6 | No backup/restore | high | high | Add file backup in Phase 8; test restore | Eng |

## Security and compliance

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| SEC1 | SHA-256 is not a KDF; PINs are brute-forceable | high | med | Move to a KDF or add a keychain pepper and throttling | Eng |
| SEC2 | No login throttling or lockout | high | med | Per-employee/device attempt limits | Eng |
| SEC3 | Sync has no peer authentication | high | high | Pairing + shared secret minimum; document trust | Eng |
| SEC4 | Kiosk actions are unattributed | certain | med | Manager PIN for sensitive actions; audit log | Product |
| SEC5 | OAuth secrets or credentials leak into the repo | med | high | Use `fx.credentials*`; never commit secrets; secret scanning | Eng |
| SEC6 | Receipt/invoice numbering is not legal for a jurisdiction | med | high | Legal review; separate invoice sequence if needed | Product |
| SEC7 | No audit trail for voids/discounts | high | med | Enforce `void_log_entry`; log discount actor | Eng |

## UX and operations

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| U1 | No keyboard flow for a busy counter | med | med | Keyboard shortcuts and focus order | Design/Eng |
| U2 | Tiny touch targets on a tablet | med | med | Touch layout mode if tablet is in scope | Design |
| U3 | Dark-mode contrast is unverified | med | low | Contrast audit | Design |
| U4 | Error copy is technical and not actionable | med | med | Copy review per error arm | Design |
| U5 | A printing failure blocks a sale | med | high | Commit the sale before printing; show retry | Product |
| U6 | Clock skew makes waiting times wrong | med | low | Monotonic elapsed time from `placed_at` | Eng |

## Testing and quality

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| T1 | No database integration tests | certain | high | In-memory migrated tests per repo | Eng |
| T2 | The screen-ordinal contract has no test | high | high | Ordinal test or generated gates | Eng |
| T3 | Node budget is never asserted | med | med | Automation assertion on POS/orders | Eng |
| T4 | The Flutter app is not used as an oracle | high | med | Golden flow capture and calculation tests | Eng |
| T5 | Docs drift from code | high | low | Status pages updated with each phase; anchors on symbols | Eng |

## Accepted risks

These are known and accepted for now. Revisit at release.

| Risk | Why accepted | Revisit |
|---|---|---|
| No deep links | Kiosk app; entry is the role picker | If a web or mobile companion appears |
| No pie charts | Bar charts carry the information | Report design review |
| No Lottie | One animation is not worth a runtime | If brand requires it |
| No mobile | Desktop is the mature SDK path | After desktop release |
| One company | v1 multi-company was unused | If enterprise demand appears |
| No custom paint | Floor plan rebuilt from grid + drag | If freeform layout is required |

## How to use this register

1. Add a risk when a decision creates one, not only when it bites.
2. Give it an owner and a revisit trigger.
3. Link the ADR or phase that mitigates it.
4. Remove a risk only when the mitigation is shipped and verified.
5. Keep the top table short; move managed items down.
