# UI: markup, components and tokens

> **Status:** Implemented. Nine templates exist: six are mounted in the
> shell and two are session gates. `src/components/` is **empty** - the
> component library is a plan. Theming is implemented: light and dark palettes, re-resolved on
> every rebuild.
> **Verification:** source review only. The Native SDK CLI is not
> installed in this workspace, so the behaviours below were read from
> the SDK reference and the app's own source, not exercised against a
> running build.
> **Source of truth:** `src/app.native`, `src/screens/*.native`,
> `src/app_sources.zig`, `src/core/theme.zig`, `src/core/model.zig`,
> `src/core/msg.zig`, plus the Native SDK's
> [native-ui authoring guide](../../../native-zig-showcase/docs/sdk/native-ui/SKILL.md).
> **Related:** [ADR-0010](../decisions/0010-markup-only-no-custom-paint.md),
> [06-ui-markup-and-theming](06-ui-markup-and-theming.md).

## The view is markup

There is no widget tree built in Zig. `src/app.native` declares the
shell, each screen is a `<template>` in `src/screens/`, and the runtime
parses the markup, resolves the bindings against the model, and builds
the widgets. The app never calls a paint API.

Two rules follow, and they are the whole contract:

- **The markup never changes state.** It binds model values and
  dispatches messages.
- **Everything the view can see is a field or a method on `Model`.** A
  file-scope function next to the struct is invisible to the markup:

```zig
// src/core/model.zig
//   1. **Everything the view can see is a field or a method on this
//      struct.** A file-scope function next to the struct is invisible
//      to the markup - the binding resolver only sees declarations
//      INSIDE the struct body.
```

## The markup rules that actually bite

These are the rules that change how a line of markup is written. They
come from the SDK's closed grammar, and each one has a shape in this
repo that satisfies it.

### Expressions are a closed grammar

An expression is pure and total - spreadsheet power, not a programming
language. The whole vocabulary:

| Category | Vocabulary |
|---|---|
| Operands | binding paths (`{c.title}`), numbers, single-quoted strings (`'text'`), `true` / `false` |
| Arithmetic | `+ - * /` (numbers only; `/` always produces a float) |
| Comparison | `== != < <= > >=` (ordering is numeric only; comparisons do not chain) |
| Boolean | `and` / `or` / `not` (booleans only - write `{count > 0}`, not `{count}`) |
| Concatenation | `++` (joins any values as display text) |
| Functions | 17, closed: `fixed`, `thousands`, `percent`, `date`, `time`, `datetime`, `upper`, `lower`, `trim`, `min`, `max`, `abs`, `round`, `floor`, `ceil`, `plural`, `pad` |

Bounds: 256 bytes, 64 terms, 16 nesting levels per expression. Where
expressions are allowed: text interpolation, attribute values, `if`
tests, template args at use sites.

Three consequences bite in practice:

- **No else-if chain.** There is no `<else-if>` tag. Nest an `<if>` /
  `<else>` inside the `<else>` body, or write a second `<if>`.
- **No negation operator on `<if>`.** There is no `!{x}` sugar and no
  ternary. The house style is an explicit boolean predicate method on
  the model, one per arm:

```zig
/// True when the last sign-in attempt failed.
pub fn login_failed(model: *const Model) bool {
    return model.login_error.len > 0;
}

/// Whether the cart holds anything at all.
pub fn cart_is_empty(model: *const Model) bool {
    return model.cart_len == 0;
}
```

- **No method calls, and bindings are zero-argument.** A binding path
  resolves a field, a zero-argument model method, or a field of a `for`
  variable. A value that needs an argument becomes a named model method
  on the `Model` struct, not a markup expression. Rows the markup
  iterates are plain data with fields, because the markup cannot call a
  method on a row:

```zig
// src/core/navigation.zig
/// One row of the navigation rail. The markup binds `id` and `label`
/// directly - it cannot call a method on a row, so a row is plain data.
pub const NavItem = struct {
    id: usize,
    label: []const u8,
};
```

One more constraint on comparisons: an arena-computed binding (a method
that takes the build arena) is rejected as a comparison operand. Compare
the source fields, or bind a `pub fn ... bool`.

### Colours and radii are token names only

Colour and radius attributes take a token **name**, and the SDK states
the rule plainly: *literals only, no bindings, no raw colors*.

| Attribute | Accepted values |
|---|---|
| `background`, `foreground`, `accent`, `accent-foreground`, `border-color`, `focus-ring` | `background`, `surface`, `surface_subtle`, `surface_pressed`, `text`, `text_muted`, `syntax_plain`, `syntax_comment`, `syntax_keyword`, `syntax_literal`, `syntax_function`, `syntax_property`, `syntax_constant`, `border`, `accent`, `accent_text`, `destructive`, `destructive_text`, `success`, `success_text`, `warning`, `warning_text`, `info`, `info_text`, `focus_ring`, `shadow`, `scrim`, `disabled` |
| `radius` | `sm`, `md`, `lg`, `xl`, `none` |

Two details that are easy to get wrong:

- The attribute is **`border-color`**, not a bare `border` - that name
  is reserved for a future width shorthand.
- A **bound** token is not accepted. `foreground="{order.tone}"` is
  rejected; dynamic styling stays in Zig through `ElementOptions.style`.

That last one shapes the floor screen, and the reason is written into
the template:

```xml
<!-- src/screens/screen-tables.native -->
<!-- The floor. A grid of tables, each one showing who is sitting at
     it. The status is a badge, not a colour: the SDK's colour
     attributes take token names, and a status-coloured tile would need
     a dynamic token the markup cannot resolve. -->
```

The domain even has a token-name helper that the markup cannot reach:

```zig
// src/domain/models.zig
/// The badge tone for the status, expressed in theme tokens.
pub fn tone(self: OrderStatus) []const u8 {
    return switch (self) {
        .pending => "warning",
        .preparing => "info",
        .ready => "success",
        .served => "accent",
        .completed => "text_muted",
        .voided => "destructive",
    };
}
```

`status_label` is the field the markup binds; `tone()` is a Zig-side
value.

### Message payloads must be bindings

On an `on-*` attribute the value is `tag` or `tag:{payload}`. The tag
is an arm of the `Msg` union; the payload is a **binding path** - never
a literal, never an expression.

```xml
<button on-press="pick_role:{role.id}">Open</button>
<card padding="8" on-press="add_to_cart:{product.id}">
<button size="sm" variant="secondary" on-press="advance_order:{order.id}">Advance</button>
```

A literal payload has no spelling, so a constant needs its own message.
That is why the POS has two category messages:

```zig
// src/core/msg.zig
/// Filter by category.
set_category: i64,
/// Clear the category filter. A payload must be a BINDING, so the
/// "all categories" button cannot carry a literal zero.
set_category_all,
```

and the markup uses the literal-free form for the "All" chip:

```xml
<toggle-button selected="{selected_category == 0}" on-press="set_category_all">All</toggle-button>
```

`set_category:0` would be the natural spelling and it is not a legal
markup value.

### One size register per row

Every control class shares a control height at a given register -
default 36, `sm` 31.5, `lg` 40.5, before density. A toolbar or filter
row reads as one height exactly when every control in it carries the
same `size`; mixing `size="sm"` buttons with a default field renders
two heights in one row. Hand-sized pressable panels (`height="30"`)
never land on the scale.

The current templates comply, because no row mixes two control
registers. The POS filter row is all `toggle-button` at the default
register:

```xml
<row gap="4" cross="center">
  <toggle-button selected="{selected_category == 0}" on-press="set_category_all">All</toggle-button>
  <for each="categories" key="id" as="category">
    <toggle-button selected="{category.id == selected_category}" on-press="set_category:{category.id}">{category.name}</toggle-button>
  </for>
</row>
```

and the cart row mixes a text leaf with one icon button, which is one
control, not two registers.

One related detail worth knowing before a control is added: a
`toggle-button`'s activation dispatches `on-toggle`, and its `on-press`
never fires. The SDK's own chip pattern is:

```html
<toggle-group gap="2" label="Theme">
  <for each="theme_prefs" as="p">
    <toggle-button size="sm" selected="{p == theme_pref}" on-toggle="set_theme:{p}">{p}</toggle-button>
  </for>
</toggle-group>
```

The POS binds `on-press` on both of its `toggle-button` rows
(`set_category`, `set_category_all`, `set_order_type`), and `Msg` has no
`on-toggle` arm. Per the SDK those two filters therefore have no
working handler. The fix is to bind `on-toggle` on the `toggle-button`,
or to use `button` with `selected=`, which is always model-driven and
dispatches `on-press`. This is the first item on the checklist below and
it should be confirmed against a running build.

### Stacking containers reject `gap`

`stack`, `panel`, `card`, `alert`, `bubble`, `dialog`, `drawer`,
`sheet` and `resizable` layer their children, so `gap` on them is a
validation error, not a silent no-op. The children go in a `column` or a
`row` inside:

```xml
<!-- src/screens/screen-pos.native -->
<card padding="8" on-press="add_to_cart:{product.id}">
  <column gap="2">
    <text wrap="true">{product.name}</text>
    <text size="sm" foreground="text_muted">{currency_symbol}{fixed(product.price_minor / 100, 2)}</text>
  </column>
</card>
```

The `gap="2"` is on the inner `column`, which is a flow container. The
same shape appears in the dashboard's stat tiles and in the kitchen
tickets.

`split` is a third case: it takes exactly two element children, and
`gap` on it sets the divider band thickness rather than spacing
children.

### Accessible names are enforced

An interactive control with no text content, no `text=` and no `label=`
is a validation error. Icon-only controls need `label`; text-entry
controls need `label` or `placeholder`.

The three controls in the app that would otherwise be unnamed:

```xml
<search-field
  text="{search_text}"
  placeholder="Search the menu"
  label="Search the menu"
  on-input="search_edit"
  grow="1"
/>
```

```xml
<text-field
  text="{pin_text}"
  placeholder="PIN"
  label="PIN"
  on-input="pin_edit"
  on-submit="submit_login"
  autofocus="true"
/>
```

```xml
<button size="icon" icon="x" label="Remove one" on-press="remove_from_cart:{line.product_id}"/>
```

`label` **replaces** the element's text content as the announced name,
so a `label` that duplicates the visible text is a warning, and
`label=""` marks an image decorative.

### Widget budgets per view

Every view has fixed per-view capacities. Overflow is loud: the build
fails with `error.WidgetNodeLimitReached`,
`error.WidgetAnchoredSurfaceLimitReached`,
`error.WidgetContextMenuLimitReached` or `error.WidgetLayoutListFull`,
and production logs a teaching diagnostic naming the budget.

| Budget | Limit | Constant |
|---|---|---|
| Retained widget nodes | **1024** | `max_canvas_widget_nodes_per_view` |
| Retained widget text | 64 KiB | - |
| Anchored floating surfaces | **16** | `max_canvas_widget_anchored_per_view` |
| Chart series | **64** | `max_canvas_widget_chart_*` |
| Chart points | 16384 | `max_canvas_widget_chart_*` |
| Context-menu items | 512 (separators count) | `max_canvas_widget_context_menu_items_per_view` |
| Per-frame commands | 2048 | - |
| Per-frame glyphs | 8192 | - |
| Per-frame text | 32 KiB | - |
| Per-frame path elements | 2048 (icons and charts share) | - |

Node count scales with what is **mounted**, not what is visible, so
every unbounded collection has to be bounded. The shell's `<if>` gates
are the first line of defence: only the active screen contributes
nodes. The second is the data: the POS filters in the model and
mounts a grid of the visible slice, the order list mounts one card per
order, and the kitchen board mounts one card per ticket.

`native automate snapshot` reports the live numbers on every canvas
surface line:

```
widget_nodes=N/1024 widget_semantics=N/1024 context_menu_items=N/512
```

A `virtualized` container on `scroll` / `list` / `grid` / `table` (with
`virtual-item-extent` for fixed extents) lays out only the visible
window plus overscan. It bounds **nodes**, not source data - the
builder still walks every item. The windowed virtual list
(`virtual-window` + `virtual-list`) is builder-only: the closed grammar
has no channel for a `for` binding to receive the runtime's range
request, so markup keeps bounded `virtualized` lists plus
`on-reach-end` on `scroll`.

## How a screen template is written

`src/screens/screen-pos.native` is the most complete screen. It is
worth reading end to end; the annotated tour below is the shape every
screen should have.

### The template wrapper

```xml
<!-- src/screens/screen-pos.native -->
<template name="screen-pos">
  <split grow="1" value="{menu_split}" on-resize="menu_resized">
    ...
  </split>
</template>
```

A template takes a kebab-case `name`, optional `args`, and **exactly
one element child**. The body is built in place of the `<use>`, so
structural widget ids hash through the parent chain at the expansion
site - two uses at different sites get different ids, and the same site
is stable across rebuilds. A template in this file cannot be used
recursively: a use may only reference templates defined earlier in the
same file.

### The model-owned split

```xml
<split grow="1" value="{menu_split}" on-resize="menu_resized">
```

`menu_split` is a model field:

```zig
// src/core/model.zig
/// The width of the menu pane in the POS, as a fraction.
menu_split: f32 = 0.62,
```

and `on-resize` writes it back:

```zig
.menu_resized => |fraction| model.menu_split = fraction,
```

The runtime applies each drag as an optimistic echo, dispatches
`on-resize` with the applied and clamped fraction, and the model stores
it and echoes it through `value` on the next rebuild. The view never
writes the fraction; it declares where the divider is.

### A derived binding, not a stored field

```xml
<for each="visible_products" key="id" as="product">
```

`visible_products` is a method that takes the build arena and filters
the menu in the model:

```zig
/// The menu after the category and search filters. A view binds
/// this with `<for each="visible_products">`.
pub fn visible_products(model: *const Model, arena: std.mem.Allocator) []const domain.Product {
    const needle = std.mem.trim(u8, model.search.text(), " ");
    var out: std.ArrayList(domain.Product) = .empty;
    defer out.deinit(arena);
    for (model.products) |product| {
        if (model.selected_category != 0 and product.category_id != model.selected_category) continue;
        if (needle.len > 0 and !containsIgnoreCase(product.name, needle)) continue;
        out.append(arena, product) catch break;
    }
    return out.items;
}
```

The arena lives for exactly one view build, so the derived list cannot
go stale - the failure mode of a cached filter maintained by hand in
`update`.

`key="id"` names a field of the row type, and it is what gives each
row a stable identity across rebuilds.

### The text field mirror

```xml
<search-field
  text="{search_text}"
  placeholder="Search the menu"
  label="Search the menu"
  on-input="search_edit"
  grow="1"
/>
```

`text` binds a derived method, never the `TextBuffer` itself:

```zig
/// The search text, trimmed - the markup binds this, never the
/// `TextBuffer` itself.
pub fn search_text(model: *const Model) []const u8 {
    return std.mem.trim(u8, model.search.text(), " ");
}
```

`on-input` is special: it names an arm carrying the runtime's text edit
event, and the model applies it:

```zig
.search_edit => |event| model.search.apply(event),
```

### Money in the view

```xml
<text size="sm" foreground="text_muted">{currency_symbol}{fixed(product.price_minor / 100, 2)}</text>
```

The model holds `price_minor: i64` - an integer count of the smallest
currency unit. The division by 100 happens in the expression, `/`
always produces a float, and `fixed(x, 2)` renders exact decimals with
half-away rounding. The rounding is presentation only: nothing in the
model or the database is ever a float amount.

### A conditional block

```xml
<if test="{cart_is_empty}">
  <text foreground="text_muted">The cart is empty.</text>
</if>
```

`cart_is_empty` is a boolean method. The inverse case is a second
`<if>` with its own predicate, never an `else`:

```xml
<!-- src/screens/screen-dashboard.native -->
<if test="{order_count == 0}">
  <column background="surface" radius="md" padding="16">
    <text foreground="text_muted">No orders yet. The kitchen board fills up as soon as the first sale lands.</text>
  </column>
</if>
<if test="{order_count > 0}">
  ...
</if>
```

`{order_count == 0}` is a comparison on a model method, which is
allowed: only *arena-computed* bindings are rejected as comparison
operands.

### The scroll shape

```xml
<scroll grow="1">
  <column gap="4">
    <for each="cart_lines" key="product_id" as="line">
      <row gap="8" cross="center">
        <text grow="1">{line.name}</text>
        <text>{line.qty}</text>
        <text>{currency_symbol}{fixed(line.total_minor / 100, 2)}</text>
        <button size="icon" icon="x" label="Remove one" on-press="remove_from_cart:{line.product_id}"/>
      </row>
    </for>
  </column>
</scroll>
```

A `scroll` wraps its multiple children in a `column`. `gap` on the
`column` is fine; `gap` on the `scroll` is not.

### A note on `screen-*` files

Each file in `src/screens/` is a **component file**: templates only, no
view root. The shell is the only view root, and the screen templates are
mounted by `<use>` inside the shell's `<if>` gates.

## How templates are imported

An import has two halves, and both are required.

**Half one - the markup.** The import lines sit at the top of the
importing file, before its templates:

```xml
<!-- src/app.native -->
<import src="screens/screen-role-picker.native"/>
<import src="screens/screen-login.native"/>
<import src="screens/screen-dashboard.native"/>
<import src="screens/screen-pos.native"/>
<import src="screens/screen-orders.native"/>
<import src="screens/screen-tables.native"/>
<import src="screens/screen-kitchen.native"/>
```

**Half two - the embedded source set.** Every file the markup imports
must also be listed in `src/app_sources.zig`:

```zig
// src/app_sources.zig
//! The embedded markup import closure.
//!
//! Every file the markup imports must also be listed here: the runtime
//! engine's first build reads this set, and hot reload re-resolves the
//! same paths from disk. A missing entry fails loudly at the import
//! site - which is the point: a screen that is not compiled in is a
//! screen that does not exist.

pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "screens/screen-role-picker.native", .source = @embedFile("screens/screen-role-picker.native") },
    .{ .path = "screens/screen-login.native", .source = @embedFile("screens/screen-login.native") },
    .{ .path = "screens/screen-dashboard.native", .source = @embedFile("screens/screen-dashboard.native") },
    .{ .path = "screens/screen-pos.native", .source = @embedFile("screens/screen-pos.native") },
    .{ .path = "screens/screen-orders.native", .source = @embedFile("screens/screen-orders.native") },
    .{ .path = "screens/screen-tables.native", .source = @embedFile("screens/screen-tables.native") },
    .{ .path = "screens/screen-kitchen.native", .source = @embedFile("screens/screen-kitchen.native") },
};
```

The set is wired into the app and into the tests:

```zig
// src/main.zig
pub const app_markup = @embedFile("app.native");
pub const app_sources = @import("app_sources.zig").sources;
```

```zig
// src/main.zig
.markup = .{
    .source = app_markup,
    .sources = &app_sources,
    .watch_path = "src/app.native",
    .io = init.io,
},
```

**A missing entry fails loudly at the import site.** That is deliberate:
a screen that is not compiled in is a screen that does not exist. The
half-one/half-two pairing is the mechanism - the `<import>` line names
a path, and the source set is what the engine can actually read, so a
path in one and not the other cannot resolve.

The test harness resolves the same closure the runtime does, so the
tests see exactly what the app sees:

```zig
// src/tests.zig
fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    const sources = main.app_sources;
    var loader = canvas.ui_markup.SourceSetLoader{ .set = &sources };
    const root_source = main.app_markup;

    var diagnostic: canvas.ui_markup.MarkupErrorInfo = .{};
    const document = canvas.ui_markup.resolveImports(arena, "app.native", root_source, loader.loader(), &diagnostic) catch |err| {
        std.debug.print("import resolution failed: {s} at {d}:{d}\n", .{ @errorName(err), diagnostic.line, diagnostic.column });
        return err;
    };
    ...
```

Rules that go with the import:

- Paths are relative to the importing file, and always under the root
  view file's directory. Absolute paths and escapes are errors.
- An imported file defines **templates only**. A view root inside one is
  an error, and a component file checks standalone.
- Importing splices the imported templates (transitively) **before**
  yours, in import order - so define-before-use stays the only ordering
  rule, and duplicate template names are an error naming both sites.
- A use inside a template body may only reference templates defined
  earlier in the file.

For a release build the same markup can be compiled at comptime, which
turns markup and binding mistakes into compile errors with line and
column:

```zig
const dev = @import("builtin").mode == .Debug;
const App = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev });
const CompiledView = canvas.CompiledMarkupView(Model, Msg, @embedFile("app.native"));
// options:
// .view = CompiledView.build,
// .markup = if (dev) .{ .source = ..., .watch_path = "src/app.native", .io = init.io } else null,
```

Restaurant OS runs the runtime engine today, in every build mode.

## The component library

`src/components/` exists and is empty. The nine templates repeat their
patterns inline: the empty state appears in four screens, the screen
header in five, the row-with-badge in three. The table below is the
plan - each row names a component Restaurant OS needs and the platform element it
maps to.

| Component | Platform element | Needed for |
|---|---|---|
| App shell | `split` + `column` | the rail-and-content frame in `app.native` |
| Nav rail | `list` + `list-item`; `tree` with `role="treeitem"` for drill-down | the role's sections, and the settings tree |
| Screen header | `row` + `text` + `badge` | dashboard, orders, tables, kitchen |
| Stat tile | `card` + `column` + `text size="display"` | the dashboard's four numbers |
| Empty state | `card` or `column` + `text foreground="text_muted"` | orders, tables, kitchen, cart |
| Product tile | `card` + `text` | the POS menu grid |
| Cart line row | `row` + `text` + `button size="icon"` | the POS cart |
| Order row | `card` + `row` + `badge` + `text` | the order list |
| Kitchen ticket | `card` + `badge` + `text` + `button` | the kitchen board |
| Floor table tile | `card` + `text` + `badge` | the dining tables grid |
| Category filter strip | `toggle-group` + `toggle-button` (exclusive, model-driven) | the POS category filter |
| Order type switch | `segmented-control`, or `toggle-group` + `toggle-button` | the POS order type |
| Action button | `button variant="default\|primary\|secondary\|outline\|ghost\|destructive"` | every screen |
| Icon action | `button size="icon" icon="..." label="..."` | remove a cart line, close a row |
| Money readout | `text` + `fixed()` over integer minor units | prices, totals, order lines |
| Amount field | `text-field` with a `label` | payments, discounts, tax slabs |
| Search | `search-field` with a `label` | the POS menu, customer search |
| Payment keypad | `grid` of `button` | the payments screen |
| Status timeline | `timeline` + `timeline-item` | an order's lifecycle |
| Report chart | `chart` + `series` | the reports screen |
| Confirmation modal | `dialog` (title via the `text` attribute) | void an order, close a shift |
| Detail side panel | `drawer` or `sheet` | order detail, table detail |
| Notice banner | `alert` or `bubble` | the `error_text` banner that does not exist yet |
| Settings row | `row` + `text` + `toggle` / `switch` / `select` | the settings tree |
| Option dropdown | `select` + `dropdown-menu` in a `stack`, with `anchor` | a picker with a list of options |
| Loading placeholder | `skeleton` / `spinner` | the shell before the first query returns |
| Long list | `list` / `grid` with `virtualized` + `virtual-item-extent` | orders, customers, products |
| Operator chip | `avatar` | the signed-in operator |
| Status badge | `badge` | every status in the app |
| Read-only report body | `code` (monospace, no chrome) | an X report, a SQL dump |
| Help copy | `markdown` | the help screen |
| Inline emphasis | `text` > `span` | mixed-weight one-paragraph copy |
| Form group | `input-group` (`textarea` + `input-group-actions`) | the notes composer |

Notes on the mapping:

- **`toggle-group` + `toggle-button`** is the SDK's exclusive chip
  pattern and it carries a `label` for accessibility. The POS filter row
  is the candidate for it.
- **`select` is a trigger, not a picker.** There is no `options=`
  attribute; the options are a `dropdown-menu` of `menu-item`s floated
  with `anchor`, beside the trigger inside a `stack`, and the open state
  is a model boolean.
- **`button` with `selected=`** is always model-driven and dispatches
  `on-press`; a `toggle-button` with `selected=` is model-driven and
  dispatches `on-toggle`. A component that needs a pressed state must
  pick the right one.
- **A `card` is a stacking container.** Every component that wants
  internal spacing puts a `column` inside it.
- **`virtualized`** bounds nodes, not data. A list that can grow
  without bound needs a `virtualized` container or a bounded window in
  the model.

The library is not needed to start: a component file is a `.native`
file of templates, imported the same way the screens are, and it adds
one more entry to `app_sources.zig` per file.

## The design tokens

`src/core/theme.zig` is the whole design system, in one file a
designer can read and a developer can diff. The platform's token
references resolve against the app's **live** tokens on every rebuild
(`finalizeWithTokens`), so a themed app re-resolves them when the theme
changes - dark mode flips `surface` automatically, with no rebuild
trigger and no per-element work.

### The brand palette

```zig
// src/core/theme.zig
/// The Restaurant OS brand palette.
const brand = struct {
    // The light semantic fills are the darkest step of the v1 hues that
    // clears WCAG AA with white text, and as text on the light
    // background and surface. The test in tests.zig is the guard.
    const primary = rgb(0x17, 0x6B, 0x84); // v1 cyan blue, one step down
    const primary_dark = rgb(0x12, 0x56, 0x6A);
    const secondary = rgb(0x4A, 0xC3, 0xA1); // v1 secondary - the teal green
    const accent = rgb(0x70, 0x5E, 0xE0); // v1 accent - the purple
    const success = rgb(0x1B, 0x6E, 0x47);
    const warning = rgb(0x87, 0x52, 0x0C);
    const danger = rgb(0xB3, 0x2D, 0x22);
    const info = rgb(0x2F, 0x5E, 0xC2);
};
```

| Brand role | Light value | Dark value | Token it drives |
|---|---|---|---|
| Primary (cyan blue) | `#176B84` | `#4CC2EA` | `accent`, `focus_ring` |
| Secondary (teal green) | `#4AC3A1` | - | reserved |
| Accent (purple) | `#705EE0` | - | reserved |
| Success | `#1B6E47` | `#45B886` | `success` |
| Warning | `#87520C` | `#E09A3C` | `warning` |
| Danger | `#B32D22` | `#E85D51` | `destructive` |
| Info | `#2F5EC2` | `#5B8CE0` | `info` |

The light semantic fills are deliberately darker than v1's brand
values: each clears WCAG AA for normal text with its paired `_text`
token, and as text on `background` and `surface`. The test
`every text pair in the light and dark palettes clears WCAG AA` asserts
those combinations for both palettes, so a palette edit that breaks one
fails the suite.

### The two palettes

`light()` and `dark()` are two complete `canvas.DesignTokens` values.
The dark palette is the same brand one step down in luminance.

| Token | Light | Dark |
|---|---|---|
| `background` | `#F7F8FA` | `#0F1318` |
| `surface` | `#FFFFFF` | `#171C23` |
| `surface_subtle` | `#F1F3F6` | `#1F262E` |
| `surface_pressed` | `#E6EAEF` | `#272F38` |
| `text` | `#151A21` | `#ECEFF3` |
| `text_muted` | `#646E7A` | `#9AA5B1` |
| `border` | `#E1E5EA` | `#2A333D` |
| `accent` | `#176B84` | `#4CC2EA` |
| `accent_text` | `#FFFFFF` | `#081014` |
| `destructive` | `#B32D22` | `#E85D51` |
| `destructive_text` | `#FFFFFF` | `#120808` |
| `success` | `#1B6E47` | `#45B886` |
| `success_text` | `#FFFFFF` | `#06140E` |
| `warning` | `#87520C` | `#E09A3C` |
| `warning_text` | `#FFFFFF` | `#140E04` |
| `info` | `#2F5EC2` | `#5B8CE0` |
| `info_text` | `#FFFFFF` | `#060E18` |
| `focus_ring` | `#176B84` | `#4CC2EA` |

The palettes set 18 of the token names the platform's colour list
includes. The `syntax_*` roles (the code-block palette), `shadow`,
`scrim` and `disabled` are not set, so a screen that renders a code
block, a shadowed surface or a disabled control should set them
explicitly rather than assume a value.

### The type, spacing and radius scales

Both palettes carry the same three scales:

| Scale | Values | Token names |
|---|---|---|
| Type | body 14, label 13, title 20, heading 28, display 48, button 14 | `body_size`, `label_size`, `title_size`, `heading_size`, `display_size`, `button_size` |
| Spacing | xs 4, sm 8, md 12, lg 16, xl 24 | `spacing.xs` .. `spacing.xl` |
| Radius | none 0, sm 4, md 8, lg 12, xl 16 | `radius.none` .. `radius.xl` |

The `text` element's `size` attribute selects among `default`, `sm`,
`lg`, `heading` and `display`; the SDK pins `heading` and `display` to
the named token steps `heading_size` (28) and `display_size` (48), and
the `sm` and `lg` rungs ride the label and title steps of the same
scale. `heading` and `display` are typography rungs for **text** -
putting them on a control is a teaching error.

`radius` takes `sm`, `md`, `lg`, `xl` or `none` and it is a token name
like a colour:

```xml
<column background="surface" radius="md" padding="16">
```

The spacing scale is not exposed as a token in markup - padding and gap
are literal numbers - so the scale is a convention the templates
follow, not something the platform enforces.

### Light and dark are model state

The theme is a model field, and the runtime asks for the tokens on every
rebuild:

```zig
// src/core/theme.zig
/// The tokens for the current model state. The runtime asks for these
/// on every rebuild, so flipping the theme is a model change and
/// nothing else.
pub fn tokens(model: *const Model) canvas.DesignTokens {
    return if (model.theme_dark) dark() else light();
}
```

```zig
// src/core/model.zig
/// Dark palette instead of the house light one.
theme_dark: bool = false,
```

```zig
// src/core/update.zig
.toggle_theme => model.theme_dark = !model.theme_dark,
```

```zig
// src/main.zig
.tokens_fn = theme.tokens,
```

`tokens_fn` is the model-owned path: the runtime calls it on every
rebuild and re-resolves every colour and radius reference against the
value it returns. A `toggle_theme` message flips the field, `update`
returns, the rebuild happens, and the new palette is in place - there is
no separate "apply theme" step and no per-element work.

The button that does it is in the shell's title bar:

```xml
<button size="sm" variant="ghost" on-press="toggle_theme">Theme</button>
```

`theme_dark` is in `Model.view_unbound`: the view binds the Theme
button's message, not the flag.

## Traps

| Mistake | Symptom | Fix |
|---|---|---|
| A message payload that is a literal (`on-press="set_category:0"`) | Markup validation error: a payload is a path, not a value | Give the constant its own message (`set_category_all`), or bind a path that carries the value |
| A file-scope `&.{ ... }` literal built inside a function and returned | The view reads a dead stack frame on a later frame - a crash that looks like a platform bug | Keep every table the markup binds at file scope with comptime-known contents, as `rbac.zig` does |
| An `<else>` that does not directly follow an `<if>` | Parse error at the import site | The `<else>` must immediately follow its `<if>`; there is no else-if chain, so nest an `<if>` / `<else>` inside the `<else>` body |
| `gap` on a stacking container (`card`, `panel`, `stack`, `dialog`, ...) | Validation error, not a silent no-op | Put the children in a `column` or `row` inside the stacking container |
| A hex colour, a raw colour, or a bound token (`foreground="{order.tone}"`) | Unknown token name or a rejected binding | Colours and radii are token names, as literals. Dynamic styling goes into Zig through `ElementOptions.style` |
| `border` used as a colour attribute | Validation error | The attribute is `border-color`; a bare `border` is reserved |
| Calling a method on a row (`{section.label()}`) | The path does not resolve; the view fails at build time | Rows are plain data with fields; a value that needs an argument becomes a named model method |
| A helper declared at file scope next to the `Model` struct | "each does not name an iterable" at run time, or a binding that never resolves | Declare it **inside** the `pub const Model = struct { ... }` body |
| Mixing `size="sm"` with default controls in one row | Two control heights in one toolbar | One size register per row |
| An icon-only button with no `label` | Accessible-name validation error | Add `label="..."`; `label` replaces the text content as the announced name |
| `size="heading"` on a control | Teaching error naming text as the home of the typography rungs | `heading` and `display` are `text` rungs only |
| An `<import>` with no matching entry in `app_sources.zig` | Import resolution fails loudly at the import site | Keep the `<import>` line and the `canvas.ui_markup.SourceFile` entry in step |
| A view root inside an imported file | Validation error | An imported file defines templates only; the shell is the only view root |
| A `for` body that puts the `gap` on the `for` | Validation error | `gap` belongs on the `column` or `row` inside the `for` |
| Comparing an arena-computed binding | Teaching error on the comparison | Compare the source fields, or bind a `pub fn ... bool` |
| Mounting an unbounded list | `error.WidgetNodeLimitReached` at 1024 nodes, or a slow rebuild | `virtualized` + `virtual-item-extent`, or a bounded window in the model |

## Checklist

Writing a screen template:

- [ ] The file is a component file: templates only, one `<template>`
      with exactly one element child.
- [ ] Every binding is a model field, a zero-argument model method, or
      a field of a `for` variable - and the method is declared **inside**
      the `Model` struct.
- [ ] Every conditional is an `<if>` with an explicit boolean predicate
      method; there is no `else` and no else-if chain.
- [ ] Every message payload is a binding path; a constant has its own
      message.
- [ ] Colours and radii are token names, written as literals.
- [ ] Every `card`, `panel`, `stack`, `dialog`, `drawer`, `sheet`,
      `alert` and `bubble` puts its children in a `column` or a `row`.
- [ ] Every row uses one control size register.
- [ ] Every interactive control has text content, `text=` or `label=`;
      icon-only controls carry `label`.
- [ ] Every `for` names a `key` field that exists on the row type.
- [ ] The mounted node count stays well inside 1024; unbounded lists are
      `virtualized` or bounded in the model.

Wiring a screen in:

- [ ] The `<import src="screens/screen-<name>.native"/>` line is in
      `src/app.native`.
- [ ] The matching `canvas.ui_markup.SourceFile` entry with its
      `@embedFile` is in `src/app_sources.zig`.
- [ ] The shell has an `<if test="{screen_index == N}">` gate using the
      enum's ordinal.
- [ ] A test builds the tree and finds a landmark text.

Building a component:

- [ ] The component lives in `src/components/<name>.native` as a
      component file: templates only.
- [ ] The component is imported by the file that uses it, and listed in
      `src/app_sources.zig`.
- [ ] The component's inputs are template args with **literal** defaults
      only - a `{binding}` default is an error.
- [ ] The component is model-driven: it binds values and dispatches
      messages, and it holds no state of its own.

Theming:

- [ ] A new colour is added to **both** `light()` and `dark()`.
- [ ] A new colour or radius is a token name the markup can use as a
      literal.
- [ ] `tokens_fn` still returns the live palette for the model's
      `theme_dark` state, so the theme flip stays a model change.
