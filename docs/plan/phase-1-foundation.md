# Phase 1 — Foundation: model, navigation, theme, shell

> **Status:** Partial
> **Estimate:** 4 engineer-days
> **Depends on:** Phase 0
> **Exit criterion:** automation walks role picker → login → dashboard
> shell, and every role reaches a rendered home screen.

## Goal

The frame every later screen hangs on: a pure model, an append-only screen
enum, a permission matrix, design tokens, and a shell that adapts to the
role.

## What exists

- `Model` with session, navigation, company, datasets, cart and runtime
  state.
- `Msg` union and `update` with session, navigation, data and chrome arms.
- `Role`, `Screen` (43 values), `Stack` (depth 32).
- `rbac.allows`, `rbac.home`, `rbac.nav_sections`, `rbac.section_screen`.
- Light and dark `DesignTokens`; `toggle_theme`.
- `app.native`: title bar, role picker gate, login gate, rail + content
  split, status bar.
- Role picker and login templates.
- `go()` guard and `open_section`.

## What is missing

| Item | Detail |
|---|---|
| Screen templates | 36 of 43 screens have no template |
| Mounted screens | Only 5 (`dashboard`, `pos`, `orders`, `dining_tables`, `kds_board`) |
| Waiter home | `waiter_tables` is allowed but not rendered |
| Display home | `display_board` is allowed but not rendered |
| Layout mode | No wide/narrow computation; no rail↔tabs switch; no table↔card switch |
| Back affordance | `go_back` exists; nothing dispatches it |
| Role memory | Every boot starts at the role picker |
| Exact RBAC test | The matrix test only asserts lock-out guarantees |
| Screen coverage test | Nothing detects a blank pane |
| Ordinal contract test | Nothing protects the append-only enum |
| Setup / fresh install | No company or employee creation, so login cannot succeed on a fresh DB |

## Tasks

1. **Lock the ordinal contract.** Add a test that asserts the index of every
   mounted screen, or generate the shell gates from a table.
2. **Make coverage visible.** Add a test that, for each role, opens every
   allowed screen and asserts a rendered landmark or an explicit
   "unavailable" state.
3. **Render the waiter home** (`waiter_tables` → a waiter table template).
4. **Render the display home** (`display_board` → a status board).
5. **Add `layout_mode`** to the model, computed from window size, and use
   it for rail vs tabs and table vs card list.
6. **Add a back affordance** (button in the header, or a keyboard chord)
   that dispatches `go_back`.
7. **Remember the device role** in `app_config` if the product wants it;
   otherwise document the boot-at-role-picker decision.
8. **Tighten the RBAC test** to an exact allowed-set assertion per role.
9. **Close the provisional-salt window**: refuse sign-in while
   `salt_is_provisional` is true, or load the salt before the login
   screen can be submitted (see D1 in [`status.md`](status.md)).

## Exit criterion

A headless test or an automation run can:

- start at the role picker;
- choose each role;
- sign in (PIN or device);
- reach a rendered home screen;
- open every section in that role's rail and land on something visible.

## Risks

| Risk | Mitigation |
|---|---|
| Adding a screen in the middle of the enum remaps the shell | Append-only rule + ordinal test |
| Layout mode spreads through every template | Compute it once in the model; pass it as a binding |
| Waiter/display templates become bespoke snowflakes | Extract shared header/empty-state components first |
| Role memory conflicts with kiosk security | Default to the picker; make memory opt-in |

## Unknowns

- Does the product want a device to remember its role?
- Is the waiter home the table grid, the order list, or a dashboard?
- Does the display board show one order, a queue, or a rotating list?
- What is the narrow-layout breakpoint?

See [`../open-questions.md`](open-questions.md).
