# ADR-0004: Four roles in one binary

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/03`](../architecture/03-navigation-and-rbac.md),
> [`architecture/07`](../architecture/07-windowing-and-desktop.md),
> [`architecture/12`](../architecture/12-three-apps-and-ipc.md)

**Proposed supersession.**
[ADR-0017](0017-three-apps-over-tcp-ip.md) proposes replacing this
decision with three apps over TCP/IP. It is **Proposed**, so this
decision stands until that one is accepted; nothing here is in force
in the code either way, because the tree still ships one binary.

## Context

Eatery serves four operating modes: admin, waiter, kitchen display and
customer display. v1 shipped one binary with a role enum and a route
guard; each device chose a role at launch.

The Native SDK can run multiple model-declared windows over one shared
model, and can hide window chrome for kiosks.

## Decision

**One binary, four roles, selected at runtime.** The role is model state
and decides the home screen, the rail and the allowed screens. Kiosk roles
(KDS, display) sign in by device; admin and waiter require a PIN.

The target delivery shape is **optional secondary windows over the same
model**: an admin machine can run POS, KDS and display simultaneously.
That part is Proposed and not built.

## Consequences

### Positive

- One artifact to build, sign and distribute.
- One schema and one set of repositories.
- A single machine can host several views (target).
- Kiosk devices need no user account.
- The permission matrix stays small and testable.

### Negative

- Kiosk actions are not attributable to an employee.
- A shared model means shared session state; a second window sees the
  admin's role.
- Multi-window window policy (which role opens what, close behaviour,
  kiosk chrome) is unresolved.
- A device cannot hand off a session between roles without signing out.

### Follow-ups

- Decide whether the device remembers its role across reboots.
- Decide how a kiosk exits (hidden gesture, PIN, menu chord).
- Decide whether secondary windows share the cart.
- If multi-window is not delivered, the role switch remains a full shell
  swap and the KDS must run on a separate machine.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Four binaries | Four builds, four schemas, four release paths. |
| Role fixed at build time | Loses the "one installer" property and complicates support. |
| Web admin + native kiosk | Adds a second stack; contradicts the single-binary goal. |
| Separate processes per role | Duplicate state and a sync requirement on one machine. |

## Evidence

- `src/core/navigation.zig`: `Role`, `home`, `needs_sign_in`.
- `src/core/rbac.zig`: rail tables and the matrix.
- `app.json` and `src/main.zig`: one window today.
- `PORT-PLAN.md` §6: multi-window mapping.
