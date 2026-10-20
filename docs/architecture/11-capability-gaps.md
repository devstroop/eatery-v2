# Capability gaps and workarounds

> **Status:** Reference — the target decisions are recorded here; most
> workarounds are Planned.
> **Last verified:** 2026-10-20 against `PORT-PLAN.md` §7, not re-verified
> against a live SDK installation (the CLI is absent from this workspace).

This page is the short, maintained version of the port plan's capability
matrix. It exists so a contributor can answer "can the SDK do X?" without
reading 900 lines of analysis.

Legend:

- **Direct** — the SDK expresses it; no workaround.
- **Adapted** — same outcome, different mechanism.
- **Gap** — no SDK equivalent; a decision is required.
- **Extra** — the SDK has something v1 did not.

## What the SDK does not have

Verified by the port plan's grep over the SDK source:

- Bluetooth / BLE
- ESC/POS
- WebSocket client or server
- mDNS
- XLSX / spreadsheet read/write
- a native file-open panel
- Lottie or a general animation runtime
- media queries / breakpoints
- a custom-paint hook
- a pie-chart series kind
- hex colour literals
- `??` / elvis, ternary, `else-if`

## Gap matrix

| Capability | Verdict | Workaround / decision | Status |
|---|---|---|---|
| Responsive breakpoints | Adapted | Model computes a layout mode from window size; two template variants | Planned |
| Adaptive shell (rail ↔ bottom bar) | Adapted | `split` vs `tabs` by layout mode | Planned |
| Routing / deep links | Adapted | `Screen` enum + stack; no deep links | Implemented |
| RBAC guard | Direct | Pure `allows(role, screen)` | Implemented |
| Reactive state | Adapted | Model + derived methods | Implemented |
| Async loading states | Adapted | `busy`/`error_text`; not complete on reads | Partial |
| Form validation | Adapted | Model methods + expression functions | Planned |
| Date/time pickers | Gap | Text field + `date()`/`datetime()`, or custom picker | Planned |
| Toast / snackbar | Direct | `alert` / `bubble` / `status-bar` | Planned |
| Modal sheets | Direct | `sheet` / `dialog` / `drawer` gated by `<if>` | Planned |
| Tables | Direct | `table` / `table-row` / `table-cell` | Planned |
| Lazy lists | Direct | `virtualized` / `<virtual-list>` | Planned |
| Search | Direct | `search-field` + model filter | Implemented |
| Dropdown | Direct | `select` + anchored `dropdown-menu` | Planned |
| Chips | Direct | `toggle-group` of `toggle-button` | Implemented |
| Icons | Adapted | 49 built-ins + SVG registry | Not started |
| Brand palette | Gap | Semantic tokens + accent override; lose 11 tile colours | Partial |
| Typography scale | Adapted | 14 rungs → 6 | Implemented |
| Shadows | Adapted | `shadow` + `scrim` tokens | Not used |
| Line/bar charts | Direct | `<chart><series kind="line|area|bar">` | Planned |
| Pie chart | Gap | Stacked/grouped bar, or drop | Planned |
| Sparkline | Direct | One-series chart | Planned |
| Chart hover | Direct | `hover-details` | Planned |
| Custom painting (floor plan) | Gap | Rebuild from `grid` + `on-drag` geometry | Planned |
| Lottie / celebration | Gap | Drop, or tween only | Decided: drop |
| Audio (KDS chime) | Direct | `fx.playAudio` with a local asset | Planned |
| SQLite | Direct, better | Engine-owned store; drop `libeaterystore` | Implemented |
| Schema migrations | Adapted | `src/schema/*.sql` + lock; engine migrates at boot | Implemented |
| Live data | Direct, better | `fx.dbSubscribe` | Planned (unused) |
| Key/value prefs | Direct | `fx.storeGet/Set/Scan` | Not used |
| Secrets | Direct, better | `fx.credentials*` (OS keychain) | Planned |
| Files/dirs | Direct | `app_dirs` + `fx.readFile/writeFile` | Not used |
| File picker | Gap | Known-directory listing, or sidecar | Undecided |
| Clipboard | Direct | `fx.readClipboard` / `writeClipboard` | Not used |
| Notifications | Direct | `fx.showNotification` | Not used |
| HTTP | Direct | `fx.fetch` (HTTP(S) only, streamable) | Not used |
| WebSocket sync | Gap | Op-log + sidecar | Proposed |
| mDNS discovery | Gap | Sidecar | Proposed |
| Host election | Gap | Sidecar | Proposed |
| BLE thermal printing | Gap | Print sidecar | Proposed |
| ESC/POS | Gap | Print sidecar | Proposed |
| System print | Adapted | `fx.spawn("lp"/"lpr")` | Planned |
| XLSX export | Gap | CSV via `fx.writeFile`, or sidecar | Proposed: CSV |
| XLSX import | Gap | CSV natively; xlsx via sidecar | Proposed: CSV |
| Cloud backup | Adapted | `fx.fetch` + `credentials` + `open_url`, manual OAuth | Planned |
| Multi-window | Extra | `windows_fn` + shared model | Planned |
| Hidden titlebar | Extra | `titlebar = .hidden_inset` + `window-drag` | Planned |
| BLE scan UI | Gap | Sidecar reports devices over stdout | Proposed |
| iOS / Android | Gap-ish | Desktop-first; mobile packaging experimental | Proposed |
| Packaging | Adapted | `native package --target macos` | Planned |
| Tests | Direct, better | `native test` + `native automate` | Partial |
| CI | Direct | Copy showcase workflow | Planned |

## The three hard gaps

### A. BLE + ESC/POS printing

No Bluetooth stack, no ESC/POS. Options:

1. **Print sidecar (recommended).** A helper speaks BLE and ESC/POS; the app
   spawns it per job or records a job row. App-side cost is small; helper,
   packaging and signing are the real work.
2. **Host service in an ejected app.** CoreBluetooth in Objective-C behind
   `hostRequest`. macOS-only in practice.
3. **LAN printers only.** ESC/POS over TCP :9100. Cheapest, but loses the
   Bluetooth printers small restaurants actually buy.
4. **Defer printing.** Not viable beyond a pilot.

Decision: [ADR-0008](../decisions/0008-sidecar-for-printing.md) (Proposed).

### B. LAN sync

`fx.fetch` rejects non-HTTP(S), so the app cannot speak WebSocket. The
protocol is already table-shaped, so keep the protocol and move the
transport:

- app writes `op_log` rows and watches them;
- sidecar owns WebSocket, mDNS and host election;
- LWW with logical clocks stays.

This removes the socket stack from the app entirely and is simpler than
v1. Decision:
[ADR-0009](../decisions/0009-oplog-sync-with-transport-sidecar.md)
(Proposed).

### C. Lottie and custom paint

- Drop the celebration animation; keep the elapsed-time text.
- Rebuild the floor plan as a `grid` of cards with drag-release geometry.
- Pie chart becomes a bar chart or is dropped.

Decision: [ADR-0010](../decisions/0010-markup-only-no-custom-paint.md)
(Accepted for visuals; floor plan still Planned).

## What we gain

- engine-owned SQLite with live queries;
- a pure, headlessly testable core;
- OS keychain instead of a plugin;
- multi-window KDS/display over one model;
- a 5 ms rebuild loop and a real GPU canvas;
- `native automate` for live smoke tests;
- a single binary with no runtime dependency on Flutter/Dart.

## What we lose

- the Flutter widget and package ecosystem;
- pixel-identical brand expression;
- mobile parity (for now);
- in-process WebSocket/BLE;
- custom paint;
- deep links;
- XLSX;
- a familiar router.

Every loss is either accepted in an ADR or tracked in
[`plan/open-questions.md`](../plan/open-questions.md).
