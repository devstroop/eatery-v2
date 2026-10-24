# Sync architecture

> **Status:** Implemented core, revised by ADR-0017. The op log,
> per-device Lamport clock and vector cursor are in the apps; the
> sidecar and the LWW sections below record the original design and are
> kept for context.
> **Last verified:** 2026-10-24, by source review.
> **Source:** `packages/ros-core/src/net/`,
> `packages/ros-core/src/data/repos.zig`.
> **Design:** [12-three-apps-and-ipc](12-three-apps-and-ipc.md) and
> [ADR-0017](../decisions/0017-three-apps-over-tcp-ip.md) — the op log
> survives as the wire format, the sidecar does not, and the transport
> is HTTP/1.1 on TCP between the apps themselves.

## The problem

A restaurant may run several devices: a counter POS, a waiter tablet, a
kitchen board, a customer display. They must converge on one state, often
without reliable internet. The v1 app solved this with a WebSocket server
on port 9876, mDNS discovery (`_ros-sync._tcp`), a last-writer-wins
CRDT and host election, all inside the Flutter process.

The Native SDK has no WebSocket client or server and no mDNS. It does have
an engine-owned SQLite database and subprocess effects.

## The chosen shape: transport out, protocol in

```
┌──────────────────────────┐         ┌──────────────────────────┐
│ App (Zig)                │         │ App (Zig)                │
│                          │         │                          │
│ update ──▶ write row ────┼──▶ DB   │ DB ◀── read op_log ──────┤
│                          │         │                          │
│ fx.dbSubscribe(op_log) ◀─┼── DB    │                          │
└──────────┬───────────────┘         └──────────▲───────────────┘
           │ SQLite file (WAL)                  │ SQLite file
           ▼                                    │
┌──────────────────────────┐         ┌──────────┴───────────────┐
│ sync-sidecar             │◀───────▶│ sync-sidecar             │
│ mDNS · WebSocket · relay │  LAN    │ mDNS · WebSocket · relay │
└──────────────────────────┘         └──────────────────────────┘
```

Rules:

1. **The app never speaks the network protocol.** It writes an `op_log`
   row for each mutation and watches `op_log` for incoming rows.
2. **The sidecar owns the socket, mDNS and host election.** It opens the
   same SQLite file in WAL mode and relays rows.
3. **The database is the integration point.** There is no in-process IPC
   protocol between app and sidecar beyond the file and the update hook.
4. **The app remains usable offline.** Local writes always succeed; sync
   is eventually consistent.

This keeps the risky, platform-specific transport out of the pure core and
makes it replaceable. It also turns Riverpod's manual `ref.invalidate` into
a live query, which is strictly simpler.

## Op-log schema

`op_log` is an append-only mutation ledger.

| Column | Meaning |
|---|---|
| `id` | Operation ID (text, primary key) |
| `entity_table` | Table touched, so a subscriber can wake selectively |
| `entity_id` | Row key as text |
| `operation` | `create` / `update` / `delete` |
| `data_json` | Full row snapshot after the operation |
| `previous_json` | Full row snapshot before (for conflict display/audit) |
| `logical_clock` | Lamport-style counter; higher wins |
| `device_id` | Who made the change |
| `host_id` | Which host accepted it |
| `parent_id` | Causality link |
| `created_at` | Epoch ms |

Supporting tables:

- `device(id, name, role, last_seen_at, created_at)` — device identity.
- `sync_state(key, value)` — local clock and sync metadata.

Indexes: `(entity_table, entity_id)`, `logical_clock`, `device_id`.

## Conflict rule

Last-writer-wins on `(logical_clock, device_id)`:

1. Every mutation gets `logical_clock = max(local_clock, highest_seen) + 1`.
2. On receive, the higher clock wins.
3. A tie is broken by `device_id`, deterministically.

This is simple and matches v1. It is also lossy: two edits to different
fields of the same row cannot both survive. Whether that is acceptable is
an open product question.

## Intended app responsibilities

| Responsibility | Today |
|---|---|
| Write an `op_log` row inside the same transaction as the mutation | Not implemented |
| Subscribe to `op_log` and apply incoming rows | Not implemented |
| Keep `sync_state` logical clock | Not implemented |
| Show sync status | Not implemented |
| Resolve conflicts | Not implemented |
| Define what is synced (allow-list of tables) | Not defined |

The order write is the natural first integration point: `saveOrder` and
`setOrderStatus` already build multi-statement atomic writes, so an
`op_log` insert can join the same `dbExec`.

## Intended sidecar responsibilities

| Responsibility | Today |
|---|---|
| Advertise via mDNS | No binary |
| Accept WebSocket clients | No binary |
| Relay `op_log` rows | No binary |
| Elect a host | No binary |
| Detect peers and liveness | No binary |
| Prune old ops | No policy |
| Authenticate peers | No policy |

`tools/sync-sidecar/` is an empty directory. There is no language choice,
no build script, no protocol document beyond this design.

## Failure modes to design for

| Failure | Desired behaviour | Current |
|---|---|---|
| Offline device | Queue locally, sync later | Nothing queued because nothing is synced |
| Two devices edit same row | Deterministic winner; loser visible in history | No conflict path |
| Clock skew | Logical clock, not wall clock | Schema supports it |
| Duplicate op delivery | Idempotent apply by op `id` | Not implemented |
| Device removed mid-order | Order remains local; peer sees it on reconnect | Not implemented |
| Schema version mismatch | Refuse or migrate before sync | Not defined |
| Corrupt op snapshot | Reject the op, keep local state | Not defined |
| Sidecar crashes | App keeps working; sync pauses | No sidecar |
| Host disappears | Re-elect | No election |
| Database locked by sidecar | WAL + busy timeout | Not verified in Restaurant OS |

## Security and trust

The design currently has **no authentication or authorisation**:

- any device with the WebSocket address can connect;
- `device_id` is self-asserted text;
- `op_log` accepts any snapshot;
- there is no pairing flow, shared secret, or TLS;
- the schema stores `role` as text but nothing enforces it.

For a LAN in a restaurant this may be acceptable for v1, but it should be
an explicit decision, not an omission. See
[`plan/open-questions.md`](../plan/open-questions.md).

## What is decided vs not

Decided (proposed in the ADR):

- the app does not speak WebSocket;
- `op_log` is the source of truth;
- the sidecar owns transport and election;
- LWW with logical clocks.

Not decided:

- sidecar implementation language and lifecycle;
- peer authentication;
- which tables sync;
- conflict handling beyond LWW;
- deletion semantics (tombstones vs snapshots);
- clock pruning and `op_log` growth;
- whether the app or sidecar owns schema migration;
- whether sync is required for a single-device install.

See [ADR-0009](../decisions/0009-oplog-sync-with-transport-sidecar.md) and
[phase 6](../plan/phase-6-sync-sidecar.md).

## Testing target

1. In-memory or temp-file database, two `Database` instances, a fake
   transport that copies `op_log` rows.
2. Two apps edit the same row; assert the higher clock wins.
3. An offline edit syncs on reconnect exactly once.
4. An order placed on device A appears on device B without a restart.
5. Interop: the Flutter app and the native app converge on the same state.

None of these tests exist.
