# ADR-0009: Op-log sync with the transport in a sidecar

> **Status:** Proposed — needs an owner and a go/no-go
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers, product
> **Related:** [`architecture/08`](../architecture/08-sync.md)

## Context

Multi-device restaurants need convergence. v1 implemented it inside the
Flutter process: a WebSocket server on port 9876, `web_socket_channel`
clients, mDNS discovery (`_eatery-sync._tcp`), host election and a
last-writer-wins CRDT over an `op_log` table.

The Native SDK has no WebSocket client or server and no mDNS. `fx.fetch`
is HTTP(S) only. It does have SQLite, `dbSubscribe`, and `spawn`.

The protocol is already table-shaped: operations are rows, and the
conflict rule is a comparison on a logical clock and device id.

## Decision

**Proposed: keep the op-log protocol, move the transport into a sidecar.**

- The app writes an `op_log` row in the same transaction as each
  mutation.
- The app watches `op_log` with `fx.dbSubscribe` and applies incoming
  rows.
- A sync sidecar opens the same SQLite file in WAL mode, advertises via
  mDNS, accepts WebSocket peers, relays rows, and owns host election.
- Conflict resolution is last-writer-wins on
  `(logical_clock, device_id)`.
- The app never speaks WebSocket.

## Consequences

### Positive

- No socket or mDNS stack in the pure core or the app binary.
- The database is the integration point; the sidecar is replaceable.
- `dbSubscribe` replaces manual invalidation of sync status.
- The app keeps working offline; sync is an eventually consistent
  background concern.
- Same pattern as printing: external process, shared data.

### Negative

- A second binary to package and operate.
- Two writers to the database require WAL and careful busy handling.
- No peer authentication is designed; the LAN is trusted by default.
- LWW loses concurrent edits to different fields of the same row.
- `op_log` grows without a pruning policy.
- Schema changes must be coordinated between app and sidecar.

### Follow-ups

- Define which tables sync and what a delete looks like.
- Define peer identity, pairing and trust (shared secret? TLS?).
- Define the sidecar lifecycle (always on? started by the app?).
- Define pruning and the logical-clock reset rule.
- Prove convergence with a two-instance test and an interop test against
  the Flutter app.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Implement WebSocket in the app | The SDK forbids non-HTTP schemes; would require a native extension. |
| HTTP polling with `fx.fetch` | Works for small datasets but adds latency and a server; still needs discovery. |
| Cloud-only sync | Restaurants lose internet; cannot be the only path. |
| CRDT per field | Better merge semantics, far more complexity than v1 needs. |
| No sync (single device) | A real regression for multi-station restaurants. |

## Evidence

- `src/schema/0010_sync.sql`: `device`, `op_log`, `sync_state` with clock
  and device indexes.
- `tools/sync-sidecar/` exists but is empty.
- App writes no `op_log` rows today.
- `PORT-PLAN.md` §7.1 Gap B and §8.4.
