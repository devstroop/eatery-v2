# AGENTS.md — the operating manual

You are working in **Eatery v2**: a restaurant POS (point of sale, kitchen
display, customer display, back office) written in Zig on the
[Native SDK](https://native-sdk.dev). This file is the manual for coding
agents and new contributors. Read it before you write a line.

The repo is deliberately opinionated. The rules below are not style
preferences: each one exists because breaking it produced a real defect.

---

## 1. The environment

| Tool | Version | Note |
|---|---|---|
| Zig | **0.16.0** | `source scripts/env.sh` puts it first. Zig 0.17 does not parse the SDK. |
| Node | **24+** | The relational-schema generator is TypeScript. |
| Native SDK CLI | v0.11.0 | `scripts/setup.sh` builds it into `~/native-sdk`. |

```sh
source scripts/env.sh        # zig 0.16, node 24, the native CLI
scripts/verify-all.sh            # native check + native test for every app
```

Without the SDK CLI you cannot build, test or check anything. If `native` is
not found, run `scripts/setup.sh` first.

---

## 2. The app model, and the four rules that hold it together

```
Model   what is true          apps/eatery/src/core/model.zig
Msg     what happened         apps/eatery/src/core/msg.zig
update  what is true now      apps/eatery/src/core/update.zig
markup  what the operator sees apps/eatery/src/app.native + src/screens/*.native
```

**Rule 1 — the markup never changes state.** It binds values and dispatches
messages. Every mutation happens in `update`.

**Rule 2 — everything the view can see is a field or a method ON the Model
struct.** The binding resolver reads the struct's declarations, not the
file's. A `pub fn` at file scope next to the struct is invisible to the
markup, and the failure is silent.

```zig
pub const Model = struct {
    products: []const domain.Product = &.{},
    pub fn product_count(model: *const Model) usize { return model.products.len; }
};
```

**Rule 3 — derived values are methods, never stored fields.** A stored field
that could be computed is a bug waiting to drift from its inputs.

**Rule 4 — `view_unbound` lists what the view must not see.** If you add a
private field, add it there. If the view may see it, leave it out.

---

## 3. Writing markup

The markup grammar is a **closed language**. It will reject anything
outside it, and it is worth learning the edges once:

| You want | Write | Not |
|---|---|---|
| A computed value | a method on `Model` | an expression in the markup |
| "not signed in" | a `pub fn` returning `bool` | `{!signed_in}` — there is no negation |
| An if/else | `<if>` + `<else>` | an `else-if` tag |
| A colour | `background="surface"` | `background="#30A8CF"` — tokens only |
| A message payload | `on-press="pick:{row.id}"` | `on-press="pick:0"` — payloads are bindings |
| A toggle | `on-toggle="…"` on `toggle-button` | `on-press` — a toggle-button never fires `on-press` |
| Spacing in a stack | wrap children in a `column` | `gap` on `stack`/`card`/`panel` — a validation error |

Other rules that bite:

- **Rows are plain data.** The markup cannot call a method on a loop row, so
  a row type carries plain fields (`id`, `label`), and anything derived
  about it is computed in the model.
- **Imports are two halves.** Add `<import src="…"/>` at the top of
  `app.native` **and** a matching entry in `app_sources.zig`. A missing
  entry fails loudly at the import site — that is intentional.
- **One size register per row.** `size="sm"` next to a default control
  renders two heights.
- **Accessible names are enforced.** An interactive control with no text, no
  `text=` and no `label=` is a validation error. Icon-only buttons need
  `label="…"`.
- **Budgets are per view**: 1024 retained widgets, 16 anchored floating
  surfaces, 64 chart series. Long lists need `virtualized` or a windowed
  virtual list.

---

## 4. Writing Zig

- **Zig 0.16 idioms.** `var list: std.ArrayList(T) = .empty;` then
  `list.append(allocator, item)`. `std.Io` first for anything outside the
  process. Containers are unmanaged.
- **`update` has no allocator and no clock.** Everything reaches the world
  through the effects channel (`fx.dbQuery`, `fx.dbExec`, `fx.startTimer`,
  `fx.spawn`, `fx.writeFile`, …) and comes back as a message.
- **The model must stay default-constructible.** `UiApp.create` builds it as
  `.{}`, and the model-contract checker does the same. That is why the model
  owns fixed-capacity buffers (`core/bump.zig`) instead of a heap allocator.
- **Never return a pointer to a local composite literal.**

  ```zig
  // WRONG: the array lives on this function's stack frame.
  pub fn rail() []const Row { return &.{ .{ .id = 0, .label = "Overview" } }; }

  // RIGHT: a file-scope constant.
  const rail_rows = [_]Row{ .{ .id = 0, .label = "Overview" } };
  pub fn rail() []const Row { return &rail_rows; }
  ```

  The wrong version hands the view a pointer to dead memory. It shows up as
  garbage text, an absurd allocation, or a crash inside the markup engine,
  far from the cause. **This bit us once already.**
- **Money is `i64` minor units. Time is `i64` epoch milliseconds.** Never a
  float, never a formatted string in the database.
- **Database values are untrusted.** A status column can hold a code the
  enum does not know; cast it with `repos.enumFromInt`, which falls back
  instead of trapping.

---

## 5. The database

- **Every table is `STRICT`.** `native check` rejects anything else.
- **Migrations are append-only.** Add one with
  `native db new-migration <name>`; never edit a shipped one. The lock file
  `src/schema/migrations.lock.json` is the authority for what has been
  applied.
- **One named SQL constant per query**, in `data/repos.zig`. A schema change
  is one edit, not a grep.
- **Reads copy.** The page bytes from the engine are drain scratch: valid
  through the update that receives them, dead after it. A decoder copies
  text into the model's bump buffer.
- **Writes are atomic.** One `dbExec` with several statements is one
  transaction: an order and its lines land together or not at all.

---

## 6. Tests

`native test` runs the headless suite. A test is a rule the app must not
break.

```zig
test "a role cannot open a screen it may not use" {
    var fx = try fakeFx();          // the effects channel in fake mode
    defer fx.deinit();
    var model = main.initialModel();
    main.update(&model, .{ .pick_role = @intFromEnum(nav.Role.kds) }, &fx);
    main.update(&model, .{ .open_screen = @intCast(nav.Screen.settings.index()) }, &fx);
    try testing.expectEqual(nav.Screen.kds_board, model.screen());
}
```

- **Drive the model the way the runtime does**: call `update` with a
  message, assert on the model.
- **Build the view** with `buildTree` when the question is about what the
  operator sees. The helper resolves the import closure first, exactly as
  the runtime does.
- **The effects channel in fake mode** records requests instead of touching
  the OS. Use it for anything that would write.
- **The relational store has an in-memory mode**
  (`native_sdk.relational_store.Database.openMemoryMigrated`) — use it for
  repository tests.
- Every bug fixed gets a test. A fix without a test is a fix that returns.

---

## 7. Adding a screen — the checklist

1. Append the variant to `Screen` in `core/navigation.zig`. **Append.**
   The enum order is the markup's contract: `app.native` gates screens on
   fixed ordinals.
2. Add it to the role that may open it in `core/rbac.zig`.
3. Add the messages it needs to `core/msg.zig`. Every arm the view
   dispatches must be reachable from markup; arms the view never dispatches
   go in `Msg.view_unbound`.
4. Add the state to `core/model.zig`, and the derived bindings as methods
   inside the struct body.
5. Handle the messages in `core/update.zig`. Refuse anything the role may
   not open.
6. Add the SQL to `data/repos.zig` if it needs data.
7. Write the template in `src/screens/screen-<name>.native`: one
   `<template>`, an HTML comment saying what it is.
8. Register it in `src/app_sources.zig` and import it in `src/app.native`.
9. Gate it in the shell: `<if test="{screen_index == N}"><use template="…"/></if>`.
10. Add a test: the screen opens, the role is refused if it should be, and
    the view renders without exceeding the widget budget.

---

## 8. Before you commit

```sh
scripts/verify-all.sh          # native check + native test
scripts/build.sh           # ReleaseFast build
```

Both must be green. If you touched the schema, `native check` validates it
against real SQLite — that is the point of the check.

---

## 9. Where things are

| Question | File |
|---|---|
| What is the model? | `apps/eatery/src/core/model.zig` |
| What can happen? | `apps/eatery/src/core/msg.zig` |
| What does it mean? | `apps/eatery/src/core/update.zig` |
| Who may do what? | `apps/eatery/src/core/rbac.zig` |
| What is in the database? | `apps/eatery/src/schema/*.sql` |
| What is the SQL? | `apps/eatery/src/data/repos.zig` |
| What does the operator see? | `apps/eatery/src/app.native`, `src/screens/` |
| What colour is the brand? | `apps/eatery/src/core/theme.zig` |
| How does the system fit together? | `docs/architecture/` |
| What was decided, and why? | `docs/decisions/` |
| What is left to build? | `docs/plan/backlog.md`, `docs/plan/roadmap.md` |
| What did v1 get wrong? | `docs/plan/gaps-from-v1.md` |

---

## 10. Things not to do

- Do not add a router, a service locator, or a dependency-injection
  container. The model is the dependency graph.
- Do not put business logic in a screen template. If a template computes
  something, that computation belongs in a model method.
- Do not reach for `fx.fetch` to work around a missing local capability
  without writing down why.
- Do not skip the schema check because "the SQL is obviously fine". The
  check is cheap; the STRICT table is not.
- Do not invent platform APIs. If something is not in the SDK reference
  (`../native-zig-showcase/docs/sdk/`), it does not exist: check, and if it
  is missing, write down the gap instead of guessing.
