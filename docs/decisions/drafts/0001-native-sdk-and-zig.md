# ADR-0001: Build the core on the Native SDK in Zig

**Status:** Accepted (2026-10)
**Applies to:** `apps/ros/**`, `tools/**`
**Related:** [`architecture/overview.md`](../../architecture/overview.md),
[`architecture/11-capability-gaps.md`](../../architecture/11-capability-gaps.md)

## Context

Eatery v1 is a Flutter application: 417 Dart files across `lib/` and
`packages/eatery_core/`, 104 of them under `lib/pages/`, 10 Riverpod
providers, and a `GoRouter` with 77 `GoRoute` entries in
`lib/core/router/app_router.dart`. Its data layer is a vendored SQLite C
library (`libeaterystore/`) reached through `dart:ffi`. Its sync layer is a
WebSocket server and client inside the app
(`packages/eatery_core/lib/data/sync/sync_server.dart`,
`sync_client.dart`). Its peripheral support is a plugin surface:
`lib/support/bluetooth_thermal_printer/`, Lottie assets in `assets/lottie/`,
`fl_chart` in `lib/pages/dashboard/components/dashboard_charts.dart`, XLSX
read/write in `lib/pages/dashboard/data/data_management.page.dart`, and
`image_picker` in `lib/pages/dashboard/utility/image_library.page.dart`.

That stack is the source of most of v1's documented defects. The permission
check was a router `redirect:` callback that `../eatery/docs/architecture/routing.md`
itself records as "not yet implemented". The order write had no transaction
(`../eatery/docs/plan/issue-inventory.md`, defect **DB5**: the order is saved, then
its lines are written in a loop). The database handle was a global static
(`defect L1`: `static EateryStore? _store` in `order.function.dart`), which
is why the repositories are hard to test. The business logic sat in widgets
(`defect P5`: roughly 130 lines of `placeOrder()` inside
`cart.page.dart`), and `Order.status` was a raw string with no state machine
(`defect O8`).

The Native SDK offers a different shape: a Zig 0.16 application model with a
declarative markup view rendered on a GPU canvas, a typed effects channel,
and an engine-owned relational store with live queries. The decision is not
"port or keep Flutter" in the abstract. It is whether the product gets one
native binary with a pure, headlessly testable core, at the price of the
Flutter ecosystem and a full rewrite of the view layer.

## Decision

**The app shell, the business logic, the data layer and the view are all Zig
on the Native SDK.** There is no Dart, no JavaScript runtime and no embedded
WebView in the shipped product.

The shape is fixed by `apps/ros/src/main.zig`: `UiApp.create` with
`.update_fx = update_mod.update`, `.init_fx = update_mod.boot`,
`.tokens_fn = theme.tokens` and a runtime markup source of `src/app.native`
plus the embedded closure in `src/app_sources.zig`. `src/core/update.zig` is
the only function that writes model state; `src/data/repos.zig` is the only
place SQL is written; `src/core/model.zig` is the only place the view's
surface is declared.

A TypeScript core is explicitly rejected. The SDK's guarantees that make Restaurant OS
worth building are tied to the Zig declarations: `native test` refreshes
`zig-out/model-contract.zon` from the `Model` and `Msg` declarations, and
`native check` verifies every binding path, iterable, `key` field, message
tag and payload type against that contract. A TypeScript core would sit
outside the contract, would reintroduce a language boundary in the middle of
the business logic, and would need its own build, its own package manifest
and its own bridge — the FFI seam that v1 already paid for once.

The Flutter app in `../eatery` stays in the tree as the behavioural oracle
until cutover. It is not a dependency and nothing in `apps/ros` imports
it.

## Consequences

- One native binary per platform. `apps/ros/app.json` declares macOS,
  Linux and Windows, a single `main` window and a single GPU surface
  (`main-canvas`). There is no Dart runtime, no Flutter engine and no plugin
  registry to audit or to keep patched.
- The core is testable without a window. `apps/ros/src/tests.zig` has 12
  tests that build the markup tree, dispatch messages through
  `main.update` with a fake effects channel (`fakeFx`) and assert on the
  model. The same code path the runtime uses is the code path the tests
  use.
- **Cost:** the entire view layer is new code. v1's 104 files under
  `lib/pages/` become 43 `Screen` variants in `src/core/navigation.zig` and
  a template per screen in `src/screens/`. None of the Flutter widget work
  carries over.
- **Cost:** the plugin ecosystem is gone. BLE thermal printing, Lottie, XLSX,
  `image_picker`, `fl_chart` pie charts, `googleapis` Drive backup and
  in-process WebSocket all have no equivalent in the SDK. Each of those
  losses is carried by an explicit decision — a sidecar, CSV, a bar chart —
  and is listed in [`architecture/11-capability-gaps.md`](../../architecture/11-capability-gaps.md)
  and in [`plan/gaps-from-v1.md`](../../plan/gaps-from-v1.md).
- **Cost:** the toolchain is pinned and fragile. Zig 0.16.0 is required
  because the SDK does not parse 0.17, Node 24+ is required for the
  relational-schema generator, and the CLI is v0.11.0. The `native` CLI is
  not on the PATH in this workspace, so none of the build or test claims in
  this repository can be verified from here.
- **Cost:** a young platform. SDK behaviour can change between minor
  versions, so the wrapper surface in `apps/ros/src/` is kept small.
- **Cost:** mobile is not first class. `app.json` lists desktop platforms
  only, and the SDK's mobile support is experimental.
- **Cost:** the team has to learn Zig and the SDK's closed markup grammar.
  The grammar's limits are recorded in
  [`architecture/ui-components.md`](../../architecture/ui-components.md).

## Alternatives considered

- **Keep Flutter and keep patching.** Loses because the goal is a native
  single binary with a pure core, and Flutter cannot produce either. The
  v1 defect list is a list of consequences of the stack, not of the
  individual bugs: `DB5` (no transaction), `L1` (global store), `P5`
  (logic in widgets), `O8` (stringly-typed status), `A8` (no route guard).
  Fixing them inside Flutter leaves the stack.
- **Flutter with a native shell.** Loses because it carries both stacks
  permanently, doubles the release surface, and still has no GPU-canvas
  markup model — the reason the SDK was chosen.
- **A TypeScript core with a Zig or native host.** Loses because it puts a
  second language and a second runtime between the business logic and the
  platform, keeps the FFI seam in the middle of the app, and puts the
  business rules outside the model contract that `native check` verifies.
  It also makes the effects channel a bridge instead of a typed function
  argument.
- **Another native toolkit (Qt, SwiftUI, Tauri).** Loses because it repeats
  this analysis without the SDK's three specific assets: the effects
  channel, the engine-owned relational store with migrations applied at
  boot, and the declarative markup that the platform renders directly.
- **Incremental strangler (v1 screens wrapped one at a time).** Loses
  because the data model, the permission model and the view layer all
  change together. A mixed process would carry both stacks indefinitely and
  would have two sources of truth for every order.
- **Rewrite the core in Rust or C++ and bind it.** Loses for the same
  reason as the TypeScript core: the model contract, the effects channel
  and the test harness are defined over Zig declarations.

## Checklist

Before this ADR is treated as satisfied:

- [ ] `apps/ros/app.json` lists only the platforms that are actually
      built, and the list matches the release target.
- [ ] No file under `apps/ros/` references Dart, Flutter, `googleapis`,
      `fl_chart`, `lottie`, `xlsx` or `image_picker`.
- [ ] `native check` and `native test` are green on the pinned toolchain
      (Zig 0.16.0, Node 24+, CLI v0.11.0).
- [ ] `scripts/setup.sh` and `scripts/env.sh` exist and pin those versions
      (PLANNED — `scripts/` is empty today).
- [ ] The v1 app in `../eatery` is still runnable, because it is the
      behavioural oracle until cutover.
- [ ] Every capability v1 had that the SDK lacks has an entry in
      [`plan/gaps-from-v1.md`](../../plan/gaps-from-v1.md) section 1, with the
      phase that owes it.
