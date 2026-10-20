# App model, messages and effects

> **Status:** Implemented.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/core/model.zig`, `src/core/msg.zig`, `src/core/update.zig`,
> `src/core/bump.zig`, `src/main.zig`, `src/data/page.zig`.

## The contract in one paragraph

The app is a `Model` (what is true), a `Msg` (what happened) and `update`
(what is true now). `update` is pure with respect to the outside world: it
mutates the model and may request an effect, but it never performs I/O.
Effects deliver their results back as messages. Markup binds model values
and dispatches messages; it never mutates.

This shape is what makes the app headlessly testable: build a model,
dispatch a message the way the runtime would, assert on the model and the
rebuilt tree.

## Model

`src/core/model.zig` owns all state. The struct is large (fixed buffers),
so `main.zig` constructs it with `UiApp.create` on the heap rather than
passing it by value.

### State groups

| Group | Fields | Notes |
|---|---|---|
| Session | `role`, `role_chosen`, `signed_in`, `employee_id`, `employee_name` | The PIN hash never lives in the model |
| Navigation | `screen_index`, `nav_section`, `stack`, `rail_split`, `menu_split`, `now_ms` | Screen index is an enum ordinal; the enum is append-only |
| Company | `company_id`, `company_name`, `currency_code`, `currency_symbol`, `tax_inclusive` | One company per database |
| Datasets | seven bump buffers and seven row slices | Products, tables, employees, orders, customers, categories, order lines |
| POS filters | `selected_category`, `search` | 0 means "all"; search is a `TextBuffer(64)` |
| Sign-in | `pin`, `pin_salt_buf`, `salt_is_provisional`, `login_hash`, `operator_buf`, `login_error` | Salt is provisional at boot until the database confirms it |
| Cart | `cart_buf`, `cart[50]`, `cart_len`, `cart_order_type` | Session state, never persisted until placed |
| Runtime | `db_ready`, `busy`, `error_text`, `theme_dark` | `error_text` is shown by the shell's dismissable error banner |

### Visibility rules

1. **Everything the view can see is declared inside the `Model` body.**
   A `pub fn` at file scope next to the struct is invisible to the
   binding resolver. This is the most common porting trap.
2. **Derived values are methods, never stored fields.** Examples:
   `product_count`, `open_order_count`, `cart_total_minor`,
   `visible_products(arena)`, `cart_lines(arena)`, `kitchen_tickets(arena)`.
3. **Anything the view must not see is listed in `view_unbound`.**
   Current entries: `stack`, `employee_id`, `db_ready`, `busy`,
   `company_id`, `pending_screen`, `theme_dark`. The view reads errors
   through the derived `has_error` and `error_message` methods.
4. **Rows are plain data.** The markup cannot call a method on a row, so
   labels (`status_label`, `type_label`) are resolved at decode time and
   stored in the row.

### Fixed-capacity storage

The model must be default-constructible (`UiApp.create` builds `.{}` and
the model-contract checker does the same), so it cannot own a heap
allocator. Rows live in `bump.Bump(capacity)` byte buffers:

| Buffer | Capacity | Holds |
|---|---|---|
| `products_buffer` | 96 KiB | Menu rows and their names |
| `tables_buffer` | 24 KiB | Floor rows |
| `employees_buffer` | 16 KiB | Staff rows |
| `orders_buffer` | 48 KiB | Order rows |
| `customers_buffer` | 32 KiB | Customer rows |
| `categories_buffer` | 16 KiB | Category rows |
| `order_lines_buffer` | 48 KiB | Order line rows |
| `cart_buf` | 8 KiB | Cart line names + order number |
| `operator_buf` | 1 KiB | Signed-in operator name |

Rules:

- `reset()` before replacing a dataset; otherwise old rows leak into the
  new set.
- A full bump drops the row (`alloc` returns `null`), it never grows.
- `dupe()` copies text; decoding must copy because page bytes are drain
  scratch.
- `allocSlice(T, n)` is how a decoded row set lands in the model.

Capacity is a product limit, not an implementation detail. A menu that
does not fit is a menu the app cannot show; see
[`plan/open-questions.md`](../plan/open-questions.md).

## Messages

`Msg` is a `union(enum)` in `src/core/msg.zig`. Three families:

| Family | Examples | Payload |
|---|---|---|
| Runtime-delivered | `pin_edit`, `search_edit`, `tick`, `*_loaded`, `db_failed` | Fixed by the platform: text edit event, timer event, DB result |
| App-intent | `pick_role`, `open_section`, `add_to_cart`, `place_order`, `advance_order`, `toggle_theme` | Small scalars so markup can dispatch `on-press="add_to_cart:{product.id}"` |
| Internal result | `login_checked`, `order_placed`, `order_status_saved`, `config_saved` | `EffectDbResult`; never bound by markup, listed in `Msg.view_unbound` |

Design notes:

- A payload must be a binding, not an arbitrary expression. That is why
  `set_category_all` exists: the "all" button cannot pass a literal `0`.
- Message names are the app's vocabulary. A new capability usually starts
  with a new `Msg`, not a new function call in markup.
- `Msg.view_unbound` is a lint surface: it keeps a runtime-only message
  from being accidentally dispatched by a template.

## Boot and effects

`boot` runs once:

```zig
pub fn boot(model: *Model, fx: *Effects) void {
    model.now_ms = fx.wallMs();
    fx.startTimer(.{
        .key = clock_timer_key,          // 100
        .interval_ms = 1000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick),
    });
    repos.loadConfig(fx);                // first read: the PIN salt
}
```

Rules for effects:

- **Every effect has a caller-chosen `u64` key.** Keys live in
  `repos.zig`: reads 1–10, writes 20–22, timer 100. A query and a write
  must not collide.
- **Effects never write the model.** The result arrives as a message;
  only `update` mutates.
- **Effect payloads are drain scratch.** A result is valid for the
  duration of the update that receives it. Copy anything you keep.
- **Effects are fakeable.** `Effects.init(allocator)` plus
  `fx.executor = .fake` records requests instead of touching the OS,
  which is how the tests observe `place_order` without a database.

Effect families currently used: `dbQuery`, `dbExec`, `startTimer`,
`wallMs`. The SDK also offers subprocess, fetch, files, key/value,
credentials, clipboard, notifications, audio, images, windows and
`hostRequest`; the target design uses `spawn` for sidecars, `fetch` for
cloud backup, `credentials*` for secrets and `playAudio` for the KDS
chime.

## Update

`update` is a single `switch` over `Msg`. Every arm answers one question:
"the world said this, so what is true now?"

Notable arms:

| Arm | Behaviour |
|---|---|
| `pick_role` | Set role; kiosk roles sign in immediately and load data; PIN roles go to login |
| `submit_login` | Hash PIN with salt, query `employee` by `pin_hash`, wait for `login_checked` |
| `login_checked` | On a row: set operator, sign in, go home, load data. On no row: "Wrong PIN", clear PIN |
| `open_screen` / `open_section` | Route through `go()`, which checks `rbac.allows` and pushes the stack |
| `go_back` | Pop; stay put at a root |
| `place_order` | Build an order from the cart and `dbExec` it |
| `order_placed` | Clear cart, go to confirmation, reload orders |
| `advance_order` | Compute next status and write status + history atomically |
| `*_loaded` | Decode a page into the model's bump buffers |
| `config_loaded` | Adopt the stored PIN salt, or create one on a fresh install |
| `db_failed` | Map outcome to operator copy |
| `tick` | Refresh `now_ms` |

### Navigation guard

`go` is the only navigation primitive:

```zig
fn go(model: *Model, screen: Screen) void {
    if (!rbac.allows(model.role, screen)) {
        model.error_text = "This role cannot open that screen";
        return;
    }
    if (!model.stack.push(screen)) return;   // depth 32
    model.screen_index = screen.index();
    model.nav_section = sectionIndex(screen);
}
```

This is the replacement for a router `redirect:` guard. It is pure,
total, and directly unit-tested.

### Error handling

- The shell renders `error_text` in a dismissable banner (the `has_error`
  and `error_message` methods are the bound surface).
- Read failures set `error_text` and leave the previous data in place.
- Write failures set `error_text`, clear `busy`, and do not pretend the
  write happened.
- Outcomes map to copy: `busy` → "The database is busy - try again",
  `io_failed` → "Storage error", `corrupt` → "The database is damaged".
- There is no retry policy and no offline queue. That is a target
  behaviour, not current behaviour.

## Lifecycle summary

```
main.zig
  makeSalt (provisional)
  UiApp.create
  initialModel
  boot ──▶ timer + loadConfig
                 │
                 ▼
          config_loaded ──▶ adopt/create salt
                 │
                 ▼
          role picker ──▶ login (PIN) ──▶ home ──▶ loadAll
                     └──▶ kiosk sign-in ──▶ board ──▶ loadAll
```

`loadAll` currently loads company, categories, products, tables,
employees, orders and order lines. It does **not** load customers, even
though a repository exists. This is a status fact, not a design choice;
see [`plan/status.md`](../plan/status.md).

## Known weak points

These are documented rather than silently fixed, because the fix is a
decision:

1. **The provisional salt can still be used before the database confirms
   it.** `main.zig` sets `pin_salt_len` immediately and `submit_login`
   checks only that the salt is non-empty, not `salt_is_provisional`.
   `createSalt` and `config_loaded` clear the flag, but a fast sign-in can
   race the first config read.
2. **Order IDs are the wall clock in milliseconds and order numbers are
   seconds.** Two orders in the same second collide on the `UNIQUE`
   order number. See [ADR-0013](../decisions/0013-clock-based-order-ids.md).
3. **`busy` is set on write but most read paths do not set it**, so the
   UI cannot distinguish "loading" from "empty" for reads.
4. **`now_ms` is the only clock.** There is no monotonic clock and no
   handling for clock jumps backwards.
5. **`view_unbound` still lists `pending_screen`, which is not a field.**
   The entry is harmless but stale; remove it or add the field.

## Tests that pin this contract

- role picker is the first screen;
- kiosk role signs in, PIN role lands on login;
- a role cannot open a screen it may not use;
- the permission matrix is total;
- back returns to the previous screen;
- cart arithmetic and integer money;
- model reports derived numbers instead of storing them;
- layout survives a resize;
- page decoder handles NULL, INTEGER and TEXT;
- PIN hashing is deterministic and salt-dependent.

See [10-testing-and-quality](10-testing-and-quality.md).
