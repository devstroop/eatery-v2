# Phase 6 — Sync sidecar

> **Status:** Scaffolded — tables exist, no app writes, no sidecar
> **Estimate:** 10 engineer-days
> **Depends on:** Phase 5, ADR-0009 accepted
> **Exit criterion:** two machines converge, and the Flutter app and the
> native app agree on the final state.

## Goal

Make several devices behave like one restaurant without a cloud
dependency.

## What exists

- `device`, `op_log`, `sync_state` tables with the right columns and
  indexes.
- The LWW rule documented: `(logical_clock, device_id)`.
- The v1 protocol as an oracle: `sync_server.dart`, `sync_client.dart`,
  `mdns_service.dart`, `op_log_service.dart`, host election.

## What is missing

Everything else:

| Layer | Missing |
|---|---|
| App writes | No `op_log` row is written for any mutation |
| App reads | No subscription or apply path |
| Clock | No local logical clock in `sync_state` |
| Identity | No device id generated or stored |
| Sidecar | No binary, no build, no protocol doc |
| Discovery | No mDNS |
| Transport | No WebSocket |
| Election | No host election |
| Conflict UI | No way to see or resolve a losing edit |
| Security | No pairing, auth or encryption |
| Retention | No op pruning |
| Tests | No convergence test |

## Tasks

1. **Accept or reject ADR-0009.** This phase cannot start on a maybe.
2. **Write the protocol document** (message shapes, handshake, version,
   error codes) from the v1 implementation.
3. **Define sync scope**: which tables, which columns, which operations.
4. **Generate a device id** at first boot and write the `device` row.
5. **Add `op_log` inserts** to the order and status write transactions.
6. **Implement apply-incoming**: validate, compare clocks, write the row,
   update `sync_state`.
7. **Prototype the sidecar** with a fake transport first (copy rows between
   two databases in-process); prove convergence without a network.
8. **Add mDNS + WebSocket** to the sidecar, then test on two machines.
9. **Define pairing/trust.** At minimum a shared secret per installation.
10. **Define deletion** (tombstone vs snapshot) and op pruning.
11. **Add a conflict-visibility surface** (a badge at least).
12. **Run an interop test** against the Flutter app.
13. **Decide whether a single-device install runs the sidecar at all.**

## Exit criterion

- Two app instances, two databases, fake transport: after N operations
  both converge to identical state.
- Same test over a real LAN with the sidecar.
- A losing concurrent edit is deterministic and observable.
- The Flutter and native apps agree on a fixed op-log fixture.

## Risks

| Risk | Mitigation |
|---|---|
| Two processes writing one SQLite file | WAL + busy timeout + WAL checkpoint policy; test under load |
| Silent data loss from LWW | Show conflicts; never auto-delete history |
| No authentication | Shared secret minimum; document the trust boundary |
| `op_log` growth | Retention policy from day one |
| Sidecar cannot be packaged | Solve packaging in Phase 8, not at the end of this one |
| Protocol drift from Flutter | Freeze fixtures and run interop tests |
| Clock reset after restore | Persist the clock; define a reset rule |

## Unknowns

- Must the app work with the Flutter app during a mixed rollout?
- Is a cloud relay ever required?
- Should every device be a host, or is there one admin host?
- How are devices paired: code, QR, file, or manual address?
- What is the retention window for operations?
- Does a restaurant accept LWW field loss?

See [`../open-questions.md`](open-questions.md) and
[`../architecture/08-sync.md`](../architecture/08-sync.md).
