# Restaurant OS documentation

Restaurant OS is the native rewrite of Eatery v1, the restaurant operating
system: point of sale, kitchen display, customer display and back office in
one Zig binary built on the [Native SDK](https://native-sdk.dev).

This directory is the maintained documentation set. It describes the
**target system**, and labels every subsystem with what actually exists
in the source tree today. It is not a changelog and not a promise: a page
marked `Planned` is a design, not code.

> **Last full source review:** 2026-10-20
> **Source of truth:** `apps/ros/` for behaviour, `docs/` for intent.
> **Upstream analysis:** [`../../PORT-PLAN.md`](../../PORT-PLAN.md) — the
> original Flutter-to-Native gap analysis. This documentation supersedes
> it where the two disagree; the plan document is historical input.
>
> Statuses below were established by reading the source. The Native SDK
> CLI (`native`) is not on this shell's PATH, so the test suite was not
> re-run for this review. A built binary exists at
> `apps/ros/zig-out/bin/ros`; it backs "it compiles", not "the tests
> pass". When a status changes, update the page that owns the claim, not a
> status table in three places.

---

## Status vocabulary

| Label | Meaning |
|---|---|
| **Implemented** | Code exists, is wired into the running app, and is exercised by at least one test or is directly rendered. |
| **Partial** | Code exists but is unreachable, incomplete, or only covers part of the described behaviour. |
| **Scaffolded** | A type, schema, directory or enum entry exists; no behaviour is wired. |
| **Superseded** | A later decision or phase replaces it. The page is kept for its reasoning; it is not scheduled. |
| **Planned** | Target design only. No code. |
| **Unknown** | We do not yet know the answer, including whether the question is the right one. |
| **Accepted / Proposed / Provisional / Superseded** | ADR decision states (see `decisions/`). |

A page may contain several statuses because subsystems mature at different
rates. The status block at the top of each page describes the page's main
subject, not the whole app.

---

## Read this first

If you are new to the codebase, read in this order:

1. [`architecture/01-system-overview.md`](architecture/01-system-overview.md) — the shape of the app and the vocabulary.
2. [`architecture/02-app-model-and-effects.md`](architecture/02-app-model-and-effects.md) — the Model / Msg / update contract everything obeys.
3. [`architecture/03-navigation-and-rbac.md`](architecture/03-navigation-and-rbac.md) — roles, screens, and why navigation is model state.
4. [`architecture/04-data-layer.md`](architecture/04-data-layer.md) — how rows get from SQLite into the view.
5. [`plan/status.md`](plan/status.md) — what is actually built, screen by screen.
6. [`plan/open-questions.md`](plan/open-questions.md) — what we do not know yet.

If you are changing a screen, also read
[`architecture/06-ui-markup-and-theming.md`](architecture/06-ui-markup-and-theming.md)
and the "add a screen" checklist in it.

If you are changing the database, read
[`architecture/05-schema.md`](architecture/05-schema.md) and
[ADR-0005](decisions/0005-engine-owned-sqlite-strict-schema.md).

---

## Map

### Architecture

| Document | Subject | Status |
|---|---|---|
| [01-system-overview](architecture/01-system-overview.md) | Layers, runtime topology, invariants, source map | Implemented core / Planned edges |
| [02-app-model-and-effects](architecture/02-app-model-and-effects.md) | Model, Msg, update, boot, effects, bump storage | Implemented |
| [03-navigation-and-rbac](architecture/03-navigation-and-rbac.md) | Roles, 45-screen enum, stack, permission matrix, rail | Implemented core / Partial coverage |
| [04-data-layer](architecture/04-data-layer.md) | Reads, writes, page format, repositories, ownership | Partial |
| [05-schema](architecture/05-schema.md) | 43 tables, conventions, migration policy, usage | Scaffolded beyond core |
| [06-ui-markup-and-theming](architecture/06-ui-markup-and-theming.md) | Markup subset, templates, tokens, layout, a11y | Implemented subset |
| [07-windowing-and-desktop](architecture/07-windowing-and-desktop.md) | Shell, GPU surface, target multi-window, packaging | Single window implemented / multi-window planned |
| [08-sync](architecture/08-sync.md) | OpLog, LWW, sidecar transport, failure modes | Scaffolded |
| [09-printing-and-hardware](architecture/09-printing-and-hardware.md) | ESC/POS, sidecar, printer routing | Scaffolded |
| [10-testing-and-quality](architecture/10-testing-and-quality.md) | Test layers, current coverage, CI target | Partial |
| [11-capability-gaps](architecture/11-capability-gaps.md) | What the SDK does not provide and the chosen workaround | Reference |
| [12-three-apps-and-ipc](architecture/12-three-apps-and-ipc.md) | The three-app split, the TCP/IP protocol, and who owns what | Planned |

### Extended walkthroughs

These are longer, example-heavy companions to the numbered pages above.
The numbered pages are the canonical summary; the walkthroughs go deeper
into one subsystem and include more code excerpts.

| Document | Subject | Companion |
|---|---|---|
| [overview](architecture/overview.md) | App model, lifecycle, module map, adding a screen end to end | [01](architecture/01-system-overview.md), [02](architecture/02-app-model-and-effects.md) |
| [navigation-and-roles](architecture/navigation-and-roles.md) | Screen enum contract, stack, denial path, rail, kiosks, multi-window plan | [03](architecture/03-navigation-and-rbac.md) |
| [data-model](architecture/data-model.md) | Schema rules, migration workflow, page dialect, repositories, salt lifecycle | [04](architecture/04-data-layer.md), [05](architecture/05-schema.md) |
| [ui-components](architecture/ui-components.md) | Markup grammar in practice, templates, tokens, component library plan | [06](architecture/06-ui-markup-and-theming.md) |
| [roadmap](plan/roadmap.md) | Product-ordered delivery plan, mapped to the engineering phase pages | [plan/README](plan/README.md) |
| [gaps-from-v1](plan/gaps-from-v1.md) | What Restaurant OS drops, fixes and still owes the Flutter app | [11](architecture/11-capability-gaps.md) |

Where an extended page and a numbered page disagree, the numbered page
wins until both are corrected. Status claims belong to
[plan/status](plan/status.md).

### Decisions (ADRs)

See [`decisions/README.md`](decisions/README.md) for the index and the
template. The short version:

- Accepted: native Zig rewrite, pure model/update, no router, one binary
  four roles, engine-owned SQLite + STRICT schema, integer money, markup
  only.
- Provisional: PIN hashing, clock-based order IDs.
- Proposed (need an owner): printing sidecar, sync sidecar, desktop-first,
  CSV-first interchange, three apps over TCP/IP.

The last one proposes to supersede "one binary four roles". A proposal
to supersede is not a supersession: the one-binary decision stands
until the three-app one is accepted.

### Plan

| Document | Subject |
|---|---|
| [plan/track](plan/track.md) | The tracks, the direction, and the tracker vocabulary |
| [plan/README](plan/README.md) | Phase board, milestones, definition of done |
| [plan/status](plan/status.md) | As-built matrix and known source defects |
| [plan/backlog](plan/backlog.md) | Every screen, its ordinal, status and owner phase |
| [plan/phase-0-toolchain](plan/phase-0-toolchain.md) | Toolchain and skeleton |
| [plan/phase-1-foundation](plan/phase-1-foundation.md) | Model, navigation, theme, shell |
| [plan/phase-2-schema-and-repositories](plan/phase-2-schema-and-repositories.md) | Schema, repositories, calculations |
| [plan/phase-3-pos-slice](plan/phase-3-pos-slice.md) | POS vertical slice |
| [plan/phase-4-kds-display-waiter](plan/phase-4-kds-display-waiter.md) | Kitchen, display, waiter |
| [plan/phase-5-admin-surfaces](plan/phase-5-admin-surfaces.md) | Back office, catalog, reports |
| [plan/phase-6-sync-sidecar](plan/phase-6-sync-sidecar.md) | LAN sync |
| [plan/phase-7-printing-hardware](plan/phase-7-printing-hardware.md) | Printing and devices |
| [plan/phase-8-packaging-cutover](plan/phase-8-packaging-cutover.md) | Packaging, migration, release |
| [plan/phase-9-three-apps-and-ipc](plan/phase-9-three-apps-and-ipc.md) | Three apps over TCP/IP; supersedes phase 6 |
| [apps/net-spike](../apps/net-spike/README.md) | The seam: a net thread and the loop thread, proved by running |
| [plan/risks](plan/risks.md) | Risk register |
| [plan/open-questions](plan/open-questions.md) | Known unknowns and unknown unknowns |

### Review

The findings of the 2026-10-20 audit are
[issues](https://github.com/devstroop/ros/issues) now, labelled
by the track that owns the fix. The audit itself is a dated snapshot
in the archive, and it stays as the record of how the project found out
what it did not know.

| Document | Subject |
|---|---|
| [review/README](review/README.md) | What happened to the findings, and where they went |
| [review/archive/2026-10-20-audit](review/archive/2026-10-20-audit.md) | Blockers, verified evidence, fix order |
| [review/archive/bugs](review/archive/bugs.md) | Behaviour that was wrong (37 findings) |
| [review/archive/gaps](review/archive/gaps.md) | Flows and features that did not exist (26) |
| [review/archive/enhancements](review/archive/enhancements.md) | Correctness, UX, performance, accessibility (20) |
| [review/archive/docs-audit](review/archive/docs-audit.md) | Stale or overstated documentation claims (18) |

---

## Documentation rules

1. **One claim, one owner.** A status or number lives on the page that
   owns the subsystem. Other pages link instead of repeating it.
2. **Status is evidence-based.** "Implemented" requires a code anchor
   (`path:line`) or a wired screen. "Planned" requires no code.
3. **Design and reality are separate paragraphs.** Do not describe a
   target as if it ships today. Use the status block.
4. **Source anchors are relative to `apps/ros/`.** For example
   `src/core/update.zig:67`. Line numbers drift; the symbol name is the
   stable part.
5. **An ADR is immutable once accepted** except for a status change and a
   superseding link. New information goes in a new ADR.
6. **Unknowns are first-class.** `plan/open-questions.md` is expected to
   grow. An unanswered question is safer than an invented answer.

## Keeping docs current

When a change lands, update:

| Change | Update |
|---|---|
| New screen or template | `architecture/03`, `architecture/06`, `plan/status` |
| New table or column | `architecture/05`, `plan/status` |
| New effect or message | `architecture/02`, `architecture/04` |
| Role or permission change | `architecture/03`, add/extend the RBAC test |
| New external process or protocol | `architecture/08` or `09`, `architecture/12` for the app-to-app protocol, ADR if the decision is new |
| A phase is finished | Its phase page, `plan/README`, `plan/status` |
| A question is answered | `plan/open-questions`, possibly a new ADR |
