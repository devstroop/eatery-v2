# Restaurant OS — the service app

The `service` app: the waiter's floor, menu and open orders. It runs the
**waiter** role and mounts only the screens that role may open — the
waiter's four screens, the orders and customers it works with, the
confirmation it shows after a sale, and its PIN reset.

The app is a shell over `packages/ros-core`; the shared code and the
app-model rules are described in [`apps/admin/README.md`](../admin/README.md)
and the repository root [`AGENTS.md`](../../AGENTS.md).

## Running it

```sh
cd apps/service
native dev            # debug build, run, markup hot reload
native test           # the headless suite
native check          # markup, manifest, schema
native build          # ReleaseFast binary at zig-out/bin/ros-service
```

## What is app-specific

| File | Owns |
|---|---|
| `app.json` | the manifest: id `com.devstroop.ros.service` |
| `build.zig` | the build, with the `app` option set to `service` |
| `src/main.zig` | the window and the `UiApp` construction |
| `src/app.native` | the shell and the waiter's content gates |
| `src/app_sources.zig` | the import closure |
| `src/screens/` | **copies** of the screens this app mounts |
| `src/schema/` | **a copy** of the schema |
| `src/tests.zig` | the split's tests: the fixed role, the partition, the rail |

## The rule this app enforces

A person whose stored role is not `waiter` cannot sign in here, even
with the right PIN. The binary runs one role; the person's row and the
binary have to agree. `update` refuses the pick and sets the error line.
