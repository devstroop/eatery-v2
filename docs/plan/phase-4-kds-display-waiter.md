# Phase 4 — KDS, display and waiter

> **Status:** Partial
> **Estimate:** 6 engineer-days
> **Depends on:** Phase 3
> **Exit criterion:** an order created in the POS appears on the KDS without
> a restart, the display reflects it, and the waiter flow is usable.

## Goal

The other three roles. The kitchen is the one that must be flawless: a
missed ticket is a lost meal.

## What exists

- Kitchen board: pending/preparing/ready tickets, oldest first, derived
  item summary, waiting minutes, one-tap advance.
- Status advance writes `orders.status` and `order_status_history`
  atomically.
- Role picker, kiosk sign-in, kitchen rail.
- Floor table board (read-only) shared by admin.

## What is missing

| Item | Detail |
|---|---|
| Live updates | The board refreshes only on explicit reloads; `dbSubscribe` unused |
| Station routing | `kds_station` and `product_station` exist; tickets are not filtered by station |
| Audio chime | `fx.playAudio` not used; no asset |
| Elapsed urgency | Waiting minutes shown, but no colour/priority/escalation |
| Served/completed split | Board drops `served`; the lifecycle can be ambiguous |
| Display board | `display_board` has no template |
| Display window | No secondary window; a display device shows blank content |
| Waiter home | `waiter_tables` has no template |
| Waiter menu/cart/orders | No templates |
| Waiter flows | Order taking, table transfer, split bill, course timing |
| Ticket actions | Only "next"; no recall, void, hold, re-fire |
| Kiosk exit | No gesture or PIN to leave a kiosk role |
| Offline | No queue if the database is busy |

## Tasks

1. **Wire live queries.** Subscribe the KDS to non-voided orders and order
   lines, or poll deliberately. Prove a POS write appears without a
   restart.
2. **Filter by station** and add a station selector to the board header.
3. **Add the chime** with a bundled asset and a mute control.
4. **Add ticket actions**: hold, recall, void with reason, re-fire.
5. **Build the display board** (one order or a queue) and decide its
   window policy.
6. **Build the waiter templates**: tables, menu, cart, orders.
7. **Decide waiter-specific behaviour**: table transfer, split bill,
   course, customer note.
8. **Add a kiosk exit** (long-press, hidden button, or manager PIN).
9. **Add a KDS render/automation test** for a seeded set of tickets.
10. **Define the board ordering and priority rules** (oldest first now;
    is a late ticket promoted?).

## Exit criterion

- Place an order on the POS; it appears on the KDS within one refresh
  cycle without a restart.
- Advance it on the KDS; the orders list and dashboard reflect it.
- A seeded display window shows the order status.
- A waiter can take an order from a table and see it in the order list.
- A kiosk can be exited deliberately.

## Risks

| Risk | Mitigation |
|---|---|
| A missed ticket is a failed service | Live updates + a visible connection/refresh state |
| Live queries re-render too often | Subscribe per table; keep the ticket list derived |
| Audio permissions or asset packaging | Bundle a small file; test on a clean machine |
| Multi-window shares the cart | Decide per-window state before building display |
| Station routing is modelled but unused | Decide whether v1 routes by station at all |

## Unknowns

- Does the display show one order, a queue, or a rotating carousel?
- Does the KDS need station routing on day one?
- Is the chime per-ticket or per-status?
- How does a waiter move a table or split a bill?
- Should a served order leave the board immediately?

See [`../open-questions.md`](open-questions.md).
