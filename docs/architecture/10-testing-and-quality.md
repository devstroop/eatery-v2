# Testing and quality

> **Status:** Partial — 12 headless tests; no CI; no automation smoke; no
> database integration tests.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/tests.zig`, `main.zig` (`test` block), `PORT-PLAN.md` §3.8.

## Philosophy

The architecture exists partly to make testing cheap:

- `update` is pure, so a test dispatches a message and asserts on the
  model;
- effects have a fake executor, so a test can observe requests without a
  database or a clock;
- markup is built from a model, so a test can assert that a landmark
  appears in the tree;
- the database has an in-memory migrated mode, so repository tests need no
  file.

A rule that lives only in a comment is a rule that breaks. The tests in
`src/tests.zig` are written as rules, not as coverage for its own sake.

## Current tests (12)

| # | Test | What it pins |
|---|---|---|
| 1 | The role picker is the first screen and lists the four roles | Initial model and first render |
| 2 | Picking a role that needs a sign-in lands on the PIN screen | Session gate |
| 3 | Picking a kiosk role signs the device in and opens its board | Kiosk path |
| 4 | A role cannot open a screen it may not use | RBAC guard |
| 5 | The permission matrix is total | Lock-out guarantees |
| 6 | Going back returns to the previous screen | Stack |
| 7 | The cart adds, counts and totals in minor units | Cart arithmetic |
| 8 | Money stays integer | No float money |
| 9 | A PIN is hashed, never stored | Salt and hashing |
| 10 | The page decoder reads the engine's dialect | Wire format |
| 11 | The model reports its own numbers instead of storing them | Derived values |
| 12 | The layout survives a resize | Markup build + layout at 1280×800 |

How they run:

```
native test apps/eatery --yes
```

The test block in `main.zig` imports `tests.zig`. Markup tests resolve the
same import closure as the runtime, then build and finalize a tree, so a
broken template fails a unit test with a line/column diagnostic.

The fake effects channel is `Effects.init(allocator)` with
`fx.executor = .fake`. It records requests; it does not answer them. A test
that needs a DB result must construct one by hand (as the page decoder test
does) or bind an in-memory store.

## What is not tested

| Area | Risk |
|---|---|
| Repository SQL against a real migrated database | A typo is caught only at runtime |
| Write atomicity (order + lines) | No test inserts then reads back |
| Login success path | Only hashing is tested; the SQL match is not |
| `config_loaded` salt creation | Untested; has a known source defect |
| Salt provisional race | Untested; see `plan/status.md` |
| Order ID collisions | Untested; the scheme is provisional |
| Decoders for categories/tables/employees/customers/orders/lines | Only the generic page reader is tested |
| Every screen template | Five of seven templates have no render test |
| Node budget | No assertion on `widget_nodes` |
| Error arms (`db_failed`, failed loads) | Copy and state are untested |
| Timer tick | Untested |
| Theme switch | Untested at the token level |
| Accessibility names | Left to SDK validation |
| Window resize below minimum | Untested |
| Sidecars | No code, no tests |

## Test layers (target)

| Layer | Tool | Scope | Status |
|---|---|---|---|
| Pure update | `native test` | Model transitions, RBAC, cart, status machine | Partial |
| Markup build | `native test` | Every template builds for its model fixture and contains its landmark | Partial |
| Page decoder | `native test` | Every decoder against a hand-built page | Partial |
| Relational integration | `native test` + `openMemoryMigrated` | Migrate, insert fixtures, run repo SQL, assert rows | Planned |
| Business calculations | `native test` | Tax, discount, rounding, split payment, against v1 tests as oracle | Planned |
| Live automation | `native automate` | Role picker → login → sale → KDS advance, node budget, non-blank GPU | Planned |
| Interop | External harness | Flutter app and native app converge on sync | Planned |

### Relational test recipe

```zig
var db = try native_sdk.relational_store.Database.openMemoryMigrated(
    testing.allocator,
    migrations,
);
defer db.deinit();

var fx = Effects.init(testing.allocator);
fx.executor = .fake;
fx.bindRelationalStore(db.binding());

// seed, then drive fx.dbExec / fx.dbQuery exactly as the app does
```

This is how `saveOrder` should be proven: execute, then query `orders` and
`order_line` and assert both are present, then force a failure and assert
neither is.

### Automation smoke

The showcase CI runs a live app headlessly:

```
native build -Dautomation=true
# run under xvfb
native automate assert 'gpu_nonblank=true'
native automate screenshot <view>
native automate assert 'widget_nodes=<n>/1024'
```

Target flow: role picker → admin login (seeded PIN) → POS → add item →
place order → orders list → KDS advance. This is the fastest way to catch a
shell gate that points at the wrong ordinal.

## CI

There is no CI. `.github/workflows/` is empty.

The target workflow (adapted from the showcase):

1. Install Zig 0.16.0 and Node 24.
2. Build the Native SDK CLI (or cache it).
3. `native check apps/eatery`.
4. `native test apps/eatery --yes`.
5. `native build apps/eatery -Dautomation=true`.
6. Run the automation smoke under a virtual display.
7. Upload screenshots and the trace on failure.

Pinning matters: Zig 0.17 cannot parse the SDK, and Node 22 fails the
relational toolchain. A CI runner that "looks fine" will fail at step 1.

## Quality gates before a release

| Gate | Required |
|---|---|
| `native check` clean | Yes |
| `native test` green | Yes |
| Every `Screen` either rendered or explicitly unavailable | Yes |
| Node budget asserted for POS and orders | Yes |
| Order write/read-back test | Yes |
| Migration test on a copy of a real database | Yes |
| Receipt print on target hardware | Yes, if printing ships |
| Two-device sync convergence | Yes, if sync ships |
| Keyboard-only pass on POS and login | Yes |
| Contrast audit, light and dark | Yes |
| Crash-free 30-minute service run | Yes |

## Known testing hazards

1. **Markup tests are brittle to copy changes.** They find literal text
   ("Eatery", "Sign in"). Changing display copy breaks tests; that is
   usually the right trade, but keep landmarks stable.
2. **Fake effects do not answer.** A test that expects a follow-up message
   must synthesize the result.
3. **The model is large.** Tests allocate it on the stack in some places;
   `UiApp.create` exists because that is risky in production.
4. **Line numbers in docs drift.** Anchor on symbols in tests and docs.
5. **No test covers the screen-index contract.** The most likely
   regression in this codebase is a new screen inserted in the middle of
   the enum, which silently remaps every gate in `app.native`. Add a test
   that asserts the ordinal of every rendered screen, or generate the
   gates.
