# ADR-0005: Engine-owned SQLite and a STRICT schema

> **Status:** Accepted
> **Date:** 2026-10-20
> **Deciders:** Eatery maintainers
> **Related:** [`architecture/05`](../architecture/05-schema.md),
> [`architecture/04`](../architecture/04-data-layer.md)

## Context

v1 shipped its own SQLite wrapper: `libeaterystore`, a vendored SQLite
3.47 with a C ABI (`es_open`, `es_query`, `es_exec`), JSON marshalling
across the FFI boundary, and a background isolate for heavy queries. The
schema was 39 non-STRICT tables with loose affinity.

The Native SDK links its own SQLite into a Zig-core app when the `sqlite`
capability is declared. It generates a migrations module from
`src/schema/*.sql`, opens the database migrated at boot, and exposes
`dbQuery` / `dbExec` / `dbSubscribe` through the effects channel. It
rejects non-STRICT tables with `NS1405`.

## Decision

**Drop `libeaterystore`. Use the engine-owned relational store, and
rewrite the schema as STRICT migrations.**

Rules:

- `src/schema/NNNN_name.sql`, append-only; `migrations.lock.json` is the
  authority.
- Every table is `STRICT`.
- Money is integer minor units; time is integer epoch ms.
- Booleans are integer 0/1 with a `CHECK`.
- Enumerations are integer codes with a `CHECK`.
- SQL lives in named constants in `src/data/repos.zig`.
- Reads copy into model bump buffers; writes are one atomic `dbExec`.

## Consequences

### Positive

- One SQLite, linked by the engine; no vendored C library, no FFI
  marshalling, no isolate.
- Type errors are caught by SQLite, not by convention.
- Migrations are generated and validated; `native check` prepares the SQL.
- Live queries (`dbSubscribe`) are available for sync and multi-window.
- The database is opened and migrated by the runtime, not by app code.

### Negative

- A full schema rewrite; legacy data needs a migration plan.
- STRICT surfaces every loose type in old data.
- No app control over PRAGMAs or connection pooling.
- Repository code is manual SQL + manual decoding; no ORM.
- `dbExec` is synchronous per call, so a multi-effect operation is not
  atomic. Business operations must fit one call.

### Follow-ups

- Write the legacy-data migration and validate it on a real database copy.
- Add repository integration tests with `openMemoryMigrated`.
- Decide whether `dbSubscribe` is the refresh mechanism (target) or
  explicit reloads remain.
- Add the missing indexes for reports and shift reconciliation.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Keep `libeaterystore` | Duplicate SQLite, FFI cost, and the SDK already links one. |
| Non-STRICT tables | Rejected by the SDK; STRICT is also better. |
| Greenfield schema without legacy migration | Only valid if a fresh install is acceptable; that is an open question. |
| Embedded document store | Reporting, compliance and reconciliation need relational queries. |

## Evidence

- `src/schema/0001`–`0010`, `migrations.lock.json` (version 10).
- `app.json`: `sqlite` capability.
- `src/data/repos.zig`: named SQL, atomic writes.
- `PORT-PLAN.md` §3.5, §8.
