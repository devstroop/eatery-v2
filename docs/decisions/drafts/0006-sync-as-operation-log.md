# ADR-0006: Sync is an operation log in the database; a sidecar owns the socket

**Status:** Accepted (2026-10)
**Applies to:** `apps/ros/src/schema/0010_sync.sql`,
`apps/ros/src/data/repos.zig`, `tools/sync-sidecar/**`
**Related:** [`architecture/08-sync.md`](../../architecture/08-sync.md),
[`architecture/11-capability-gaps.md`](../../architecture/11-capability-gaps.md)

## Context

v1 spoke the network protocol from inside the application.
`../eatery/packages/eatery_core/lib/data/sync/sync_server.dart` and
`sync_client.dart` implement a WebSocket host and leaf, and
`sync_message.dart` defines eight message types: `host_announce`,
`oplog_push`, `oplog_pull`, `oplog_broadcast`, `host_vote`, `host_claim`,
`heartbeat` and `ack`. Discovery was mDNS on `_ros-sync._tcp:9876`,
and host election ran inside the app: after three missed heartbeats every
leaf broadcast a `host_vote` carrying its device id, uptime and clock, and
after two seconds the highest uptime won.

The protocol was already table-shaped. `OpLogEntry` in
`packages/eatery_core/lib/data/sync/op_log_entry.dart` carries the entity
type, the entity id, the operation, the full snapshot after the mutation,
the snapshot before it, the logical clock, the device id and the parent id.
The `op_log` table in v1's `assets/db/schema.sql` is
`(clock INTEGER PRIMARY KEY, value TEXT NOT NULL)`. The conflict rule is
last-writer-wins on `(clock, deviceId)`.

The Native SDK has no WebSocket client or server, no mDNS and no
host election, and `fx.fetch` rejects anything that is not HTTP(S). The
transport cannot be rebuilt inside the app without adding a network stack, a
reconnect loop and a reconnect state machine to a core that is currently a
pure function of `(model, message)`.

## Decision

**Keep the protocol, move the transport.** The app writes its changes to an
`op_log` table and watches that table; a separate process owns the socket,
the mDNS announcement and the host election.

The schema is `apps/ros/src/schema/0010_sync.sql`: three tables.

| Table | Holds |
|---|---|
| `device` | This device's identity: `id` (TEXT PK), `name`, `role` (`admin`/`waiter`/`kds`/`display`), `last_seen_at`, `created_at` |
| `op_log` | The append-only mutation ledger: `entity_table`, `entity_id`, `operation` (`create`/`update`/`delete`), `data_json`, `previous_json`, `logical_clock`, `device_id`, `host_id`, `parent_id`, `created_at` |
| `sync_state` | The local logical clock and sync metadata, key/value |

The rules:

1. **The app never speaks a network protocol.** It writes an `op_log` row
   inside the same transaction as the mutation, and reads incoming
   operations from the table.
2. **The sidecar owns the socket, the mDNS announcement and the host
   election.** It opens the same SQLite file in WAL mode and relays rows.
3. **The database is the integration point.** There is no in-process IPC
   protocol between the app and the sidecar beyond the file and the update
   hook.
4. **The app stays usable offline.** Local writes always succeed; sync is
   eventually consistent.

The conflict rule is unchanged from v1: last-writer-wins on
`(logical_clock, device_id)`, with the sidecar bumping the local clock to
`max(local, highest seen) + 1`. The `op_log` row carries a full snapshot
rather than a field diff, because a snapshot beats a merge when two clients
can disagree.

The natural first integration point is already shaped for it:
`repos.saveOrder` and `repos.setOrderStatus` in
`apps/ros/src/data/repos.zig` build multi-statement writes and hand them
to a single `fx.dbExec`, so an `op_log` insert joins the same transaction
and cannot be separated from the mutation it describes.

## Consequences

- The app's purity is preserved. `update` gains no I/O of any kind; the
  sync substrate is rows, and rows are reached through the same effects
  channel as everything else.
- The transport becomes replaceable. A different wire protocol, or a
  different discovery mechanism, is a change to `tools/sync-sidecar/` and
  nothing else.
- The app is usable with no sidecar at all. A single-device installation
  needs no network and no second process.
- **Cost:** the app writes no operations today. `0010_sync.sql` exists,
  `tools/sync-sidecar/` is an empty directory, and there is no sidecar
  binary, no protocol document beyond this ADR and
  [`architecture/08-sync.md`](../../architecture/08-sync.md), and no op-log
  write in `src/data/repos.zig`. The whole substrate is owed.
- **Cost:** last-writer-wins is lossy. Two edits to different fields of the
  same row cannot both survive; the higher clock wins and the other edit is
  discarded. v1 had the same rule, so Restaurant OS inherits the limitation rather
  than fixing it.
- **Cost:** a second program has to be built, packaged, signed and updated
  alongside the app, on three desktop platforms. It has to open the
  database concurrently with the app, which requires WAL and a busy timeout
  — neither is configured or verified in Restaurant OS today.
- **Cost:** there is no peer authentication. Any device that can reach the
  socket can connect, `device_id` is self-asserted text, and `op_log`
  accepts any snapshot it is handed. For a restaurant LAN this may be
  acceptable, but it has to be an explicit decision with an owner, not an
  omission. It is tracked in
  [`plan/open-questions.md`](../../plan/open-questions.md) section D.
- **Cost:** `op_log` grows without bound. There is no pruning policy, no
  tombstone semantics for deletions, and no defined behaviour for a
  duplicate op delivery beyond "apply idempotently by op id".
- **Cost:** the set of synced tables is not defined. Every table that
  carries business data has to be classified as synced or local, and a
  mistake in either direction is a data bug that only shows up on a second
  device.
- **Cost:** a schema version mismatch between two devices has no defined
  behaviour. The sidecar has to refuse or migrate, and neither is decided.
- **Cost:** the live-query path the design depends on is unused. Every read
  in `src/data/repos.zig` is a one-shot `dbQuery`; the `op_log` watch needs
  `fx.dbSubscribe`, which is Phase 1 work.
- **Cost:** v1's cloud replication to a VPS was a stated future direction in
  `../eatery/docs/architecture/sync-protocol.md`. Restaurant OS does not plan for it
  and the op-log shape would have to change to support it.

## Alternatives considered

- **A WebSocket client inside the app, as v1 had.** Loses because the SDK
  has no WebSocket, and writing one in Zig would put a network stack, a
  reconnect loop and a reconnect state machine inside a core that is
  currently a pure function of `(model, message)`. It would also make the
  app's offline behaviour depend on network code.
- **Host election inside the app, as v1's `host_vote`/`host_claim` did.**
  Loses because an election has to run when the app is not running, and the
  app is not always running — the kiosk is a wall board, the POS is
  closed at night. A sidecar that is always up can hold the election.
- **HTTP polling against a central host.** Loses because it requires a
  reachable server, which the offline-first promise forbids, and because it
  inverts the trust model: the app would depend on a machine it does not
  control.
- **A field-level CRDT with per-field clocks.** Loses because the schema
  is row-snapshot shaped, and per-field clocks would mean changing every
  table's write path, every decoder and the conflict rule, for a case
  (two devices editing the same row's different fields within the sync
  window) that a restaurant rarely hits.
- **Last-writer-wins by wall clock.** Loses because clock skew between a
  tablet and a POS would silently overwrite a sale. The logical clock in
  `op_log` and the tie-break on `device_id` make the winner deterministic
  regardless of skew.
- **Peer-to-peer gossip between the apps with no host.** Loses because every
  peer then has to implement discovery, membership and conflict resolution,
  and the app would need a network stack — the thing the sidecar exists to
  keep out.
- **Drop sync entirely and ship a single-device product.** Loses because a
  restaurant with a counter POS and a kitchen board is the target case, not
  an edge case. The op-log substrate is the cheap half; the transport is
  the expensive half, and the expensive half is already isolated.

## Checklist

Before the sync phase is treated as done:

- [ ] Every mutation writes an `op_log` row in the same transaction as the
      change it describes.
- [ ] The set of synced tables is written down, table by table, and every
      table is either synced or explicitly local.
- [ ] `tools/sync-sidecar/` contains a runnable program that opens the
      database in WAL mode, relays `op_log` rows, announces over mDNS and
      runs a host election.
- [ ] Applying an incoming operation is idempotent by op id.
- [ ] The conflict rule is tested: two devices edit the same row, the
      higher `(logical_clock, device_id)` wins, deterministically.
- [ ] An offline edit syncs on reconnect exactly once.
- [ ] An order placed on device A appears on device B without a restart,
      using `fx.dbSubscribe` rather than a poll.
- [ ] The peer authentication decision is written down, with an owner, and
      either implemented or recorded as an accepted risk.
- [ ] A pruning policy for `op_log` exists, with the deletion semantics it
      implies.
