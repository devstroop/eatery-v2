# Windowing and desktop integration

> **Status:** Single window implemented; secondary windows and packaging
> Planned.
> **Last verified:** 2026-10-20, by source review.
> **Source:** `src/main.zig`, `app.json`.

## Today

The app opens one window with one GPU surface.

| Property | Value | Where |
|---|---|---|
| Window label | `main` | `main.zig`, `app.json` |
| Title | Restaurant OS | both |
| Size | 1280 × 800 | both |
| Minimum size | 960 × 600 | `app.json` only |
| Restore policy | `center_on_primary` | `app.json` only |
| View | `main-canvas`, `gpu_surface`, fill | both |
| GPU backend | Metal, BGRA8 unorm, timer present, opaque, sRGB, vsync | both |
| Renderer | Native SDK canvas (widgets, not custom paint) | `main.zig` |
| Permissions | view, command, window, dialog, filesystem, clipboard, network, notifications, credentials | both |
| Capabilities | native_views, gpu_surfaces, sqlite, filesystem, network, clipboard, notifications, credentials, open_url, menus | `app.json` |
| Navigation allow-list | `zero://app`, `zero://inline`; external links open the system browser | both |

The manifest and `main.zig` declare overlapping shell data. `main.zig` is
what the runner uses; `app.json` is what validation and packaging read.
They currently differ on minimum size and restore policy (present in the
manifest, absent in the Zig shell config). Treat the manifest as the
packaging contract and keep the two in sync.

## Target: one model, several windows

The port plan's strongest desktop idea is that the four roles can be
three windows over one model on one machine:

```
              ┌──────────────────────────────┐
              │          shared Model        │
              │  orders · tables · cart ...  │
              └───────┬──────────┬───────────┘
                      │          │
          ┌───────────▼──┐  ┌────▼──────────┐  ┌──────────────┐
          │ main (admin) │  │ KDS window    │  │ Display      │
          │ POS + admin  │  │ tickets only  │  │ customer view│
          └──────────────┘  └───────────────┘  └──────────────┘
```

Why this is better than a role switch:

- an order placed in the POS window appears on the KDS window without a
  restart, because both read the same model;
- the customer display is a different view, not a different app;
- a single machine can run a counter plus a pass-through screen.

What the SDK gives us:

- model-declared secondary windows (`windows_fn`, with presence as
  liveness);
- a per-window compiled markup tree (`window_view`);
- window verbs: `minimizeWindow`, `hideWindow`, `showWindow`, `quitApp`,
  `closeWindow`;
- `close_policy` (`.quit` / `.hide`) and a user-close message per window;
- hidden-titlebar chrome (`titlebar = .hidden_inset`, `window-drag`,
  `on_chrome`) for kiosk mode;
- one shared model across main and secondary windows.

What is missing today:

- no `windows_fn`; the app declares exactly one window;
- no role-based window policy (a KDS device still shows the role picker
  and the admin shell chrome);
- no kiosk chrome (hidden titlebar, no window controls);
- no full-screen or always-on-top policy;
- no multi-monitor placement policy.

## Window policy to decide

| Question | Options | Consequence |
|---|---|---|
| Does a KDS device open the role picker every boot? | Always / remember role in `app_config.device_role` / build-time default | Remembering is better for a wall board but needs a protected exit gesture |
| Can an admin machine open KDS and display windows? | On demand / always / never | On demand is the port plan's recommendation |
| Who owns the cart when two windows are open? | The shared model / per-window state | Shared is simpler, but a cashier and a waiter on one machine would collide |
| What does closing a secondary window do? | Hide / quit the app / ask | A display window should hide, not quit |
| Full-screen vs hidden titlebar for kiosks? | Both | Hidden titlebar needs a drag region; full-screen needs an escape |

These are open in [`plan/open-questions.md`](../plan/open-questions.md).

## Packaging target

The port plan's path is macOS first:

```
native package --target macos
  ├── app bundle from app.json
  ├── icon from assets/icon.png
  ├── signing + notarisation
  └── (later) Linux, Windows
```

Facts and gaps:

- `app.json` declares macOS, Linux and Windows.
- `assets/icon.png` exists.
- There is no `build.zig` in the app: the CLI synthesises one into
  `.native/build/`. That is fine until the app needs to link a C library,
  at which point `native eject` is required.
- Mobile targets are experimental in the SDK. Desktop-first is proposed in
  [ADR-0011](../decisions/0011-desktop-first-defer-mobile.md).
- There is no release pipeline, no versioning policy beyond `0.1.0`, and no
  update mechanism.

## Runtime environment requirements

These are build-time facts, repeated here because they break machines:

| Requirement | Value |
|---|---|
| Zig | **0.16.0**; the SDK rejects other minors. `/usr/local/bin/zig` (0.17) shadows Homebrew's 0.16 |
| Node | **≥ 24** for the relational toolchain |
| SDK | `v0.11.0` |
| SDK TS deps | `npm ci --include=dev` in `packages/core` |
| CLI | `native check`, `native test`, `native build`, `native dev`, `native automate` |

The CLI is not installed in this workspace, so these commands were not
re-run while writing these docs. See the appendix in
[`PORT-PLAN.md`](../../../PORT-PLAN.md) for the verified invocation log.

## CI target

The showcase convention is a per-app job:

1. `native check apps/ros`
2. `native test apps/ros --yes`
3. `native build -Dautomation=true`
4. run under a virtual display
5. assert `gpu_nonblank=true`
6. screenshot
7. optionally assert `widget_nodes=N/1024`

The repository has `.github/workflows/` but **no workflow files**. CI is
planned, not present.

## Desktop known weak points

1. The window cannot be resized below 960×600 in packaging, but the Zig
   shell does not declare the minimum, so `native dev` may allow a smaller
   window that the layout does not support.
2. No window state persistence (position, size, maximized).
3. No "remember this device's role" boot path; every launch starts at the
   role picker.
4. No kiosk escape gesture. A wall-mounted board with a hidden titlebar
   would need a deliberate way out.
5. The GPU surface is fixed to Metal; a Linux/Windows backend is the SDK's
   concern, not the app's, but it is untested here.
