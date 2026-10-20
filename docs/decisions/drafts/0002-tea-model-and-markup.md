# ADR-0002: Model / Msg / update with declarative markup

**Status:** Accepted (2026-10)
**Applies to:** `apps/eatery/src/core/**`, `apps/eatery/src/app.native`,
`apps/eatery/src/screens/**`
**Related:** [`architecture/overview.md`](../../architecture/overview.md),
[`architecture/ui-components.md`](../../architecture/ui-components.md)

## Context

v1 spread state across three places that each thought they owned it: a
Riverpod provider graph, a GoRouter route table, and the widget tree. The
permission check lived in the router's `redirect:` callback
(`../eatery/docs/architecture/routing.md`), and that same document
records that permission-based routing was "not yet implemented" and that
about 81 `Navigator.push` call sites remained outside the router. Business
logic sat in widgets: `../eatery/docs/plan/issue-inventory.md` defect **P5** puts
roughly 130 lines of `placeOrder()` — order creation, tax calculation,
table status update and print logic — inside `cart.page.dart`. Derived
values were recomputed by hand on every build: defect **P4** runs
`getAllProducts()` on every frame rebuild, defect **CS1** runs
`getAllCustomers()` three or more times per frame, and defect **PR6**
re-queries the category list inside a builder. The lifecycle was
stringly-typed (defect **O8**: `Order.status` is a raw string, any value can
be assigned).

The Native SDK's markup grammar has no setter. An `on-*` attribute names a
tag of the `Msg` union and, optionally, a binding path for the payload.
There is no `bind=` that writes a field, no expression with a side effect,
and no computed message name. "The view never mutates state" is therefore a
property of the language rather than a convention the codebase has to
police — and `native check` verifies every binding against the reflected
model contract, so a binding to a field that does not exist is a build
failure.

## Decision

**One `Model`, one `Msg` union, one `update(model, msg, fx)`, and a
declarative view.** `apps/eatery/src/core/model.zig` declares every fact
the app knows; `apps/eatery/src/core/msg.zig` declares every thing that can
happen; `apps/eatery/src/core/update.zig` is the only writer of model
state; `apps/eatery/src/app.native` and the templates in
`apps/eatery/src/screens/` are the view.

`update` is a pure function of `(model, message)`. It reads no clock, opens
no file and queries no database. Everything the world holds — the database,
the wall clock, files, the clipboard, a printer — is reached through the
effects channel, and every answer comes back as another message. That is
why `apps/eatery/src/tests.zig` can drive the whole app headlessly with
`fx.executor = .fake`.

Two corollaries are part of the decision, not conveniences:

- **Derived values are methods, never stored fields.** `open_order_count`,
  `cart_total_minor`, `visible_products`, `kitchen_tickets` and
  `ticket_count` are all methods on `Model`. A stored field that could be
  computed has to be re-maintained by every arm of `update` that could
  affect it, and goes stale the moment one of them is missed.
- **The model's public surface is the struct body.** A file-scope function
  written next to `pub const Model = struct` is invisible to the binding
  resolver; `Model.view_unbound` and `Msg.view_unbound` declare the
  boundary between "the model" and "the interface".

## Consequences

- The whole app is testable without a window: build the tree, dispatch a
  message the way the runtime does, assert on the model. `src/tests.zig`
  already has 12 such tests, including the permission matrix walked over
  every `(role, screen)` pair.
- Navigation is model state rather than a route table: a `Screen` enum, a
  fixed-capacity `Stack` in `src/core/navigation.zig`, and one writer —
  `go()` in `src/core/update.zig` — that checks `rbac.allows` before it
  pushes. The v1 defect **A8** (no route guard) has no analogue here.
- **Cost:** the markup expression grammar is small and closed. Seventeen
  functions, no `else-if` chain, no negation sugar, no ternary, no method
  calls on a row, and colour and radius attributes take token names as
  literals — `foreground="{order.tone}"` is rejected, which is why
  `src/screens/screen-tables.native` shows a status as a badge rather than
  a coloured tile. Every small convenience a widget tree offers has to
  become a model method or a second template.
- **Cost:** message payloads must be bindings, never literals. A constant
  needs its own message, which is why `Msg` carries `set_category_all`
  beside `set_category`.
- **Cost:** tables the markup binds must be file-scope constants. A
  composite literal built inside a function lives on that function's stack
  frame, and returning a slice of it hands the view a pointer to dead
  memory — the trap `src/core/rbac.zig` documents in a long comment after
  it bit once already.
- **Cost:** the model must be default-constructible, because the runtime
  builds it as `.{}`. It cannot own a heap allocator, so its rows live in
  fixed-capacity bump buffers (`src/core/bump.zig`: 96 KiB for products,
  48 KiB for orders, 48 KiB for order lines, and so on). A row that does
  not fit is dropped, not fatal — the bound is the compiler's.
- **Cost:** page bytes are drain scratch. They are valid through the update
  that receives them and dead after it, so every value the model keeps has
  to be copied into its bump buffer. `src/data/page.zig` states the rule;
  `src/data/repos.zig` obeys it.
- **Cost:** `update` has no allocator, so any derived list has to be built
  in the arena the view owns — the `(*const Model, std.mem.Allocator)`
  method form used by `visible_products` and `kitchen_tickets`.
- **Cost:** `Screen` is an append-only contract. `src/app.native` gates on
  literal ordinals (`screen_index == 8`, `10`, `13`, `17`, `41`), so
  inserting a variant in the middle of the enum silently remaps every gate.
  The ordinals need a test; there is not one yet.
- **Cost:** the view must be mounted one screen at a time to stay inside
  the 1024 retained-widget-node budget per view. Only the active screen
  contributes nodes, which is why the shell is a set of `<if>` gates rather
  than a container that swaps children.
- **Cost:** the whole UI is rewritten by hand. v1's widget vocabulary
  (`AppFormField`, `AppMultiStepForm`, `AppDialog`, `AppNotificationBanner`)
  has no equivalent library in v2; `apps/eatery/src/components/` is empty
  and building it is Phase 2 work.

## Alternatives considered

- **A retained-mode widget tree built in Zig.** Loses because it puts
  painting and state in the same place, which is the arrangement that
  produced v1's defects P5, P4, CS1 and PR6. The SDK's markup grammar
  removes the possibility of a view writing state, which is worth more
  than the flexibility a retained tree would buy.
- **Keep a router-driven app, as v1 did.** Loses because the route table
  is where v1 put the permission check, and it was neither pure nor
  tested: `../eatery/docs/architecture/routing.md` records the guard as unimplemented
  and 81 `Navigator.push` sites bypassing it. `rbac.allows` is a pure
  function a test can walk in full.
- **Riverpod-style providers inside the Zig app.** Loses because it creates
  two sources of truth for state; the `Model` would stop being total and
  `update` would stop being a pure function of `(model, message)`, which
  is the property the whole test suite is built on.
- **A pure Elm/Redux-style core with a hand-written renderer.** Loses
  because it gives the purity but not the view. The SDK's markup is the
  view, it renders directly on the GPU canvas, and the platform's
  accessibility, focus and layout machinery comes with it.
- **Keep the business logic in a TypeScript service and drive it from Zig.**
  Loses because the update loop would cross a language boundary on every
  message; the model contract that `native check` verifies would no longer
  cover the code that holds the rules.

## Checklist

Before a change to the app model is treated as done:

- [ ] Every state change is an arm of `update` in `src/core/update.zig`;
      nothing outside it writes a model field.
- [ ] Every value the view binds is a field, a zero-argument method inside
      the `Model` struct body, or a field of a `for` variable.
- [ ] Every derived value is a method, not a stored field.
- [ ] New private fields are added to `Model.view_unbound`; new
      runtime-delivered messages are added to `Msg.view_unbound`.
- [ ] Every message payload in markup is a binding path; constants have
      their own message.
- [ ] Every table the markup binds is a file-scope constant with
      comptime-known contents.
- [ ] `native check` is clean and `native test` is green.
- [ ] The mounted node count is inside the budget — `native automate
      snapshot` reports `widget_nodes=N/1024`.
