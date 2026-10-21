# ADR-0008: A sidecar owns printing and BLE

> **Status:** Proposed — needs an owner and a go/no-go
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers, product
> **Related:** [`architecture/09`](../architecture/09-printing-and-hardware.md)

## Context

Receipts and kitchen tickets are core to a POS. The target hardware is
usually an inexpensive Bluetooth thermal printer speaking ESC/POS. The
Native SDK has no Bluetooth stack and no ESC/POS. It can spawn a process
and pass bytes.

The options were analysed in `PORT-PLAN.md` §7.1:

1. a sidecar helper process;
2. a host service in an ejected app (CoreBluetooth in Objective-C);
3. LAN printers only (TCP :9100);
4. defer printing.

## Decision

**Proposed: build a print sidecar that owns device discovery, BLE and
ESC/POS. The app owns the job content and the routing configuration.**

Two integration modes are allowed:

- **Per job (first):** the app renders ESC/POS bytes and `fx.spawn`s the
  helper; the helper exits with a status.
- **Worker (later):** the app writes a print job row; the sidecar watches
  the table, retries, and reports status.

Routing is stored in `printer` and `auto_print`. The app must never block
a committed sale on a printer.

## Consequences

### Positive

- BLE and ESC/POS live outside the pure core and outside the SDK's
  capability surface.
- The sidecar is testable on its own and replaceable per platform.
- LAN printers (TCP :9100) and OS print queues reuse the same job model.
- The app side is small: build bytes, spawn, interpret status.

### Negative

- A second binary to build, sign, package and update.
- An IPC contract to version.
- Device permissions and OS pairing are platform-specific.
- The helper can crash or hang; the app needs a timeout.
- Printing is asynchronous, so the UI must show job status honestly.

### Follow-ups

- Choose implementation language and packaging per platform.
- Define the job protocol (`stdin` bytes vs job table).
- Decide retry/idempotency, so a retry does not double-print.
- Define receipt/KOT content and code pages.
- Decide failure policy: warn, queue, or block.
- Test on real hardware before committing to BLE.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Host service in an ejected app | Objectively viable, but macOS-only in practice and embeds ObjC in the app. |
| LAN printers only | Lowest cost, but loses the Bluetooth printers the target market uses. |
| In-process ESC/POS with a raw socket | No socket API; `fetch` is HTTP(S) only. |
| Defer printing | Not viable for a restaurant beyond a pilot. |

## Evidence

- `src/schema/0009_printing.sql`: `printer`, `auto_print`.
- `tools/print-sidecar/` exists but is empty.
- `PORT-PLAN.md` §7.1 Gap A and §11 Phase 7.
- SDK effect surface has `spawn` but no Bluetooth or socket.
