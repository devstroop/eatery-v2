# ADR-0013: Clock-based order IDs

> **Status:** Provisional — in use, expected to be superseded
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/04`](../architecture/04-data-layer.md),
> [`plan/status.md`](../plan/status.md)

## Context

`orders.id` is an `INTEGER PRIMARY KEY` and `orders.order_no` is `TEXT
UNIQUE`. The app needs to create both without a database round trip for a
sequence, and inside a pure update that has no allocator.

The current implementation uses the wall clock:

- `orders.id = fx.wallMs()`
- `order_no = wallMs / 1000` as text
- order line ids = order id + line index

## Decision

**Provisional: use the wall clock as the order identity until a durable
sequence is designed.**

This is accepted as a first-slice shortcut, not as a production identity
scheme.

## Consequences

### Positive

- No extra query, no sequence table, no allocator.
- Readable order numbers ("1749843210").
- Works offline and across restarts.
- Easy to reason about in the POS slice.

### Negative

- **Two orders in the same second collide on the unique order number.**
  A busy counter can do this.
- **Two orders in the same millisecond collide on the primary key.**
- An order rewritten in the same millisecond collides on line ids.
- Clock jumps backwards (NTP, manual change) can reuse ids.
- Multi-device sync makes collisions more likely, not less.
- The order number is not sequential, which some jurisdictions require
  for invoices.

### Follow-ups

- Introduce a sequence: a `next_order_no` row in `app_config`, or a
  dedicated `sequence` table incremented in the same transaction as the
  order insert.
- Or use a UUIDv7-style id with a monotonic component and keep a
  human-readable, jurisdiction-safe invoice number separately.
- Make the write retry on `UNIQUE` conflict with a new id.
- Add a test that places two orders in the same millisecond.

## Alternatives considered

| Alternative | Why not |
|---|---|
| SQLite `AUTOINCREMENT` | The app supplies the id today; the engine would need to return it. Also not portable to sync. |
| UUID | Good uniqueness, but not readable and needs allocation. |
| Sequence row in `app_config` | Correct direction; needs a read-modify-write transaction. |
| Device prefix + counter | Good for multi-device; needs a device id and a persisted counter. |
| Keep the clock | Fast, but collides under load and after clock changes. |

## Evidence

- `src/core/update.zig:418` `placeOrder`.
- `src/core/update.zig:464` `allocOrderNo`.
- `src/schema/0005_orders.sql`: `order_no TEXT NOT NULL UNIQUE`.
- No test covers same-second order placement.
