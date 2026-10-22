# Phase 9 — Three apps over TCP/IP

> **Status:** Planned. The decision is
> [ADR-0017](../decisions/0017-three-apps-over-tcp-ip.md) (Proposed); the
> design is [`architecture/12`](../architecture/12-three-apps-and-ipc.md).
> **Estimate:** 42 engineer-days
> **Depends on:** Phase 3 (the POS slice), Phase 5 (the admin
> surfaces), ADR-0017 accepted, **and the PIN salt settled**
> **Supersedes:** [Phase 6](phase-6-sync-sidecar.md) — the op log and the
> transport are the same work, and the sidecar is not being built
> **Exit criterion:** three apps on three machines converge, the kitchen
> keeps cooking while the admin app is closed, and an order taken on one
> device is served on the other two.

## Goal

Turn one binary with four roles into three apps that talk to each other
over TCP/IP, without breaking the sale that already works.

## Why this is not Phase 6 with a new transport

Phase 6 planned a WebSocket sidecar that relayed `op_log` rows between
apps that shared one SQLite file. Two of its three premises are false
now:

- **The apps cannot share one file.** The database is engine-owned and
  pathless; each app has its own `app.db` in its own data directory, and
  `ATTACH` is denied. The database was never going to be the integration
  point across machines.
- **The sidecar is not needed.** If the apps cannot share a file, then
  something has to move the rows, and the thing that moves them can be
  the peers themselves.

What survives from Phase 6 is the part that was always right: the op
log is the protocol, and the conflict rule is per entity class rather
than a blanket last-writer-wins. The parts that die are the sidecar,
the mDNS, the WebSocket and the host election.

## What exists

- One binary, four roles, one model, one `update`, one schema.
- `op_log`, `device` and `sync_state` with the right columns.
- The order identifier and the request key ([ADR-0014](../decisions/0014-order-identity.md)),
  which is what makes a repeated write idempotent.
- The permission matrix, which becomes three.
- `scripts/verify-all.sh` and `scripts/build.sh`, which already loop
  over `apps/*/`.

## What is missing

| Layer | Missing |
|---|---|
| Packages | A shared package; three app packages that depend on it |
| Manifests | Three manifests with three ids |
| The role | A constant per binary instead of model state |
| Screens | A partition, and the role picker as a person picker in all three apps |
| Wire | A frame format, an endpoint set, a version |
| Client | Nothing: `fx.fetch` is the client |
| Server | A TCP listener on `std.Io.net`, an HTTP/1.1 parser, a writer |
| The seam | The outbox, and the rule that the net thread never touches the model |
| Ops | No app writes an `op_log` row |
| Apply | No path that applies an incoming op |
| Discovery | No beacon, no peer list, no manual address |
| Reference data | No push, no version |
| Push | No event stream |
| Bootstrap | No snapshot, no replay |
| Security | No peer authentication |
| Tests | No two-device test of any kind |

## The slices

Each slice leaves the tree green. `scripts/verify-all.sh` and
`scripts/build.sh` are green after every one of them - and no slice
leaves a restaurant unable to serve, which is a stronger rule and the
one the [order](#the-order-of-the-slices) is built around.

### What this phase costs to merge with the back office

The back-office work (PR #101) and this branch touch the same ten
files, and the merge is small. It has been done and measured: three
files conflict, and the whole of the resolution is one line plus three
test changes.

| Conflict | What it is | How it resolves |
|---|---|---|
| `core/update.zig` | The boot reads, and the salt change adds one more read | Both sides keep their reads; the loader takes the model, so the calls change shape |
| `screens/screen-login.native`, `screens/screen-role-picker.native` | The back office grouped the session screens into one file, and the salt change edited them where they were | The salt change's two templates move into the grouped file |
| `core/update.zig` (the PIN reset) | `hashPin` now takes the employee's id, because the hash is the employee's | One argument: the reset already knows whose PIN it is resetting |
| `tests_data.zig` | The sign-in names the person before it hashes | The tests pick a person and type the PIN again, because a failed attempt clears it |

Merged, the two lines of work run **123/123 green**. That number is
worth having before the phase starts: the split is not a fork of the
back office, it is a continuation of it.

### The order of the slices

**The split comes last, and the reason is the database.**

Each app gets its own engine-owned database in its own data directory,
and the database cannot be shared. So replication over the network is
mandatory for **any** multi-device deployment - one binary with four
roles on three machines needs it just as much as three binaries do.
The split does not cause the fabric; the SDK's pathless database does.

That has a consequence for the order, and the consequence is not
cosmetic. If the three shells are built before the fabric, then for
the slices in between:

- the `service` app **cannot sign anybody in**. The sign-in names the
  person, and the picker lists the people who work here - and the
  service app's own database has none of them, because the people
  arrive as reference data in 9.5. The salt (9.0) fixes the *hash*; it
  does not deliver the *rows*;
- the `kiosk` board **shows no orders**, because the orders arrive as
  ops in 9.3 and are pushed in 9.6;
- a restaurant running the three apps **cannot serve a customer**.

A green test suite is not a working restaurant, and the slices are
ordered so that no slice leaves a restaurant worse off than the one
before it. The split is a **release event, not a development event**:
the code can be written early, but the three apps are not what a
restaurant runs until the fabric under them works.

The other half of the order is the same argument seen from the other
side: the protocol is the risky part - it is the only part of the
phase that has to survive a network - and the spike exists to find out
whether it can be done at all. So the risky part goes first, while
there is still one app to fall back on.

### 9.0 — The blockers (6 days)

**The two things that are not solved by the protocol, spent first.**

1. **The seam** (2 days) — **DONE.** `apps/net-spike` proves all three
   claims by calling its own listener:
   1. a `std.Io.net` listener in a `main` thread accepts a connection
      and serves HTTP/1.1;
   2. `fx.fetch` from the same app reaches that listener, and the
      response arrives as a `Msg`;
   3. bytes posted from the net thread with `ChannelHandle.post` arrive
      as a `Msg` payload, and a response written by `update` reaches the
      socket.

   The round trip, from the app's own log:

   ```
   SEAM: the net thread bound port 63627
   SEAM: fetch outcome=ok status=200 body="pong" -> SEAM OK
   ```

   It settled five things the design had assumed. **The outbox needs
   no lock**: `std.Thread.Mutex` is gone in Zig 0.16 and `std.Io.Mutex`
   needs the `Io` that `update` does not have, so the ring is
   single-producer/single-consumer and two atomic counters do the job -
   `update` never blocks and never waits. **The outbox is per
   connection**, because a frame carries no peer id, so an answer could
   otherwise reach the wrong peer, and a leftover answer could be
   handed to the next connection. **A thread that owns a socket needs
   a stop**, and a flag is not enough because `accept` blocks: the app
   connects to its own listener to make it return - without that, the
   app hangs on quit on Linux and Windows, where the runtime returns
   from `runWithOptions` instead of terminating the process. **An
   answer that does not fit must say so** rather than be truncated on
   the way to the socket. And **plain `http://` works**, because the
   SDK's fetch is built on Zig's `std.http.Client` rather than on the
   platform's, so App Transport Security does not stand in the way of a
   LAN address.

   What it does not prove, and what slice 9.2 must: a **peer on a
   different machine** - the spike fetches its own listener, so the
   traffic never leaves the host, and a same-subnet bind proves the
   seam but not the network; more than one connection in flight at
   once, which the per-connection slots make room for; and the wake-up
   path a self-pipe would give. The macOS Local Network permission is
   still untested too: it is asked the first time an app opens a
   socket to a local-network address, which is what the LAN bind does.

   The spike binds the address it is told to, so the LAN path is
   exercisable without a rebuild:

   ```sh
   ROS_SPIKE_BIND=192.168.1.42 ./zig-out/bin/net-spike
   ```

2. **The salt** (4 days) - **DONE.** The `service` app cannot let a
   waiter in unless the sign-in works without the installation salt,
   and each app has its own installation salt.

   **This one does not wait for the go/no-go, and it should not.** It
   is the recorded follow-up of an *accepted* decision (ADR-0016 says
   the per-employee salt is the fix, "when the sign-in can identify the
   employee before it hashes"), it stands on its own as a security
   property - a cracked database gives up one PIN, not every PIN - and
   it makes the sign-in better for the same product: a person picks
   their own name instead of a role. Landed on its own, it is a
   security fix; held until the three apps are decided, it is a
   security fix that waits for a product decision about packaging. **The salt becomes
   per-employee**, by
   [ADR-0018](../decisions/0018-the-pin-hash-is-the-employees.md)
   and [#95](https://github.com/devstroop/ros/issues/95) - the
   sign-in identifies the employee before it hashes, so the employee row
   is self-verifying and no shared secret has to cross the wire. The
   picker that makes this possible sits in place of the role picker: a
   person is on the picker with the mode they work in, and the two
   device modes sign in by being the device. It landed on `develop` on
   its own in [#117](https://github.com/devstroop/ros/pull/117). See
   [`architecture/12`](../architecture/12-three-apps-and-ipc.md#the-sign-in-problem).

**Done when:** one app, one loop thread, one net thread, one request
answered, one test per direction; and the salt landed on `develop` in
[#117](https://github.com/devstroop/ros/pull/117).

### 9.1 — The package split (3 days)

Move the shared code into `packages/ros-core` and make the three
apps depend on it. `native eject` each app so the build owns its
dependency on the shared package. **No behaviour changes.** The single
app keeps working, and its tests keep passing.

**Done when:** `packages/ros-core` holds the core, the data layer,
the domain and the schema; `apps/ros` is a shell over it; the suite
is green and unchanged.

### 9.2 — The wire (5 days)

The frame format, the endpoints, the version. A `net` module in the
shared package: a client built on `fx.fetch`, a server built on
`std.Io.net`, the outbox, and the discovery beacon.

`GET /v1/hello` first, then `GET /v1/ops` and `POST /v1/ops`.

**Done when:** two app instances on one machine exchange ops over a real
socket, and the exchange is covered by a test that runs against the
fake executor for the client side.

### 9.3 — Ops in and ops out (5 days)

Every mutation writes an `op_log` row in the same transaction as the
write itself - `saveOrder` and `setOrderStatus` already build
multi-statement writes, so the insert joins the same `dbExec`. An
incoming op is validated, applied idempotently by op id, and written
with its own op row so it propagates.

The cursor is a **vector**: a device tracks the highest clock it has
applied *per source device*, and asks each peer for what it is missing
from that peer. A scalar cursor drops ops whenever two devices'
counters disagree, which is the normal case - see
[`architecture/12`](../architecture/12-three-apps-and-ipc.md#clocks).
The writer bumps its own Lamport clock to
`max(own, highest seen) + 1`, which the sidecar used to do.

**Done when:** an order placed on one instance appears on the other,
an op delivered twice changes nothing the second time, and a test
proves that ops from two peers with unrelated counters are both
delivered.

### 9.4 — Discovery (2 days)

The UDP beacon, the peer list, and the manual address. The port is
chosen at bind time and advertised, so three apps on one machine do not
collide.

**Done when:** an app finds a peer with no configuration on a plain LAN,
and a second app with a manually entered address finds it too.

### 9.5 — Reference data (4 days)

The admin app owns the reference rows and pushes them with a version
number. A peer accepts only a newer version, and keeps the last one it
received when the admin app is away.

**Done when:** a catalogue edit in the admin app reaches the service and
kiosk apps, and a peer that misses it gets it on reconnect.

### 9.6 — Push (3 days)

`GET /v1/events`, held open by the server, read by the client with
`fx.fetch` in `.stream` mode. The kitchen board updates when the order
is placed, not on the next poll.

**Done when:** an order placed on the service app appears on the kiosk
app's board without a poll tick in between.

### 9.7 — Bootstrap, compaction and the three-device proof (6 days)

A device that joins replays the log; a compacted log answers with a
snapshot. The op log grows, so it is summarised. Then the proof: three
apps, three machines, one restaurant, with the admin app closed in the
middle of it.

**Done when:** the kitchen keeps cooking and the till keeps selling
with the admin app closed; a device that has been off for a week
converges; the log is compacted and a new device still converges.

### 9.8 — The three shells (4 days)

Add `apps/admin`, `apps/service` and `apps/kiosk`. Each declares its
role as a constant. Each mounts its own screens and its own import
closure.

This slice is **last before the release**, and that is the point. The
split is not what makes the three apps talk to each other - the
SDK's pathless database does that, and it does it whether there is one
binary or three. The split is a packaging and a safety decision on top
of a fabric that already works, so it belongs at the end of the fabric
and not in the middle of it. See [the order of the slices](#the-order-of-the-slices).

**Done when:** three binaries build; each refuses the screens its role
may not open, by the same code path and the same test as today; the
permission matrix test walks all three; and a restaurant running the
three apps serves a customer exactly as it did when it ran one.

### 9.9 — Packaging (4 days, overlaps Phase 8)

Three signed artifacts, three installs, three updates. The Local
Network permission prompt is part of the kiosk's install, by hand.

**Done when:** three signed builds install on clean machines and the
kiosk asks for the Local Network permission in its own words.

## Exit criterion

- Three apps, three machines, one restaurant, converging with no cloud
  involved.
- The admin app is closed for an hour of service: the till sells, the
  kitchen cooks, the customer display shows the truth.
- An order taken on the service app is advanced on the kiosk app and
  seen on the admin app.
- An op delivered twice changes nothing the second time.
- A device that joins the restaurant reaches the same state as the ones
  that were there at the start.
- The suite proves it: a two-instance convergence test, a three-device
  test on a real LAN, and a test that the net thread never reaches the
  model.

## Risks

| Risk | Mitigation |
|---|---|
| The outbox seam breaks the pure-core rule | 9.0 exists only to find this out, before anything is built on it. If it breaks, the protocol moves to a polling model and the transport gets simpler. |
| **No waiter can sign in on the `service` app** | The installation salt is per app and the hash is matched for equality, so the sign-in does not work across apps as the code stands. Decided: the salt becomes per-employee ([#95](https://github.com/devstroop/ros/issues/95)), and slice 9.0 implements it before the protocol is frozen. |
| A scalar cursor drops ops | The cursor is a vector, per source device, and 9.3 has a test with two peers whose counters disagree. |
| Three apps drift apart | The shared package is one package; the build proves all three compile against it. A fix lands in one place. |
| The protocol changes after devices ship | Freeze it before the first restaurant. `/v1/hello` carries the version and a mismatched peer refuses to talk rather than half-working. |
| Broadcast is blocked, or macOS withholds the Local Network permission | The manual address is a first-class path, not a fallback. The kiosk's install asks for the permission. |
| The op log grows without bound | Compaction is in 9.7, not later. A snapshot is the answer to a device that joins late. |
| Two waiters edit one table's order | Already an open question (A20). The ownership table in `architecture/12` names the one place where a conflict is accepted. |
| The admin app owns too much | Reference data is a small, slow-changing set. If the split is wrong, moving an entity between owners is a protocol change, not a rewrite. |
| Security is a trusted LAN | An explicit decision with a named follow-up: a shared secret in `/v1/hello`. Small, and it should land before the first real restaurant. |

## Unknowns

- **The PIN salt is decided**: per-employee, by
  [#95](https://github.com/devstroop/ros/issues/95). It is the
  first thing slice 9.0 implements, because the sign-in does not work
  across the apps until it lands.
- Is the counter POS the `admin` app or the `service` app? The matrix
  today gives `pos` and `payments` to `admin` only, which puts the till
  on the dedicated machine.
- Does the waiter ever take money? The matrix says no.
- How are peers authenticated?
- How long are ops retained, and what is the compaction rule?
- What happens to a device that is removed from the restaurant?
- Must the Flutter app interoperate during a mixed rollout?

The first three are tracked in
[`open-questions.md`](open-questions.md). See also
[`architecture/12`](../architecture/12-three-apps-and-ipc.md) and
[`architecture/08`](../architecture/08-sync.md).

## Where this sits against the milestones

This phase does not start until M1 is honest. The sale works on one
machine before the fabric is built, because a split that breaks the
sale teaches nothing about the fabric.

It **replaces Phase 6** and **multiplies Phase 8** by three. The
milestone board needs a new line for it, and M3 grows from "two devices
converge" to "three apps converge".
