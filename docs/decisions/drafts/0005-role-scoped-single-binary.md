# ADR-0005: One binary, four roles, scoped by a pure permission matrix

**Status:** Accepted (2026-10)
**Applies to:** `apps/eatery/src/core/navigation.zig`,
`apps/eatery/src/core/rbac.zig`, `apps/eatery/src/core/update.zig`
**Related:** [`architecture/navigation-and-roles.md`](../../architecture/navigation-and-roles.md)

## Context

v1 already ran one Flutter binary in four dispatch modes — admin, waiter,
KDS and display, chosen on first launch and persisted in SQLite. The model
was right. The mechanism was not: the role check lived in the GoRouter's
`redirect:` callback as a map of route names to sets
(`../eatery/docs/architecture/routing.md`), it was a side effect of
navigation, and the same document records that permission-based routing was
"not yet implemented" — while about 81 `Navigator.push` call sites bypassed
the router entirely. v1's own audit lists the consequence as defect **A8**
("no route guard: any user who knows a URL can navigate to any page without
logging in"). The kiosk roles were exempted inside that callback, by
comparing role strings.

v2 keeps the one-binary model and replaces the mechanism. `Role` in
`apps/eatery/src/core/navigation.zig` is `admin | waiter | kds | display`.
`rbac.allows(role, screen)` in `apps/eatery/src/core/rbac.zig` is the whole
access-control surface: a pure function with an answer for every pair, and
`apps/eatery/src/tests.zig` walks all of them.

The sizes are fixed by the matrix. Admin may open all 43 screens. Waiter may
open 12: the role picker, sign-in, the landing page, the four waiter
surfaces, the order list, the order detail, the order confirmation, the
customer list and the PIN reset. KDS and display may open four each: the
role picker, sign-in, their own board, and the order detail.

## Decision

**One binary, four roles, one permission matrix, one writer for navigation.**

The role is chosen at the role picker, which is the first screen
(`Model.role_chosen` starts `false` and `show_role_picker` is derived from
it). `update`'s `pick_role` arm sets the role, and then branches on
`Role.needs_sign_in()`:

```zig
if (role.needs_sign_in()) {
    go(model, .login);
} else {
    // Kiosk roles are signed in by device.
    model.signed_in = true;
    go(model, rbac.home(role));
    repos.loadAll(fx);
}
```

**Where the kiosk roles differ.** The whole difference is how the session is
established, and it cascades:

| | admin / waiter | kds / display |
|---|---|---|
| Session | role picker, then PIN | role picker only |
| `signed_in` set by | `login_checked` | `pick_role` |
| Operator identity | `employee_id` + `employee_name` | none; `operator_label` reads "Not signed in" |
| Home screen | `admin_dashboard` / `waiter_tables` | `kds_board` / `display_board` |
| Data loaded | after a successful sign-in | immediately on role pick |
| Allowed screens | 43 / 12 | 4 / 4 |
| PIN change, reset, lockout | yes | none |

The consequences of a device-signed session are stated plainly rather than
papered over: a kiosk action cannot be attributed to an employee, because
`employee_id` stays 0; a kiosk has no way to lock itself, so it has no way
to be safe on an open floor; and neither kiosk role may open `pos`,
`payments`, `order_confirmation` or `settings`, which is the actual
mitigation. The attribution gap is visible in the schema:
`order_status_history.changed_by` is nullable, and it will be null for a
kitchen advance.

Navigation has one writer. `go()` in `src/core/update.zig` checks
`rbac.allows` first and refuses without touching the stack or the index,
pushes second and only then writes `screen_index`, and derives
`nav_section` from the screen rather than from the caller. The rail is the
role's own table in `src/core/rbac.zig`, so it can never offer a
destination the role may not open.

## Consequences

- Four roles, one release. A customer who only wants a kitchen display
  still takes the whole application.
- The permission decision is a pure function with a total test. v1's
  defect **A8** has no analogue: `go()` refuses a destination and sets a
  reason the operator can see, and the shell renders it as a banner
  (`src/app.native` binds `has_error` and `error_message`).
- The kiosk roles are fast to start: a device signs in by picking a role,
  with no keypad and no PIN.
- **Cost:** one binary means one version for all four roles. A bug in the
  POS path ships to a wall-mounted display.
- **Cost:** kiosk actions are unauthenticated and unattributed. A kitchen
  advance cannot be tied to a person, so the audit trail has a permanent
  hole for kitchen and counter-display activity. The mitigation is the
  narrow permission list, not attribution.
- **Cost:** the kiosk roles still render the role picker, the title bar,
  the nav rail and the status bar. A wall-mounted board should boot
  straight into its own screen. `device.role` in
  `src/schema/0010_sync.sql` is where a remembered role belongs, and it
  needs an escape gesture to leave — that is Phase 3 work.
- **Cost:** `rbac.allows` and the four rail tables in `src/core/rbac.zig`
  are maintained by hand and can drift. A rail entry without a matching
  `allows` arm produces a button that refuses itself when pressed, and the
  refusal is silent in the sense that no screen changes.
- **Cost:** the four roles do not have to be four machines, but nothing
  implements that yet. The SDK can declare secondary windows over one
  model (`windows_fn`), which would let a counter machine be POS, KDS and
  customer display at once. That needs a window policy, a decision about a
  shared cart (a cashier and a waiter on one machine would collide) and a
  decision about a shared session (a second window would see the admin's
  role and the admin's operator name). All three are open.
- **Cost:** `Role.needs_sign_in()` and `rbac.home(role)` are the two
  switches the session flow depends on. A new role needs both, plus a
  `Screen` set, plus a rail table, or the role cannot be picked.
- **Cost:** the waiter's 12-screen set includes `landing`, `waiter_tables`,
  `waiter_menu`, `waiter_cart`, `waiter_orders`, `customers` and
  `reset_pin`, and none of them has a template. The waiter signs in and
  lands on an empty content pane. That is a coverage gap, not a
  permission gap, and Phase 3 closes it.

## Alternatives considered

- **Four separate binaries, one per role.** Loses because the code is the
  same for all four; four binaries would quadruple the release and
  packaging work and let the four copies drift. v1's one-binary
  role dispatch was the right product decision.
- **One binary, everyone signs in with a PIN, including the kiosk roles.**
  Loses because a kitchen board with a keypad is a worse kitchen board,
  and a customer-facing display with a PIN prompt is a display nobody
  looks at. v1 already exempted the kiosk roles from auth and the
  exemption was correct.
- **Role fixed at build time or by a command-line flag, as v1's
  `--dart-define=role` did for development.** Loses because a device is
  re-purposed by its owner during a shift, and because a build-time flag
  makes the role a packaging decision rather than an operational one.
- **Permissions in the router, as v1 did.** Loses because the check has to
  be a pure function a test can walk in full, and because the router's
  redirect callback was neither pure nor complete — v1's `redirect:` was
  the one place that knew what a role could open, and it was untested.
- **Permissions in the view, hiding screens the role may not open.** Loses
  because the model would then be reachable from a screen the role should
  not be on. The check has to happen before the state changes, which is
  what `go()` does.
- **One role per database instead of per session.** Loses because the
  role is a property of the device and the shift, not of the data: the
  same database is served by an admin POS, a waiter tablet, a kitchen
  board and a customer display.

## Checklist

Before a role or permission change is treated as done:

- [ ] `Role.needs_sign_in()` and `rbac.home(role)` are consistent with the
      session flow in `src/core/update.zig`.
- [ ] `rbac.allows` grants the screen to the roles that may open it and
      denies it to the ones that may not, and the matrix test walks every
      pair.
- [ ] Every role can still reach `role_picker` and `login`; a device is
      never locked out.
- [ ] Neither kiosk role can open `pos`, `payments`, `order_confirmation`
      or `settings`.
- [ ] A new rail entry has a matching `allows` arm and a
      `rbac.section_screen` mapping.
- [ ] Every navigation goes through `go()`; no other arm writes
      `screen_index`.
- [ ] The kiosk boot path is decided and written down: the remembered
      device role, the escape gesture, and what a kiosk close means.
