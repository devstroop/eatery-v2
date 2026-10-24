# Navigation and roles

> **Status:** Implemented. Nine templates exist: six are mounted in the
> shell and two are session gates. The other 36 `Screen` values are
> reachable in the model but have no template. Multi-window delivery is a
> **plan** (see the last section), not a feature.
> **Verification:** source review only. The Native SDK CLI is not
> installed in this workspace, so nothing below was exercised against a
> running build.
> **Source of truth:** `src/core/navigation.zig`, `src/core/rbac.zig`,
> `src/core/model.zig`, `src/core/update.zig`, `src/app.native`,
> `src/screens/*.native`, `src/tests.zig`.
> **Related:** [ADR-0003](../decisions/0003-no-router-screen-enum-and-stack.md),
> [ADR-0004](../decisions/0004-four-roles-one-binary.md),
> [03-navigation-and-rbac](03-navigation-and-rbac.md),
> [07-windowing-and-desktop](07-windowing-and-desktop.md).

## There is no router

Navigation is model state. There is no route table, no URL, no deep link
and no transition system. A navigation is three things and nothing else:

1. a `Screen` enum value,
2. a push onto a fixed-capacity stack,
3. a `usize` the markup compares against.

Eatery v1 had 77 `GoRoute` entries with a `redirect:` callback that owned
the permission check. That callback was the one place that knew what a
role could open, and it was untested. Restaurant OS moves the same decision into a
pure function (`core/rbac.zig`) that a test is meant to walk in full (the
current matrix test is tautological; see the documentation audit),
and leaves the drawing of the result to the markup.

The consequence that matters in practice: **the view never decides where
the operator is.** The markup binds a number and compares it; the model
owns the number. Any question of the form "can this role be on that
screen?" is answered in `update`, before the state changes, and the
answer is a boolean from `rbac.allows`.

The model owns the whole navigation surface:

```zig
// src/core/model.zig
/// The screen being shown, as the index into `core/navigation.zig`'s
/// `Screen`. The markup compares this against fixed positions, so
/// the enum order is a contract: append, never reorder.
screen_index: usize = 0,
/// The nav rail's own index, so the rail can mark the current
/// section.
nav_section: usize = 0,
/// The history behind the current screen.
stack: Stack = .{},
```

`stack` is listed in `Model.view_unbound`: the history is model state the
view must never see. The view sees `screen_index` and `nav_section`, and
nothing else about navigation.

## The Screen enum is an append-only contract

`Screen` names every destination in the product - 43 values, indices
0 to 42:

```zig
// src/core/navigation.zig
/// Every destination in the product. The order of this enum is the
/// navigation contract: `Screen.index()` is what the markup compares
/// against, so **never reorder the variants** - append new ones at the end.
pub const Screen = enum {
    // onboarding and session
    role_picker,
    login,
    ...
    // kiosk
    kds_board,
    display_board,

    pub fn index(self: Screen) usize {
        return @intFromEnum(self);
    }
```

`Screen.index()` is `@intFromEnum`, so the declaration order IS the
number the view sees. The model stores the number, not the enum:

```zig
// src/core/model.zig
pub fn screen(model: *const Model) Screen {
    return std.enums.fromInt(Screen, model.screen_index) orelse .role_picker;
}
```

The `orelse .role_picker` fallback means a stale or out-of-range
`screen_index` degrades to the first screen rather than trapping. That
is a safety net, not a licence: the mapping is meant to be exact.

### The rule

**New screens are appended at the end of the enum. Variants are never
reordered, never inserted in the middle, never removed.**

The reason is that the markup hard-codes the ordinals:

```xml
<!-- src/app.native -->
<if test="{screen_index == 8}"><use template="screen-dashboard"/></if>
<if test="{screen_index == 10}"><use template="screen-pos"/></if>
<if test="{screen_index == 13}"><use template="screen-orders"/></if>
<if test="{screen_index == 17}"><use template="screen-tables"/></if>
<if test="{screen_index == 41}"><use template="screen-kitchen"/></if>
```

Reordering the enum does not produce a compile error. It produces a shell
that mounts the wrong template, or none. The mapping the shell encodes:

| Ordinal | `Screen` | Template | Rail section |
|---|---|---|---|
| 0 | `role_picker` | `screen-role-picker` | none (top-level gate) |
| 1 | `login` | `screen-login` | none (top-level gate) |
| 8 | `admin_dashboard` | `screen-dashboard` | overview |
| 10 | `pos` | `screen-pos` | sell |
| 13 | `orders` | `screen-orders` | orders |
| 17 | `dining_tables` | `screen-tables` | floor |
| 41 | `kds_board` | `screen-kitchen` | kitchen |

The remaining 36 enum values have no gate, so the content pane is empty
when they are current. `native check` cannot catch this class of drift
on its own, because the ordinals are integers in an attribute; a test is
the only guard, and there is not one yet (see the checklist).

### How the markup gates a screen

The shell is a set of `<if>` gates over the screen templates. There is
no `else`, no `else-if` chain, and no dynamic template name - the
closed grammar has no mechanism for "mount the template for the current
screen". Each candidate screen is a separate gate, and only the matching
one mounts:

```xml
<!-- src/app.native -->
<if test="{show_role_picker}">
  <use template="screen-role-picker"/>
</if>

<if test="{show_login}">
  <use template="screen-login"/>
</if>

<if test="{show_shell}">
  <split grow="1" value="{rail_split}" on-resize="rail_resized">
    ...
    <column grow="1">
      <if test="{screen_index == 8}"><use template="screen-dashboard"/></if>
      <if test="{screen_index == 10}"><use template="screen-pos"/></if>
      ...
    </column>
  </split>
</if>
```

Two things follow from this shape:

- **Only the active screen is mounted.** The gates are siblings inside a
  column, and only one `<if>` is true at a time, so the other screens
  contribute no nodes. That is what keeps the 1024-node budget per view
  within reach with a hundred-product menu in the POS.
- **The expression is an equality against a number.** The markup never
  compares a `Screen` value; it compares `screen_index`, the model's
  number. A boolean predicate method on the model
  (`pub fn showing_pos(model: *const Model) bool`) is the alternative
  shape, and it costs one method per screen.

The top-level gates use model methods rather than ordinals, because they
are about session state, not destination:

```zig
// src/core/model.zig
pub fn show_role_picker(model: *const Model) bool {
    return !model.role_chosen;
}

pub fn show_login(model: *const Model) bool {
    return model.role_chosen and !model.signed_in;
}

pub fn show_shell(model: *const Model) bool {
    return model.signed_in;
}
```

## The navigation stack

`nav.Stack` is a fixed-capacity array, because the model must be
default-constructible (the runtime builds it as `.{}`) and `update` has
no allocator to hand out.

```zig
// src/core/navigation.zig
/// The navigation stack. A fixed-capacity array, because the model must
/// be default-constructible and `update` has no allocator to hand out.
///
/// The stack holds the session's history with the current screen on top,
/// so `back` is always "drop the top and show the new top".
pub const max_depth = 32;

pub const Stack = struct {
    items: [max_depth]Screen = undefined,
    len: usize = 0,
```

| Operation | Behaviour | Bound |
|---|---|---|
| `push(screen)` | No-op when the screen is already on top; at depth 32 drops the oldest entry and appends | `max_depth = 32` |
| `pop()` | Drops the top, returns the new top. Returns `null` at a root | — |
| `resetTo(screen)` | Discards the history, lands on one screen | — |
| `current()` | The screen on top, `null` when empty | — |
| `peek()` | The screen under the top, `null` at a root | — |

The depth bound is history length, not a refusal: a full stack drops
its OLDEST entry, so a busy service can keep navigating. `go` refuses
only for permissions. See
[ADR-0015](../decisions/0015-session-scoped-navigation.md).

### The one writer

Every navigation in the app goes through one helper in
`src/core/update.zig`:

```zig
/// Move to a screen, refusing destinations the role may not open.
fn go(model: *Model, screen: Screen) void {
    if (!rbac.allows(model.role, screen)) {
        model.error_text = "This role cannot open that screen";
        return;
    }
    model.stack.push(screen);
    model.screen_index = screen.index();
    model.nav_section = sectionIndex(screen);
}
```

Three properties of `go` are load-bearing:

1. **The permission check comes first.** A refused navigation does not
   touch the stack, so the history cannot contain a screen the role may
   not see.
2. **The push and the index write happen together.** A full stack drops
   its oldest entry rather than refusing, so the stack and the index
   cannot disagree.
3. **The nav section is derived from the screen**, not set by the
   caller, so the rail's highlight can never point at a section the
   current screen is not in.

The only other writers of `screen_index` are the session transitions,
which go through `resetSession(model, gate)` and `resetNavigation` in
`src/core/update.zig`. The reset clears the operator, cart, filters,
waiter state, last sale, forms, errors and history, then lands on the
gate:

```zig
fn resetNavigation(model: *Model, gate: Screen) void {
    model.stack.resetTo(gate);
    model.screen_index = gate.index();
    model.nav_section = sectionIndex(gate);
}
```

A PIN role's sign-out resets to `login`; a kiosk role's sign-out resets
to the role picker. A successful sign-in resets to the role's home, so
the sign-in screen is never behind the first screen of the session.

### How the stack is reached from the markup

Two messages move between screens:

| Message | Payload | Handler |
|---|---|---|
| `open_screen` | `u8` - the `Screen` index | `go(model, screen)` |
| `open_section` | `u8` - the nav section id | `go(model, rbac.section_screen(section))` |
| `go_back` | none | `model.stack.pop()` |

```zig
.open_screen => |index| {
    const screen = std.enums.fromInt(Screen, index) orelse return;
    go(model, screen);
},

.go_back => {
    if (model.stack.pop()) |screen| {
        model.screen_index = screen.index();
        model.nav_section = sectionIndex(screen);
    }
},
```

`go_back` is the one place that pops, and it is the only place that
writes `screen_index` without a `go`. It does not consult `rbac`: the
screen under the top was already vetted when it was pushed, and the role
cannot change while the shell is up without a sign-out, which resets the
stack anyway.

**`go_back` has no visible affordance.** No template binds it. A kiosk
operator who has drilled into a screen has no way back except the role
picker. This is a known gap, tracked in
[ADR-0003](../decisions/0003-no-router-screen-enum-and-stack.md).

## The four roles and the permission matrix

`Role` names the four operating modes one device can run in:

```zig
// src/core/navigation.zig
pub const Role = enum {
    admin,
    waiter,
    kds,
    display,
```

One binary, four dispatch modes. The role decides the home screen, the
rail and the allowed screens.

| Role | Label | Sign-in | Home screen | Rail sections | Allowed screens |
|---|---|---|---|---|---|
| `admin` | Admin | PIN | `admin_dashboard` | Overview, Sell, Orders, Floor, Catalog, People, System | 43 (all) |
| `waiter` | Waiter | PIN | `waiter_tables` | Service | 12 |
| `kds` | Kitchen | none (device) | `kds_board` | Kitchen | 4 |
| `display` | Display | none (device) | `display_board` | Display | 4 |

`rbac.allows(role, screen)` is the whole access-control surface of the
app, and it is a total pure function - every (role, screen) pair has an
answer:

```zig
// src/core/rbac.zig
pub fn allows(role: Role, screen: Screen) bool {
    return switch (role) {
        .admin => true,
        .waiter => switch (screen) {
            .role_picker, .login, .landing,
            .waiter_tables, .waiter_menu, .waiter_cart, .waiter_orders,
            .orders, .order_detail, .order_confirmation,
            .customers, .reset_pin,
            => true,
            else => false,
        },
        .kds => switch (screen) {
            .role_picker, .login, .kds_board, .order_detail,
            => true,
            else => false,
        },
        .display => switch (screen) {
            .role_picker, .login, .display_board, .order_detail,
            => true,
            else => false,
        },
    };
}
```

The sets, written out:

| Role | Allowed screens |
|---|---|
| `admin` | every screen in the enum |
| `waiter` | `role_picker`, `login`, `landing`, `waiter_tables`, `waiter_menu`, `waiter_cart`, `waiter_orders`, `orders`, `order_detail`, `order_confirmation`, `customers`, `reset_pin` |
| `kds` | `role_picker`, `login`, `kds_board`, `order_detail` |
| `display` | `role_picker`, `login`, `display_board`, `order_detail` |

Four guarantees fall out of the matrix, and each one is a test:

1. **No role is ever locked out.** `role_picker` and `login` are in
   every role's set, so a device can always reach the role picker and
   change role.
2. **The kiosk roles exclude everything that moves money.** Neither
   `kds` nor `display` may open `pos`, `payments`, `order_confirmation`
   or `settings`.
3. **The shared screens are the boring ones.** `order_detail` is the
   only non-boarding screen both kiosks may open, which is what a
   customer display needs to show one order and what the kitchen needs
   to read a note.
4. **The matrix is walked, not sampled.** The test iterates
   `std.enums.values(Role)` against `std.enums.values(Screen)`.

### Allowed is not the same as rendered

The matrix is broader than the mounted surface. `waiter` may open
`waiter_tables`, `waiter_menu`, `waiter_cart`, `waiter_orders`,
`customers`, `reset_pin` and `landing` - none of which has a template.
The waiter signs in, lands on `waiter_tables`, and the content pane is
empty. The `display` role lands on `display_board`, which also has no
template.

The same gap exists on the admin rail: `Catalog` opens
`product_categories`, `People` opens `employees` and `System` opens
`settings` - three of the seven admin rail entries lead to an empty
pane.

This is a coverage gap, not a permission gap: `rbac.allows` is doing its
job, and the shell has not caught up. A screen-coverage test that
asserts "every allowed screen is either mounted or explicitly listed as
unavailable" does not exist yet.

## How a denied navigation is handled

A denied navigation has one outcome, and it is the same outcome for
every trigger:

- the model does not move (`screen_index`, `stack` and `nav_section` are
  untouched),
- `model.error_text` is set to a human-readable reason,
- the view does not change.

The denial happens in `go`, before the push. There is no second path
into `screen_index` that skips the check - `open_screen`, `open_section`,
`pick_role`, `login_checked` and `order_placed` all call `go`.

```zig
test "a role cannot open a screen it may not use" {
    ...
    // The kiosk asks for the settings screen.
    main.update(&model, .{ .open_screen = @intCast(nav.Screen.settings.index()) }, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
    try testing.expect(model.error_text.len > 0);
}
```

The refusal is total, not a soft warning: the kiosk stays on its board.

### The denial is visible

The denial sets `error_text`, and the shell now renders it. The model
exposes a derived `has_error` and `error_message`; `app.native` binds them
to a banner with a **Dismiss** button that dispatches `dismiss_error`:

```xml
<if test="{has_error}">
  <row padding="8" gap="8" cross="center" background="destructive">
    <text foreground="destructive_text" grow="1">{error_message}</text>
    <button size="sm" variant="ghost" on-press="dismiss_error">Dismiss</button>
  </row>
</if>
```

`error_text` therefore left `view_unbound`; the binding surface is the two
methods. The same banner now surfaces the other failure copy ("The cart is
empty", "Could not save the order", "Storage error", ...), which was
previously recorded but invisible.

Two residual issues:

- the banner is a single global line, so a background read failure can
  overwrite a more urgent write failure;
- `view_unbound` still lists `"pending_screen"`, which is not a field. It
  is a stale entry, harmless today, but evidence that the list is not
  re-checked when the model changes.

## The nav rail

The rail is a list of the sections the **current role** may open. It is
derived, not stored: `Model.nav_sections` returns the role's table, and
`rbac.nav_sections` returns a file-scope constant.

```zig
// src/core/model.zig
/// The rail rows for the current role.
pub fn nav_sections(model: *const Model) []const nav.NavItem {
    return rbac.nav_sections(model.role);
}
```

```zig
// src/core/rbac.zig
const admin_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.overview), .label = "Overview" },
    .{ .id = @intFromEnum(nav.NavSection.sell), .label = "Sell" },
    .{ .id = @intFromEnum(nav.NavSection.orders), .label = "Orders" },
    .{ .id = @intFromEnum(nav.NavSection.floor), .label = "Floor" },
    .{ .id = @intFromEnum(nav.NavSection.catalog), .label = "Catalog" },
    .{ .id = @intFromEnum(nav.NavSection.people), .label = "People" },
    .{ .id = @intFromEnum(nav.NavSection.system), .label = "System" },
};

const waiter_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.service), .label = "Service" },
};

const kitchen_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.kitchen), .label = "Kitchen" },
};

const display_rail = [_]nav.NavItem{
    .{ .id = @intFromEnum(nav.NavSection.display), .label = "Display" },
};

/// The screens a role can reach from the shell rail, in rail order.
/// The shell draws exactly this list, so the rail can never show a
/// destination the role may not open.
pub fn nav_sections(role: Role) []const nav.NavItem {
    return switch (role) {
        .admin => &admin_rail,
        .waiter => &waiter_rail,
        .kds => &kitchen_rail,
        .display => &display_rail,
    };
}
```

Because the rail is the role's table and the permission check is the
matrix, **the rail can never offer a destination the role may not
open**. The two are maintained by hand, so they can drift - a new rail
entry without a matching `allows` arm produces a button that refuses
itself when pressed.

The rows are plain data on purpose:

```zig
// src/core/navigation.zig
/// One row of the navigation rail. The markup binds `id` and `label`
/// directly - it cannot call a method on a row, so a row is plain data.
pub const NavItem = struct {
    id: usize,
    label: []const u8,
};
```

The shell draws them in a `for`, marks the current one, and dispatches
`open_section` with the row's id:

```xml
<!-- src/app.native -->
<column width="200" gap="2" padding="12" background="surface">
  <text size="sm" foreground="text_muted">NAVIGATION</text>
  <for each="nav_sections" key="id" as="section">
    <list-item selected="{section.id == nav_section}" on-press="open_section:{section.id}">{section.label}</list-item>
  </for>
  <separator/>
  <text size="sm" foreground="text_muted">{operator_label}</text>
</column>
```

`nav_section` is the model field that holds the current section's index
(`model.nav_section`, set by `sectionIndex(screen)`), so the
`selected` comparison is a plain equality between two numbers.

### The section-to-screen table

A rail entry is a section; a section opens a screen. The mapping is
another file-scope table:

```zig
// src/core/rbac.zig
/// The screen a nav section opens.
pub fn section_screen(section: nav.NavSection) Screen {
    return switch (section) {
        .overview => .admin_dashboard,
        .sell => .pos,
        .orders => .orders,
        .floor => .dining_tables,
        .catalog => .product_categories,
        .people => .employees,
        .system => .settings,
        .service => .waiter_tables,
        .kitchen => .kds_board,
        .display => .display_board,
    };
}
```

`Screen.nav_section()` is the inverse map, and returns `null` for a
screen that is reached by drilling in rather than by a tab:

```zig
/// The nav tree the shell draws for a role. `null` means the screen is
/// not in the role's rail - it is reached by drilling in, not by a tab.
pub fn nav_section(self: Screen) ?NavSection {
    return switch (self) {
        .admin_dashboard, .control_center, .reports => .overview,
        .pos, .pos_cart, .order_confirmation => .sell,
        ...
        else => null,
    };
}
```

### Fixed defect: `open_section` conflated a section id with a row index

This bug was fixed after this page was first written. It is kept because
the failure mode is easy to reintroduce.

The markup dispatches the section's **id** (the `NavSection` enum
ordinal). The update arm used to treat the payload as an **index into the
role's rail array**:

```zig
// src/core/update.zig
.open_section => |index| {
    const sections = rbac.nav_sections(model.role);
    if (index >= sections.len) return;
    const section = std.enums.fromInt(nav.NavSection, sections[index].id) orelse return;
    go(model, rbac.section_screen(section));
},
```

The two coincide for the admin rail, whose ids are 0 to 6 and whose array
is in that order. They diverge for every other role:

| Role | Rail | `section.id` | `sections.len` | Result |
|---|---|---|---|---|
| `admin` | Overview..System | 0..6 | 7 | works (ids happen to be the positions) |
| `waiter` | Service | 7 | 1 | `7 >= 1` - the move is silently refused |
| `kds` | Kitchen | 8 | 1 | `8 >= 1` - silently refused |
| `display` | Display | 9 | 1 | `9 >= 1` - silently refused |

So the admin rail navigates and the other three rails do not. The
refusal is silent: no error is set, the screen does not change, and the
operator sees a button that does nothing. The admin's three dead-end
sections (Catalog, People, System) mask the symptom, because they
already land on an empty pane.

The fix is in place: the payload is the section ordinal, and `update`
checks that the ordinal belongs to the role's rail before navigating:

```zig
.open_section => |ordinal| {
    const section = std.enums.fromInt(nav.NavSection, ordinal) orelse return;
    const section_id = section.index();
    var known = false;
    for (rbac.nav_sections(model.role)) |row| {
        if (row.id == section_id) known = true;
    }
    if (!known) return;
    go(model, rbac.section_screen(section));
},
```

The rule is that the payload and the lookup must agree on what the number
means. A test that clicks every rail row for every role would pin it.

### The model-owned split fraction

The rail's width is a fraction of the window, and the model owns it:

```zig
// src/core/model.zig
/// The width of the nav rail, as a fraction of the window.
rail_split: f32 = 0.18,
/// The width of the menu pane in the POS, as a fraction.
menu_split: f32 = 0.62,
```

```xml
<split grow="1" value="{rail_split}" on-resize="rail_resized">
```

```zig
.rail_resized => |fraction| model.rail_split = fraction,
```

This is the SDK's controlled-split contract: the runtime applies each
drag step as an optimistic echo, dispatches `on-resize` with the applied
and clamped fraction, and the model stores it and echoes it back through
`value` on the next rebuild, so the panes land exactly where the divider
is. The fraction is never written by the view.

The POS uses the same shape one level down, with `menu_split` and
`menu_resized`.

One thing to check: the rail pane also carries a definite
`width="200"`. In the SDK, `width` is "definite: the element is exactly
that size", while `min-width` is the attribute the split uses to bound
the drag on a pane. A definite width on the first pane and a
model-owned fraction on the split are two claims on the same dimension.
The split-pane idiom is `min-width` on the pane plus the fraction on the
split; the definite width should go.

## The kiosk roles

Two of the four roles are kiosks: `kds` and `display`. They differ from
`admin` and `waiter` in one decision - how the session is established -
and that difference cascades.

```zig
// src/core/navigation.zig
/// Kiosk roles sign in by device, not by PIN.
pub fn needs_sign_in(self: Role) bool {
    return switch (self) {
        .admin, .waiter => true,
        .kds, .display => false,
    };
}
```

| | `admin` / `waiter` | `kds` / `display` |
|---|---|---|
| Session start | role picker, then PIN entry | role picker only |
| `signed_in` set by | `login_checked` (a matching PIN hash) | `pick_role` |
| Operator identity | `employee_id` + `employee_name` | none (`operator_label` reads "Not signed in") |
| Home screen | `admin_dashboard` / `waiter_tables` | `kds_board` / `display_board` |
| Data loaded | after a successful sign-in | immediately on role pick |
| Allowed screens | 43 / 12 | 4 / 4 |
| Lockout, PIN change, reset | yes | none |

The update arm is where the difference is visible:

```zig
.pick_role => |index| {
    const role = std.enums.fromInt(Role, index) orelse return;
    model.role = role;
    model.role_chosen = true;
    model.login_error = "";
    model.error_text = "";
    if (role.needs_sign_in()) {
        go(model, .login);
    } else {
        // Kiosk roles are signed in by device.
        model.signed_in = true;
        go(model, rbac.home(role));
        repos.loadAll(fx);
    }
},
```

A kiosk is signed in by **device**, not by person. The consequences are
honest and worth stating plainly:

- a kiosk action cannot be attributed to an employee, because
  `employee_id` stays 0;
- a kiosk has no way to lock itself, so it has no way to be safe on an
  open floor;
- a kiosk cannot reach anything that moves money, which is the actual
  mitigation.

The PIN path is the mirror image, and the salt is the reason two
restaurants with the same PIN do not share a digest:

```zig
.submit_login => {
    if (model.pin_salt().len == 0) {
        model.login_error = "Still starting up - try again in a moment";
        return;
    }
    if (model.pin.text().len == 0) {
        model.login_error = "Enter your PIN";
        return;
    }
    auth.hashPin(model.pin_salt(), model.pin.text(), &model.login_hash);
    fx.dbQuery(.{
        .key = repos.key_login,
        .sql = login_sql,
        .params = &.{.{ .text = model.login_hash[0..] }},
        .on_result = Effects.dbMsg(.login_checked),
    });
},
```

The plaintext PIN never reaches the database, and the view binds a
derived method rather than the buffer:

```zig
/// The sign-in PIN as typed. The view binds this, never the buffer.
pub fn pin_text(model: *const Model) []const u8 {
    return model.pin.text();
}
```

### What a kiosk device looks like today

A kiosk device is the same binary with a different role, and it still
shows the role picker, the title bar, the nav rail and the status bar.
The role picker itself announces the difference:

```xml
<for each="roles" key="id" as="role">
  <card padding="16">
    <column gap="4" main="center">
      <text size="lg">{role.title}</text>
      <text foreground="text_muted" wrap="true">{role.blurb}</text>
      <row gap="8" cross="center">
        <badge>{role.kind}</badge>
        ...
```

with the `kind` field carrying "PIN sign-in" or "Kiosk":

```zig
const role_cards = [_]RoleCard{
    .{ .id = @intFromEnum(Role.admin), .title = "Admin", .blurb = "Full point of sale, management, configuration and reports.", .kind = "PIN sign-in" },
    .{ .id = @intFromEnum(Role.waiter), .title = "Waiter", .blurb = "Order taking, table management and the floor plan.", .kind = "PIN sign-in" },
    .{ .id = @intFromEnum(Role.kds), .title = "Kitchen", .blurb = "Live kitchen tickets, station by station. No sign-in.", .kind = "Kiosk" },
    .{ .id = @intFromEnum(Role.display), .title = "Display", .blurb = "Customer-facing order status. No sign-in.", .kind = "Kiosk" },
};
```

## PLAN: several windows over one model

> **This section is a plan. None of it exists in the tree today.** The
> app declares exactly one window and one GPU surface:
>
> ```zig
> // src/main.zig
> const shell_windows = [_]native_sdk.ShellWindow{.{
>     .label = "main",
>     .title = "Restaurant OS",
>     .width = window_width,
>     .height = window_height,
>     .views = &shell_views,
> }};
> ```
>
> There is no `windows_fn`, no `window_view`, and no window policy.

The platform supports **model-declared secondary windows**: the app
declares, from the model, which windows should exist right now, and the
runtime reconciles them after every dispatch - creating the newly
declared, closing the no-longer-declared, and rebuilding every open
window's view from the same model.

The shape the SDK offers, for a Zig core:

```zig
fn windows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    var count: usize = 0;
    if (model.settings_open) {
        scratch.windows[count] = .{
            .label = "settings", .canvas_label = "settings-canvas",
            .title = "Settings", .width = 360, .height = 320,
            .min_width = 320, .min_height = 280,
            .on_close = .settings_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}
fn windowView(ui: *App.Ui, model: *const Model, window_label: []const u8) App.Ui.Node { ... }
// options: .windows_fn = windows, .window_view = windowView,
```

### What Restaurant OS would do with it

The product argument is that the four roles do not have to be four
machines. A counter machine can be the POS, the KDS and the customer
display at once, over one model:

```
              ┌──────────────────────────────┐
              │          shared Model        │
              │  orders · tables · cart ...  │
              └───────┬──────────┬───────────┘
                      │          │
          ┌───────────▼──┐  ┌────▼──────────┐  ┌──────────────┐
          │ main (admin) │  │ KDS window    │  │ Display      │
          │ POS + admin  │  │ tickets only  │  │ customer view│
          └──────────────┘  └───────────────┘  └──────────────┘
```

An order placed in the POS window appears on the KDS window without a
restart and without a second process, because both read the same model
and every dispatch rebuilds every open window's view.

The model already holds what a KDS window needs -
`kitchen_tickets(arena)` and `ticket_count()` are the same derived
values the in-window KDS screen binds today - so the window is a
different **view** over existing state, not new state.

### Constraints the platform imposes

| Constraint | Value | Consequence for Restaurant OS |
|---|---|---|
| Declared windows | at most 4 (`UiApp.max_ui_windows`) | admin + KDS + display fits, with room to spare |
| Canvas labels | unique across the app | the KDS and display windows need their own `canvas_label` |
| Markup per window | one window's content per markup tree; there is no `window` element in the closed grammar | each window needs its own markup root under `src/windows/`, listed in `app_sources.zig` |
| Rebuild | every dispatch rebuilds every open window's view | a ticket advancing in the POS repaints the KDS window in the same frame |
| Close policy | `.quit` (default) or `.hide` | a display window should hide, not quit the app |
| Restore policy | `.clamp_to_visible_screen` by default, `.center_on_primary` on macOS | model-declared windows deliberately do not restore persisted frames |
| Present before show | canvas windows become visible only after their first frame presents | no flash of an empty window on open |
| Minimum size | `.min_width` / `.min_height` on the descriptor | the KDS window needs a floor, or a 300 px window shows a clipped grid |

### What the plan needs before it can start

1. **A window policy.** Which role opens which windows, and what a
   close means. A display window closing should hide, not quit.
2. **A kiosk boot path.** A wall-mounted board should not show the role
   picker on every power cycle. This needs the device's role to be
   remembered somewhere, and an escape gesture to leave.
3. **Window markup roots.** `src/windows/kds.native` and
   `src/windows/display.native`, imported the same way the screens are -
   `<import>` in the root plus an entry in `app_sources.zig`.
4. **A decision about the cart.** A shared model means a shared cart. A
   cashier and a waiter on one machine would collide.
5. **A session model.** A shared model means a shared session: a second
   window sees the admin's role and the admin's operator name.

### Open question: which engine builds a window's view

The SDK documents the per-window view as a compiled markup tree: a
markup-authored secondary window is a `canvas.CompiledMarkupView` whose
`build` the `window_view` callback calls for that label. Restaurant OS runs the
**runtime** markup engine in development (`.markup = .{ .source =
app_markup, .sources = &app_sources, .watch_path = "src/app.native" }`),
not the compiled one, so the hot-reload path for a secondary window's
markup is not established. That is the first thing to prove, before any
window policy is decided.

The windowing questions are tracked in
[07-windowing-and-desktop](07-windowing-and-desktop.md) and in
[ADR-0004](../decisions/0004-four-roles-one-binary.md), where this part
is recorded as **Proposed**.

## Traps

| Mistake | Symptom | Fix |
|---|---|---|
| Inserting a `Screen` variant in the middle of the enum | The shell mounts the wrong template, or an empty pane, with no error. `screen_index == 8` still means "the eighth variant", which is no longer `admin_dashboard` | Append new screens at the end of `Screen`. Reordering is a silent breakage; the ordinals are a contract |
| Writing `screen_index` from anywhere other than `go` | The stack and the index disagree: `go_back` lands on the wrong screen, or the rail highlights a section the current screen is not in | Route every move through `go`; the only exception is `go_back`, which pops the stack it owns |
| Building a rail or role table inside a function and returning `&.{ ... }` | The view reads a dead stack frame on a later frame. It looks like a platform bug and is not one | Keep every table the markup binds at file scope with comptime-known contents, as `rbac.zig` does |
| Sending a `NavSection` ordinal where the handler expects a row index | For `waiter`, `kds` and `display` the payload exceeds the rail length and the move is silently refused - a rail button that does nothing | Make the payload and the lookup agree: resolve the id to a `NavSection` and check it against the role's rail |
| Adding a rail entry without adding the screen to `rbac.allows` | The rail shows a destination the role may not open; pressing it sets `error_text` and stays put | The rail table and the permission matrix move together; the matrix test walks every pair |
| Assuming a kiosk is signed in | `signed_in` is false until `pick_role` sets it for `kds`/`display`; the shell does not mount and the app looks frozen | `Role.needs_sign_in()` is the switch; only `pick_role` and `login_checked` set `signed_in` |
| Trusting a bound colour token for a status colour | The colour attributes take token **names as literals**; a bound token is rejected. `OrderStatus.tone()` returns a token name and cannot be bound | Use a static token, or move the dynamic styling into Zig |
| Giving a split pane a definite `width` while the split owns the fraction | The pane and the fraction make two claims on the same dimension; the divider and the pane can disagree | Put `min-width` on the pane and let the model-owned fraction size it |
| Pushing a screen without checking the return value | At depth 32 the history is silently truncated and the way back is lost | `push` returns `false` at the bound; `go` already checks it |
| Expecting `go_back` to be reachable by the operator | No template binds `go_back`; a kiosk that drilled in has no way back | Add an explicit affordance, and document the escape for kiosk roles |

## Checklist

Adding or changing a screen:

- [ ] The new `Screen` variant is **appended** at the end of the enum
      in `src/core/navigation.zig`, with a `title` and a `nav_section`
      (or an explicit `null`).
- [ ] Its ordinal was read off the enum, not counted by hand.
- [ ] `rbac.allows` grants it to the roles that may open it, and denies
      it to the ones that may not.
- [ ] If it is a rail destination, it appears in the right role's rail
      table in `rbac.zig` **and** in `rbac.section_screen`.
- [ ] A template exists at `src/screens/screen-<name>.native` with
      exactly one `<template name="screen-<name>">`.
- [ ] The file is imported in `src/app.native` **and** listed in
      `src/app_sources.zig`.
- [ ] The shell has an `<if test="{screen_index == N}">` gate for it, and
      the gate is inside the `show_shell` block.

Changing navigation:

- [ ] Every new movement goes through `go`; no arm writes
      `screen_index` directly.
- [ ] A refused push is handled - `push` returns `false` at depth 32.
- [ ] A refused permission sets a reason the operator can see (today it
      sets `error_text`, which nothing renders).
- [ ] The rail still cannot offer a destination the role may not open.

Roles and sessions:

- [ ] `Role.needs_sign_in` and `rbac.home` are still consistent with the
      session flow in `update`.
- [ ] A kiosk role can still reach `role_picker` and `login` - the
      matrix test asserts this for every role.
- [ ] A kiosk role can still not open `pos`, `payments`,
      `order_confirmation` or `settings`.

Before the multi-window plan starts:

- [ ] The window policy is written down: which role opens which window,
      and what a close means.
- [ ] The per-window markup roots exist and are in `app_sources.zig`.
- [ ] The runtime-markup path for a secondary window is proven, or the
      app switches to the compiled markup view for windows.
- [ ] The shared-cart question is answered in writing.
- [ ] The kiosk escape gesture and the remembered device role are
      decided.
