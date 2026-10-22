# Three apps and the protocol between them

> **Status:** Target design. The three shells exist and build
> ([slice 9.1 and the shell split](../plan/phase-9-three-apps-and-ipc.md));
> the fabric between them does not. The decision is
> [ADR-0017](../decisions/0017-three-apps-over-tcp-ip.md); the delivery
> order is [`plan/phase-9`](../plan/phase-9-three-apps-and-ipc.md).
> **Last reviewed:** 2026-10-23, after `apps/ros` became `apps/admin`.

## What this page is

The product stops being one binary with four roles and becomes three
apps that talk to each other over TCP/IP. This page says which screens
live in which app, what the wire looks like, who owns which piece of
data, and what happens when a device is off, unreachable or new.

It is the target, not the as-built. The as-built picture is
[`plan/status.md`](../plan/status.md).

## The three apps

| App | Role | Sign-in | Home | Screens |
|---|---|---|---|---|
| `admin` | `admin` | PIN | `admin_dashboard` | 50 |
| `service` | `waiter` | PIN | `waiter_tables` | 9 |
| `kiosk` | `kds` or `display`, chosen at install | device | `kds_board` or `display_board` | 3 per mode |

Each app is a separate Native SDK app: its own `app.json`, its own id
(`com.devstroop.ros.admin`, `com.devstroop.ros.service`, `com.devstroop.ros.kiosk`),
its own window, its own engine-owned database in its own app-data
directory, and its own release artifact.

### The screen partition

The split follows the permission matrix in `src/core/rbac.zig` exactly.
`Role.needs_sign_in()` is already the boundary: `admin` and `waiter`
sign in with a PIN, `kds` and `display` sign in by device.

The counts are read off the enum and the matrix, not estimated. The
`admin` app mounts the 50 screens the admin role may open, less the
three every app shares; the `service` app mounts the 9 the waiter role
may open, less those three; the `kiosk` app mounts 3 per mode - its
board and `order_detail` - plus the person picker and the sign-in.

**These counts move, and they have moved.** The first draft of this
page said 38, 11 and 3, read off the enum as it stood on 2026-10-21.
The enum has grown since - the back office added the payments, the
report, the stock, the dishes, the control centre, the database
inspector, the customer and modifier forms, the cart, the table
categories and the floor plan - and the numbers with it. The counts
here are read off the tree **this phase will be built on**, which is
the back office merged: 53 screens in the enum, 50 for the admin app.

The partition is not something to maintain by hand. The matrix is
walked against the enum by a test in `src/tests.zig`, and the shell's
gates are pinned to the enum by another, so a screen cannot be added
or moved without a test saying so. The table below is the partition
those two tests describe.

| Screen group | admin | service | kiosk |
|---|---|---|---|
| `admin_dashboard`, `control_center` | ● | | |
| `pos`, `pos_cart` | ● | | |
| `orders` | ● | ● | |
| `order_detail` | ● | ● | ● |
| `order_confirmation` | ● | ● | |
| `payments` | ● | | |
| `customers` | ● | ● | |
| `dining_tables`, `table_categories`, `floor_plan`, `reservations` | ● | | |
| `kitchen_dishes`, `inventory_items`, `product_categories`, `suppliers`, `purchase_orders` | ● | | |
| `employees`, `employee_form`, `reports` | ● | | |
| `settings`, `settings_company`, `settings_currency`, `settings_tax`, `settings_modifiers`, `settings_discounts`, `settings_printers`, `data_management`, `db_inspector` | ● | | |
| `product_form` | ● | | |
| `tax_slab_form`, `discount_form`, `category_form`, `categories` | ● | | |
| `modifier_group_form`, `customer_form`, `table_category_form`, `stock_count` | ● | | |
| `waiter_tables`, `waiter_menu`, `waiter_cart`, `waiter_orders` | | ● | |
| `kds_board` | | | ● in kitchen mode |
| `display_board` | | | ● in display mode |
| `login` | ● | ● | ● |
| `landing`, `reset_pin` | ● | ● | |
| `setup`, `wizard`, `create_company`, `upgrade` | ● | | |
| `role_picker` (the person picker) | ● | ● | ● |

`role_picker` is the one screen whose meaning changes, and **it is
mounted in all three apps** - which is a change from the first draft of
this page, and the change is a correction.

Under [ADR-0018](../decisions/0018-the-pin-hash-is-the-employees.md)
the sign-in names the *person* and the PIN says they are that person.
So the picker is no longer a choice between four roles: it is a list of
the people who work here, each with the mode they work in, and it is
the way in to the PIN. `admin` and `service` both sign in with a PIN,
so both need it. In `kiosk` it carries the two device modes as well -
the kitchen board and the customer display are not people, and nobody
types a PIN into them - and the choice is stored in the device's
configuration.

The first draft of this page said the picker survived only in `kiosk`.
That was written against the salt being settled but not implemented, and
it does not match the code: `pick_employee` in `core/update.zig` is the
entry to the PIN, and the login screen refuses a sign-in with "Choose
who you are first" when it has not been sent. The enum's name stays -
the enum is append-only - but the screen behind it is the **person
picker** now, and it is mounted wherever a person signs in.

The `Screen` enum stays append-only. Nothing is renumbered and no
ordinal moves: the markup's contract is the enum's order, and the
partition is expressed by what each app *mounts*, not by renumbering.

### One model, three shells

The apps do not carry three copies of the logic. There is one shared
package with the domain, the model, the messages, `update`, the
repositories and the protocol. The apps differ in:

- the manifest and the id;
- `main.zig`, which declares the app's fixed role;
- `app.native`, which mounts that role's screens;
- `app_sources.zig`, the import closure of those screens.

`Role` stops being model state. It is a constant of the binary, and
`rbac.allows` is evaluated against it exactly as it is today - so the
refusal path, and its test, do not change.

## What one app looks like inside

```
┌────────────────────────────────────────────────────────────────────────┐
│                                                                        │
│  loop thread                            net thread (started in main)   │
│  ┌                            ┐         ┌                        ┐     │
│  │ UiApp                      │         │ std.Io.net             │     │
│  │   Model ◀─ update ─▶ Msg   │         │  TCP listen :45871     │     │
│  │     ▲                      │         │   accept → HTTP/1.1    │     │
│  │     │ fx.dbQuery / dbExec  │         │  UDP beacon :45872     │     │
│  │     │ fx.fetch  (client)   │         │       │                │     │
│  │     │ fx.openChannel       │◀────────┤ post(ChannelHandle)    │     │
│  │     │ fx.startTimer        │         └                        ┘     │
│  └                            ┘                                        │
│         ▲                            │                                 │
│         │                                                              │
│                              ┌───────┴───────┐                         │
│                              │    outbox     │                         │
│                              └───────────────┘                         │
│  SQLite (engine-owned, one database per app)                           │
└────────────────────────────────────────────────────────────────────────┘
```

### The rule that keeps this honest

**The net thread never touches the model and never touches the
database.** It moves bytes. That is the whole of it.

- **Thread to app:** the net thread posts the received bytes with
  `ChannelHandle.post`. The SDK delivers them as a `Msg`, so the bytes
  arrive as a message payload rather than as a drain of a queue. The
  pure-core rule survives: `update` is still a function of the model and
  the message it was given.
- **App to thread:** the SDK has no channel that runs the other way, so
  the app owns a small, bounded outbox. `update` writes an answer into
  it; the net thread reads the answer back and writes it to the socket.
  The net thread is woken by a self-pipe where the platform offers one
  (`std.Io.Dispatch`), and by a short timed poll where it does not.
- **The handshake:** the net thread cannot post into a channel that
  does not exist yet, and the channel can only be opened from `update`,
  which is the loop thread's job. So the loop thread opens it and
  publishes the handle; the net thread waits for it. One atomic flag
  and one handle.
- **The stop:** a thread that owns a socket needs a way to stop, and
  `accept` blocks, so a flag alone cannot wake it. The app sets the
  flag and connects to its own listener, which is the portable way to
  make `accept` return.

This outbox is the one piece of shared mutable state in an app. It is
app-owned memory, not the world: no clock, no allocator, no I/O happens
in `update`. It is called out here because it is the one place the
design bends, and because a reader should be able to find it.

**It does not need a lock, and that is a finding rather than a
preference.** `std.Thread.Mutex` is gone in Zig 0.16, and
`std.Io.Mutex` takes the `Io` it locks against - which `update` does
not have, because `update` is pure and has no `Io`. A mutex is
therefore not available to the code that needs it. The outbox is
single-producer and single-consumer: the loop thread is the only
writer and the net thread is the only reader. Two atomic counters are
enough, with a release store after a write and an acquire load before
a read. `update` never blocks, and it never waits.

**The outbox is per connection, not one shared ring.** A frame carries
no peer id, so a shared ring would let one peer's answer reach
another peer - and a leftover answer from a connection that timed out
would be handed to the next connection that reused the slot. Each
connection owns a slot, and the slot is cleared when the connection is
accepted. The protocol will have several peers connected to one app at
once, so this is not a nicety: it is the difference between an answer
and the wrong answer.

### What the spike proved

`apps/net-spike` is the proof, and it runs in the repository's own
suite. It is a net thread with a real listener and a real app with a
real model, and it does one thing: it calls its own listener.

| Claim | How it is proved |
|---|---|
| A `std.Io.net` listener in a `main` thread accepts a connection and speaks HTTP/1.1 | The app fetches its own listener and gets a 200 |
| `fx.fetch` reaches that listener, and the response arrives as a `Msg` | The body arrives in the model as a `.fetched` message |
| Bytes posted from the net thread arrive as a `Msg` payload | The app copies them out of the message and answers |
| A response written by `update` reaches the socket | The fetch gets back the response `update` wrote |

The round trip, from the app's own log:

```
SEAM: the net thread bound port 63627
SEAM: fetch outcome=ok status=200 body="pong" -> SEAM OK
```

Seven things the spike settled that the design had assumed:

1. **The outbox is lock-free**, as above. The design said "lock
   protected"; the code says "two atomics", because a lock is not
   available to `update`.
2. **The outbox is per connection.** The first version of the spike
   used one shared ring, and the review found the hole: a frame
   carries no peer id, so an answer could reach the wrong peer, and an
   answer left behind by a timed-out connection would be handed to the
   next one. The slots fixed both, and the test that proves it is
   "an answer never crosses to another connection".
3. **The port is learned as bytes.** The net thread posts `PORT 45123`
   and the app reads it out of a message, so the model is the only
   place the port lives. A shared variable would have been a second
   source of truth.
4. **Plain `http://` works.** The SDK's fetch is built on Zig's own
   `std.http.Client`, not on the platform's, so macOS App Transport
   Security does not stand in the way of a LAN address.
5. **The channel's bytes are drain scratch.** They are valid only for
   the `update` call that receives them, so the app copies them. This
   is the same rule the database's page bytes follow.
6. **A thread that owns a socket needs a stop, and a flag is not
   enough.** `accept` blocks. The app sets a flag *and* connects to
   its own listener, which is what makes `accept` return. Without it
   the app hangs on quit wherever the runtime returns from
   `runWithOptions` instead of terminating the process - which is
   Linux and Windows, and not macOS, where AppKit's `exit()` hides it.
7. **An answer that does not fit must say so.** The read reports the
   frame's full length, so the caller can refuse rather than write
   half a response to a socket.

The spike binds the address it is told to bind, so the LAN path can be
exercised without a rebuild:

```sh
ROS_SPIKE_BIND=192.168.1.42 ./zig-out/bin/net-spike
```

What the spike still does **not** prove, and what a later slice must:
a peer on a **different** machine - the spike fetches its own listener,
so the traffic never leaves the host, and a loopback or same-subnet
path proves the seam but not the network; more than one connection in
flight at once, which the per-connection slots make room for but the
spike does not exercise; and the wake-up path that a self-pipe would
give. The macOS Local Network permission is also still untested: it is
asked the first time an app opens a socket to a local-network address,
which is exactly what the LAN bind does, and a machine that has never
been asked will show the prompt.

### Why the client is `fx.fetch` and not a socket

The client half of the protocol is ordinary SDK effects. That means:

- it is journaled, so a recorded session replays;
- it is cancellable, so a request in flight can be dropped by key;
- it is testable against the fake executor, with no socket in the test;
- it is timed out and bounded by the SDK, not by our discipline.

Only the server half is ours. A peer is both, so each app carries a
listener - but the listener is a byte pipe, and the app is the only
thing that knows what a byte means.

## The protocol

HTTP/1.1 over raw TCP. The default port is **45871**, and a device
advertises the port it actually bound (see [Discovery](#discovery)).
Bodies are NDJSON: one JSON object per line,
`Content-Type: application/x-ndjson`.

HTTP is chosen over a bespoke framing for three reasons: `fx.fetch`
speaks it, so the client needs no code; it is debuggable with `curl` and
`nc` from a support laptop; and it is a framing that a future web client
could speak without a second protocol.

### Endpoints

| Endpoint | Direction | Body | Purpose |
|---|---|---|---|
| `GET /v1/hello` | peer → peer | — | The peer card: device id, role, protocol version, app version, local clock |
| `GET /v1/ops?since=<cursor>` | peer → peer | NDJSON out | Every op the peer holds that the cursor does not already cover |
| `POST /v1/ops` | peer → peer | NDJSON in | Ops this peer produced |
| `GET /v1/reference?after=<version>` | admin → peer | NDJSON out | Admin-owned reference rows above a version |
| `GET /v1/snapshot` | peer → peer | NDJSON out | A compacted base state, for a device that joins late |
| `GET /v1/events` | peer → peer | NDJSON out | A long-lived stream of push notifications |

`GET /v1/events` is the push path. The server holds the response open
and writes a line as something happens; the client reads it with
`fx.fetch` in `.stream` mode, and each line arrives as a `Msg`. A
poll on a timer is the fallback, and the two coexist: the stream makes
the common case immediate, the poll makes the system converge even if
the stream is dropped.

### Records

An operation is one line:

```json
{"id":"dev-3:1042:7","entity_table":"order","entity_id":"O-000123",
 "operation":"create","logical_clock":1042,"device_id":"dev-3",
 "created_at":1758000000000,"data":{"table_id":12,"status":"pending"}}
```

| Field | `op_log` column | Meaning |
|---|---|---|
| `id` | `id` | Globally unique: `<device_id>:<clock>:<sequence>` |
| `entity_table` | `entity_table` | What the operation touched |
| `entity_id` | `entity_id` | The row's key |
| `operation` | `operation` | `create`, `update` or `delete` |
| `logical_clock` | `logical_clock` | The Lamport counter of the writer |
| `device_id` | `device_id` | The writer |
| `created_at` | `created_at` | Epoch milliseconds |
| `data` | `data_json` | The row snapshot after the operation |

The wire names are the column names, so the table and the wire are the
same record and only two things differ:

- `data_json` is a JSON **string** in the column and a nested **object**
  on the wire. It is the same value in two encodings, so the codec is
  parse-into-an-object on the way in and serialise-on-the-way-out, not
  a translation.
- Three columns are **not carried**: `previous_json`, `host_id` and
  `parent_id`. They only had meaning under the host-elected sidecar
  that this design replaces - a host, and a causality chain between
  hosts. The receiving side writes `'{}'` and `''` for them. They are
  columns in a shipped migration, so they stay; a later migration can
  drop them.

An operation is **idempotent**: applying one whose `id` is already known
is a no-op, which is what makes a repeated delivery, a reconnect and a
re-ask all safe.

Two rules govern every value on the wire:

- **Money is an integer in minor units.** No float crosses the wire, and
  the decoder rejects a fractional part rather than truncating it.
- **Time is epoch milliseconds.** One shape for every timestamp.

### Clocks

There is no leader, so the clock cannot be a single number that means
"everything I have seen". Each device has its own Lamport counter, and
the counters of different devices are unrelated.

**Writing.** Before it writes an op, a device sets
`logical_clock = max(its own clock, the highest clock it has seen from
any source) + 1`. That is the rule the sidecar used to apply, now
applied by the writer itself, because the sidecar is gone.

**The cursor is a vector.** A device that has applied ops from three
peers has three separate positions, one per source, and a single
scalar cursor cannot express them. The cursor is therefore a map from
device id to the highest `logical_clock` applied from that device:

```
GET /v1/ops?since=dev-1:1042,dev-3:87
```

and the peer answers with every op whose `(device_id, logical_clock)` is
above the cursor **for that device**.

Why a scalar is wrong, concretely: device C is partitioned. B takes an
order at B's clock 20. A takes an order at A's clock 500. C reconnects,
pulls from A first - its cursor for A becomes 500 - and then pulls from
B with a single scalar of 500. **B's op 20 is below the cursor and is
never delivered**, and C silently never converges. The vector cursor
does not have this failure, because B's position is tracked separately
from A's.

The `id` of an op stays `<device_id>:<clock>:<sequence>`, so a repeated
delivery is still recognisable without trusting the cursor.

### Discovery

There is no mDNS in the SDK, so discovery is a **UDP broadcast beacon**
on port **45872**, sent every five seconds:

```json
{"proto":"ros/1","device":"dev-3","role":"kds",
 "host":"192.168.1.42","tcp":45892}
```

The `role` is the **device table's vocabulary** - `admin`, `waiter`,
`kds` or `display` - because that is what `device.role` accepts
(`src/schema/0010_sync.sql` constrains it with a CHECK, and that table
is in the shared schema all three apps migrate). The kiosk *app* has
two modes, and the device row records the mode it is in: `kds` on a
kitchen screen, `display` on a customer-facing one. A peer that reads
`kds` knows to expect tickets, and one that reads `display` knows to
expect a status board.

The role travels with the beacon, so a peer learns both that a device
exists and whether it is the admin it should ask for reference data.

**The port is chosen at bind time and advertised.** Nothing listens on a
fixed port by default, because three apps on one machine - which is how
this is developed and demonstrated - would collide on one. A device
binds an ephemeral port and puts the port it got into its beacon. The
fixed port is a convenience for the admin app only, and even there it is
a fallback to the ephemeral one.

Broadcast is blocked by some managed and guest networks, and macOS asks
the user for Local Network permission the first time a socket is used.
So every app also accepts a **manually configured peer address**, and
the admin app keeps a list of the devices it has seen. A restaurant that
blocks broadcast configures one address per device and never thinks
about it again.

### Bootstrap

A device that has never seen the restaurant asks for `/v1/ops` with an
empty cursor and replays the log. The log is the history, so replay
*is* the state. When the log is compacted, the peer answers
`/v1/snapshot` instead: a base state plus the per-device clocks it was
taken at.

A device that has been offline for a week replays the ops it missed,
from whichever peer holds them. Because ops are idempotent and the
cursor is per source device, replaying a range a peer has already sent
costs nothing but time - and a range from one peer can never hide a
range from another.

## Who owns what

The rule is that a conflict is impossible wherever it can be made
impossible, and only accepted where it cannot.

| Entity | Writer | How it reaches other devices | Merge |
|---|---|---|---|
| Company, settings, tax slabs, printers | `admin` | `GET /v1/reference` | The admin's row wins; a peer accepts only a newer version |
| Employees and PINs | `admin` | `GET /v1/reference` | Same - but see [The sign-in problem](#the-sign-in-problem) before trusting this row |
| Product categories, products, modifier groups | `admin` | `GET /v1/reference` | Same |
| Dining tables, table categories | `admin` | `GET /v1/reference` | Same |
| Customers | the device that created the row | ops | Last writer - on the **vector** clock and then the device id, because two devices' scalar clocks are not comparable |
| An order's content and its lines | the device that created the order | ops | Single writer - nobody else writes it |
| An order's status | any device | ops | Monotonic: the furthest along wins |
| Payments | the device that took the money | ops | Single writer, idempotent by request key ([ADR-0014](../decisions/0014-order-identity.md)) |
| Devices | each device, for itself | ops | Insert-only |

Two properties fall out of this and both are worth stating plainly:

- **Reference data cannot conflict.** One writer means there is never a
  second opinion about the menu.
- **Order status cannot conflict.** The status machine only moves
  forward, so "furthest along wins" is not a heuristic - it is the
  merge of two monotonic values.

What is left is the genuinely hard case, and it is already an open
question in the plan: two waiters editing the same table's order at the
same time ([`open-questions.md` A20](../plan/open-questions.md)).

## The sign-in problem

**This is a blocker, and it is not solved by the protocol.** It is
recorded here because the three apps cannot work without settling it,
and because a reader who takes the ownership table at face value will
build the service app and then find that no waiter can sign in.

The mechanism, as it stands:

- `data/auth.zig` `hashPin` derives the bcrypt salt from the
  **installation salt** (`deriveSalt`), so a hash is a function of
  (installation salt, PIN) and of nothing else.
- `data/repos.zig` `login_sql` finds the employee by **matching the
  computed hash for equality**:
  `WHERE (pin_hash = ?1 OR pin_hash = ?2) AND role = ?3 AND active = 1`.
- `data/auth.zig` says why it is written that way: a random
  per-employee salt "would mean trying every employee in turn, and a
  slow hash for each of them".
- The installation salt is generated once per **installation**
  (`main.zig` calls `auth.makeSalt`) and stored in `app_config.pin_salt`
  by `repos.saveSalt`, which is `ON CONFLICT DO NOTHING` - written once
  and never replaced.

Each app has its own database in its own data directory, so **each app
has its own installation salt**. The employee hashes were computed
against the admin app's salt. The service app computes
`hashPin(service_salt, "123456")`, which is a different bcrypt string
from the stored one, the equality match misses, and **the waiter cannot
sign in** - including in exactly the case the design is built for: the
admin app is closed.

There are two ways out.

### Option A - replicate the installation salt

The salt becomes reference data owned by the admin app, exactly like the
employee rows. The service app stores it and the existing sign-in path
works unchanged: no schema change, no migration, no UX change.

The cost is that a **shared secret crosses the wire in plain HTTP**,
and a stolen service device's database becomes as crackable as the
admin's is today. It also contradicts the security claim below.

### Option B - the salt becomes per employee

`employee` grows a per-employee random salt. A bcrypt crypt string
already embeds its own salt, so the row becomes **self-verifying**: any
device holding the row can verify the PIN with one `bcrypt.strVerify`
and needs nothing else.

The sign-in then has to identify the employee before it hashes - which
is exactly the follow-up ADR-0016 already records: *"The per-employee
salt, when the sign-in can identify the employee before it hashes: an
employee picker makes the salt per employee and the login one hash."*
The alternatives are an employee picker (one hash) or trying the
active employees of that role in turn (one hash each, a few hundred
milliseconds at cost 2^10).

The cost is a schema migration and a sign-in flow change, which is a
product decision.

### The recommendation

**Option B.** It is the one that keeps the wire free of a shared
secret, it is the recorded follow-up of an accepted decision, and it
makes a replicated employee row self-verifying - which is the property
the whole three-app design needs. Option A is cheaper to build and
weakens the threat model in a way that is awkward to undo later, because
once a secret has crossed a wire in plaintext it has crossed it.

The question belongs to the product as much as to engineering, so it is
[open question D19](../plan/open-questions.md) and it must be answered
before the protocol is frozen - not during the implementation of it.

**It is answered: the salt becomes per-employee**, by
[#95](https://github.com/devstroop/ros/issues/95) - the sign-in
identifies the employee before it hashes, so the row is self-verifying
and no shared secret crosses the wire. That issue also plans the picker
*in place of the role picker*, which the three-app split makes
convenient: the `service` app signs in by picking an employee, and the
role picker is only still needed by `kiosk`, for the choice between the
kitchen board and the customer display.

Whichever way it goes, one thing is settled now: **the employee row
replicates as reference data, and the row must contain everything a
device needs to verify a PIN offline.** A row that needs a second,
separately replicated secret is the thing to avoid.

## Failure modes

| Failure | What happens | What it costs |
|---|---|---|
| A device is off | The others keep working. Reference data is the last version they received; orders keep their own writers. | Nothing, until the device returns |
| The admin app is off | The till keeps selling; the kitchen keeps cooking. Only *changes to the menu* wait. | New catalogue edits are deferred |
| The network is down | Every device writes locally and queues its ops. The orders are taken. | Convergence is late, not lost |
| A peer is unreachable | The fetch fails, is classified, and is retried on the next tick | A stale board for a moment |
| A frame is dropped | The channel's back-pressure drops it; the pull path asks again from the cursor it held | A duplicated request, never a lost order |
| A duplicate op arrives | Applying an op whose id is known is a no-op | Nothing |
| Two devices write the same order's status | Both advance; the merge keeps the furthest along | Nothing |
| A device is removed from the restaurant | Its ops stay in the log; its reference rows stop being served | Needs a policy - see the follow-ups |
| The protocol version differs | `/v1/hello` reports it and the peer refuses to talk | A device must be updated |

## Security

The trust model is a trusted LAN, and it is a decision rather than an
omission: a restaurant's devices sit on a network the owner controls,
and the alternative - pairing, certificates, a key exchange - is a
second product.

What that means concretely:

- Every peer can read the reference data and the ops. A device that
  joins the LAN is a device in the restaurant.
- **PINs are never sent.** The digits a cashier types never leave the
  device. What crosses the wire is the **hash** - and, under the salt
  as it stands today, the **installation salt** as well, because the
  hash is computed from it. That is why
  [the sign-in problem](#the-sign-in-problem) has to be settled before
  this section can be called accurate: a peer must receive a row it can
  verify a PIN against, and the salt question decides whether that row
  is self-verifying or whether a shared secret has to travel with it.
- Money is never trusted from a peer: an order's total is recomputed
  from its lines by the device that owns the order.
- The wire is plain HTTP on the LAN. It is readable by anyone on the
  wire, and that is a known, accepted cost.

The follow-up is peer authentication: a shared secret in the admin app's
settings, presented in `/v1/hello`. That is a small change to one
endpoint and it should be decided before the first restaurant runs on
this.

## The shared package

```
apps/
  admin/
    app.json                 id: com.devstroop.ros.admin
    src/main.zig             the role constant, the shell
    src/app.native           mounts the admin screens
    src/app_sources.zig      the import closure
  service/
    app.json                 id: com.devstroop.ros.service
  kiosk/
    app.json                 id: com.devstroop.ros.kiosk
packages/
  ros-core/
    build.zig  build.zig.zon
    src/
      core/     model, msg, update, navigation, rbac, theme, bump
      data/     repos, page, auth
      domain/   models
      net/      the protocol: frames, the client, the server, discovery
      schema/   0001..0015_*.sql and the migration lock
```

Each app ejects its build (`native eject`) so it owns a `build.zig` that
depends on `packages/ros-core` as a path dependency and adds the
shared module as an import. The generated build graph is regenerated by
the CLI on every `native dev`, so the dependency has to live in the
ejected file.

`scripts/verify-all.sh` and `scripts/build.sh` already loop over
`apps/*/`, so three apps are picked up without changes.

The schema stays in the shared package, so all three apps run the same
migration chain. That is what keeps the op log and the reference rows
meaningful across the three databases.

## What is not decided here

- **The PIN salt.** The sign-in problem above is a blocker: either the
  installation salt replicates as reference data, or it becomes
  per-employee. The second is the recommendation, and it is a product
  decision as much as an engineering one.
- Whether the counter POS is the `admin` app or the `service` app.
  Today the permission matrix gives `pos` and `payments` to `admin`
  only, which puts the till on the dedicated machine. If the till is a
  counter tablet, the matrix has to change and the partition with it.
- Peer authentication (see Security).
- Compaction: how the log is summarised into a snapshot, and when.
- Whether a removed device's ops are retained.
- The port numbers, which are a proposal, not a reservation.

The first three are tracked as open questions. The rest belong to the
phase that needs them.
