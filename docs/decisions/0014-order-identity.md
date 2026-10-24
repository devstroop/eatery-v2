# ADR-0014: The order identity

> **Status:** Accepted
> **Date:** 2026-10-21
> **Deciders:** Devstroop maintainers
> **Related:** [`architecture/04`](../architecture/04-data-layer.md),
> [`architecture/05`](../architecture/05-schema.md),
> [`plan/status.md`](../plan/status.md),
> [ADR-0013](0013-clock-based-order-ids.md) (superseded),
> [ADR-0006](0006-integer-money-epoch-ms.md)

## Context

A sale has three names, and they were all the same one:

- `orders.id` was the wall clock in milliseconds;
- `orders.order_no` was the same number, as text;
- a retry of a sale was a second sale, because nothing said the two
  writes were the same one.

That last one is the expensive mistake. A write can land and the answer
can be lost - the database is busy, the connection drops, the app is
closed - and the cashier taps again. From where they stand the sale did
not happen. So the app wrote it again, and the restaurant had two
tickets, one table, and money to take twice.

The other two names were wrong for different reasons. A clock is not a
sequence, so the number on the ticket was not the sequential number a
jurisdiction may ask an invoice to carry. And a clock is not unique:
two sales in the same millisecond wanted the same id, and the write
used to resolve that by updating the order that was already there - two
tickets became one row with one cashier's lines and the other
cashier's status.

## Decision

**The order has three names, and each one does one job.**

1. **The number is a sequence the database assigns.** A `sequence` table
   holds a counter; the order write takes the next number and stores
   the order in one transaction. A sale that fails does not consume a
   number, and the number on the ticket is the number that was stored.
2. **The id is the wall clock, with a floor.** The id is what everything
   else points at. It stays the clock - it is cheap, it sorts, and it
   survives a restart - and a per-device floor keeps it unique within
   the device that minted it.
3. **The request key names the attempt.** It is this device's token and
   the attempt's id, and the database holds one sale per key. A write
   that carries a key the database has seen is a retry, and the order
   that is already there stays.

The number is six digits, so it sorts as the string it is.

## Consequences

### Positive

- A retry is the same sale. The cashier can tap again.
- The number on the ticket counts, and a jurisdiction can read it.
- A failed sale consumes no number, and a retry consumes none either:
  the numbers on the tickets have no gaps.
- Two devices writing to the same database cannot take the same
  number, because SQLite serialises the two transactions.
- The order that a duplicate write used to merge into now fails
  loudly instead.

### Negative

- The id is still unique only within a device. Two devices with two
  databases can mint the same id, and the sync track has to settle that
  when it merges them. The request key is device-scoped, so they cannot
  mistake each other's sale for a retry in the meantime.
- The number is a global count, not a per-day one. A jurisdiction that
  wants a per-day sequence gets it by reading the date and the number
  off the order; if the sequence itself has to be per day, the name of
  the sequence row is the only thing that changes.
- The number is assigned by the database, so the app learns it by
  reading the order back. The confirmation shows the number the
  database gave the order, not the one the app expected.

### Follow-ups

- The sync track owns the cross-device identity: a device-scoped id, or
  a merge that can tell two devices' orders apart.
- The question of whether the number may repeat across devices or days
  is a question for accounting, not for the database, and it is open.
- Refunds and voids need numbers of their own, and they are not
  sequences of the orders.

## Alternatives considered

- **A UUIDv7 or ULID for the id.** Rejected for now: the id is the key
  everything points at, and the sync track will have to give it a
  cross-device story anyway. Making it a 128-bit value now would move
  the schema, the model, and the sync keys for a problem that is not
  yet real. The floor keeps the id unique where the id is minted.
- **Letting the database assign the id as an autoincrement.** Rejected
  for the same reason, and for one more: the app would have to read
  the order back before it could pay for it, and the payment is taken
  against an id the app has to know.
- **A per-day sequence for the number.** Deferred: the mechanism is the
  same, and the scope of the sequence is one name. A global count
  satisfies the "sequential and unique" rule without a day to reset on.
- **Keeping the wall clock for the number and making the write
  idempotent alone.** Rejected: the number would still not be the
  sequential number an invoice may need.
