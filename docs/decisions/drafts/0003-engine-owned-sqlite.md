# ADR-0003: The platform's relational store, not a vendored SQLite FFI

**Status:** Accepted (2026-10)
**Applies to:** `apps/ros/src/schema/**`, `apps/ros/src/data/**`
**Related:** [`architecture/data-model.md`](../../architecture/data-model.md),
[`architecture/04-data-layer.md`](../../architecture/04-data-layer.md)

## Context

v1 shipped its own SQLite. `libeaterystore/` is a Zig C library with its
own `build.zig`, built with `libeaterystore/scripts/build.sh` and bound
into Dart through `dart:ffi`. The app reached it through a global mutable
handle: `../eatery/docs/plan/issue-inventory.md` defect **L1** records
`static EateryStore? _store` in `order.function.dart`, which the audit
describes as breaking testability, dependency injection and any second app
in the same process. The repository layer also mixed blocking FFI reads with
`Future`-wrapped writes (defect **R1**), and every `getAll*()` ran
`SELECT *` with no limit (defect **R2**), which is why v1's product list and
customer list each ran their queries inside a widget `build()`.

The transactional gap lived in that same boundary. Defect **DB5** in
`../eatery/docs/plan/issue-inventory.md`: `SqliteOrderRepository` saved the order and
then wrote its line items in a loop, with no transaction. A crash midway
left orphaned line items. v1 also had no type discipline in the store: 39
tables in `assets/db/schema.sql` with SQLite's loose affinity and no
`STRICT` keyword, money columns typed `REAL`, and `employee.pin TEXT`
holding the PIN in the clear.

The Native SDK owns the relational store. `apps/ros/app.json` declares
the `sqlite` capability; the SDK generates a migrations module from
`apps/ros/src/schema/` and wires it into the runner, so the database is
opened already migrated at boot. The app never opens a connection, never
issues a `PRAGMA`, and never runs migration code.

## Decision

**Use the engine-owned relational store and write SQL against it from
`apps/ros/src/data/repos.zig`.** No SQLite library is vendored, built or
bound.

The schema is ten numbered migrations in `apps/ros/src/schema/`,
0001..0010, 43 tables, every one `STRICT`, with the lock file
`migrations.lock.json` recording the version, a SHA-256 per file and a
whole-set hash. `native check` prepares the schema against real SQLite at
build time and fails on a non-`STRICT` table, an unresolved foreign key, SQL
that does not parse, or a migration whose hash does not match the lock. A
shipped migration is never edited; a change is a new file with the next
number.

The repository layer has one named SQL constant per query, one loader per
query, one decoder per dataset and one writer per mutation. Writes are one
`fx.dbExec` carrying all the statements for the transaction, and the engine
runs them atomically — `repos.saveOrder` sends the order plus one statement
per line in a single call, so v1's DB5 cannot recur. Reads copy out of the
engine's row format, which `apps/ros/src/data/page.zig` reads with a
streaming reader that addresses columns by name so a column reorder in SQL
cannot silently swap two fields in a decoder.

The store also provides live queries. `fx.dbSubscribe` re-runs a read query
after any transaction that touched a subscribed table, which is the direct
replacement for v1's `ref.invalidate` and `FutureProvider` invalidation.

## Consequences

- One engine. There is no second SQLite build to compile, sign, patch or
  track, and no FFI seam between the business logic and the data.
- The write path is atomic by construction. `repos.setOrderStatus` sends the
  status update and the `order_status_history` row in one `dbExec`, so the
  timeline cannot disagree with the order's current status; `repos.saveOrder`
  does the same for the order and its lines.
- The schema is checked, not trusted. A non-`STRICT` table or a broken
  foreign key fails `native check` rather than production.
- The engine owns the lifecycle. Migrations are applied before the first
  frame, so the app never has to think about a half-migrated database.
- **Cost:** the app cannot choose its SQLite build, its page size, its
  journal mode or its pragmas. Those are the engine's decisions, and there
  is no way to override them from the app.
- **Cost:** the row format is a fixed little-endian dialect with a hard
  limit of 64 columns per query (`page.max_columns`). The app has to carry
  its own reader (`src/data/page.zig`) rather than use a library.
- **Cost:** the page bytes are drain scratch — valid through the update
  that receives them, dead after it. Every value the model keeps has to be
  copied into a bump buffer, so the data layer is more verbose than a
  conventional ORM.
- **Cost:** `native check` is the only thing that validates the schema
  against a real engine. It has to run in CI, or the guarantee is
  decorative. There is no CI workflow in this repository yet.
- **Cost:** there is no FFI escape hatch for the data layer. Anything that
  needs a C library (BLE, ESC/POS, a spreadsheet writer) has to go through
  a sidecar rather than an in-process link, which is why
  `tools/sync-sidecar/` and `tools/print-sidecar/` exist as separate
  programs.
- **Cost:** the engine's transaction semantics are the only transaction
  semantics. There is no `BEGIN IMMEDIATE`, no savepoint and no
  `PRAGMA journal_mode` to hand to a long-running reader.
- **Cost:** the live-query path is available but unused. Every read in
  `src/data/repos.zig` is a one-shot `dbQuery`, so the kitchen board does
  not refresh when another window advances a ticket. Converting the KDS,
  the order list, the floor board and the `op_log` watch to `dbSubscribe`
  is Phase 1 work.

## Alternatives considered

- **Keep the vendored SQLite behind an FFI boundary, as v1 did.** Loses
  because it is the arrangement that produced the global store handle (L1),
  the mixed sync/async repository API (R1), the unbounded `getAll*()` (R2)
  and the missing transaction (DB5). It also means shipping and patching a
  C library for three desktop platforms, which is exactly the maintenance
  burden the rewrite is meant to shed.
- **An in-process store with JSON files on disk.** Loses because it gives up
  range queries over time, aggregation for reports, referential integrity
  between `orders` and `order_line`, and atomic multi-statement writes.
  Every one of those is needed by the product.
- **An ORM over the engine store.** Loses because it hides the SQL, and the
  SQL is the part that has to be reviewable: v1's repository defects (D1's
  `as dynamic` casts, D3's incomplete interface, R3's interface/implementation
  drift) were all repository-layer defects. Named constants in one file
  (`src/data/repos.zig`) keep the statements legible and greppable.
- **A document store with JSON rows.** Loses for the same reason as the
  in-process store: the compliance and reporting requirements in
  `src/schema/0008_compliance.sql` require an X/Z report to be
  reconstructible from the database alone, months later.
- **Keep the schema in the app and run the migrations itself.** Loses
  because the SDK already applies them at boot and runs them in the right
  order. An app-run migration path would mean a second source of truth
  about which schema version a database holds.

## Checklist

Before a data-layer change is treated as done:

- [ ] Every new table is `STRICT`, with `CHECK` constraints on enums and
      booleans, integer minor-unit money and epoch-millisecond time.
- [ ] Every new migration is a new numbered file; no shipped file is edited.
- [ ] `apps/ros/src/schema/migrations.lock.json` is regenerated and the
      version advanced.
- [ ] `native check` passes and reports no `NS1405` diagnostic.
- [ ] Every new query has a named constant, a loader and a decoder in
      `src/data/repos.zig`, and its effect has its own `key_*` constant in a
      family that cannot collide.
- [ ] Every write that must be atomic is one `dbExec` with all its
      statements, not a sequence of calls.
- [ ] Every value the model keeps is copied into a bump buffer; no slice
      into page bytes outlives the update that received it.
- [ ] There is an in-memory database test for the new path, using
      `native_sdk.relational_store.Database.openMemoryMigrated`.
