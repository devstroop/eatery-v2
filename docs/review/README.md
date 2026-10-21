# Review and audit

> **Status:** Snapshot — not a living specification. Re-run the checks and
> re-read the source before acting on an individual finding.
> **Snapshot:** 2026-10-20 23:30 local time, working tree at commit
> `1bc8343` plus the uncommitted `tests_data.zig` / `main.zig` changes.
> **Scope:** the whole repository — source, schema, tests, scripts, CI,
> manifests, and the documentation set. No code was changed.

**Since this snapshot:** the first-run setup, the data-layer integration
suite, the order confirmation and the payment have landed (commits
`c42af4a`, `bc33547`), and they fixed a number of the findings below -
the fresh-install gap, the missing data-layer tests, the unpayable order
and the crash on the point of sale are all closed. On 2026-10-21 the
waiter, the kitchen stations, the customer display, the settings screens
and the catalogue and people forms landed, and with them B-002 (the
sign-in now checks the employee's stored role), B-003 (the sign-in waits
for the database to confirm the salt), B-036 (two effects shared an
effect key) and B-037 (four screens bound a count the model did not
have). **The findings have not been re-verified line by line: re-read the
source before acting on one.**

This directory records what is wrong, missing, risky or worth improving.
It is deliberately separate from the [plan](../plan/README.md): the plan
says what we intend to build, the [as-built status](../plan/status.md)
says what exists, and this review says what does not hold up.

## Severity

| Level | Meaning |
|---|---|
| **P0** | A core flow cannot work, or a defect is a security / data-integrity blocker. Fix before any demo or release. |
| **P1** | Wrong behaviour, unsafe state, a broken core workflow, or a test/CI gap that hides regressions. |
| **P2** | Quality, usability, performance, accessibility or documentation issue with a workaround. |
| **P3** | Polish, cleanup, or a future improvement. |

## Finding sets

| Set | Contents | Count |
|---|---|---|
| [Bugs](bugs.md) | Behaviour that is wrong now — security, data, runtime, navigation, payment | 37 |
| [Gaps](gaps.md) | Flows and features that do not exist yet | 26 |
| [Enhancements](enhancements.md) | Improvements to correctness, UX, performance, accessibility, ops | 20 |
| [Documentation audit](docs-audit.md) | Claims that are stale, contradictory, or untested | 18 |

The [executive audit](2026-10-20-audit.md) condenses the four sets into the
blockers, the evidence, and the recommended fix order.

## How this review was produced

1. Read every source file under `apps/eatery/src/`, the manifest, the
   scripts, the CI workflow, and the test files.
2. Ran `native check apps/eatery` against the committed tree.
3. Ran `native test apps/eatery` against both the committed tree and the
   current working tree.
4. Reproduced the order write in a throwaway SQLite database built from
   the app's own migrations.
5. Re-read the documentation set and checked its claims against the
   source.

The commands and results are recorded in the [executive
audit](2026-10-20-audit.md#verified-evidence).

## Ground rules

- A finding must name a file, a symbol, or a reproducible command. Where
  the evidence is conditional (for example, an engine setting we cannot
  inspect), the finding says so.
- Source anchors are relative to `apps/eatery/`; line numbers drift, so
  the symbol name is the stable part.
- No finding here is a commitment to a particular implementation. The
  fix column describes the smallest change that removes the failure.
- The working tree is changing while development continues. Re-run the
  evidence before treating a finding as current.

## Related

- [Plan status](../plan/status.md) — the as-built matrix
- [Risks](../plan/risks.md) — likelihood and impact register
- [Open questions](../plan/open-questions.md) — what we do not know
- [Architecture](../architecture/01-system-overview.md) — how the system is meant to work
