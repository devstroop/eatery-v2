# Sync sidecar — the LAN sync transport

> **Status: DESIGN.** Nothing in this directory is implemented. There is no
> language choice, no build script, no source file and no test. This
> document specifies what the sidecar has to do and what it is allowed to
> assume, so that the first line of code written later has something
> honest to answer to.
>
> **Sources:**
> [`docs/architecture/08-sync.md`](../../docs/architecture/08-sync.md),
> [`docs/decisions/0009-oplog-sync-with-transport-sidecar.md`](../../docs/decisions/0009-oplog-sync-with-transport-sidecar.md),
> [`docs/plan/phase-6-sync-sidecar.md`](../../docs/plan/phase-6-sync-sidecar.md),
> `apps/eatery/src/schema/0010_sync.sql`, and the v1 Dart implementation in
> `../eatery/packages/eatery_core/lib/data/sync/`.
>
> **Last verified:** 2026-10-20, by source review.

---

## The problem

A restaurant runs several devices — a counter POS, a waiter tablet, a
kitchen board, a customer display — and they must converge on one state,
often with no internet.

Eatery v1 solved this inside the Flutter process. `sync_server.dart` ran a
WebSocket server on port `9876`; `sync_client.dart` connected to
`ws://$host:$port` with `web_socket_channel`; `mdns_service.dart`
advertised `_eatery._tcp` over multicast DNS and browsed for it;
`op_log_service.dart` kept the operation log; `sync_coordinator.dart`
applied incoming operations to the local store.

The Native SDK has none of that:

| v1 capability | SDK | Consequence |
|---|---|---|
| WebSocket server | absent | the app cannot accept a peer |
| WebSocket client | absent | the app cannot reach a peer |
| mDNS | absent | the app cannot advertise or discover |
| `fx.fetch` | HTTP(S) only | cannot be bent into a socket |
| SQLite | present, engine-owned | the substrate is there |
| `fx.dbSubscribe` | present, unused | the app can watch a table |
| `fx.spawn` | present | the app can start a helper |

The app therefore must not speak the network protocol. The sidecar owns
the socket, the announcement and the election; the app owns the rows.

## The shape: transport out, protocol in

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

Four rules, from ADR-0009:

1. **The app never speaks the network protocol.** It writes an `op_log`
   row for each mutation and watches `op_log` for incoming rows.
2. **The sidecar owns the socket, mDNS and host election.** It opens the
   same SQLite file in WAL mode and relays rows.
3. **The database is the integration point.** There is no in-process IPC
   protocol between app and sidecar beyond the file and the update hook.
4. **The app remains usable offline.** Local writes always succeed; sync
   is eventually consistent.

The sidecar does **not** apply operations to the app's domain tables. It
relays `op_log` rows; the app applies them. That keeps the LWW decision
in one place — the app — and stops the sidecar from needing to know the
schema beyond `op_log`.

## What the sidecar does

| Responsibility | Mechanism |
|---|---|
| Advertise on the LAN | mDNS, service type under discussion (see open questions) |
| Accept peers | WebSocket server, port `9876` as in v1 |
| Read local ops | `SELECT` from `op_log` in WAL mode |
| Push ops to peers | `oplog_push`, batched |
| Receive ops from peers | `oplog_push` from a peer, written into the local `op_log` |
| Answer a pull | `oplog_pull` → `oplog_push` with everything after `sinceClock` |
| Elect a host | `host_vote` / `host_claim` — see below, v1 never finished this |
| Report state to the app | NDJSON on stdout |

### The row it writes

The v2 `op_log` table is column-shaped; the v1 table was a clock column
plus a JSON blob. The sidecar reads and writes the v2 columns.

| Column | Type | Meaning |
|---|---|---|
| `id` | `TEXT` PRIMARY KEY | operation id |
| `entity_table` | `TEXT` | the table the operation touched |
| `entity_id` | `TEXT` | row key as text |
| `operation` | `TEXT` | `create` / `update` / `delete` (CHECK-constrained) |
| `data_json` | `TEXT` | full row snapshot after the operation |
| `previous_json` | `TEXT` | full row snapshot before |
| `logical_clock` | `INTEGER` | the LWW counter |
| `device_id` | `TEXT` | who made the change |
| `host_id` | `TEXT` | which host accepted it |
| `parent_id` | `TEXT` | causality link |
| `created_at` | `INTEGER` | epoch milliseconds |

Indexes: `op_log_entity(entity_table, entity_id)`, `op_log_clock(logical_clock)`,
`op_log_device(device_id)`.

## Protocol v1, kept

The v1 protocol is table-shaped already, so it is kept and the transport
moves. Three things are kept: the operation shape, the conflict rule, and
the message vocabulary.

### The operation shape

v1 carried a Dart `OpLogEntry` with this JSON form
(`op_log_entry.dart`, `toJson`):

```json
{
  "id": "device_42",
  "entityType": "order",
  "entityId": 1749843210123,
  "operation": "create",
  "data": { "order_no": "1749843210", "total_minor": 49000 },
  "prevData": null,
  "timestamp": 1749843210123,
  "deviceId": "device_42",
  "parentId": null,
  "hostId": null,
  "metadata": null
}
```

The v2 row carries the same information with different names:

| v1 JSON key | v2 column | Difference |
|---|---|---|
| `id` | `id` | v1 built it as `'${deviceId}_$_clock'`; v2 wants a free text key |
| `entityType` | `entity_table` | renamed; v1 applied a fixed allow-list of 31 entity types |
| `entityId` | `entity_id` | v1 `int`, v2 `TEXT` |
| `operation` | `operation` | v1 allowed `create`/`update`/`void`/`refund`/`payment`; v2 CHECK allows only `create`/`update`/`delete` |
| `data` | `data_json` | same content: the full snapshot after |
| `prevData` | `previous_json` | same content: the full snapshot before |
| `timestamp` | `created_at` | v1 wall-clock ms, v2 epoch ms — same shape |
| `deviceId` | `device_id` | — |
| `parentId` | `parent_id` | — |
| `hostId` | `host_id` | — |
| `metadata` | *(none)* | no v2 column; free-form metadata was never used |
| *(v1 table column `clock`)* | `logical_clock` | v1 kept the logical clock as the row key; v2 keeps it as a column so `id` can be anything |

### The conflict rule

Last-writer-wins on `(logical_clock, device_id)`:

1. Every mutation gets `logical_clock = max(local_clock, highest_seen) + 1`.
2. On receive, the higher clock wins.
3. A tie is broken by `device_id`, deterministically.

The rule is lossy on purpose: two edits to different fields of the same row
cannot both survive. v1 behaved the same way, and matching v1 is what makes
the interop test in phase 6 possible.

### The message vocabulary

v1's `sync_message.dart` defines one JSON text frame shape for every
message — `type`, `deviceId`, `clock`, plus optional `deviceName`,
`devicePlatform`, `appVersion`, `entries` and `payload` — and eight
message types:

| `type` | v1 factory | payload / entries | v1 server behaviour |
|---|---|---|---|
| `host_announce` | `hostAnnounce` | `deviceName` | sent by the host every 5 s |
| `oplog_push` | `opLogPush` | `entries`: a list of operation objects | applied, acked, re-broadcast |
| `oplog_pull` | `opLogPull` | `payload.sinceClock` | answered with `oplog_push` |
| `oplog_broadcast` | `opLogBroadcast` | `entries` | the host's fan-out to every client |
| `host_vote` | `hostVote` | `payload.uptimeSeconds` | **treated as a heartbeat**, not a vote |
| `host_claim` | `hostClaim` | `payload.lastOpTimestamp`, `payload.entryCount` | **never handled** |
| `heartbeat` | `heartbeat` | — | resets the missed-heartbeat counter |
| `ack` | `ack` | `payload.lastAppliedClock` | advances the sender's `lastSyncedClock` |

Two honest notes about v1's implementation, because the v2 sidecar inherits
the vocabulary but not the behaviour:

- **Host election was never finished in v1.** `host_vote` and `host_claim`
  exist as message factories, but `sync_server.dart`'s `_handleMessage`
  handles `host_vote` by calling `syncService.receiveHeartbeat()` and
  never handles `host_claim` at all. The v2 sidecar has to implement the
  election properly; the message shapes are the only thing carried over.
- **The v1 host was fixed by configuration.** `SyncCoordinator` took an
  `isHost` flag and a `host` address at construction; `SyncHostConfig`
  persisted a single host address in an `app_config` table under the key
  `sync_host_address`. Discovery existed (`MdnsService.discoverHosts`) but
  nothing in the coordinator called it.

### Timings and limits inherited from v1

| Constant | v1 value | v1 location |
|---|---|---|
| host broadcast interval | 5 s | `sync_server.dart` `_startBroadcastLoop` |
| client push interval | 3 s | `sync_client.dart` `_pushTimer` |
| heartbeat considered stale after | 15 s | `sync_service.dart` `_startHostCheck` |
| missed heartbeats before the host is lost | 3 | `sync_service.dart` `detectHostLoss` |
| reconnect backoff | `1 << (attempt-1)` seconds, clamped to 30 s | `sync_client.dart` `_scheduleReconnect` |
| max entries per message | 500 | `op_log_service.dart` `batchForPush` |
| max retained ops | 10 000, oldest pruned first | `op_log_service.dart` `_pruneIfNeeded` |
| default port | 9876 | `sync_server.dart`, `sync_client.dart` |
| mDNS service type | `_eatery._tcp` | `mdns_service.dart` `kServiceType` |
| mDNS multicast group / port | `224.0.0.251` / `5353` | `mdns_service.dart` |

Proposal for v2: keep the port, the service type and the batch limit; drop
the fixed 10 000-row prune in favour of a policy that respects the logical
clock (see open questions).

## The process contract with the app

### How the app spawns it

The SDK's spawn effect is `fx.spawn(.{ ... })`, taking a `SpawnOptions`:

| Field | Type | Meaning |
|---|---|---|
| `key` | `u64` | caller-chosen identity; must not collide with another live effect |
| `argv` | `[]const []const u8` | the command line |
| `stdin` | `?[]const u8` | **written to the child's stdin once, then stdin closes** |
| `output` | `EffectOutputMode` | `.lines` (default) streams stdout through `on_line`; `.collect` accumulates the whole stdout |
| `max_line_bytes` | `usize` | per-line bound; default 4 KiB, ceiling 256 KiB; zero or above the ceiling is rejected |
| `on_line` | `?LineMsgFn` | `fn (line: EffectLine) Msg` |
| `on_exit` | `?ExitMsgFn` | `fn (exit: EffectExit) Msg` |

`EffectLine` carries `key`, `line`, `truncated` and `dropped_before`.
`EffectExit` carries `key`, `code`, `reason`, `dropped_lines`, and — for
`.collect` spawns — `output`, `output_truncated`, `stderr_tail`,
`stderr_truncated`. The `reason` is one of `.exited`, `.signaled`,
`.cancelled`, `.rejected`, `.spawn_failed`.

So the contract is: **the sidecar writes NDJSON on stdout, one JSON
object per line; the app decodes each line in `on_line` and maps the exit
in `on_exit`.**

Proposed stdout vocabulary (proposal — nothing implements it yet):

```json
{"v":1,"type":"ready","device_id":"...","host_id":"...","port":9876}
{"v":1,"type":"peers","count":2}
{"v":1,"type":"host","host_id":"...","device_id":"..."}
{"v":1,"type":"applied","op_id":"...","entity_table":"orders","entity_id":"1749843210123"}
{"v":1,"type":"error","code":"database_busy","message":"..."}
```

Proposed argv (proposal):

```text
sync-sidecar --db <path> --device-id <id> --port 9876 [--role host|leaf|auto] [--mdns <service-type>]
```

The `--db` path is the engine-owned database file, resolved by the app
through the SDK's `app_dirs` (the same path `native db status` prints).

One constraint from the SDK shapes the whole design: **`stdin` is written
once and then closed.** The sidecar cannot be fed through stdin after
start-up. It is therefore a start-announce-relay-stop process whose only
inputs are argv, the environment and the database file. If a future
version needs to push instructions into a running sidecar, that channel
does not exist in the SDK today.

### How it is told to stop

- `fx.cancel(key)` cancels the spawn effect. The exit arrives with
  `reason == .cancelled` and the app can clear its sync state there.
- Because the SDK closes the child's stdin immediately after the spawn,
  **EOF on stdin is not a stop signal** and must not be treated as one.
- The sidecar handles `SIGTERM` and `SIGINT` for shutdown outside the
  app's control (an operator killing the process, or the app being
  terminated rather than closed).

## The file layout the sidecar will have

Proposed. Nothing exists yet.

```text
tools/sync-sidecar/
├── README.md              this document
├── PROTOCOL.md            the frozen wire catalogue (proposal: see next step)
├── build.zig              the build
├── build.zig.zon
├── src/
│   ├── main.zig           argv parsing, the process lifecycle, the stdout writer
│   ├── db.zig             the SQLite handle: WAL, busy timeout, the op_log reader and writer
│   ├── op_log.zig         the row shape, the JSON codec, the LWW comparison
│   ├── protocol.zig       the eight v1 message types, encoded and decoded
│   ├── mdns.zig           advertise and browse
│   ├── ws.zig             the WebSocket server and client
│   ├── election.zig       host election
│   ├── relay.zig          the push, pull and broadcast loops
│   └── status.zig         the NDJSON lines the app reads
└── tests/
    ├── op_log_test.zig    the row codec and the LWW comparison
    ├── protocol_test.zig  a round trip for every message type
    ├── election_test.zig  one host wins; a silent host is replaced
    └── relay_test.zig     convergence over a fake transport
```

## Open questions

1. **Language and build.** Zig matches the repo, but the Zig standard
   library has no WebSocket and no mDNS: both have to be written, and the
   WebSocket framing (RFC 6455) is the larger of the two. A language with
   both in the standard library would start faster. This is the single
   biggest cost in the phase and it is undecided.
2. **The mDNS service type.** `docs/architecture/08-sync.md` says
   `_eatery-sync._tcp`; the v1 code used `_eatery._tcp`
   (`MdnsService.kServiceType`, `MdnsService.kServiceDomain`). If the
   Flutter v1 app must interoperate during a mixed rollout, `_eatery._tcp`
   wins.
3. **Peer trust.** The current design has no authentication: any device
   that can reach the port can connect and push `op_log` rows, and
   `device_id` is self-asserted text. A shared secret per installation is
   the minimum; whether TLS is required is a product decision (open
   question C1).
4. **Sync scope.** Which tables and columns sync is still open (D2). The
   v1 coordinator had an explicit allow-list of 35 entity types, which is
   a reasonable starting point.
5. **Deletion semantics.** v2's `operation` CHECK includes `delete`, and
   `data_json` holds the last snapshot, so a delete carries a tombstone by
   construction. v1's `rebuildState` returned `null` on `void` or
   `delete`. Which one the app applies is undecided.
6. **Retention and the logical-clock reset rule.** v1 pruned at 10 000
   rows and clamped the clock upward with `advanceClockTo`. Pruning rows
   whose clock is still the highest in the log would break the LWW
   comparison, so the two rules have to be decided together.
7. **Schema version mismatch.** The sidecar reads the same file as the
   app. A newer schema means the sidecar must refuse rather than guess.
8. **Single-device installs.** Does the sidecar run at all when there is
   one device (D6)? A restaurant with one till should not carry the
   process.
9. **Two writers.** WAL plus a busy timeout is the stated answer, but v2
   has not verified it under load.
10. **The app's side.** The app currently writes no `op_log` row, keeps no
    logical clock, has no device identity, and never applies an incoming
    row. The order write (`repos.saveOrder`) and the status write
    (`repos.setOrderStatus`) are the natural first integration points,
    because both are already single atomic `dbExec` transactions.

## How it will be tested

1. **Unit — the row codec.** An `op_log` row round-trips through the JSON
   the wire protocol carries, including the `previous_json` snapshot and
   the empty-string defaults.
2. **Unit — the LWW comparison.** A higher `logical_clock` wins; a tie is
   broken by `device_id`; equal clock and equal device is a no-op; a
   delete beats an update of the same clock.
3. **Unit — the message codec.** A round trip for each of the eight v1
   message types, including `oplog_push` with a batch of entries.
4. **Unit — election.** One host wins a round; a host that stops
   answering heartbeats is replaced after the stale threshold; the
   replacement is deterministic across the peers.
5. **Integration, no network.** Two temp-file databases and a fake
   transport that copies `op_log` rows. After N operations both databases
   hold identical state. This is the phase 6 exit criterion.
6. **Integration, no network.** An offline edit syncs exactly once on
   reconnect — not twice, not zero times.
7. **Integration, LAN.** Two sidecars on two machines over a real
   WebSocket: an order placed on A appears on B without a restart.
8. **Integration — the app's half.** The app writes an `op_log` row inside
   the same transaction as the order write, the sidecar relays it, and the
   app never opens a socket. Asserted by the fake effects executor: no
   fetch effect is ever recorded.
9. **Interop.** The Flutter v1 app and the native app converge on the
   same state over a frozen op-log fixture.
10. **Failure injection — the sidecar dies.** The app keeps working, sync
    pauses, and the queued operations are still there when the sidecar
    restarts.
11. **Failure injection — two writers.** The app and the sidecar write
    concurrently; WAL plus the busy timeout holds and no operation is
    lost.

## Next step

Write `tools/sync-sidecar/PROTOCOL.md`: the frozen wire catalogue — the
eight v1 message types with their JSON shapes, the handshake, the version
field, the mapping onto the `op_log` columns, and the exact contents of
the NDJSON lines the app reads. Then take that document to a review that
settles the two decisions everything else waits on: the sidecar's
language, and whether the mDNS service type stays `_eatery._tcp` (v1) or
becomes `_eatery-sync._tcp` (the architecture doc).
