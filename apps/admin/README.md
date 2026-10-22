# Restaurant OS — the back office app

The `admin` app: point of sale, orders, the floor, the catalogue, the
people and the settings. It runs the **admin** role and mounts every
screen that role may open.

The three apps share one package. This directory is a shell:

```
packages/ros-core/   the model, the messages, `update`, the domain, the
                     data layer and the protocol
apps/admin/          the manifest, the fixed role, the markup it mounts
                     and its schema
```

The app-model rules (markup never mutates, derived values are methods,
`view_unbound` lists what the view must not see) are in the repository
root [`AGENTS.md`](../../AGENTS.md). The split itself is
[`docs/architecture/12`](../../docs/architecture/12-three-apps-and-ipc.md).

## Running it

```sh
cd apps/admin
native dev            # debug build, run, markup hot reload
native test           # the headless suite
native check          # markup, manifest, schema
native build          # ReleaseFast binary at zig-out/bin/ros-admin
```

`scripts/verify-all.sh` at the repository root runs check and test for
every app; `scripts/build.sh` builds them all.

## What is app-specific

| File | Owns |
|---|---|
| `app.json` | the manifest: id `com.devstroop.ros.admin`, permissions, capabilities, the window |
| `build.zig` | the app's build: the SDK, `packages/ros-core`, and the build option that says which binary this is |
| `build.zig.zon` | the app package: the SDK by path and `ros-core` |
| `src/main.zig` | the window, the `UiApp` construction, the installation salt and device token |
| `src/app.native` | the shell and the content-pane gates for this role's screens |
| `src/app_sources.zig` | the embedded markup import closure |
| `src/screens/` | the screen templates |
| `src/schema/` | the migrations and the lock file |
| `src/tests.zig` | the authored headless tests |
| `src/tests_data.zig` | the database-backed tests |

Everything else is `@import("ros_core")`.

## The other two apps

`apps/service` (the waiter role) and `apps/kiosk` (the kitchen and
customer boards) are shells over the same package. They carry **copies**
of the screens they mount and of the whole schema, because the SDK
resolves both from `<app>/src` with no override. `scripts/check-copies.sh`
compares every copy against this app and fails the build when one drifts.

`apps/admin` is the source for those copies: edit the screen here, then
copy it across.
