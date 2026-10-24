# ADR-0011: Desktop first; defer mobile

> **Status:** Proposed — needs a product decision
> **Date:** 2026-10-20
> **Deciders:** Product, Devstroop maintainers
> **Related:** [`architecture/07`](../architecture/07-windowing-and-desktop.md),
> [`plan/open-questions.md`](../plan/open-questions.md)

## Context

v1 shipped on Android and iOS. The waiter flow in particular is used on
tablets. The Native SDK's mobile packaging is experimental, and its design
language is desktop-oriented. The desktop targets (macOS, Linux, Windows)
are the mature path.

A restaurant install often has a counter desktop, a kitchen screen and
waiter tablets. Dropping mobile is not a neutral choice.

## Decision

**Proposed: ship desktop first (macOS, then Linux/Windows) and treat mobile
as a separate, later effort.**

- The Restaurant OS UI targets a 1280×800 desktop window with a 960×600 floor.
- Touch-first interaction (large targets, gestures, on-screen keyboard) is
  not designed.
- A tablet build is explicitly out of scope until the desktop release is
  stable.
- The data model and RBAC stay platform-agnostic so a later mobile shell
  can reuse the core.

## Consequences

### Positive

- Ships on the platform the SDK supports best.
- Avoids designing two interaction models at once.
- The counter/KDS/display desktop story is the strongest part of Restaurant OS.
- Packaging and signing are understood on macOS.

### Negative

- Waiter tablets are unsupported, which may block real deployments.
- The touch layout is not validated.
- A later mobile effort may require model and markup changes (layout
  mode, gestures, virtual keyboard).
- The product's addressable market shrinks for the first release.

### Follow-ups

- Confirm which roles actually need mobile in the first release.
- If tablet is required, define a touch layout mode and a device profile
  before phase 5.
- Investigate the SDK's mobile target status at the time of the decision.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Mobile first | The SDK's mobile path is experimental; desktop is the mature target. |
| Desktop + mobile simultaneously | Doubles design and test surface before the desktop core is stable. |
| Responsive web for mobile | A second stack; contradicts the single-binary goal. |
| Desktop only, permanently | Rejects a real part of the current product; keep it as a later option. |

## Evidence

- `app.json`: `platforms: ["macos", "linux", "windows"]`.
- `src/main.zig`: a 1280×800 desktop window.
- `PORT-PLAN.md` §7 rows 51–52, §12 decision 4–5.
- The SDK's mobile packaging is described as experimental in the plan.
