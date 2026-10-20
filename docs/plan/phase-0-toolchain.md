# Phase 0 — Toolchain and skeleton

> **Status:** Partial
> **Estimate:** 2 engineer-days
> **Depends on:** nothing
> **Exit criterion:** `native check` and `native test` are green on the app
> with the SQLite capability declared, in a reproducible environment.

## Goal

Make the project buildable by someone who is not the person who set it up.
The hard part is not the code; it is the pinned environment.

## What exists

- `apps/eatery/app.json` — id, name, version, platforms, permissions,
  capabilities (including `sqlite`), one window, one GPU surface, security
  origins.
- `apps/eatery/src/main.zig` — `UiApp.create`, shell config, panic
  capture, salt generation, runner options.
- `apps/eatery/src/schema/` — 10 migrations and a lock file.
- The CLI-synthesised build directory `.native/build/` (generated, not
  owned).

## What is missing

| Item | Why it matters |
|---|---|
| A committed environment pin (Zig 0.16.0, Node ≥ 24, SDK v0.11.0) | A new machine will pick Zig 0.17 and fail |
| A bootstrap script or asdf/mise file | The port plan's PATH incantation is easy to get wrong |
| `.github/workflows/ci.yml` | Nothing verifies the tree |
| `scripts/verify-all.sh` | No one-command check |
| A clean-build proof | `.native/build/` exists, but no recorded green run in this workspace |

Known environment facts (from the port plan, not re-verified here):

- Zig **must** be 0.16.0. `/usr/local/bin/zig` is 0.17 and shadows Homebrew.
- Node **≥ 24** is required by the relational toolchain.
- The SDK's `packages/core` needs `npm ci --include=dev`.
- The SDK must be built once: `zig build -Doptimize=ReleaseFast`.
- The CLI is `native` from `~/native-sdk/zig-out/bin`.
- The CLI is **not on this shell's PATH**. A binary exists at
  `apps/eatery/zig-out/bin/eatery`, but there is no recorded reproducible
  bootstrap in the repo.

## Tasks

1. Add a pin file (`mise.toml`, `.tool-versions`, or a documented script)
   for Zig 0.16.0 and Node 24.
2. Add `scripts/bootstrap.sh`: clone/use the SDK, install TS deps, build
   the CLI, print the PATH.
3. Add `scripts/verify.sh`: `native check`, `native test`, optionally
   `native build`.
4. Add a CI workflow adapted from the showcase: pin versions, cache the
   SDK and `node_modules`, run check + test, then an automation smoke.
5. Record the first green run with the CLI version and commit in the repo
   (or in `status.md`).
6. Decide whether the app owns a `build.zig` now (`native eject`) or stays
   managed. Managed is fine until a C library is linked.

## Exit criterion

A clean machine, following only the repo's own instructions, can run:

```
native check apps/eatery
native test apps/eatery --yes
```

green, with no global state beyond the pinned tools.

## Risks

| Risk | Mitigation |
|---|---|
| Zig/Node drift | Pin both; fail fast with a version check |
| SDK changes under us | Pin v0.11.0; upgrade deliberately |
| `npm ci` too slow in CI | Cache `packages/core/node_modules` keyed on the lockfile |
| Someone edits `.native/build` | It is generated; never commit it |

## Unknowns

- Does the SDK CLI build from source on Linux and Windows CI runners?
- Is there a prebuilt CLI release we could use instead of building?
- Does `native test` require a display on any platform?

See [`../open-questions.md`](open-questions.md).
