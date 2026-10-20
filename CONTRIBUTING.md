# Contributing to Eatery v2

Eatery v2 is a restaurant POS written in Zig on the
[Native SDK](https://native-sdk.dev). It is a rewrite of a Flutter app, and
it inherits one lesson from that app: **the rules that protect the money
must live in code, not in a convention everybody remembers.**

## Before you start

```sh
./scripts/setup.sh      # toolchain: zig 0.16, node 24, the native CLI
source ./scripts/env.sh # put them on PATH
scripts/verify-all.sh   # everything green before you change anything
```

Read [AGENTS.md](AGENTS.md) before you write code. It is the manual for
this codebase: the app model, the markup rules, the Zig traps, the schema
rules and the checklist for adding a screen.

## The shape of a change

1. **A test that fails.** Write the rule first. Every bug that gets fixed
   in this repo gets a test that would have caught it.
2. **The smallest change that makes it pass.** Model, message, update,
   markup - in that order of preference.
3. **`scripts/verify-all.sh` is green.**
4. **`scripts/build.sh` succeeds.**

## Rules that are not negotiable

| Rule | Why |
|---|---|
| Money is `i64` minor units | v1 stored money in `REAL` columns and lost cents to rounding |
| Time is `i64` epoch milliseconds | One shape for every timestamp; no per-column date parsing |
| Every table is `STRICT` | A declared column type that the database enforces |
| The markup never mutates state | One place decides what is true |
| Derived values are methods | A stored field that could be computed drifts |
| Permissions are a pure function | A permission check you cannot test is not a permission check |
| PINs are salted and hashed | v1 stored them in the clear |
| Migrations are append-only | The lock file is the authority for what has shipped |

## Commit messages

The repository uses Conventional Commits:

```
feat(pos): modifier sheet with per-group selection
fix(auth): reject a PIN when the installation salt is missing
docs(plan): mark the payments screen as phase 2
refactor(model): move the cart into its own module
```

## Pull requests

- One concern per PR. A schema change and a UI change are two PRs.
- Say what you verified and how (`native check`, `native test`, a
  `native automate` run, a screenshot).
- If you changed the schema, say which migration and why it is
  append-only.
- If you hit a platform limitation, write it down in
  `docs/plan/open-questions.md` rather than working around it silently.

## Where things are

| Question | File |
|---|---|
| How the system fits together | `docs/architecture/` |
| What was decided, and why | `docs/decisions/` |
| What is left to build | `docs/plan/backlog.md` |
| What v1 got wrong | `docs/plan/gaps-from-v1.md` |
| The rules | `AGENTS.md` |

## Licence

MIT. By contributing you agree that your work is licensed under it.
