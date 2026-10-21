# Review and audit

> **Status:** An archive and a pointer. The findings that were recorded
> here are issues now, and the audit that produced them is a dated
> snapshot in [`archive/`](archive/).

## What happened to the findings

The 2026-10-20 audit read the whole repository and produced 101
findings: 37 bugs, 26 gaps, 20 enhancements and 18 documentation
claims. Every one of them that was still true became an issue, with a
plan, the files it touches and a done-when, labelled by severity, by
kind and by the track that owns the fix.

- **The tracker:** [devstroop/eatery-v2/issues](https://github.com/devstroop/eatery-v2/issues)
- **The tracks:** [`../plan/track.md`](../plan/track.md) - which branch
  each label lands on, and in what order
- **The snapshot:** [`archive/2026-10-20-audit.md`](archive/2026-10-20-audit.md)
  and the four finding sets beside it

The findings that were already fixed when the audit was written - the
order write, the company copy, the nullable foreign keys, and the
sign-in and effect-key work that landed with this restructure - are not
issues. The history records them, and the archive says which ones they
were.

## The archive

| File | Contents |
|---|---|
| [2026-10-20-audit](archive/2026-10-20-audit.md) | The executive audit: the blockers, the evidence and the recommended fix order |
| [bugs](archive/bugs.md) | Behaviour that was wrong (37) |
| [gaps](archive/gaps.md) | Flows and features that did not exist (26) |
| [enhancements](archive/enhancements.md) | Correctness, UX, performance, accessibility (20) |
| [docs-audit](archive/docs-audit.md) | Claims that were stale, contradictory or untested (18) |

The archive is a snapshot, not a specification. It describes the tree as
it stood on 2026-10-20, and it is kept because it is the record of how
the project found out what it did not know. Re-read the source before
acting on anything in it.

## Why the findings left the documents

A finding that lives in a document is a finding nobody is looking at.
An issue has an owner, a label, a milestone and a state, and it is
closed by a commit that says `Closes #<n>`. The documents keep the
plan and the state; the tracker keeps the work.
