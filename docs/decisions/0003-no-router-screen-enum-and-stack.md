# ADR-0003: No router; a screen enum and a stack

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/03`](../architecture/03-navigation-and-rbac.md)

## Context

Eatery v1 had 77 `GoRoute` entries with a `redirect:` callback for RBAC
and six slide transitions. The router was the only place that knew which
role could open which screen, and it was not unit-tested; the router
regression test was stale.

The Native SDK has no router. Navigation is whatever the model says it is.

## Decision

**Navigation is model state.** A `Screen` enum names every destination.
`screen_index` is the current one. A fixed-capacity `Stack` holds history.
`rbac.allows(role, screen)` is the only permission check, called from a
single `go()` helper.

The enum is **append-only**; markup compares ordinals, so reordering
variants is a silent breakage. Screens are reached by `open_section`
(rail), `open_screen` (explicit) or session transitions.

## Consequences

### Positive

- One guard, one stack, no router callback.
- The permission matrix is a pure function and is tested.
- A denied navigation has a defined outcome: stay put, set `error_text`.
- No transition subsystem to debug.
- Kiosk apps do not need URLs or deep links.

### Negative

- No deep links, no browser history, no route-level code splitting.
- No free back-button semantics; `go_back` exists but has no visible
  affordance.
- The ordinal contract is fragile; a test is needed (and is missing).
- A full-screen modal or multi-step wizard needs explicit screen variants
  rather than routes.
- Screen coverage and the enum can drift: 43 enum values, 5 mounted
  templates.

### Follow-ups

- Add a test asserting the ordinal of every rendered screen, or generate
  the shell gates from the enum.
- Add a visible back affordance for drill-in screens.
- Decide whether unreachable screens stay in the enum or are removed.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Port GoRouter semantics | The SDK has no router; reimplementing one in Zig adds surface for no product value. |
| One screen field, no stack | Loses return paths and makes drill-in awkward. |
| URL-like string paths | No external entry point; strings would be untyped. |
| Per-role enum subsets | Duplicates screens and makes the matrix harder to read. |

## Evidence

- `src/core/navigation.zig`: `Role`, `Screen` (43 values), `Stack`.
- `src/core/rbac.zig`: `allows`, `home`, `nav_sections`.
- `src/core/update.zig:329`: `go`.
- Tests: kiosk denied navigation, back, role routing.
