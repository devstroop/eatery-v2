# UI markup and theming

> **Status:** Implemented subset — 7 templates render (5 in the shell, 2 as
> session gates). Theming is implemented (light/dark).
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/app.native`, `src/screens/*.native`, `src/app_sources.zig`,
> `src/core/theme.zig`, `src/core/model.zig`.

## The view is markup

There is no widget tree built in Zig. `app.native` declares the shell, and
each screen is a `<template>` in `src/screens/`. The runtime parses the
markup, resolves bindings against the model, and builds widgets. The app
never calls a paint API.

Consequences:

- A screen is data plus a template, not a class.
- Bindings are zero-argument reads. Reactivity is "the model changed, so
  rebuild".
- There is no place to put imperative UI code, which is the point.

## File layout and imports

```
app.native                 shell + top-level gates
screens/screen-*.native    one <template> per screen
app_sources.zig            embedded import closure
```

`app.native` imports each screen:

```xml
<import src="screens/screen-role-picker.native"/>
...
```

Every imported file must also be listed in `app_sources.zig`. The compiler
enforces this, and hot reload re-resolves the same paths from disk. A
missing entry fails loudly at the import site, which is intentional: a
screen that is not compiled in is a screen that does not exist.

`app.native` is embedded with `@embedFile` and watched at
`src/app.native` for hot reload.

## Shell structure

```
column
├── row            title bar: company, role badge, theme toggle
├── if has_error     error banner: message + Dismiss
├── if !role_chosen   → screen-role-picker
├── if role_chosen && !signed_in → screen-login
├── if signed_in
│   └── split      rail (200px) | content
│       ├── column  nav rail: sections
│       └── column  content: <if screen_index == N> gates
└── status-bar     screen title | company | operator
```

Only the active screen is mounted. That is what keeps the 1024-node
budget reachable.

The content gates are hard-coded ordinals:

| Index | Screen | Template |
|---|---|---|
| 8 | `admin_dashboard` | `screen-dashboard` |
| 10 | `pos` | `screen-pos` |
| 13 | `orders` | `screen-orders` |
| 17 | `dining_tables` | `screen-tables` |
| 41 | `kds_board` | `screen-kitchen` |

The other 36 screens render an empty pane. See
[03-navigation-and-rbac](03-navigation-and-rbac.md).

## Markup vocabulary used

The app uses a small, conservative subset:

| Purpose | Elements |
|---|---|
| Layout | `column`, `row`, `split`, `scroll`, `grid`, `spacer` |
| Surfaces | `card` (stacking), `separator` |
| Text | `text` (with `size`, `foreground`, `wrap`, `grow`) |
| Controls | `button`, `toggle-button`, `search-field`, `text-field` |
| Data display | `badge`, `for` |
| Structure | `if`, `template`, `use`, `import` |
| Chrome | `status-bar` |

Not yet used: `table`, `timeline`, `chart`, `stepper`, `dialog`, `sheet`,
`select`, `virtualized`, `drag`, `tooltip`, `avatar`, `image`.

## Grammar rules that shape the code

These come from the SDK and are non-negotiable:

1. **Expressions are a closed language.** Binding paths, numbers, quoted
   strings, `+ - * /`, comparisons, `and/or/not`, `++`, and 17 functions
   (`fixed`, `thousands`, `percent`, `date`, `time`, `datetime`, `upper`,
   `lower`, `trim`, `min`, `max`, `abs`, `round`, `floor`, `ceil`,
   `plural`, `pad`).
2. **No method calls in markup.** A row cannot call `row.label()`; labels
   are fields resolved at decode time.
3. **No negation operator, no ternary, no else-if.** Every conditional is
   an `<if>`; the inverse is a second `<if>`.
4. **Colours and radii are token names only.** No hex literals.
   `border-color`, not `border`.
5. **One size register per row.** Mixing `size="sm"` with default
   controls produces two heights.
6. **Stacking containers reject `gap`.** `card`, `stack`, `panel`,
   `dialog`, `sheet`, `drawer`, `alert`, `bubble`, `resizable`. Wrap
   children in a `column`.
7. **`split` takes exactly two children.** `gap` is divider thickness.
8. **Interactive controls need an accessible name.** Text, `text=` or
   `label=` is required.
9. **`<else>` must directly follow `<if>`.**
10. **Widget budget per view:** 1024 retained nodes, 64 KiB text, 512
    context-menu items, 16 floating surfaces, 2048 commands / 8192 glyphs
    per frame.

## Binding patterns

### Derived values

```xml
<text size="display">{open_order_count}</text>
```

`open_order_count` is a method on `Model`, not a stored count.

### Filtered rows

```xml
<for each="visible_products" key="id" as="product">
  <card on-press="add_to_cart:{product.id}">
    <text wrap="true">{product.name}</text>
    <text size="sm">{currency_symbol}{fixed(product.price_minor / 100, 2)}</text>
  </card>
</for>
```

`visible_products(arena)` applies the category and search filters. The
markup never filters.

### Dispatch with a payload

```xml
<button on-press="pick_role:{role.id}">Open</button>
<button on-press="advance_order:{ticket.id}">Next</button>
```

A payload must be a binding. A literal must become its own message
(`set_category_all`).

### Conditional sections

```xml
<if test="{cart_is_empty}"><text>The cart is empty.</text></if>
<scroll grow="1"><!-- list --></scroll>
```

There is no else-if; each branch is its own `<if>`.

## Theming

`src/core/theme.zig` supplies `canvas.DesignTokens` on every rebuild:

```zig
pub fn tokens(model: *const Model) canvas.DesignTokens {
    return if (model.theme_dark) dark() else light();
}
```

`toggle_theme` flips `theme_dark`, so the theme is model state.

### Brand palette

| Name | Value | Use |
|---|---|---|
| Primary | `#30A8CF` | Accent, focus ring |
| Primary dark | `#227A96` | Reserved |
| Secondary | `#4AC3A1` | Brand, success family |
| Accent | `#705EE0` | Reserved |
| Success | `#2F9E69` | Success text/status |
| Warning | `#C87A14` | Warning |
| Danger | `#D94335` | Destructive |
| Info | `#2F5EC2` | Info |

### Semantic tokens in use

| Token | Light | Dark |
|---|---|---|
| `background` | `#F7F8FA` | `#0F1318` |
| `surface` | `#FFFFFF` | `#171C23` |
| `surface_subtle` | `#F1F3F6` | `#1F262E` |
| `surface_pressed` | `#E6EAEF` | `#272F38` |
| `text` | `#151A21` | `#ECEFF3` |
| `text_muted` | `#646E7A` | `#9AA5B1` |
| `border` | `#E1E5EA` | `#2A333D` |
| `accent` | `#30A8CF` | `#4CC2EA` |
| `destructive` | `#D94335` | `#E85D51` |
| `success` | `#2F9E69` | `#45B886` |
| `warning` | `#C87A14` | `#E09A3C` |
| `info` | `#2F5EC2` | `#5B8CE0` |

### Type, spacing, radius

| Scale | Values |
|---|---|
| Type | body 14, label 13, title 20, heading 28, display 48, button 14 |
| Spacing | xs 4, sm 8, md 12, lg 16, xl 24 |
| Radius | none 0, sm 4, md 8, lg 12, xl 16 |

The v1 app had 14 type rungs, 11 menu-tile colours and an 8-step spacing
scale. v2 keeps 6/5/5. The lost colour range is a deliberate trade-off;
see [ADR-0010](../decisions/0010-markup-only-no-custom-paint.md) and the
open question about brand fidelity.

### Theme limitations

- There is no way to supply an arbitrary 40-colour palette. The runtime
  resolves semantic tokens and an accent override.
- Markup cannot select a colour per row, so table status is shown as a
  badge label, not a status-coloured tile.
- The design system is defined twice (light and dark) rather than derived;
  adding a token means editing both.

## Layout patterns

| Pattern | Where | Notes |
|---|---|---|
| Rail + content | Shell | `split` with a model-owned fraction (0.18 default) |
| Menu + cart | POS | Inner `split` with `menu_split` (0.62 default) |
| Card grid | POS, tables, KDS | `grid columns="3"` or `"4"` inside `scroll` |
| Summary strip | Dashboard | Four `card`s in a `row`, each `grow="1"` |
| Empty state | Orders, KDS, tables, cart | `<if count == 0>` + muted text |

There is no responsive variant yet. The shell assumes a desktop window
(1280×800 default, 960×600 minimum in `app.json`).

## Accessibility

- Shell and canvas carry accessibility labels ("Eatery").
- Icon-only buttons must carry `label=`; the SDK rejects unnamed
  interactive controls.
- Text is real text, so the OS can read it; there is no canvas-drawn copy.
- Focus order follows declaration order. The POS search field is not
  autofocused; login's PIN field is.
- Colour is not the only status signal: badges carry a text label.
- Target: a keyboard-only pass, focus-visible checks, and a contrast audit
  of both palettes. Not done.

## Adding a screen: checklist

1. Add the `Screen` variant at the **end** of the enum in
   `core/navigation.zig`; add a title and a nav section.
2. Add it to `rbac.allows` for the roles that may open it, and decide
   `rbac.section_screen` if it is a rail landing.
3. Write `screens/screen-<name>.native` with exactly one
   `<template name="screen-<name>">`.
4. Import it in `app.native` and add the file to `app_sources.zig`.
5. Add an `<if test="{screen_index == N}">` gate in the shell, using the
   enum's ordinal.
6. Add model fields and derived methods; add `Msg` variants for every
   interaction. Keep private fields in `view_unbound`.
7. Keep the template under 1024 nodes; use `scroll`/`grid` and plan for
   virtualization on long lists.
8. Add a test that builds the tree and finds a landmark text.
9. Update `docs/architecture/03`, `06` and `plan/status.md`.

## Current templates

| Template | Screen | State |
|---|---|---|
| `screen-role-picker` | 0 | Implemented |
| `screen-login` | 1 | Implemented |
| `screen-dashboard` | 8 | Implemented |
| `screen-pos` | 10 | Implemented |
| `screen-orders` | 13 | Implemented |
| `screen-tables` | 17 | Implemented |
| `screen-kitchen` | 41 | Implemented |

No reusable components exist in `src/components/`, although the directory
is present. The target is ~24 component templates (button/card/empty
state/order card/product card/timeline/adaptive shell/etc.); today the
patterns are repeated inline.

## Known weak points

1. **Index-gated shell.** Hard-coded ordinals in markup are brittle; a test
   should assert them, or the shell should switch on a model method.
2. **No virtualization.** A 200-order list renders every row; the node
   budget will fail before the data does.
3. **No component library.** Duplication across templates is already
   visible (empty states, headers, rows).
4. **No responsive mode.** Window resize changes the split fraction only.
5. **No motion.** There are no transitions or tweened values.
6. **No dark-mode contrast audit.**
