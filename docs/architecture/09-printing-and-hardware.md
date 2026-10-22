# Printing and hardware

> **Status:** Scaffolded — `printer` and `auto_print` tables exist; no print
> code, no sidecar, no device integration.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/schema/0009_printing.sql`, `tools/print-sidecar/` (empty),
> `PORT-PLAN.md` §7.1 Gap A.

## Why this is hard

The SDK has no Bluetooth stack and no ESC/POS support. It can spawn a
subprocess and write bytes to files/stdin; it cannot open a BLE
characteristic or speak to a USB printer.

The Restaurant OS target market uses inexpensive Bluetooth thermal receipt
printers. Dropping BLE is a visible feature regression. The port plan
therefore recommends a sidecar rather than an in-process port.

## Chosen shape: a print sidecar

```
┌─────────────────────┐        ┌──────────────────────────┐
│ App (Zig)           │        │ print-sidecar            │
│                     │        │                          │
│ render job rows ────┼──▶ DB  │ watch/manual trigger     │
│ or fx.spawn ────────┼──▶ stdin│  ├─ ESC/POS encoder      │
│                     │        │  ├─ BLE transport        │
│ status / errors ◀───┼── stdout│  ├─ TCP :9100           │
└─────────────────────┘        │  ├─ USB / file           │
                               │  └─ OS print queue (lp)  │
                               └──────────────────────────┘
```

Two integration options, both viable:

1. **Spawn per job (recommended first).** The app builds the ESC/POS
   payload and `fx.spawn`s the helper with the bytes or a temp file. The
   helper exits with a status; the app shows success/failure. Simple,
   stateless, easy to test.
2. **Long-lived worker.** The app writes a print-job row and the sidecar
   watches the table (same pattern as sync). Better for retries and device
   discovery, more moving parts.

The persisted `printer` and `auto_print` tables suggest the long-lived
design: the app records configuration, the sidecar owns devices.

## ESC/POS job model

A receipt is not a string; it is a command stream.

| Concern | Decision needed |
|---|---|
| Encoding | ASCII? Code page 437/850? UTF-8 with a code-page select? |
| Currency | Symbol in the device code page, or text fallback |
| Width | 58 mm vs 80 mm; character columns (32/42/48) |
| Cut | Full/partial cut command support |
| Cash drawer | Kick pulse on cash payment |
| Logo | Raster bitmap, size, dithering |
| Barcodes/QR | Which symbologies the device supports |
| Alignment | Left/right/centre commands |
| Bold/double height | Per-line style commands |
| Reprints | Idempotency key so a retry does not double-print |

None of these are decided. The app currently renders no receipt at all.

## Printer routing

Schema:

| Table | Fields |
|---|---|
| `printer` | `name`, `kind` (`escpos`/`system`), `transport` (`ble`/`tcp`/`usb`/`file`), `address`, `job` (`receipt`/`kot`/`report`), `paper_width_mm`, `active` |
| `auto_print` | `printer_id`, `job`, `enabled` |

Intended routing:

| Job | Content | Typical device |
|---|---|---|
| `kot` | Kitchen order ticket: table/order no, items, qty, notes, station | Kitchen thermal printer |
| `receipt` | Customer receipt: line items, tax, discount, total, payment | Counter thermal printer |
| `report` | X/Z report, shift summary | Back-office or counter |

Open routing questions:

- Does one order print one KOT per station or one combined KOT?
- Are modifiers printed as indented lines?
- Does a void print a cancellation ticket?
- Is printing automatic on order placement, or a button?
- What happens when the printer is offline: block the sale, queue, or warn?
- Can a device have multiple printers of the same job?

## Failure handling

| Failure | Desired | Current |
|---|---|---|
| No printer configured | Sale proceeds; warning | N/A |
| Printer offline | Queue and retry, or warn | N/A |
| BLE disconnected | Reconnect or surface an error | N/A |
| Paper out | Surface device status if available | N/A |
| Duplicate retry | Idempotency key | N/A |
| Partial write | Reprint whole job, never half | N/A |

A POS that blocks a sale because a printer is offline is usually the wrong
trade. The target is: the order is committed first, printing is a
best-effort side effect with a visible status.

## Platform notes

| Platform | BLE from a helper | System print | Risk |
|---|---|---|---|
| macOS | CoreBluetooth via a small Swift/ObjC helper | `lp` | Permissions prompts, pairing |
| Windows | WinRT BLE or a vendor SDK | `print` / `Start-Process` | Helper distribution |
| Linux | BlueZ D-Bus | `lp` | Varies by distro |
| Mobile | Not in scope | — | SDK mobile is experimental |

The sidecar must be packaged and signed with the app. This is a release
engineering task, not just a code task.

## Alternatives considered

1. **BLE sidecar** (recommended): helper speaks BLE + ESC/POS. ~4 days
   estimated.
2. **Host service in an ejected app**: bind `HostCallBinding` and write
   CoreBluetooth in Objective-C inside the app. macOS-only in practice.
3. **LAN printers only**: ESC/POS over TCP :9100 via a helper. Lowest
   cost, but loses Bluetooth devices.
4. **Defer printing**: ship without receipts. Unacceptable for a real
   restaurant beyond a pilot.

See [ADR-0008](../decisions/0008-sidecar-for-printing.md) (Proposed) and
[phase 7](../plan/phase-7-printing-hardware.md).

## What is not known

- Which printer models are actually used by target customers.
- Whether the OS BLE APIs can pair without a UI prompt on each platform.
- Whether the SDK's `spawn` can stream binary safely on all desktops.
- Whether printer status (paper out, cover open) is readable on the
  target hardware.
- The legal receipt requirements by jurisdiction (tax number, GST/VAT
  breakdown, sequential invoice numbering).
- Whether an X/Z report must be immutable and signed.

See [`plan/open-questions.md`](../plan/open-questions.md).

## Other hardware

| Device | Need | Status |
|---|---|---|
| Cash drawer | Kick pulse via printer, or USB | Not designed |
| Barcode scanner | Keyboard-wedge input | Not designed; likely just a text field |
| Card terminal | Payment integration | Not designed |
| Kitchen bump bar | Keyboard/GPIO | Not designed |
| Customer display | Secondary window | Planned |
| Scale | Serial/HID | Not designed |
| Label printer | ESC/POS or vendor SDK | Not designed |

The app's `capabilities` list does not include a USB/serial capability;
anything beyond keyboard-wedge and network printers needs a sidecar or a
host service.
