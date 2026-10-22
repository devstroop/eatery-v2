# ADR-0010: Markup only; no custom paint or Lottie

> **Status:** Accepted (consequences accepted; floor plan reimplementation
> is still Planned)
> **Date:** 2026-10-20
> **Deciders:** Devstroop maintainers, product/design
> **Related:** [`architecture/06`](../architecture/06-ui-markup-and-theming.md),
> [`architecture/11`](../architecture/11-capability-gaps.md)

## Context

v1 used `CustomPainter` for the floor plan and the pie chart, `fl_chart`
for line/bar/pie, and Lottie for a celebration animation.

The Native SDK's view is declarative markup over a fixed element catalog.
There is no paint hook. Charts support line/area/bar, not pie. Animation
is limited to tweened transitions. Colours are semantic tokens, not
arbitrary hex values.

## Decision

**Express the UI entirely in markup. Do not port custom painting,
Lottie or pie charts.**

- The floor plan becomes a `grid` of table cards with drag-release
  geometry (`on-drag`), not a painted canvas.
- The pie chart becomes a stacked/grouped bar, or is dropped.
- The celebration animation is dropped; elapsed-time and status text
  remain.
- Brand colour is expressed through the semantic token set plus an accent
  override. The 11 menu-tile colours are not reproduced.
- Any "computed" visual is a model method or one of the expression
  functions.

## Consequences

### Positive

- One rendering model; no paint escape hatch to maintain.
- UI is testable: build the tree, assert landmarks.
- Accessibility is real text, not painted glyphs.
- No animation runtime dependency.
- The 1024-node budget forces disciplined layouts.

### Negative

- The floor plan loses freeform positioning and custom decoration; it is
  a grid with drag.
- Pie charts are not available; the report design changes.
- The celebration moment is lost.
- Brand fidelity is reduced; tile colours collapse into tokens.
- Complex diagrams (org chart, seat map, receipt preview) need creative
  markup.

### Follow-ups

- Design the floor-plan template: grid coordinates, drag, resize, zones.
- Decide the report chart set (line, bar, stacked bar).
- Get design sign-off on the reduced palette.
- Add a component library so visual patterns are consistent.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Custom paint via a platform extension | Not in the SDK; high cost and platform-specific. |
| Render the floor plan as an image | Static, not editable, not accessible. |
| Use an embedded web view for charts | Adds a browser engine and a second UI stack. |
| Keep Lottie by porting a runtime | Large dependency for one animation. |
| Arbitrary palette through a custom theme pack | The SDK resolves semantic tokens; a pack is not app-supplied. |

## Evidence

- `src/app.native`, `src/screens/*.native`: markup only.
- `src/core/theme.zig`: semantic tokens, no hex in markup.
- `PORT-PLAN.md` §7 Gap C, §3.3 grammar rules.
- SDK element catalog: `chart` series kinds exclude pie.
