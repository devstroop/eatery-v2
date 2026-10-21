# Documentation audit

> **Snapshot:** 2026-10-20. The docs are generally strong: the status
> vocabulary, ADR set and architecture pages are unusually explicit. The
> failures below are staleness and overstatement, not a missing structure.

| ID | Severity | Claim / issue | Disposition |
|---|---|---|---|
| [D-001](#d-001--ci-is-reported-as-zero) | P1 | `plan/status` and `plan/README` say there are no CI workflows | Fixed |
| [D-002](#d-002--three-pages-say-there-is-no-ci) | P1 | Architecture 10, phase 8 and the app README repeat “no CI” | Fixed |
| [D-003](#d-003--environment-is-reported-as-unpinned) | P2 | Scripts and CI pin Zig/Node/SDK, but status says they do not | Fixed |
| [D-004](#d-004--sidecar-directories-are-called-empty) | P3 | Both directories contain READMEs; they are still code-free | Fixed |
| [D-005](#d-005--the-order-flow-is-described-as-working) | P0 | Status/app README say a row is written; the insert fails (B-001) | Fixed |
| [D-006](#d-006--test-totals-do-not-match-the-runner) | P2 | “12 tests” vs 13/13 committed / 25/25 in the working tree | Clarified |
| [D-007](#d-007--the-rbac-matrix-test-is-tautological) | P1 | The “matrix is total” test cannot fail | Documented |
| [D-008](#d-008--the-rbac-test-is-called-table-driven) | P2 | The root README implies a table that does not exist | Documented |
| [D-009](#d-009--phase-0-lists-scripts-and-ci-as-missing) | P2 | `verify-all.sh`, `setup.sh` and CI now exist | Fixed |
| [D-010](#d-010--the-roadmap-says-scripts-is-empty-and-names-verifysh) | P2 | Scripts exist; the file is `verify-all.sh`, not `verify.sh` | Fixed |
| [D-011](#d-011--the-phase-board-reports-zero-ci) | P2 | Same stale count in the phase board | Fixed |
| [D-012](#d-012--phase-8-says-there-is-no-ci) | P3 | CI exists; packaging still does not | Fixed |
| [D-013](#d-013--native-check-is-described-as-not-opening-the-database) | P3 | `native check` prepares the schema with SQLite; the wording is misleading | Clarified |
| [D-014](#d-014--salted-sha-256-is-presented-as-sufficient) | P1 | It is fast and unsalted per user; the docs omit the threat model | Open |
| [D-015](#d-015--the-data-layer-page-omits-the-two-write-blockers) | P1 | It documents the write shape but not `updated_at` or FK `0` | Open |
| [D-016](#d-016--open-questions-omit-four-known-unknowns) | P2 | FK enforcement, PIN KDF, currency exponent, harness semantics | Addressed |
| [D-017](#d-017--the-root-readme-says-12-tests-guard-the-rules) | P2 | One is tautological; the SQL suite is uncommitted | Open |
| [D-018](#d-018--counts-and-status-are-duplicated-across-pages) | P2 | Violates the “one claim, one owner” rule the index states | Open |

---

## D-001 — CI is reported as zero

`docs/plan/status.md` scoreboard says `CI workflows | 0`; the phase board
in `docs/plan/README.md` repeats it. `.github/workflows/ci.yml` exists with
a `verify` and a `smoke` job. **Fixed** in this pass.

---

## D-002 — Three pages say there is no CI

`docs/architecture/10-testing-and-quality.md` (“There is no CI”),
`docs/plan/phase-8-packaging-cutover.md` (“No packaging, no CI”) and
`apps/eatery/README.md` (“There is no CI”). **Fixed** in this pass; the
phase-8 line now distinguishes CI from packaging.

---

## D-003 — Environment is reported as unpinned

`plan/status` says “environment not pinned in repo” and phase 0 lists a
pin file as missing. `scripts/env.sh` and `scripts/setup.sh` pin Zig
0.16.0 / Node 24 / SDK v0.11.0, and CI pins the same. The scripts are
macOS-centric, which is a different issue. **Fixed** in this pass.

---

## D-004 — Sidecar directories are called empty

Status says “empty sidecar dir”. `tools/print-sidecar/README.md` and
`tools/sync-sidecar/README.md` exist; there is still no code. **Fixed** to
“README only”.

---

## D-005 — The order flow is described as working

`plan/status` and `apps/eatery/README.md` said “place order → row written
to `orders` + `order_line`”. At committed `HEAD` the insert omitted
`orders.updated_at` (B-001), so the write failed; the working tree fixes
it. **Fixed**: the pages now distinguish the working tree from committed
`HEAD` and link the audit.

---

## D-006 — Test totals do not match the runner

The docs said 12 headless tests. The committed tree runs 13/13 (12
authored + one generated); the working tree has 13 authored + 11
in-memory DB tests + one generated = 25/25. **Clarified** in status and
architecture 10: authored, integration, generated.

---

## D-007 — The RBAC matrix test is tautological

`src/tests.zig`:

```zig
const permitted = rbac.allows(role, screen);
if (permitted) {
    try testing.expect(rbac.allows(role, screen));
}
```

The assertion is inside `if (permitted)`, so it always passes. The test
does not compare against an expected table. Documentation calls it a
table-driven matrix and a lock-out guarantee. **Documented**; the test
itself needs a code change.

---

## D-008 — The RBAC test is called table-driven

The root README says permissions are “a pure function ... with a
table-driven test”. There is no table and the test is tautological
(D-007). **Documented**; correct the sentence when the test is fixed.

---

## D-009 — Phase 0 lists scripts and CI as missing

`docs/plan/phase-0-toolchain.md` “What is missing” lists
`scripts/verify-all.sh`, a bootstrap script and CI. All three exist. The
remaining gap is the clean-machine proof and the macOS-only assumptions.
**Fixed** in this pass.

---

## D-010 — The roadmap says `scripts/` is empty and names `verify.sh`

`docs/plan/roadmap.md` line 129 says the scripts do not exist and names
`verify.sh`. The files are `setup.sh`, `env.sh`, `dev.sh`, `build.sh` and
`verify-all.sh`. **Fixed**.

---

## D-011 — The phase board reports zero CI

`docs/plan/README.md` scoreboard `CI workflows | 0`. **Fixed** to one
workflow with two jobs.

---

## D-012 — Phase 8 says there is no CI

`docs/plan/phase-8-packaging-cutover.md` starts “No packaging, no CI, no
migration path.” CI exists; packaging and migration do not. **Fixed** to
separate the three.

---

## D-013 — `native check` is described as not opening the database

`apps/eatery/README.md` says check “does not open the database. The schema
is exercised when the app opens it.” `native check` does validate the
schema: a temporary non-STRICT table in a copy of the app makes it fail
with `NS1405`. It does not open the app's live database, which may be
what the sentence meant. **Clarified**: check validates the schema in a
prepared SQLite context; the live database is opened at runtime.

---

## D-014 — Salted SHA-256 is presented as sufficient

The README and ADR-0007 present salted SHA-256 as the PIN fix. It removes
plaintext storage, which is real, but a single fast hash over a four-digit
PIN is trivial to brute force offline. There is no per-user salt, KDF,
lockout or audit. **Open**: add a threat-model note and a superseding ADR
when the KDF lands.

---

## D-015 — The data-layer page omits the two write blockers

`docs/architecture/04-data-layer.md` describes `saveOrder` and the
`ON CONFLICT` clauses but not the missing `updated_at` (B-001) or the
zero foreign keys (B-005). `docs/architecture/10-testing-and-quality.md`
also shows a “relational test recipe” that sets `fx.executor = .fake`
before binding a store; a fake executor does not run the SQL. Both pages
now carry a warning or a corrected recipe, but the design text still
reads as if the write works. **Open**: link B-001/B-005 in
the write section.

---

## D-016 — Open questions omit four known unknowns

`docs/plan/open-questions.md` has no entry for: whether the engine
enforces foreign keys, which KDF/rotation policy PINs need, which currency
exponents must be supported, or how the test harness's `dbExec` drain
semantics work. **Addressed**: added to the open-questions page.

---

## D-017 — The root README says 12 tests guard the rules

The sentence was true in count but overstated coverage: one test is
tautological, the SQL suite is uncommitted, and five of eight templates
have no render test. **Open**: reword to “13 authored headless tests plus
an uncommitted 11-test database suite”.

---

## D-018 — Counts and status are duplicated across pages

The same counts (43 screens, 8 templates, 13 headless tests, 43 tables) appear in
`docs/README`, `plan/README`, `plan/status`, `architecture/10`, the app
README and the root README. The index's own rule says “one claim, one
owner”. They drifted within one day. **Open**: keep the canonical table in
`plan/status.md` and link to it; let the other pages describe, not count.
