# Tracks

> **Status:** Living. This page owns the direction: what the tracks are,
> what each one owns, and the order they run in.
> **The as-built tree is described by [`status.md`](status.md).** The
> findings that became this page are tracked in the
> [issue tracker](https://github.com/devstroop/eatery-v2/issues) - one
> issue per finding, labelled by track and milestone.

## What this page is for

A restaurant runs a service on Eatery v2 when:

1. an owner installs it, creates a company, an admin PIN, a menu and a
   floor;
2. a cashier takes an order, takes payment and prints a receipt;
3. the kitchen sees the ticket and advances it;
4. the customer display shows the order;
5. a second device converges on the same state;
6. the app survives a reboot and a power cut without losing a sale.

Everything below is in service of those six. A piece of work that does
not move one of them is a piece of work that waits.

## The tracks

Eight tracks. Each one is a branch, each one has a scope, each one has
an exit criterion that can be checked rather than asserted.

| Track | Branch | Scope | Done when |
|---|---|---|---|
| **Money** | `feat/money` | Tax and discount arithmetic, the order identifier, idempotent writes, a payment that cannot be taken twice, a PIN that is not a fast digest over four digits | A bill is right for a taxed restaurant, and an order cannot complete unpaid |
| **Back office** | `feat/back-office` | The operator's surfaces: the catalogue, the people, the customers, the stock, the floor, and the writes behind them | Every entity in the schema can be written, and every screen that shows one can edit it |
| **Reports** | `feat/reports` | Z and X reports, the tax report, item mix, CSV export, the audit trail | A report is a query, not a description of a query |
| **Sync** | `feat/sync-sidecar` | The operation log the app writes, and the LAN sidecar that relays it | Two devices on the same network converge with no cloud involved |
| **Print** | `feat/print-sidecar` | The receipt and kitchen-ticket payloads, the ESC/POS encoder, the sidecar that writes them | A receipt prints on a real device, and the same bytes can be tested to a file |
| **Release** | `chore/release` | Packaging, signing, the v1 data decision, the CI sale smoke | A signed build installs on a clean machine with a migrated database |
| **Core** | `feat/core` | The app model and the runtime: the session, the navigation stack, the loading states, the accessibility pass | The shell behaves the same on every role, and the app is operable without a mouse |
| **Docs** | `chore/docs` | The documentation set: one owner per claim, the status vocabulary, the checks that keep it true | Every number in the docs has one page that owns it, and a test or a check proves it |

### The order

```
Money ──┐
        ├─► M1  a usable sale: role picker to login to POS to order to
Back office ─┤           payment to KDS, on one machine
        │
Core ──┘
        │
        ├─► M2  a back office: every screen renders, every entity writes
Reports ┘
        │
        ├─► M3  fabric: two devices converge, receipts and tickets print
Sync ───┤
Print ──┘
        │
        └─► M4  release: a signed build, migrated data, a CI sale smoke
```

**Money is first** because a sale that computes the wrong total is not
a sale, and no amount of screen work makes it one. **Sync and print
come last** because they are the only two tracks that need a second
machine, a second process, or hardware to be believed.

### Why the tracks are branches

Each track is a branch off `develop`, and each branch is developed in its
own worktree. Two reasons:

- a track that touches `core/update.zig` and a track that only touches
  a template should not be waiting on each other;
- the branch is the unit of review, and a review reads better when the
  diff is one concern.

The branch names are the vocabulary. A commit that lands on `develop`
directly is a commit that was too small to be reviewed; a commit that
touches two tracks is a commit that needs splitting.

## The branches

| Branch | What it is |
|---|---|
| `main` | What is released. It moves when `develop` is promoted. |
| `develop` | The integration branch. Every track merges here, and every commit on it is green. |
| `feat/…`, `chore/…` | A track. Cut from `develop`, merged back into `develop`. |

Two tracks can be in flight at once - in two worktrees, on two
branches - and neither waits for the other. The promotion is a pull
request like any other: `develop` to `main`, and its review is the
review of everything the tracks landed since the last one.

## How work lands

1. **A branch, cut from `develop`:** `git worktree add ../eatery-v2-worktrees/<name> -b <type>/<name> develop`.
2. **A test that fails first.** Every rule this repository protects is a
   test. A fix without a test is a fix that comes back.
3. **Conventional Commits,** one concern per commit, in the imperative:
   `fix(auth): check the employee's role before signing in`.
4. **The message states the plan,** not the history of the debugging:
   what the slice establishes, what is in it, what is deliberately not
   in it, and what it sets up for the next slice.
5. **`scripts/verify-all.sh` green, `scripts/build.sh` green.**
6. **A pull request into `develop`** that says what was verified and
   how. The contributor guide has the checklist.
7. **The promotion:** `develop` to `main`, when the tracks have landed
   something worth releasing.

## The tracker

The findings from the 2026-10-20 audit are issues, one per finding, so
that a track and a person can work the same list at the same time.

| Label | Meaning |
|---|---|
| `p0` … `p3` | Severity. `p0` blocks a demo or a sale. |
| `type/bug`, `type/gap`, `type/enhancement`, `type/doc` | What kind of finding it is. |
| `track/money`, `track/back-office`, `track/reports`, `track/sync`, `track/print`, `track/release`, `track/core`, `track/docs` | The track that owns the fix. |

A milestone says when: **M1 - Usable sale**, **M2 - Back office**,
**M3 - Fabric**, **M4 - Release**.

An issue is closed by a commit that says `Closes #<n>`. A finding with
no issue is a finding nobody is looking at.

### Two sets of numbers

The issue titles carry the number of the finding they came from, and
there are two sets of those numbers:

- **The 2026-10-20 audit** - `B-001` to `B-037`, `G-001` to `G-026`,
  `E-001` to `E-020`, `D-001` to `D-018`. These are the findings in
  [`review/archive/`](../review/archive/), and they are the numbers the
  commits and the decisions use. Every one of them carries the label
  `source/audit`.
- **The v1 app's inventory** - what the Flutter app still owed, carried
  over as it is. Their titles are prefixed `V1-`, because the two sets
  overlap by name and not by finding: the v1's `B-036` is the accounting
  date, and the audit's `B-036` is two effects sharing an effect key.
  Every one of them carries the label `source/v1`.

The issue NUMBER is what identifies an issue - `#77` is the v1's
accounting date, `#1` is the audit's order ids - and that is the number
a commit closes.

## The findings, and the issues they became

The audit of 2026-10-20 read the whole repository and produced 101
findings. The ones that were still true became issues; the ones that
were already fixed are in the history, and the archive says which.

| Track | Milestone | Issues |
|---|---|---|
| Track | Milestone | Issues |
|---|---|---|
| `feat/money` | M1 - Usable sale, M2 - Back office | #1, #2, #3, #7, #8, #9, #19, #20, #22, #25, #26, #30, #39, #51, #52, #57, #66, #68, #95 |
| `feat/core` | M1 - Usable sale, M2 - Back office, M4 - Release | #4, #5, #6, #16, #18, #21, #40, #44, #45, #47, #49, #53, #55, #56, #58, #60, #61, #62, #63, #64, #67, #70, #96 |
| `feat/back-office` | M2 - Back office, M1 - Usable sale | #10, #11, #12, #13, #14, #15, #23, #24, #27, #28, #29, #34, #35, #36, #37, #38, #54, #59 |
| `feat/reports` | M2 - Back office, M3 - Fabric | #33, #43 |
| `feat/sync-sidecar` | M3 - Fabric | #32, #46 |
| `feat/print-sidecar` | M3 - Fabric | #31 |
| `chore/release` | M4 - Release | #17, #41, #42, #48, #65 |
| `chore/docs` | M2 - Back office, M4 - Release | #50, #69, #71, #72, #73, #74, #75, #76 |

Every issue carries the plan, the files it touches and a done-when. The
number in the title is the finding's own number, so a conversation can
say "B-014" and mean the same thing in the tracker, in the archive and
in a commit message.

The findings that were already fixed when the issues were opened, and
so are not issues:

| Finding | What it was | Where the fix landed |
|---|---|---|
| B-001 | The order insert omitted a required column | `feat(app)` |
| B-002 | The sign-in ignored the employee's stored role | `fix(auth)` |
| B-003 | The salt was used before the database confirmed it | `fix(auth)` |
| B-004 | The company strings pointed into dead page bytes | `feat(setup)` |
| B-005 | The order foreign keys were written as zero, not null | `feat(app)` |
| B-016 | The inactive rows were shown | `feat(lists)` |
| B-018 | A status cast was a latent compile error | `feat(app)` |
| B-023 | The shell gates were hard-coded ordinals | `fix(core)` |
| B-030 | The seedable schema had invalid default references | `feat(schema)` |
| B-034 | The confirmation showed raw epoch milliseconds | `feat(orders)` |
| B-036 | Two effects shared an effect key | `fix(core)` |
| B-037 | Four screens bound a count the model did not have | `fix(core)` |
| G-016 | There were no database integration tests | `feat(setup)` |
| G-017 | There was no screen-coverage or ordinal test | `fix(core)` |

## The rules that do not move

These are not preferences. Each one exists because breaking it produced
a real defect, and the repository keeps them in the code rather than in
everybody's memory.

| Rule | Why |
|---|---|
| Money is `i64` minor units | A float price loses cents, and a restaurant notices |
| Time is `i64` epoch milliseconds | One shape for every timestamp, so no column needs its own parser |
| Every table is `STRICT` | The engine refuses the wrong value, not the app |
| The markup never mutates state | One place decides what is true |
| Derived values are methods | A stored number that could be computed drifts from its inputs |
| Permissions are a pure function | A permission check you cannot test is not a permission check |
| Migrations are append-only | The lock file is the authority for what has shipped |
| PINs are salted and hashed | v1 stored them in the clear |

## Related

- [`status.md`](status.md) - the tree as it stands, screen by screen
- [`roadmap.md`](roadmap.md) - the delivery order in product terms
- [`backlog.md`](backlog.md) - every screen, one row each
- [`risks.md`](risks.md) - what could go wrong next
- [`open-questions.md`](open-questions.md) - what we do not know yet
