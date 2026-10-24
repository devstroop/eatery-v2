# ADR-0002: A pure Model / Msg / update core

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Devstroop maintainers
> **Related:** [`architecture/02`](../architecture/02-app-model-and-effects.md)

## Context

Flutter v1 spread state across 10 Riverpod provider files, `AsyncNotifier`s,
`FutureProvider`s and `ref.invalidate` calls. The router held a second kind
of state. Tests had to construct providers, and some behaviour was only
observable through the widget tree.

The Native SDK's app model is a single `Model` with a `Msg` union and an
`update` function. It also offers an effects channel (`fx`) that performs
I/O and returns results as messages.

## Decision

**All app state lives in one `Model`. All transitions go through
`update(model, msg, fx)`.** `update` does not perform I/O directly. It
requests effects and reacts to result messages.

Supporting rules:

- The model is default-constructible and owns fixed buffers; it never
  holds an allocator.
- Derived values are methods, not fields.
- The view binds fields and dispatches messages; it never mutates.
- Every effect has an explicit key and delivers a typed message.
- Runtime-only messages and hidden model fields are declared in
  `view_unbound`.

## Consequences

### Positive

- A headless test can reproduce any transition.
- No provider graph, no invalidation bugs, no hidden state.
- Effect results are explicit messages, so loading and error paths are
  first-class.
- The view is a pure function of the model, so screenshots and automation
  are deterministic.
- A second window over the same model (target) is trivial.

### Negative

- Every state change, including trivial UI state, pays the ceremony of a
  message.
- The model is large and must be heap-allocated.
- No allocator in `update` forces bump buffers and capacity limits.
- Derived lists allocate into a view-owned arena, which is a less familiar
  ownership model than a provider.
- A single model does not fit truly independent multi-window state (the
  cart collides if two windows edit it).

### Follow-ups

- Keep `update` arms small; push multi-step logic into helpers that take
  `(model, fx)`.
- Add the split between read loading state and write busy state; `busy` is
  currently write-only.
- Decide whether secondary windows get per-window state.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Riverpod-style graph in Zig | No reactive runtime; reimplements what the SDK already gives. |
| Mutable screen objects | Untestable without a UI; breaks headless automation. |
| Effects that write the model directly | Destroys the single-writer rule and replayability. |
| Heap allocator in the model | The model must be default-constructible. |

## Evidence

- `src/core/model.zig`, `src/core/msg.zig`, `src/core/update.zig`.
- 12 headless tests, including RBAC, cart arithmetic and a markup build.
- `Effects.init` with `fx.executor = .fake` is used by the tests.
