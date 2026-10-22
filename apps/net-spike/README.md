# Net Spike

The seam between a net thread that owns a socket and a loop thread that
owns the model.

This app exists to answer one question, and it answers it by running:
**can a thread that owns a TCP socket talk to the thread that owns the
model?** The three-app design rests on the answer, so the answer is
proved rather than assumed.

## What it proves

It starts a `std.Io.net` listener on a loopback port, then calls its
own listener with `fx.fetch`. The round trip crosses the seam twice:

```
net thread  --ChannelHandle.post-->  loop thread (update)
net thread  <------- outbox  -------  loop thread (update)
```

| Claim | Where it is proved |
|---|---|
| A `std.Io.net` listener in a `main` thread accepts a connection and speaks HTTP/1.1 | `netThread` in `src/main.zig` |
| `fx.fetch` reaches that listener, and the response arrives as a `Msg` | the `.fetched` arm of `update` |
| Bytes posted with `ChannelHandle.post` arrive as a `Msg` payload | the `.net` arm of `update` |
| A response written by `update` reaches the socket | the outbox, and the `writer` in `netThread` |

Run it and it says so:

```sh
native build
./zig-out/bin/net-spike
```

```
SEAM: the net thread bound port 63627
SEAM: fetch outcome=ok status=200 body="pong" -> SEAM OK
```

## The rule it holds

**The net thread never touches the model and never touches the
database.** It moves bytes. The only state both threads touch is the
outbox, and the outbox is *lock-free*: it is a single-producer,
single-consumer set of slots with two atomic counters each.

That is not a preference. `std.Thread.Mutex` is gone in Zig 0.16, and
`std.Io.Mutex` takes the `Io` it locks against - which `update` does
not have, because `update` is pure. A lock is not available to the code
that needs it, so the outbox does not use one. `update` never blocks
and never waits.

**The outbox is per connection.** A frame carries no peer id, so one
shared ring would let a peer's answer reach another peer - and an
answer left behind by a connection that timed out would be handed to
the next connection that reused the slot. Each connection owns a slot,
and the slot is cleared when the connection is accepted.

## The stop

A thread that owns a socket needs a way to stop, and `accept` blocks,
so a flag alone cannot wake it. The app sets the flag **and** connects
to its own listener, which is what makes `accept` return.

Without that, the app hangs on quit wherever the runtime returns from
`runWithOptions` instead of terminating the process - Linux and
Windows, not macOS, where AppKit's `exit()` hides it. The test "a
listener is woken out of accept by a connection" proves the mechanism
on its own.

## What it does not prove

- A LAN address rather than loopback, which is where macOS's Local
  Network permission may ask the user.
- More than one connection in flight at once. The spike serves one at a
  time on purpose: it is about the seam, not about routing several
  peers. The per-connection slots make room for it.
- The wake-up path a self-pipe would give. The spike polls the outbox
  every 2 ms.

Those belong to slice 9.3 of
[phase 9](../../docs/plan/phase-9-three-apps-and-ipc.md).

## Tests

`native test` runs the deterministic half: the outbox's per-connection
isolation, its refusal and its count, its truncation report, the
request-to-response path through `update`, the wake-up that stops the
net thread, and the three ways a fetch can fail to be the seam. The
live round trip is proved by running the app.

## Commands

```sh
native dev     # build and run the app with hot reload
native test    # run the app's test suite
native build   # produce a ReleaseFast binary in zig-out/bin/
native check   # validate src/*.native markup and app.json
```
