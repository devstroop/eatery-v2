# ADR-0017: Three apps, one core, TCP/IP between them

> **Status:** Proposed - needs an owner and a go/no-go
> **Date:** 2026-10-21
> **Deciders:** Devstroop maintainers, product
> **Related:** [`0004-four-roles-one-binary.md`](0004-four-roles-one-binary.md)
> (superseded), [`0009-oplog-sync-with-transport-sidecar.md`](0009-oplog-sync-with-transport-sidecar.md)
> (revised), [`architecture/12`](../architecture/12-three-apps-and-ipc.md),
> [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md)

## Context

Six forces make this a decision rather than a preference.

**One binary with four roles puts every capability on every device.**
ADR-0004 chose one binary and a role chosen at launch. The kitchen
screen therefore carries the administrator's PIN form, and the customer
display carries the catalogue editor. A kiosk is an unattended, shared
surface; the ability to walk one into administrator mode is a liability,
not a feature. ADR-0004 already lists the other costs: kiosk actions are
not attributable to an employee, a second window sees the administrator's
session, and a device cannot hand a session between roles without
signing out.

**The split boundary already exists in the code.** `Role.needs_sign_in()`
divides the four roles exactly in two: `admin` and `waiter` sign in with
a PIN, `kds` and `display` sign in by device. That is the seam the
three apps cut along.

**The database cannot be shared.** The Native SDK's relational store is
engine-owned and pathless: the runner opens `app.db` inside the app's own
data directory, keeps the path private, and the SQLite authorizer denies
`ATTACH` and `DETACH`. Each app therefore has its own database, and
three apps on three machines could not share one even if they could. The
database stops being the integration point between devices, and
replication over the network becomes mandatory rather than optional.

**The SDK has no discovery and no inbound effect.** There is no mDNS, no
WebSocket, no UDP broadcast and no listening-socket effect. `fx.fetch`
speaks `http` and `https` to a URL the app names, and nothing in the
effects channel accepts a connection. Zig 0.16 keeps the sockets in
`std.Io.net` - `IpAddress.listen`, `IpAddress.connect`, `Server.accept`,
`Socket.bind` for UDP - and `main` receives the `std.Io` that drives
them as `init.io`.

**The SDK sanctions an app-owned thread.** `fx.openChannel` returns a
`ChannelHandle` whose `post` is thread-safe and produces a `Msg` on the
loop thread. The SDK's own comment names "socket reader" as the
intended producer of a channel. This is the sanctioned seam between a
socket and the pure core.

**The admin app will run on a dedicated, always-on machine.** So the
availability question that has to be answered is not "what happens when
the admin app is closed" but "what happens when *one* of the three is
closed".

## Decision

**Three apps over one shared core, peer to peer, speaking HTTP/1.1 over
raw TCP.**

1. **Three apps.** `admin`, `service` and `kiosk` are separate Native
   SDK apps: separate manifests, separate ids, separate databases,
   separate windows, separate release paths.

   | App | Roles | Sign-in | What it is |
   |---|---|---|---|
   | `admin` | `admin` | PIN | The till and the back office: POS, catalogue, floor, people, money, reports, settings |
   | `service` | `waiter` | PIN | The floor: tables, menu, cart, the orders of the floor |
   | `kiosk` | `kds`, `display` | device | The kitchen board and the customer display |

   The role stops being model state and becomes a constant of the
   binary: the role picker is no longer mounted in `admin` or `service`,
   and in `kiosk` it survives as the one-time choice between the kitchen
   board and the customer display. The permission matrix in `rbac.zig`
   becomes three matrices that are each a subset of the one matrix it is
   today.

2. **One shared core.** The domain, the model, the messages, `update`,
   the repositories and the wire protocol live in one package that all
   three apps depend on. The apps differ in their manifest, their
   `main.zig`, their mounted screens and their import closure - not in
   their logic. The Model is one model; `update` refuses anything the
   app's fixed role may not do, exactly as it refuses a role today.

3. **The transport is HTTP/1.1 with NDJSON bodies, over raw TCP, on
   port 45871.** The client is `fx.fetch`, so the client side of the
   protocol stays inside the effects channel: journaled, replayable,
   cancellable, and testable against the fake executor. The server is a
   thread in `main` that owns `init.io` and speaks HTTP/1.1 to the wire;
   it never touches the model and never touches the database. Push is a
   streamed response - `fx.fetch` in `.stream` mode against an endpoint
   the server holds open.

4. **Discovery is a UDP broadcast beacon on port 45872**, plus a
   manually configured peer address for networks that block broadcast.
   There is no mDNS, so this is a beacon plus a fallback, not a
   zero-configuration answer.

5. **Authority is by discipline, not by a leader.** Each entity class
   has exactly one writer, or is monotonic, so most conflicts cannot
   arise:

   | Entity | Writer | Merge |
   |---|---|---|
   | Company, settings, tax, printers, employees, catalogue, floor | `admin` only | The admin's version wins; a peer accepts only a newer version |
   | An order's content and its lines | the device that created the order | Single writer |
   | An order's status | any device | Monotonic - the furthest along wins |
   | Customers | the device that created the row | Last writer on `(clock, device)` - the one accepted compromise |
   | Devices, operations | append-only | Union |

   The employee row is the one entry in that table that is not yet
   settled: a device can only verify a PIN if the row carries the salt
   it needs, and the salt is currently the **installation's**, which
   each app owns separately. See [the sign-in problem](../architecture/12-three-apps-and-ipc.md#the-sign-in-problem).
   The protocol does not change either way - the row replicates as
   reference data - but the row's contents do, and that has to be
   decided before the protocol is frozen.

6. **The op log is the wire format.** ADR-0009's `op_log` table becomes
   the payload of the protocol rather than a table a sidecar polls. The
   record's field names are the column names, so the table and the wire
   are the same record; three columns that only meant something under
   the sidecar - `previous_json`, `host_id`, `parent_id` - are not
   carried. The WebSocket sidecar is not built, and the peers speak to
   each other.

7. **The cursor is a vector, not a number.** Each device has its own
   Lamport counter, and the counters of different devices are
   unrelated, so a single cursor cannot say what a peer has seen. A
   device tracks the highest clock it has applied **per source device**,
   and asks for what is missing from each source separately. A scalar
   cursor silently drops ops whenever two devices' counters disagree,
   which is the normal case, not the edge case.

## Consequences

### Positive

- A kiosk cannot become an administrator terminal: the capability is not
  in the binary, so there is nothing to mis-click into.
- The kitchen and the customer display are small, quiet programs that
  can be updated on their own schedule.
- No device is a single point of failure. The kitchen keeps cooking when
  the manager's laptop is asleep, because the kitchen holds the order
  it was given.
- Convergence is defined per entity class, so the interesting conflicts
  cannot occur rather than being resolved after the fact.
- The client half of the protocol is ordinary SDK effects: no new
  impurity enters `update`, and the fake executor tests it for free.
- The schema stays identical in all three apps, because it is one
  migration chain in one shared package.

### Negative

- **The sign-in does not work across the apps until the salt is
  settled.** The PIN hash is computed from the *installation* salt and
  the sign-in finds the employee by matching that hash for equality.
  Each app has its own installation salt, so the `service` app cannot
  verify a waiter's PIN as the code stands. **Answered: the salt
  becomes per-employee**, by
  [#95](https://github.com/devstroop/ros/issues/95) - the sign-in
  identifies the employee before it hashes, so the row is
  self-verifying and no shared secret has to cross the wire.
- Three manifests, three apps to sign, three update paths, three
  supported versions of the same protocol.
- The shared core must not drift between apps; the build has to prove
  all three compile against one package version, or a fix that lands in
  one app and not the others is a bug that ships.
- A device that joins the restaurant has to be bootstrapped. The op log
  is the history, so it can be replayed, but it grows and needs
  compaction.
- UDP broadcast is blocked by some managed and guest networks, and
  macOS asks the user for Local Network permission. A kiosk that is
  installed by hand needs that permission granted by hand.
- The net thread is the one part of an app that is not inside the
  effects channel, and it is the part that must never reach the model.
- A vector cursor is more state to keep than a number, and it has to
  survive a restart.

### Follow-ups

- **Settle the PIN salt** (per-employee, or replicate the installation
  salt). It blocks the sign-in and it is a product decision as much as
  an engineering one. **Answered: per-employee**, by
  [#95](https://github.com/devstroop/ros/issues/95).
- Decide the wire framing in detail and freeze it before the first
  device ships: a protocol that three apps and two app versions must
  agree on is not something to change in flight.
- Decide peer authentication. A trusted LAN is the default and an
  explicit decision, not an omission.
- Decide whether the admin app is the preferred bootstrap peer and the
  reference-data seed, or whether any peer may serve either.
- Decide how a device that has been offline for a week reconciles.
- Decide what happens to a device that is removed from the restaurant.
- Decide the op-log retention and compaction rule, and whether
  `previous_json`, `host_id` and `parent_id` are dropped by a later
  migration.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Four binaries, one per role | `admin` and `service` share a shell and a sign-in model, and `kds` and `display` are the same program with a different board. Four binaries is four copies of the same bug and four release paths. |
| One binary, role at launch (ADR-0004) | The kiosk liability above, and a role picker is a screen a shared device can be walked into. It also keeps the shared session state ADR-0004 lists as a cost. |
| The admin app as the hub | It makes one device a single point of failure and turns "the admin app is closed" into a special case in every screen. The admin app is on a dedicated machine, so it *could* be the hub - but a peer design survives that case without a special case, and the hub can be layered on later as a preferred peer. |
| A fourth hub daemon | A fourth artifact to install, sign, update and support, in a restaurant with three devices. |
| WebSocket and mDNS, as v1 | The SDK has neither, and both would have to live in a sidecar - the extra artifact just rejected. |
| HTTP only, with no raw TCP | `fx.fetch` is a client and nothing accepts a connection. Somebody has to listen, and the only listener available is one written against `std.Io.net`. |
| One SQLite file shared by the apps | The database boundary is pathless and `ATTACH` is denied. It also does nothing for the three-machine case, which is the case that matters. |
| A web admin with native clients | Adds a second stack and a browser to a product whose whole point is a local, offline, desktop-native tool. |

## Evidence

Everything below was read from the source, not from the docs. The
paths are given so a reader can check the claim rather than trust it.

**In this repository** (`apps/ros/`):

- `src/core/navigation.zig`: `Role.needs_sign_in()` - the split
  boundary is already in the code.
- `src/core/rbac.zig`: `allows`, `home`, `nav_sections` - the
  permission matrix, which becomes three.
- `src/schema/0010_sync.sql`: `device`, `op_log`, `sync_state` - the
  wire format this reuses; `device.role`'s CHECK constrains the
  vocabulary the beacon must use.
- `src/data/auth.zig`: `hashPin` derives the bcrypt salt from the
  installation salt, and `deriveSalt` says why.
- `src/data/repos.zig`: `login_sql` matches the computed hash for
  equality, and `saveSalt` writes the installation salt once.
- `src/main.zig`: `auth.makeSalt(init.io, ...)` - the salt is made
  per installation, and each app is its own installation.
- [`architecture/08`](../architecture/08-sync.md): the
  transport-out, protocol-in shape this refines.

**Proved by running it** - `apps/net-spike`, in this repository, in
the suite. A net thread with a real listener and an app with a real
model, calling its own listener:

- a `std.Io.net` listener in a `main` thread accepts a connection and
  serves HTTP/1.1;
- `fx.fetch` reaches it, and the response arrives as a `Msg`;
- bytes posted with `ChannelHandle.post` arrive as a `Msg` payload, and
  a response written by `update` reaches the socket.

```
SEAM: the net thread bound port 63627
SEAM: fetch outcome=ok status=200 body="pong" -> SEAM OK
```

It settled that the outbox needs **no lock**: `std.Thread.Mutex` is
gone in Zig 0.16 and `std.Io.Mutex` needs the `Io` that `update` does
not have, so the ring is single-producer/single-consumer and two
atomic counters do the job. It settled that the outbox must be **per
connection**, because a frame carries no peer id and an answer could
otherwise reach the wrong peer. It settled that a thread owning a
socket needs a **stop** that makes `accept` return, because a flag
alone cannot. And it settled that plain `http://` works, because the
SDK's fetch is built on Zig's `std.http.Client` rather than on the
platform's, so App Transport Security does not apply.

**In the Native SDK** (`~/native-sdk`, v0.11.0):

- `src/runtime/effects.zig`: `FetchOptions` - the `url` is "http:// or
  https://", and `response` is `.buffered` or `.stream` with
  `on_line`; `openChannel` and `ChannelHandle.post` - the thread-safe
  post that produces a `Msg`.
- `src/runtime/relational_store.zig`: `Database.open(allocator,
  data_dir)` opens `<data_dir>/app.db`; the authorizer denies `ATTACH`.
- `docs/content/docs/sqlite.mdx`: "The database boundary stays
  pathless."
- `docs/content/docs/security.mdx`: the `network` permission is "network
  requests from native code"; no listener, socket or discovery effect
  is offered anywhere in the effects channel.

**In Zig 0.16.0** (`/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std`):

- `Io/net.zig`: `IpAddress.listen`, `IpAddress.connect`,
  `Server.accept`, `Socket.bind` with `allow_broadcast` - TCP and UDP
  without a `std.net`, which no longer exists in 0.16.
- `Io/Dispatch.zig`: the poll/kqueue abstraction a thread uses to wait
  on a socket and a wake-up pipe at once.

To re-check the SDK claims: `grep -n "pub fn openChannel\|pub const FetchOptions" ~/native-sdk/src/runtime/effects.zig`.
To re-check the Zig claims: `grep -n "pub fn listen\|pub fn connect" /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Io/net.zig`.
