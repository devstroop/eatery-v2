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

Each track is a branch off `main`, and each branch is developed in its
own worktree. Two reasons:

- a track that touches `core/update.zig` and a track that only touches
  a template should not be waiting on each other;
- the branch is the unit of review, and a review reads better when the
  diff is one concern.

The branch names are the vocabulary. A commit that lands on `main`
directly is a commit that was too small to be reviewed; a commit that
touches two tracks is a commit that needs splitting.

## How work lands

1. **A branch, cut from `main`:** `git worktree add ../eatery-v2-worktrees/<name> -b <type>/<name> main`.
2. **A test that fails first.** Every rule this repository protects is a
   test. A fix without a test is a fix that comes back.
3. **Conventional Commits,** one concern per commit, in the imperative:
   `fix(auth): check the employee's role before signing in`.
4. **The message states the plan,** not the history of the debugging:
   what the slice establishes, what is in it, what is deliberately not
   in it, and what it sets up for the next slice.
5. **`scripts/verify-all.sh` green, `scripts/build.sh` green.**
6. **A pull request** that says what was verified and how. The
   contributor guide has the checklist.

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
