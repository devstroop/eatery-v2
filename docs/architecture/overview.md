# Architecture overview

> **Scope:** how the Restaurant OS app is put together — the app model, the
> runtime lifecycle, the module map, the data flow, and the mechanics of
> adding a screen.
> **Source:** `apps/admin/src/**`, `apps/admin/app.json`, and the Native
> SDK authoring guides in `native-zig-showcase/docs/sdk/`.
> **Method:** read from source. The Native SDK CLI (`native`) is not on the
> PATH in this workspace, so no build or test run backs the claims here.

---

## 1. The app model

The Native SDK's app model has four moving parts, and Restaurant OS uses
all four:

| Part | Where it lives | What it owns |
|---|---|---|
| **Model** | `src/core/model.zig` | Every fact the app knows: session, navigation, company, datasets, cart, error text. Plus the derived bindings the view reads. |
| **Msg** | `src/core/msg.zig` | The complete vocabulary of things that can happen. One tagged union; every arm is a state change the app understands. |
| **update** | `src/core/update.zig` | The only place model state changes. `update(model, msg, fx)` maps a message onto new state plus a set of effects. |
| **markup** | `src/app.native`, `src/screens/*.native` | What the operator sees. It binds model values and dispatches messages. It never changes state. |

The shape, as the README puts it:

```
Model  ── what is true              (src/core/model.zig)
Msg    ── what happened             (src/core/msg.zig)
update ── what is true now          (src/core/update.zig)
markup ── what the operator sees    (src/app.native, src/screens/*.native)
```

### Why it is strict

The strictness is not stylistic. It is enforced by three mechanisms in
the SDK, and each one exists because the corresponding v1 failure mode was
real.

**1. The markup grammar has no setter.** An `on-*` attribute names a tag
of the `Msg` union; the payload binds a path. That is the entire set of
things markup can do to the model. There is no `bind=` that writes a
field, no expression with a side effect, and no computed message name.
So "the view never mutates state" is not a convention the code must
police — it is a property of the language.

**2. Bindings resolve against a reflected model contract.** `native test`
refreshes `zig-out/model-contract.zon` from the `Model` and `Msg`
declarations; `native check` then verifies every binding path, iterable,
`key` field, message tag, payload type and expression type against the
app's real surface, with did-you-mean over the actual field names. A
binding to a field that does not exist is a build failure, not a blank
label at runtime.

**3. Only declarations inside the `Model` struct body are bindable.** A
file-scope `pub fn` written *next to* the struct is invisible to the
resolver. This is why `core/model.zig` carries that warning at the top:

```zig
//!   1. **Everything the view can see is a field or a method on this
//!      struct.** A file-scope function next to the struct is invisible
//!      to the markup - the binding resolver only sees declarations
//!      INSIDE the struct body.
```

The consequence is that the model's public surface is exactly the struct
body, and `view_unbound` is the lint that keeps a private field from
becoming an accidental public API:

```zig
pub const Model = struct {
    /// Fields the view never binds directly. Keep this list honest:
    /// it is the boundary between "the model" and the interface.
    pub const view_unbound = .{
        "stack",
        "employee_id",
        "db_ready",
        "busy",
        "error_text",
        "company_id",
        "pending_screen",
        "theme_dark",
    };
```

`core/msg.zig` carries the same declaration for the message side, since
messages the runtime delivers or `update` raises are never dispatched by
markup:

```zig
/// Messages the view never dispatches. The runtime delivers these
/// (database results) or `update` raises them; no markup binds
/// them, so they are declared here to keep the lint honest.
pub const view_unbound = .{
    "login_checked",
    "products_loaded",
    // ...
};
```

**Derived values are methods, never stored fields.** Counts, totals,
filtered lists and formatted strings are computed on rebuild:

```zig
/// How many open (not yet completed) orders are on the board.
pub fn open_order_count(model: *const Model) usize {
    var count: usize = 0;
    for (model.orders) |order| {
        switch (order.status) {
            .pending, .preparing, .ready, .served => count += 1,
            .completed, .voided => {},
        }
    }
    return count;
}
```

A stored field that could be derived has to be re-maintained by every
arm of `update` that could affect it, and goes stale the moment one of
them is missed. A method cannot.

**`update` is a pure function of (model, message).** It reads no clock,
opens no file, and queries no database. The world is reached through the
effects channel and the answer comes back as another message.

### The one place with an `Io`

`main.zig` is the only place with randomness, because Zig 0.16 takes
randomness from an `Io` and `update` does not have one:

```zig
// The installation salt. It is made here because this is the one
// place with an `Io` (and therefore with randomness); `boot` writes
// it to the database if this is a fresh installation.
auth.makeSalt(init.io, &app_state.model.pin_salt_buf);
app_state.model.pin_salt_len = app_state.model.pin_salt_buf.len;
```

---

## 2. The runtime lifecycle

```
main(init)
  └─ UiApp.create(...)                 model constructed as .{}
  └─ auth.makeSalt(init.io, ...)      provisional installation salt
  └─ runner.runWithOptions(...)
       └─ install scene on first GPU frame
            └─ init_fx  = boot(model, fx)      once, before the first view build
            └─ first frame: markup resolves imports, builds the tree,
                            theme.tokens(model) supplies the palette
            └─ update loop: Msg -> update(model, msg, fx) -> rebuild -> present
                 └─ effects drain: engine result -> Msg -> update -> rebuild
```

### 2.1 Boot and `init_fx`

`main.zig` builds the app:

```zig
const app_state = try RosApp.create(std.heap.page_allocator, .{
    .name = "ros",
    .scene = shell_scene,
    .canvas_label = canvas_label,
    .update_fx = update_mod.update,
    .init_fx = update_mod.boot,
    .tokens_fn = theme.tokens,
    .markup = .{
        .source = app_markup,
        .sources = &app_sources,
        .watch_path = "src/app.native",
        .io = init.io,
    },
});
```

`create` heap-allocates and constructs the model in place, because the
model carries the row buffers and is far too large for the stack. The
model must be default-constructible — the runtime builds it as `.{}` —
which is the constraint that shapes `core/bump.zig`.

`init_fx` is `update_mod.boot`, and it runs exactly once, on the
installing frame, before the first view build:

```zig
/// Boot effects: the clock timer and the first read of the database.
pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    fx.startTimer(.{
        .key = clock_timer_key,
        .interval_ms = 1000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    // The first read: the settings the app needs before it can sign
    // anybody in, then the rest of the shell's data.
    repos.loadConfig(fx);
}
```

Two things start here: the repeating clock timer (key `100`, arm
`.tick`) that keeps `model.now_ms` fresh so the kitchen board can say
how long a ticket has been waiting, and the first database read — the
`app_config` row that holds the PIN salt.

### 2.2 First frame

The runtime resolves the markup's import closure, builds the widget tree
from the model, asks for the design tokens, lays the tree out and
presents it. Two details matter:

* **The import closure is explicit.** Every file the markup imports must
  also be embedded in `src/app_sources.zig`. A missing entry fails loudly
  at the import site — "a screen that is not compiled in is a screen that
  does not exist".
* **The palette is a function of the model.** The runtime asks for
  tokens on every rebuild, so flipping the theme is a model change and
  nothing else:

  ```zig
  /// The tokens for the current model state. The runtime asks for these
  /// on every rebuild, so flipping the theme is a model change and
  /// nothing else.
  pub fn tokens(model: *const Model) canvas.DesignTokens {
      return if (model.theme_dark) dark() else light();
  }
  ```

The first frame shows the role picker, because `Model.role_chosen`
defaults to `false` and `show_role_picker` is derived from it:

```zig
pub fn show_role_picker(model: *const Model) bool {
    return !model.role_chosen;
}
```

### 2.3 The update loop

Every input event, every timer tick and every effect result enters
through the same door: `update(model, msg, fx)`. The markup dispatches a
message; `update` decides what it means; the view is rebuilt from the
result.

`update` is wired as `.update_fx`, which is the three-argument form. The
two-argument form (`.update`) is for apps with no effects.

### 2.4 Effects drain

An effect the app requests (`fx.dbQuery`, `fx.dbExec`, `fx.startTimer`,
`fx.wallMs`) completes on the engine side, and the result arrives as an
ordinary message on the next drain. There is no callback into app code
and no second path around `update`.

The payload types are fixed by the platform. The database result is
`native_sdk.EffectDbResult`, the timer is `native_sdk.EffectTimer`, and
the text edit is `canvas.TextInputEvent`:

```zig
pub const Msg = union(enum) {
    /// The PIN check came back.
    login_checked: native_sdk.EffectDbResult,
    /// The order write came back.
    order_placed: native_sdk.EffectDbResult,
    /// The wall clock tick: the model keeps `now_ms` fresh so the
    /// kitchen board can say how long a ticket has waited.
    tick: native_sdk.EffectTimer,
```

**Payloads are drain scratch.** The bytes of a page are valid through the
update that receives them and dead after it. Anything the model keeps has
to be copied — into the model's bump buffers. That rule is the reason
`core/bump.zig` exists.

---

## 3. Module map

`apps/admin/src/`, one line per module:

| Path | Owns |
|---|---|
| `main.zig` | The shell: `UiApp` wiring, window and GPU surface, the permission list, `runner.runWithOptions`, and the provisional salt generation. Re-exports `update` and `boot` so the tests drive the app exactly as the runtime does. |
| `app.native` | The shell view: title bar, nav rail, and the `<if>` gates that mount one screen template at a time. |
| `app_sources.zig` | The embedded markup import closure — every `.native` file the shell imports, `@embedFile`d. |
| `core/model.zig` | The `Model` struct: every field, the `view_unbound` list, and every derived binding (methods). Also owns the `OrderTypeOption`, `CartRow` and `Ticket` row shapes the view renders. |
| `core/msg.zig` | The `Msg` union: every message the app understands, and its own `view_unbound` list. |
| `core/update.zig` | `update(model, msg, fx)` and `boot(model, fx)`: the only writers of model state, plus the navigation helper `go`, the cart helpers, and `nextStatus`. |
| `core/navigation.zig` | The `Role` and `Screen` enums, `Screen.title()` / `Screen.nav_section()`, the role cards, the `NavSection` enum, and the fixed-capacity `Stack`. |
| `core/rbac.zig` | The permission matrix: `allows(role, screen)`, `home(role)`, the per-role nav rails, and `section_screen(section)`. A pure function with a total test. |
| `core/theme.zig` | The design tokens: the brand palette, the light and dark token sets, and `tokens(model)` which picks between them. |
| `core/bump.zig` | `Bump(comptime capacity)`: the fixed-capacity allocator the model uses for its rows. `alloc`, `dupe`, `dupeC`, `allocSlice`, `reset`, `used`, `free`. |
| `domain/models.zig` | The entities: `Product`, `Order`, `OrderLine`, `DiningTable`, `Customer`, `Employee`, `CartLine`, `TaxSlab`, `Shift`, and the enums `OrderType`, `OrderStatus`, `ProductType`, `FoodType`, `TableStatus`, `PaymentMode`. |
| `data/repos.zig` | The data layer: the effect keys, the SQL constants, the loader functions (`loadProducts`, `loadOrders`, `loadAll`, …), the decoders (`decodeProducts`, `decodeOrders`, …), the writers (`saveOrder`, `setOrderStatus`, `saveConfigValue`) and the defensive `enumFromInt` cast. |
| `data/page.zig` | The reader for the engine's row format: `Reader.init`, `readHeader`, `nextRow`, `indexOf`, `intOf`, `boolOf`, `textOf`, and the `Value` union. |
| `data/auth.zig` | PIN hashing: `hashPin`, `makeSalt`, `equal`, and `hex_len`. Pure — no clock, no allocation, no effects. |
| `schema/0001..0010_*.sql` | The database: ten migrations, 43 tables, every one `STRICT`. |
| `schema/migrations.lock.json` | The migration authority: version 11, eleven per-file hashes, and a `schema_hash`. |
| `screens/*.native` | Nine screen templates: setup, role picker, login, dashboard, POS, orders, confirmation, tables, kitchen. |
| `tests.zig` | The rules the app must not break. Twelve tests, written as rules. |
| `app.json` (in `apps/admin/`) | The manifest: identity, permissions, capabilities (`sqlite` among them), the shell window and its GPU surface, and the navigation policy. |

`src/components/` exists and is empty. It is the place for shared
component templates once the screen count grows.

---

## 4. Data flow

The cycle, end to end:

```
markup dispatches ──▶ update mutates ──▶ effects reach the world
        ▲                                      │
        │                                      ▼
the view rebuilds ◀── update mutates ◀── results come back as messages
```

### Worked example: placing an order

**1. The markup dispatches.** `src/screens/screen-pos.native`:

```html
<button variant="primary" grow="1" on-press="place_order">Place order</button>
```

The tag `place_order` must be an arm of `Msg`. It is.

**2. `update` mutates.** `src/core/update.zig`:

```zig
.place_order => placeOrder(model, fx),
```

`placeOrder` builds the order and its lines from the cart. The order id is
the wall clock in milliseconds, the order number is the wall clock in
seconds, and the total comes from a derived method:

```zig
/// The cart total in minor units.
pub fn cart_total_minor(model: *const Model) i64 {
    var total: i64 = 0;
    for (model.cart[0..model.cart_len]) |line| {
        total += line.price_minor * line.qty;
    }
    return total;
}
```

**3. The effect reaches the world.** `repos.saveOrder` builds one statement
array on the stack — the order, then one statement per line — and hands
it to a single `dbExec`:

```zig
fx.dbExec(.{
    .key = key_write_order,
    .statements = statements[0..count],
    .on_result = Effects.dbMsg(.order_placed),
});
```

The engine runs the statements as one transaction, so a half-written
order cannot exist.

**4. The result comes back as a message.** `Msg.order_placed` carries a
`native_sdk.EffectDbResult`.

**5. `update` mutates again.**

```zig
.order_placed => |result| {
    model.busy = false;
    if (result.outcome != .ok) {
        model.error_text = "Could not save the order";
        return;
    }
    model.cart_len = 0;
    model.cart_buf.reset();
    go(model, .order_confirmation);
    repos.loadOrders(fx);
},
```

**6. The view rebuilds.** `repos.loadOrders` issues a `dbQuery`; the
result arrives as `Msg.orders_loaded`; the arm calls
`repos.decodeOrders(model, result.bytes)`, which copies every row into
`model.orders_buf` and points `model.orders` at the copied slice. The
markup's `<for each="orders" key="id" as="order">` then renders the new
set.

### The same flow, read from the other end

| Stage | Entry point | Output |
|---|---|---|
| Markup dispatches | `on-press="tag:{payload}"` | `Msg` |
| `update` mutates | `core/update.zig` | new model state |
| Effect reaches the world | `repos.*` → `fx.dbQuery` / `fx.dbExec` / `fx.startTimer` | engine-side work, keyed |
| Result comes back | `Effects.dbMsg(.tag)` / `Effects.timerMsg(.tag)` | `Msg` carrying a platform payload |
| View rebuilds | `canvas.MarkupView(Model, Msg).build` | new widget tree, laid out and presented |

---

## 5. Adding a screen, end to end

The `Screen` enum in `src/core/navigation.zig` is append-only. The markup
compares `screen_index` against fixed ordinals, so reordering the enum
would silently remap every gate in `app.native`. The steps below assume
a new screen called `suppliers`.

**1. Append the variant to `Screen`.** `src/core/navigation.zig`:

```zig
pub const Screen = enum {
    // ...
    /// The order of this enum is the
    /// navigation contract: `Screen.index()` is what the markup compares
    /// against, so **never reorder the variants** - append new ones at the end.
```

New screens go at the end of the enum, so no existing ordinal moves.

**2. Give it a title and a nav section.** Same file, same `switch`:

```zig
pub fn title(self: Screen) []const u8 {
    return switch (self) {
        // ...
        .suppliers => "Suppliers",
    };
}

/// The nav tree the shell draws for a role. `null` means the screen is
/// not in the role's rail - it is reached by drilling in, not by a tab.
pub fn nav_section(self: Screen) ?NavSection {
    return switch (self) {
        // ...
        .suppliers => .catalog,
    };
}
```

**3. Grant the permission.** `src/core/rbac.zig`. `allows` is the whole
access-control surface, and it is a pure function:

```zig
pub fn allows(role: Role, screen: Screen) bool {
    return switch (role) {
        .admin => true,
        .waiter => switch (screen) {
            // ...
            => true,
            else => false,
        },
```

A screen nobody may open is unreachable; `go()` in `update` refuses it
and sets `error_text`:

```zig
/// Move to a screen, refusing destinations the role may not open.
fn go(model: *Model, screen: Screen) void {
    if (!rbac.allows(model.role, screen)) {
        model.error_text = "This role cannot open that screen";
        return;
    }
```

**4. Add the messages.** `src/core/msg.zig`. Any message the view never
dispatches goes in `Msg.view_unbound`.

**5. Add the state and the bindings.** `src/core/model.zig`. Fields for
the state, methods for everything derived. Private fields go in
`Model.view_unbound`.

**6. Add the arms.** `src/core/update.zig`. One arm per message, each
answering "the world said this, so what is true now?".

**7. Add the data path, if the screen needs it.** `src/data/repos.zig`:
the SQL constant, the loader, the decoder. The decoder copies into the
model's bump buffer.

**8. Write the template.** `src/screens/screen-suppliers.native`, with a
`<template name="screen-suppliers">` at the top and exactly one element
child:

```html
<template name="screen-orders">
  <column grow="1" gap="12" padding="16" background="background">
    <row gap="8" cross="center">
      <text size="heading" grow="1">Orders</text>
      <badge>{order_count} open</badge>
    </row>
```

**9. Embed it.** `src/app_sources.zig`:

```zig
pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "screens/screen-role-picker.native", .source = @embedFile("screens/screen-role-picker.native") },
    // ...
    .{ .path = "screens/screen-suppliers.native", .source = @embedFile("screens/screen-suppliers.native") },
};
```

**10. Import it and gate it.** `src/app.native`:

```html
<import src="screens/screen-suppliers.native"/>
```

```html
<if test="{screen_index == 43}"><use template="screen-suppliers"/></if>
```

The ordinal is the new variant's index in the `Screen` enum. The gates
live inside the shell's content column, and only the active screen is
mounted — that is what keeps the widget budget (1024 nodes per view)
within reach.

**11. Test it.** `src/tests.zig`. Two assertions matter most: that the
screen's ordinal is what the markup expects, and that the template
builds and contains its landmark.

```zig
const tree = try buildTree(arena, &model);
_ = try expectByText(tree.root, .text, "Restaurant OS");
```

**12. Validate.**

```sh
cd apps/admin
native check        # manifest, markup and schema validation
native test         # headless update-logic and repository tests
```

---

## 6. The five invariants

These are the rules a change must not break. Each maps onto the
conventions listed in `README.md` under "Conventions that are not
negotiable", and each has a code anchor or a test.

| # | Invariant | README convention | Anchor |
|---|---|---|---|
| **I1** | **The markup never mutates state.** It binds values and dispatches messages. Every state change happens in `update`. | 1 | `src/core/update.zig` — `update` is the only writer; the markup grammar has no setter |
| **I2** | **Everything the view can see is a field or a method on `Model`, and everything derived is a method.** A file-scope function next to the struct is invisible to the markup. `view_unbound` keeps the boundary honest. | 2, 3, 4 | `src/core/model.zig` — `Model.view_unbound`; `src/core/msg.zig` — `Msg.view_unbound`; `src/core/rbac.zig` — the file-scope rail tables |
| **I3** | **Money is integer minor units. Time is epoch milliseconds, UTC.** No float money, anywhere. | 5 | `src/domain/models.zig`; `src/schema/*.sql`; the money test in `src/tests.zig` |
| **I4** | **Every table is `STRICT`.** A column's declared type means something. | 6 | `src/schema/0001..0010_*.sql`; `native check` rejects a non-STRICT table |
| **I5** | **Anything the markup binds is a file-scope constant, and the rules are tests.** A composite literal built inside a function lives on that function's stack frame; returning a slice to it hands the view a pointer to dead memory. | 7, 8 | `src/core/rbac.zig` and `src/core/navigation.zig` — the rail and role-card tables; `src/tests.zig` |

The stack-frame trap in I5 is not hypothetical. The tables the view binds
at a later frame live on the stack of the function that built them:

```zig
// The role cards are a FILE-SCOPE constant on purpose: a composite
// literal built inside a function lives on that function's stack frame,
// and returning a slice to it hands back a pointer to dead memory. The
// markup reads these rows on a later frame.
const role_cards = [_]RoleCard{ ... };
```

---

## 7. Build, test and automation loop

### Toolchain

| Tool | Version | Why |
|---|---|---|
| Zig | **0.16.0** | The SDK pins it. 0.17 does not parse the SDK. |
| Node | **24+** | The relational-schema generator is TypeScript. |
| Native SDK CLI | v0.11.0 | `native dev / test / check / build / automate` |

### The four verbs

```sh
cd apps/admin
native dev          # debug build + markup hot reload
native test         # headless update-logic and repository tests
native check        # manifest, markup and schema validation
native build        # ReleaseFast binary in zig-out/bin/
```

* `native dev` watches `src/app.native` (the `watch_path` in `main.zig`).
  Editing a template hot-reloads the view within about two seconds,
  preserving model state and widget ids. A parse failure keeps the last
  good view and records the diagnostic.
* `native test` is the rule suite. It also refreshes the model contract
  (`zig-out/model-contract.zon`) that `native check` then verifies
  against.
* `native check` validates the manifest, the markup grammar, the binding
  contract and the schema — the schema is prepared with real SQLite, so a
  non-STRICT table or a broken foreign key fails the check rather than
  production.
* `native build` produces the release binary.

### The test loop

`src/tests.zig` is imported by the `test` block in `src/main.zig`:

```zig
test {
    _ = @import("tests.zig");
}
```

Two helpers make the tests possible:

```zig
/// Build the view for a model. The markup error names the position in
/// app.native, which is the difference between a two-minute fix and a
/// two-hour one.
fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
```

```zig
/// A model with the effects channel in fake mode: requests are recorded
/// instead of touching the OS.
fn fakeFx() !Effects {
    var fx = Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}
```

So a test dispatches a message the way the runtime does, then asserts on
the model and on the rebuilt tree — no window, no database file.

### The automation loop

`native automate` drives a live app headlessly:

```sh
native automate wait                       # wait for the running app
native automate assert 'gpu_nonblank=true' # assert the window drew something
native automate snapshot                   # dump the widget tree
```

The snapshot reports the widget node count against the 1024-node budget
(`widget_nodes=N/1024`), so the budget can be asserted rather than
guessed.

### Repo-level wrappers

`README.md` refers to three shell wrappers:

```sh
scripts/verify.sh        # native check + native test for every app
scripts/build.sh         # ReleaseFast build of every app
scripts/dev.sh           # debug run of the app with markup hot reload
```

`scripts/` is currently empty, and so are `tools/sync-sidecar` and
`tools/print-sidecar`. The wrappers are the intended shape of the loop,
not a working entry point yet.

---

## 8. Gotchas

| Gotcha | Why it bites | Where |
|---|---|---|
| `Screen` is append-only. | The markup compares `screen_index` against literal ordinals. Inserting a variant in the middle remaps every gate in `app.native` silently. | `src/core/navigation.zig`, `src/app.native` |
| The `Screen` enum has 43 variants (indices 0–42). | `src/app.native` gates on 8, 10, 13, 17 and 41. | `src/app.native` |
| A file-scope function next to `Model` is invisible to bindings. | The resolver only sees declarations inside the struct body. The symptom is "each does not name an iterable" at run time. | `src/core/model.zig` |
| A composite literal built inside a function dies with the frame. | Returning a slice to it hands the view a pointer to dead memory. It presents as a crash that looks like a platform bug. | `src/core/rbac.zig`, `src/core/navigation.zig` |
| Page bytes are drain scratch. | Keeping a slice into them keeps a pointer to memory that is dead after the update. Copy into the bump buffer. | `src/data/page.zig`, `src/data/repos.zig` |
| `update` has no allocator. | Any derived list must be built in the arena the view owns — the `(*const Model, std.mem.Allocator)` method form. | `src/core/model.zig` |
| The model must be default-constructible. | It is built as `.{}`. It cannot own a heap allocator, so its size is a compile-time fact and it uses `Bump`. | `src/core/bump.zig`, `src/main.zig` |
| A `.native` file not in `app_sources.zig` does not exist. | The import closure is embedded; a missing entry fails loudly at the import site. | `src/app_sources.zig` |
| `native` is not on the PATH in this workspace; the installed Zig is 0.17.0. | The SDK pins Zig 0.16.0 and 0.17 does not parse it. The statuses in this document come from source review, not from a run. | `README.md` |
| Counts drift between prose and the tree. | The schema holds 43 tables and `src/tests.zig` holds 12 tests; the root README has been corrected to match, but any hand-written count will drift again. | `README.md`, `src/schema/`, `src/tests.zig`, `plan/status.md` |
| The root `README.md` used to link `docs/architecture/sync.md`, `docs/plan/gaps-from-v1.md`, `docs/plan/roadmap.md`, `docs/plan/backlog.md` and `AGENTS.md`. | Those paths do not exist; the maintained pages are `08-sync.md`, `plan/README.md` and `plan/status.md`. The root README should point at them. | `README.md` |

---

## 9. Next step

Add a screen test that pins the ordinal of every rendered screen. The
most likely regression in this codebase is a new variant inserted in the
middle of the `Screen` enum, which remaps every gate in `app.native` and
nothing catches it. A single test that asserts the ordinals of
`admin_dashboard`, `pos`, `orders`, `dining_tables` and `kds_board`
closes the loop between `core/navigation.zig` and the `<if>` gates in
`src/app.native`.
