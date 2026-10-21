# Draft ADRs

These six files are early, unreferenced drafts written in parallel with the
canonical decision records one directory up. They are kept for their longer
context and code excerpts, but they are **not** the authoritative records
and nothing links to them.

Use the indexed set in [`../README.md`](../README.md).

| Draft | Canonical record |
|---|---|
| `0001-native-sdk-and-zig.md` | [0001](../0001-native-sdk-zig-rewrite.md) Run the rewrite on the Native SDK in Zig |
| `0002-tea-model-and-markup.md` | [0002](../0002-pure-model-msg-update.md) Pure model/update, plus [0010](../0010-markup-only-no-custom-paint.md) markup-only view |
| `0003-engine-owned-sqlite.md` | [0005](../0005-engine-owned-sqlite-strict-schema.md) Engine-owned SQLite and STRICT schema |
| `0004-integer-money-and-time.md` | [0006](../0006-integer-money-epoch-ms.md) Integer minor units and epoch ms |
| `0005-role-scoped-single-binary.md` | [0004](../0004-four-roles-one-binary.md) Four roles in one binary |
| `0006-sync-as-operation-log.md` | [0009](../0009-oplog-sync-with-transport-sidecar.md) Op-log sync with a sidecar transport |

If one of these drafts contains a detail the canonical record lacks, move
that detail into the canonical record (or a new ADR) rather than reviving
the draft.
