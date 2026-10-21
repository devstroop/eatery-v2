# Architecture decision records

An ADR records a decision that is expensive to reverse. It states the
context, the decision, the consequences and the alternatives, so a future
contributor can tell the difference between "we chose this" and "we did not
think about it".

This project follows a lightweight MADR-style format.

## Index

| ID | Title | Status |
|---|---|---|
| [0001](0001-native-sdk-zig-rewrite.md) | Rewrite on the Native SDK in Zig | Accepted |
| [0002](0002-pure-model-msg-update.md) | Pure Model / Msg / update core | Accepted |
| [0003](0003-no-router-screen-enum-and-stack.md) | No router; screen enum and stack | Accepted |
| [0004](0004-four-roles-one-binary.md) | Four roles in one binary | Accepted |
| [0005](0005-engine-owned-sqlite-strict-schema.md) | Engine-owned SQLite and a STRICT schema | Accepted |
| [0006](0006-integer-money-epoch-ms.md) | Integer minor-unit money and epoch-ms time | Accepted |
| [0007](0007-pin-hashing.md) | Salted SHA-256 PIN hashing | Provisional |
| [0008](0008-sidecar-for-printing.md) | A sidecar owns printing and BLE | Proposed |
| [0009](0009-oplog-sync-with-transport-sidecar.md) | Op-log sync with the transport in a sidecar | Proposed |
| [0010](0010-markup-only-no-custom-paint.md) | Markup only; no custom paint or Lottie | Accepted |
| [0011](0011-desktop-first-defer-mobile.md) | Desktop first; defer mobile | Proposed |
| [0012](0012-csv-first-interchange.md) | CSV first for import/export | Proposed |
| [0013](0013-clock-based-order-ids.md) | Clock-based order IDs | Superseded by ADR-0014 |
| [0014](0014-order-identity.md) | The order identity: a sequence, an id and a request key | Accepted |

## Drafts

`drafts/` holds six early, unreferenced drafts of the first decisions.
They are kept for reference only; the numbered records below are the
canonical set. See [`drafts/README.md`](drafts/README.md).

## Status meanings

| Status | Meaning |
|---|---|
| **Proposed** | Written down, not agreed. Code may not exist. Needs an owner. |
| **Accepted** | Agreed and reflected in the code or the target design. |
| **Provisional** | In use, but known to be insufficient. Expected to be superseded. |
| **Superseded** | Replaced by a later ADR; keep for history. |
| **Rejected** | Considered and not chosen. |

## Template

```markdown
# ADR-NNNN: Title

> **Status:** Proposed | Accepted | Provisional | Superseded by ADR-XXXX
> **Date:** YYYY-MM-DD
> **Deciders:** names or roles
> **Related:** links

## Context

What forces are at play? What makes this a decision rather than an
obvious step? Include the constraint and the evidence.

## Decision

What we will do. Be specific enough that a reviewer can disagree.

## Consequences

### Positive

### Negative

### Neutral / follow-ups

## Alternatives considered

| Alternative | Why not |
|---|---|

## Evidence

Code, tests, spikes or external constraints that back the decision.
```

## Rules

1. Accepted ADRs are immutable except for status and superseding links.
2. A new fact goes in a new ADR, not an edit to history.
3. An ADR that has no code must say so.
4. Link the owning architecture page from the ADR, and the ADR from the
   architecture page.
5. If a decision is reversed, write the superseding ADR first.
