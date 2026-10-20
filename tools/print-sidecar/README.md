# Print sidecar — the receipt printer transport

> **Status: DESIGN.** Nothing in this directory is implemented. There is no
> language choice, no build script, no source file and no test. This
> document specifies what the sidecar has to do, which ESC/POS commands it
> has to speak, and what the app may assume about it.
>
> **Sources:**
> [`docs/architecture/09-printing-and-hardware.md`](../../docs/architecture/09-printing-and-hardware.md),
> [`docs/decisions/0008-sidecar-for-printing.md`](../../docs/decisions/0008-sidecar-for-printing.md),
> [`docs/plan/phase-7-printing-hardware.md`](../../docs/plan/phase-7-printing-hardware.md),
> `apps/eatery/src/schema/0009_printing.sql`, and the v1 Dart
> implementation in `../eatery/lib/support/bluetooth_thermal_printer/`
> and `../eatery/lib/services/printing/`.
>
> **Last verified:** 2026-10-20, by source review.

---

## The problem

The Native SDK has no Bluetooth stack and no ESC/POS support
(`docs/architecture/11-capability-gaps.md`). It can spawn a subprocess and
write bytes to files and stdin; it cannot open a BLE characteristic or
speak to a USB printer.

Eatery's target market buys inexpensive Bluetooth thermal receipt
printers. Dropping BLE is a visible feature regression, so the port plan
chose a sidecar over an in-process port.

What v1 carried is worth naming, because it is the specification the
sidecar inherits:

| v1 artefact | Path | What it held |
|---|---|---|
| BLE adapter | `lib/support/bluetooth_thermal_printer/flutter_bluetooth_adapter.dart` | a `flutter_blue_plus` wrapper: scan, connect, pick the first writable characteristic, write |
| print service | `.../src/services/bluetooth_printer.service.dart` | chunking, timeouts, the result enum |
| ESC/POS command table | `.../src/esc_utils/commands.dart` | every byte sequence the app used |
| ESC/POS generator | `.../src/esc_utils/generator.dart` | 860 lines: text, styles, columns, images, barcodes, QR |
| capability profiles | `.../src/esc_utils/capability_profile.dart`, `.../src/resources/capabilities.json` | four printer models and their code-page tables |
| barcode and QR | `.../src/esc_utils/barcode.dart`, `.../src/esc_utils/qrcode.dart` | symbologies and the QR sub-commands |
| receipt builder | `lib/services/printing/print_invoice.dart` | the receipt layout, and a KOT appended to it |
| report builder | `lib/services/printing/print_report.dart` | the sales report layout, commented out and unused |

Two facts about that code shape the design:

- **v1 printed the receipt and the kitchen ticket as one ticket.** In
  `print_invoice.dart` the receipt is followed by `ticket.hr(ch: '=')`, a
  centred `KOT` heading, the KOT block, and a single cut. That is a v1
  layout decision, not a contract. v2 routes the two jobs separately.
- **v1 had no result codes on the wire.** `PrintResult` is a Dart enum
  (`success`, `timeout`, `printerNotSelected`, `ticketEmpty`,
  `printInProgress`, `scanInProgress`) with a `value` extension that
  numbers them 1 to 6, but the value never left the process.

## The architecture

The app owns the job content and the routing configuration. The sidecar
owns the device. The app renders the ESC/POS bytes, the sidecar writes
them and reports what happened.

```
┌─────────────────────┐        ┌──────────────────────────┐
│ App (Zig)           │        │ print-sidecar            │
│                     │        │                          │
│ render job bytes ───┼──▶ stdin│  ├─ ESC/POS passthrough   │
│                     │        │  ├─ BLE transport        │
│ status / errors ◀───┼── stdout│  ├─ TCP :9100           │
└─────────────────────┘        │  └─ file (tests)        │
                               └──────────────────────────┘
```

ADR-0008 allows two integration modes:

1. **Per job (first).** The app renders the bytes and `fx.spawn`s the
   helper; the helper exits with a status.
2. **Worker (later).** The app writes a print-job row and the sidecar
   watches the table, the same pattern as sync.

Mode 1 is first, and the SDK's spawn shape is why. `SpawnOptions.stdin`
is written to the child's stdin **once, then stdin closes**. That is
exactly the per-job shape: one envelope in, one result out, process gone.
A long-lived worker cannot be fed through stdin at all, so mode 2 will
have to use the database — a new job table — rather than a pipe.

### The job envelope

Proposed. One JSON object on stdin, then EOF.

```json
{
  "v": 1,
  "job_id": "1749843210123",
  "kind": "receipt",
  "printer": {
    "id": 1,
    "transport": "ble",
    "address": "AA:BB:CC:DD:EE:FF",
    "paper_width_mm": 80,
    "code_page": "CP437"
  },
  "payload_b64": "G0AbdGVzdA==",
  "idempotency_key": "receipt:1749843210123",
  "timeout_ms": 5000
}
```

The payload is base64 because `docs/architecture/09-printing-and-hardware.md`
lists "whether the SDK's `spawn` can stream binary safely on all desktops"
as an unknown. Base64 sidesteps the question for the payload; the sidecar
decodes it and writes raw bytes to the device.

### The result

Proposed. One NDJSON object on stdout, then a non-zero exit code on
failure.

```json
{"v":1,"type":"result","job_id":"1749843210123","ok":true,"bytes_written":412,"duration_ms":820}
{"v":1,"type":"result","job_id":"1749843210123","ok":false,"code":"printer_offline","message":"write failed"}
```

Proposed exit codes, carrying v1's `PrintResult` vocabulary:

| Exit | Meaning | v1 equivalent |
|---|---|---|
| `0` | printed | `success` |
| `2` | no printer configured or selected | `printerNotSelected` |
| `3` | the device was unreachable, or the job timed out | `timeout` |
| `4` | the job envelope was rejected, or the payload was empty | `ticketEmpty` |
| `5` | another print was already in flight | `printInProgress` |
| `6` | a device scan was in progress | `scanInProgress` |

## The transports

The `printer.transport` column is CHECK-constrained to
`'ble' | 'tcp' | 'usb' | 'file'`.

| Transport | Device | `address` holds | Notes |
|---|---|---|---|
| `ble` | the OS Bluetooth stack | the device address | The target hardware. |
| `tcp` | a LAN printer | `host:port`, default port `9100` | Raw ESC/POS over TCP, no handshake. |
| `file` | a file on disk | a path | The test transport. No hardware needed. |
| `usb` | a USB device | not defined | In the schema's CHECK, not designed. |

### BLE

What v1 did, and therefore what the sidecar has to reproduce:

- Scan with `flutter_blue_plus` and `withServices: []`; the scan is a
  separate step from the connect.
- Connect with a 10-second timeout, then discover the services and pick
  the **first characteristic that is writable or writable-without-response**.
- Write with `withoutResponse: true`.
- Chunk the payload at **20 bytes** with a **20 ms** gap between chunks
  (`chunkSizeBytes = 20`, `queueSleepTimeMs = 20`).
- v1 re-scanned for one second before connecting, because it could only
  connect once per scan.
- v1's whole-print timeout was 5 seconds, and it disconnected 3 seconds
  after the write loop finished.

Proposal: keep the chunk size, the chunk gap and the write-without-response
mode, because those are the numbers a cheap printer was tested with. Make
the connect timeout and the whole-job timeout configurable, with 5 seconds
as the default.

### TCP

ESC/POS over a raw TCP socket on port 9100. The socket is opened per job:
the sidecar writes the bytes and closes it. No handshake, no response, no
status. This is the cheapest real transport to test — a local listener
that captures the bytes is enough.

### File

The sidecar writes the decoded payload bytes to the path in `address` and
reports the byte count. This is how the encoder is tested with no
hardware at all, and it is the transport the test suite uses.

## The job kinds

`printer.job` and `auto_print.job` are both CHECK-constrained to
`'receipt' | 'kot' | 'report'`.

| Job | Content | Typical device |
|---|---|---|
| `receipt` | customer receipt: company name, tax number, food licence number, address, phone, email; order number and type; the customer row; line items with quantity, particulars, price and amount; taxable total, tax, round-off, total; a footer; a QR code of the order id | counter thermal printer |
| `kot` | kitchen order ticket: order number and type, items with quantity, table name, timestamp, a QR code of the order id | kitchen thermal printer |
| `report` | X/Z report: a date range, one row per order (date, order id, amount), the total sales | back office or counter |

The `printer` table as it exists:

| Column | Type | Meaning |
|---|---|---|
| `id` | `INTEGER` PRIMARY KEY | — |
| `name` | `TEXT` | display name |
| `kind` | `TEXT` | `escpos` (thermal) or `system` (the OS print queue) |
| `transport` | `TEXT` | `ble`, `tcp`, `usb`, `file` |
| `address` | `TEXT` | `host:port` for TCP, the device address for BLE |
| `job` | `TEXT` | `receipt`, `kot`, `report` |
| `paper_width_mm` | `INTEGER` | 58 or 80, default 80 |
| `active` | `INTEGER` | 0 or 1 |
| `created_at` | `INTEGER` | epoch ms |

`auto_print(printer_id, job, enabled)` maps printers to jobs. `kind =
'system'` is a different pipeline — the OS print queue via `lp`/`lpr` —
and is not part of this sidecar's job.

## The ESC/POS command set

The table below is the v1 command table
(`lib/support/bluetooth_thermal_printer/src/esc_utils/commands.dart`)
with the byte sequences spelled out. `ESC` is `0x1B`, `GS` is `0x1D`,
`FS` is `0x1C`.

### Miscellaneous

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cInit` | `1B 40` | ESC @ — initialize the printer, clear the buffer and reset the styles |
| `cBeep` | `1B 42` | ESC B — beeper, `[count] [duration]` |

### Mechanical control

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cCutFull` | `1D 56 30` | GS V 0 — full cut |
| `cCutPart` | `1D 56 31` | GS V 1 — partial cut |

### Character formatting

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cReverseOn` | `1D 42 01` | GS B 1 — reverse (white on black) on |
| `cReverseOff` | `1D 42 00` | GS B 0 — reverse off |
| `cSizeGSn` | `1D 21` | GS ! — select character size `[N]` |
| `cSizeESCn` | `1B 21` | ESC ! — select character size `[N]` |
| `cUnderlineOff` | `1B 2D 00` | ESC - 0 — underline off |
| `cUnderline1dot` | `1B 2D 01` | ESC - 1 — underline, 1 dot |
| `cUnderline2dots` | `1B 2D 02` | ESC - 2 — underline, 2 dots |
| `cBoldOn` | `1B 45 01` | ESC E 1 — emphasized on |
| `cBoldOff` | `1B 45 00` | ESC E 0 — emphasized off |
| `cFontA` | `1B 4D 00` | ESC M 0 — Font A |
| `cFontB` | `1B 4D 01` | ESC M 1 — Font B |
| `cTurn90On` | `1B 56 01` | ESC V 1 — rotate 90° clockwise on |
| `cTurn90Off` | `1B 56 00` | ESC V 0 — rotation off |
| `cCodeTable` | `1B 74` | ESC t — select character code table `[N]` |
| `cKanjiOn` | `1C 26` | FS & — Kanji character mode on |
| `cKanjiOff` | `1C 2E` | FS . — Kanji character mode off |

### Print position

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cAlignLeft` | `1B 61 30` | ESC a 0 — left justification |
| `cAlignCenter` | `1B 61 31` | ESC a 1 — centred |
| `cAlignRight` | `1B 61 32` | ESC a 2 — right justification |
| `cPos` | `1B 24` | ESC $ — set absolute print position `[nL] [nH]` |

### Print

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cFeedN` | `1B 64` | ESC d — print and feed `n` lines `[N]` |
| `cReverseFeedN` | `1B 65` | ESC e — print and reverse feed `n` lines `[N]` |

### Bit image

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cRasterImg` | `1D 28 4C` | GS ( L — raster bit image, graphics form |
| `cRasterImg2` | `1D 76 30` | GS v 0 — raster bit image, the obsolete form |
| `cBitImg` | `1B 2A` | ESC * — bit image, column format |

### Barcode

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cBarcodeSelectPos` | `1D 48` | GS H — position of the HRI characters `[N]` |
| `cBarcodeSelectFont` | `1D 66` | GS f — font for the HRI characters `[N]` |
| `cBarcodeSetH` | `1D 68` | GS h — barcode height `[N]` |
| `cBarcodeSetW` | `1D 77` | GS w — barcode width `[N]` |
| `cBarcodePrint` | `1D 6B` | GS k — print the barcode |

The barcode symbologies v1 supported, with their `GS k` type byte:
UPC-A `0`, UPC-E `1`, EAN13 `2`, EAN8 `3`, CODE39 `4`, ITF `5`, CODABAR
`6`, CODE128 `73`. Function A (`type <= 6`) appends a `00` terminator;
Function B (CODE128) prefixes the data length.

### Cash drawer

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cCashDrawerPin2` | `1B 70 30 33 30` | ESC p 0 3 0 — drawer pulse, pin 2 |
| `cCashDrawerPin5` | `1B 70 31 33 30` | ESC p 1 3 0 — drawer pulse, pin 5 |

### QR code

| v1 constant | Bytes | Meaning |
|---|---|---|
| `cQrHeader` | `1D 28 6B` | GS ( k — the QR command header |

The QR sub-commands, from `qrcode.dart`:

| Step | Bytes | FN |
|---|---|---|
| set the module size | `1D 28 6B 03 00 31 43 <size>` | 167 |
| select the error-correction level | `1D 28 6B 03 00 31 45 <level>` | 169 |
| store the data | `1D 28 6B <len> 00 31 50 30` + data | 180 |
| transmit the symbol size | `1D 28 6B 03 00 31 52 30` | 182 |
| print the symbol | `1D 28 6B 03 00 31 51 30` | 181 |

Error-correction levels: L `48`, M `49`, Q `50`, H `51`. Module sizes 1
to 8.

### Two sequences that were not in the table

`generator.dart` emits two byte sequences inline, around the column-format
image:

| Bytes | Meaning |
|---|---|
| `1B 33 10` | ESC 3 16 — set the line spacing to 16/180 inch |
| `1B 32` | ESC 2 — restore the default line spacing |

### Text is not a command

There is no "print text" ESC/POS command: the generator writes the
encoded text bytes straight to the stream, and a line break is `0A`. The
encoding is latin1 for plain text and GBK for text flagged as Chinese,
with a substitution pass that rewrites `’`, `´`, `»`, a non-breaking space
and `•` to ASCII.

### Paper width

From `PaperSize` and `Generator._getMaxCharsPerLine`:

| Paper | Dots wide | Characters per line (Font A) | Characters per line (Font B) |
|---|---|---|---|
| 58 mm | 372 | 32 | 42 |
| 80 mm | 558 | 48 | 64 |

v1 laid out receipts as a 12-column grid: each `PosColumn` has a width
between 1 and 12, and the widths of a row must sum to exactly 12 —
`PosColumn`'s constructor throws otherwise. A column's text that does not
fit is split onto the next row, which the generator recurses into.

### Code pages

`ESC t n` takes a numeric page id, and that id depends on the printer
model. v1 shipped four profiles in `capabilities.json`:

| Profile | Vendor | Model | Code pages |
|---|---|---|---|
| `default` | Generic | Default | 62 |
| `XP-N160I` | Xprinter | XP-N160I | 67 |
| `RP80USE` | Rongta | RP80USE | 43 |
| `TP806L` | HPRT | TP806L | 18 |

CP850 is id `2` in all four. Id `0` is `CP437` in the first three and
`PC437` in the HPRT profile, and id `16` is `CP1252` in the first three
and `WPC1252` in the HPRT one — the same page, spelled differently. The
sidecar needs the map, because a receipt that prints `?` where the
currency symbol should be is a receipt the restaurant cannot use.

## Failure and retry policy

The trade-off, stated by `docs/architecture/09-printing-and-hardware.md`:
the order is committed first, printing is a best-effort side effect with a
visible status. A POS that blocks a sale because a printer is offline is
usually the wrong trade.

| Failure | Behaviour |
|---|---|
| No printer configured | The sale proceeds. The app shows a warning. The sidecar exits `2`. |
| Printer offline | The job fails with a transport-specific code. The app shows a warning and offers a retry. |
| BLE disconnected mid-write | The job is reported failed. The whole job is reprinted, never half. |
| Paper out / cover open | Only detectable if the device exposes status. v1 never read it; neither will the first version. |
| Duplicate retry | Every job carries an `idempotency_key`. A retry with the same key does not print twice. |
| The sidecar hangs | The app's timeout fires and the spawn is cancelled with `fx.cancel(key)`. |
| The sidecar crashes | The app sees `reason == .signaled` or `.exited` with a non-zero code, and shows the failure. |
| A partial write | Treated as "the job did not happen": the sidecar reports failure and the app may retry the whole job. |

In the per-job mode the sidecar holds no retry queue — the app owns the
retry, because the app owns the status the operator sees. The idempotency
key is the mechanism that makes a retry safe; proposal: the sidecar keeps
the keys it has printed in memory for the lifetime of the process, and the
app keeps the durable record.

v1's failure vocabulary is worth keeping as the result codes, because it
already names the states a print can be in: `success`, `timeout`,
`printerNotSelected`, `ticketEmpty`, `printInProgress`, `scanInProgress`.

## The file layout the sidecar will have

Proposed. Nothing exists yet.

```text
tools/print-sidecar/
├── README.md              this document
├── PROTOCOL.md            the frozen job envelope and result codes (proposal)
├── build.zig              the build
├── build.zig.zon
├── src/
│   ├── main.zig           argv, the job envelope, the process lifecycle
│   ├── job.zig            the job envelope codec
│   ├── escpos.zig         the command table and the byte builders
│   ├── encoder.zig        the text, column and QR encoder
│   ├── codepages.zig      the per-model code-page map
│   ├── result.zig         the result codes and the NDJSON reply
│   └── transport/
│       ├── ble.zig        the OS Bluetooth stack
│       ├── tcp.zig        raw TCP on 9100
│       └── file.zig       write to a file
└── tests/
    ├── escpos_test.zig    every command's byte sequence
    ├── encoder_test.zig   the receipt and KOT layouts
    └── transport_test.zig the file transport, end to end
```

## Open questions

1. **Language and packaging per platform.** ADR-0008 leaves it open. The
   BLE transport is the constraint: macOS wants CoreBluetooth, Windows
   wants WinRT, Linux wants BlueZ over D-Bus. A single helper that speaks
   all three is not a small thing.
2. **BLE or LAN-only.** Open question E1. LAN-only is the cheapest path
   and drops the hardware the target market actually buys.
3. **Which printer models are supported.** Open question E2. The code-page
   map, the cut support and the drawer pulse all depend on the answer.
4. **What happens when the printer is offline.** Open question E8: warn,
   queue, or block. The current recommendation is warn.
5. **Reprints and duplicates.** Open question E9. The idempotency key is
   the mechanism; where it is stored is undecided.
6. **Code pages per locale.** Open question E10. The v1 generator encoded
   plain text as latin1, which cannot represent the currency symbol of
   every market.
7. **A logo on receipts.** Open question E11. The raster command set is
   in v1, but the app has no logo asset and the SDK has no image pipeline
   for this.
8. **The cash drawer.** Is one attached to the printer? The drawer pulse
   is implemented in v1 (`ESC p`), and the drawer is also listed as
   un-designed hardware in `docs/architecture/09-printing-and-hardware.md`.
9. **One KOT per station, or one combined KOT.** Open in the architecture
   doc. `kds_station` and `product_station` exist in the schema, which
   points at per-station routing.
10. **Does a void print a cancellation ticket?** Also open in the
    architecture doc.
11. **Whether the SDK's `spawn` can stream binary safely on all desktops.**
    Base64 in the job envelope sidesteps it for the payload; the result
    lines are JSON, so they are safe.
12. **Legal receipt requirements** per jurisdiction: tax number, GST/VAT
    breakdown, sequential invoice numbering.

## How it will be tested

1. **Unit — the command table.** Every command's byte sequence, asserted
   against the v1 table above. A byte changed in the wrong place shows up
   here and nowhere else.
2. **Unit — the encoder.** A fixed receipt fixture produces an exact
   golden byte string. The fixture is the v1 receipt for one order, so a
   v1 and a v2 receipt can be compared side by side.
3. **Unit — the code-page map.** Every profile in `capabilities.json`
   resolves the right `ESC t n` value for a named code page, and an
   unknown page name is an error rather than a silent `0`.
4. **Integration, no hardware — the file transport.** The sidecar writes
   to a temp file; the test asserts the bytes. This is the transport the
   whole test suite runs on.
5. **Integration — the TCP transport.** A local listener captures the
   bytes and the connection closes.
6. **Integration — the app's half.** The app spawns the sidecar with a
   job on stdin and receives the result line. The SDK's fake effects
   executor records the `SpawnRequest` (key, argv, stdin), so the test
   asserts the envelope without running anything.
7. **Integration — the exit path.** A rejected envelope produces the
   documented exit code and a `result` line with `ok: false`.
8. **Failure injection — no printer.** The sidecar exits non-zero; the
   app shows the error and the committed sale stands.
9. **Failure injection — the device disappears mid-write.** The job is
   reported failed, not partially printed.
10. **Failure injection — a retry.** The same `idempotency_key` twice
    does not print twice.
11. **Hardware.** One printer of each supported model: a receipt, a KOT
    and a drawer pulse, plus the paper-out case if the device reports it.

## Next step

Write `tools/print-sidecar/PROTOCOL.md`: the frozen job envelope, the
result line, and the exit-code table, with the `printer` and `auto_print`
columns each envelope field comes from. Then build the `file` transport
and the ESC/POS command table with their byte-sequence tests — the file
transport is the only one that can be tested without hardware, and it
validates the encoder before BLE is in play.
