# ADR-0015: A session owns its state and its history

> **Status:** Accepted
> **Date:** 2026-10-21
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/03`](../architecture/03-navigation-and-rbac.md),
> [`architecture/02`](../architecture/02-app-model-and-effects.md),
> [`plan/status.md`](../plan/status.md),
> [ADR-0003](0003-no-router-screen-enum-and-stack.md)

## Context

Navigation is model state (ADR-0003), but the model had no lifecycle for
it. Three defects shared one cause:

- the stack was a log, not a history: every press pushed, including a
  press on the screen already showing;
- the stack was hard-bounded at 32 entries and refused the next push, so
  a busy service could keep pressing a rail that no longer did anything
  until the app was signed out;
- sign-in pushed the home screen onto the sign-in screen, so the first
  Back after signing in exposed a session gate - a blank shell with no
  way forward;
- session state was not a session: a new operator inherited the previous
  operator's cart, search, filters and selected table.

The symptoms were filed separately (B-009, B-010, B-011), but the rule
they were missing is one rule: **a session is a boundary, and the stack
is that session's history.** A full stack is not a permission failure,
and a session gate is not a destination behind the home screen.

## Decision

1. **One session reset path.** `resetSession(model, gate)` clears the
   operator identity, the cart, the POS filters, the waiter's table and
   lines, the last sale, the edit forms, the errors and the history, and
   lands on `gate`. `pick_role`, `login_checked`, `sign_out`,
   `pick_role_again`, a successful setup and a failed setup all call it.
   Device settings - theme, split widths, the KDS station filter, the
   installation salt and the device token - are deliberately kept.
2. **The gate is the root.** A sign-in resets straight to the role's
   home; it does not push home on top of the sign-in screen. A PIN role's
   sign-out resets to `login`; a kiosk role's sign-out resets to the role
   picker, because a kiosk has no PIN. Back from the first screen of a
   session stays on that screen.
3. **The stack is bounded history.** Pushing the screen already on top
   is a no-op. At `max_depth` (32) the OLDEST entry is dropped and the
   new destination lands. `go` cannot fail because the stack is full;
   permission is still the only reason a navigation is refused. `pop` at
   a root stays put.

## Consequences

### Positive

- A busy service can keep navigating; the stack never freezes.
- Repeated rail and shortcut presses do not grow the history.
- Back from home, or from any session's first screen, cannot expose a
  previous session or a session gate.
- The next operator starts with no cart, search, table or form from the
  previous one.
- "What survives a session" is one function, not a convention in four
  arms of `update`.

### Negative

- A very long drill-in path eventually loses its oldest entries. Back
  reaches the recent path, not the first screen of the session, once the
  stack has wrapped. This is the price of a bounded, freeze-free stack.
- A kiosk sign-out now returns to the role picker rather than the PIN
  screen. That is the correct gate for a role that has no PIN, but it is
  a behaviour change for a caller that assumed `sign_out` always meant
  `login`.

### Follow-ups

- Surface a visible Back affordance. `go_back` still has no control in
  any template; this ADR does not add one.
- Decide whether a session should also drop loaded datasets. The reset
  clears what the operator can see and act on; the next sign-in reloads
  through `loadAll`.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Refuse a push at depth 32 and show an error | The rail would still stop working after 32 presses. A visible error is better than silence, but the app is still frozen until sign-out. |
| Grow the stack without a bound | The model must stay default-constructible and cannot own a heap allocator. |
| Keep sign-in in the history and mark it non-restorable | The view would need a second rule for "back skips this entry"; resetting to the gate is simpler and has one writer. |
| Clear only the cart on sign-out | Search, filters, the selected table and half-typed forms are the same leak. The issue names the visible symptoms; the boundary is the session. |

## Evidence

- `apps/eatery/src/core/update.zig`: `resetSession`, `resetNavigation`,
  the session arms, `go`.
- `apps/eatery/src/core/navigation.zig`: `Stack.push`, `max_depth`.
- `apps/eatery/src/tests.zig`: a full history does not freeze; a repeated
  destination does not grow; a role change ends the session; sign-out
  clears the cart, filters and operator.
- `apps/eatery/src/tests_data.zig`: Back from home after a sign-in stays
  home; signing out clears the cart and the operator.
