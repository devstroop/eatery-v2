# ADR-0001: Rewrite Eatery on the Native SDK in Zig

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/01`](../architecture/01-system-overview.md),
> [`architecture/11`](../architecture/11-capability-gaps.md)

## Context

Eatery v1 is a Flutter application: Dart 3.11, Flutter 3.41, Riverpod,
GoRouter, 77 routes, 4 roles, a 39-table SQLite schema reached through a
vendored C SQLite library, a WebSocket sync server, BLE thermal printing
and a custom design system.

The target platform is the Native SDK v0.11.0: a Zig 0.16 application
model with a declarative markup view, a GPU canvas, a typed effects
channel and an engine-owned relational store. The reference conventions
come from the `native-zig-showcase` apps.

The choice is not "port or keep Flutter" in the abstract. It is whether
the product should be re-expressed as a native Zig app, with the
capability losses that implies, or kept in Flutter.

## Decision

**Rewrite the app on the Native SDK in Zig.** `eatery-v2` is a new
codebase. It does not share Dart code, widgets, the Riverpod provider
graph, the GoRouter tables or `libeaterystore`. Product behaviour, the
data model and the permission matrix are the sources of truth to carry
over.

The rewrite follows the showcase conventions verbatim: `Model`/`Msg`/
`update`, markup templates, `view_unbound`, append-only migrations,
`UiApp.create` on the heap, panic capture.

## Consequences

### Positive

- One native binary with no Dart runtime or Flutter engine.
- A GPU canvas with a 5 ms rebuild loop.
- Engine-owned SQLite with live queries; `libeaterystore` disappears.
- A pure core that is headlessly testable.
- Real OS integration: keychain, notifications, files, windows.
- The possibility of multi-window POS + KDS + display over one model.
- No plugin ecosystem to audit for supply-chain risk.

### Negative

- A full rewrite: every screen, form and flow is new code.
- Loss of the Flutter package ecosystem (charts, Lottie, file picker,
  BLE, XLSX, WebSocket).
- Loss of pixel-identical brand expression; the palette is approximated
  with semantic tokens.
- Mobile is not first-class.
- The team must learn Zig and the Native SDK's markup grammar.
- The SDK is young; its behaviour can change between minor versions.

### Follow-ups

- Every hard gap gets its own ADR: printing (0008), sync (0009), visuals
  (0010), mobile (0011), interchange (0012).
- The Flutter app stays the behavioural oracle until cutover.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep Flutter | The stated goal is a native single binary and the SDK's model; Flutter cannot produce that. |
| Flutter + native shells | Keeps the plugin and runtime burden and still lacks the native canvas. |
| Port to another native toolkit (Qt, SwiftUI, Tauri) | Repeats the analysis without the SDK's app model, effects channel or relational store. |
| Incremental strangler | The UI and data layers differ enough that a mixed process would carry both stacks indefinitely. |

## Evidence

- `../../PORT-PLAN.md` §1–§3: verified SDK shape, build constraints and
  live relational-store spike.
- `apps/eatery/` exists as a Zig-core app with `sqlite` capability and 10
  migrations.
- The app builds in the showcase conventions (`main.zig`, `app.native`,
  `tests.zig`).
