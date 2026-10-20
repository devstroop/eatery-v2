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
- `apps/eatery/src/schema/` — 11 migrations and a lock file.
- The CLI-synthesised build directory `.native/build/` (generated, not
  owned).
- `scripts/setup.sh`, `env.sh`, `dev.sh`, `build.sh`, `verify-all.sh`.
- `.github/workflows/ci.yml` (verify + non-blank smoke).

## What is missing

| Item | Why it matters |
|---|---|
| A non-macOS pin/instruction | `scripts/env.sh` and `setup.sh` assume Homebrew paths at `/opt/homebrew` |
| A recorded clean-machine proof | The scripts exist; Linux and Windows are unproven |
| CI coverage of the sale path | The workflow runs check/test and a non-blank smoke only |

Environment facts (verified on this machine on 2026-10-20):

- Zig **must** be 0.16.0. `/usr/local/bin/zig` is 0.17 and shadows Homebrew.
- Node **≥ 24** is required by the relational toolchain.
- The SDK's `packages/core` needs `npm ci --include=dev`.
- The SDK must be built once: `zig build -Doptimize=ReleaseFast`.
- On this machine the CLI is at `~/native-sdk/zig-out/bin/native`;
  `scripts/env.sh` puts it on `PATH`. The app builds and `native check`
  passes. There is still no recorded clean-machine bootstrap on a second
  platform.

## Tasks

1. Generalise `scripts/env.sh`/`setup.sh` beyond Homebrew/macOS (or add a
   `mise.toml`/`.tool-versions`).
2. Add a Linux bootstrap and prove `native check`/`native test` there.
3. Extend CI's smoke through a seeded sale (see G-018).
4. Record a green run with the CLI version and commit in `status.md`.
5. Decide whether the app owns a `build.zig` now (`native eject`) or stays
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
