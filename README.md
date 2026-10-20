# Eatery v2

A restaurant operating system in one native binary: **point of sale, kitchen
display, customer display and back office**, written in Zig on the
[Native SDK](https://native-sdk.dev).

This is a ground-up rewrite of Eatery v1 (the Flutter app that lived in
`../eatery`). v1 taught us a lot about what a restaurant actually needs and
where it went wrong; v2 keeps the product and rebuilds the machinery on a
native GPU canvas, an engine-owned SQLite store and a typed effect channel.

```sh
cd apps/eatery
native dev          # debug build + markup hot reload
native test         # headless update-logic and repository tests
native check        # manifest, markup and schema validation
native build        # ReleaseFast binary in zig-out/bin/
```

---

## Why v2 exists

v1 was a Flutter app: 400+ Dart files, a router, a reactive widget tree, a
vendored SQLite C library behind an FFI boundary, and a WebSocket sync stack
that lived inside the business logic. It worked, and it also taught us
exactly where the seams hurt:

| v1 problem | v2 answer |
|---|---|
| Money in `REAL` columns, rounded by the UI | **Money is `i64` minor units, everywhere.** No float money, ever. |
| PINs readable in the database | PINs are **salted SHA-256**; the plaintext never touches the disk |
| Permissions buried in a router `redirect:` | Permissions are a **pure function** (`core/rbac.zig`); the current matrix test is tautological and is being replaced with a real table |
| A router, a navigator, and a riverpod graph | **One model, one `update`.** Navigation is model state. |
| A second SQLite engine vendored into the app | **The platform's own store** — engine-owned, live queries, migrations included |
| Sync transport tangled into the domain | The app writes an **operation log**; a sidecar owns the socket |
| A 39-table schema with no type discipline | **43 STRICT tables**, one migration per concern, checked at build time |
| Business logic and widgets in one tree | **Model / Msg / update** in Zig, declarative markup for the view, nothing in between |

The full comparison, the capability gaps and the reasoning behind every
decision are in [`docs/architecture/11-capability-gaps.md`](docs/architecture/11-capability-gaps.md)
and [`docs/decisions/`](docs/decisions/README.md).

---

## The shape of the app

The Native SDK's app model is small and strict, and everything in this repo
follows it:

```
Model  ── what is true              (src/core/model.zig)
Msg    ── what happened             (src/core/msg.zig)
update ── what is true now          (src/core/update.zig)
markup ── what the operator sees    (src/app.native, src/screens/*.native)
```

* The **markup never changes state.** It binds model values and dispatches
  messages. Every state change happens in `update`.
* **Derived values are methods, not fields.** Counts, totals and filtered
  lists are computed on rebuild, so they cannot drift from their inputs.
* **The world is reached through the effects channel.** The database, the
  clock, files, the clipboard, a printer - all of it is an effect with a
  typed result message. `update` stays a pure function of (model, message).
* **The app is testable without a window.** `native test` builds the view,
  dispatches messages the way the runtime does, and asserts on the model.

### Module map

```
apps/eatery/src/
├── main.zig              the app: shell, UiApp, runner wiring
├── app.native            the shell: title bar, nav rail, screen gates
├── app_sources.zig       the embedded import closure for the templates
├── core/
│   ├── model.zig         the Model: every field and every derived binding
│   ├── msg.zig           the Msg union: every message the app understands
│   ├── update.zig        the update function: the only place state changes
│   ├── navigation.zig    the Screen enum and the navigation stack
│   ├── rbac.zig          the permission matrix (a pure function)
│   ├── theme.zig         the design tokens: Eatery's own palette
│   └── bump.zig          fixed-capacity storage for the model's rows
├── domain/models.zig     the entities: Product, Order, Table, Employee...
├── data/
│   ├── repos.zig         the SQL: one named statement per query
│   ├── page.zig          the reader for the engine's row format
│   └── auth.zig          PIN hashing
├── schema/*.sql          the database: ten migrations, all STRICT
├── screens/*.native      one template per screen
└── tests.zig             the rules the app must not break
```

---

## The database

The schema lives in `apps/eatery/src/schema/` as numbered migrations and is
applied by the platform when the database opens. Three rules hold in every
table:

* **`STRICT` tables only.** A column's declared type means something.
* **Money is `INTEGER` minor units.** A price is an integer count of the
  smallest unit, never a float.
* **Time is `INTEGER` epoch milliseconds, UTC.** Every timestamp in the
  database has the same shape.

```sh
cd apps/eatery
native db new-migration add_promotions   # appends src/schema/000N_add_promotions.sql
```

`native check` validates every migration against real SQLite at build time -
a non-STRICT table or a broken foreign key fails the check, not production.

The **operation log** (`op_log`) is the sync substrate: the app writes its
changes there and watches it with a live query, while a sidecar process owns
the WebSocket and the mDNS announcement. See
[`docs/architecture/08-sync.md`](docs/architecture/08-sync.md).

---

## Running it

### Requirements

| Tool | Version | Why |
|---|---|---|
| Zig | **0.16.0** | The SDK pins it. 0.17 does not parse the SDK. |
| Node | **24+** | The relational-schema generator is TypeScript. |
| Native SDK CLI | v0.11.0 | `native dev / test / check / build / automate` |

```sh
./scripts/setup.sh      # installs the toolchain and builds the SDK CLI
source ./scripts/env.sh # puts zig 0.16, node 24 and the CLI on PATH
```

### Everyday commands

```sh
scripts/verify-all.sh        # native check + native test for every app
scripts/build.sh         # ReleaseFast build of every app
scripts/dev.sh           # debug run of the app with markup hot reload

cd apps/eatery
native automate wait                       # wait for the running app
native automate assert 'gpu_nonblank=true' # assert the window drew something
native automate snapshot                   # dump the widget tree
```

---

## Repository layout

```
eatery-v2/
├── apps/eatery/          the app
├── docs/                 the architecture, the decisions, the plan
│   ├── architecture/      how the system is put together
│   ├── decisions/         ADRs: what we decided and why
│   └── plan/              roadmap, backlog, the gaps from v1
├── scripts/              setup, verify, build, dev
├── tools/
│   ├── sync-sidecar/      the LAN sync transport (planned)
│   └── print-sidecar/     the receipt printer transport (planned)
└── AGENTS.md             the operating manual for coding agents
```

---

## Status

The foundation is in place and building: the app model, the permission
matrix, the design tokens, the schema (43 tables), the repository layer, the
PIN sign-in, the role picker, first-run setup, the dashboard, the point of sale, the
order list, the floor and the kitchen board. The order write is fixed in
the working tree but not committed (see the audit). 15 authored headless
tests cover the model, navigation and markup basics; the uncommitted
in-memory suite covers the SQL.

The rest of the product is on the phase board in
[`docs/plan/README.md`](docs/plan/README.md), with the as-built screen
matrix in [`docs/plan/status.md`](docs/plan/status.md). The documentation
index is [`docs/README.md`](docs/README.md); the dated findings are in
[`docs/review/2026-10-20-audit.md`](docs/review/2026-10-20-audit.md).

---

## Conventions that are not negotiable

1. **Markup never mutates state.** It binds and dispatches.
2. **Everything the view can see is a field or a method on `Model`.** A
   file-scope function next to the struct is invisible to the markup.
3. **Derived values are methods.** A stored field that could be computed is a
   bug waiting to drift.
4. **`view_unbound` lists what the view must not see.** Keep it honest.
5. **Money is integer minor units. Time is epoch milliseconds.**
6. **Every table is `STRICT`.**
7. **Files the markup binds are file-scope constants.** A composite literal
   built inside a function lives on that function's stack frame; returning a
   slice to it hands the view a pointer to dead memory. (This one bit us
   once already - see `core/rbac.zig`.)
8. **Tests are the rules.** If a rule matters, it is a test.

`AGENTS.md` has the long version, including the platform traps worth knowing
before you write a line of markup.

---

## Licence

MIT. See [LICENSE](LICENSE).
