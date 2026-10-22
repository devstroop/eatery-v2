# Restaurant OS — the kiosk app

The `kiosk` app: the kitchen board and the customer display on one
device. It boots as the **kitchen board**, and the picker offers the two
board modes — the choice is the device's, and nobody types a PIN into a
board.

The app is a shell over `packages/ros-core`; the shared code and the
app-model rules are described in [`apps/admin/README.md`](../admin/README.md)
and the repository root [`AGENTS.md`](../../AGENTS.md).

## Running it

```sh
cd apps/kiosk
native dev            # debug build, run, markup hot reload
native test           # the headless suite
native check          # markup, manifest, schema
native build          # ReleaseFast binary at zig-out/bin/ros-kiosk
```

## What is app-specific

| File | Owns |
|---|---|
| `app.json` | the manifest: id `com.devstroop.ros.kiosk` |
| `build.zig` | the build, with the `app` option set to `kiosk` |
| `src/main.zig` | the window and the `UiApp` construction |
| `src/app.native` | the shell and the two board gates |
| `src/app_sources.zig` | the import closure |
| `src/screens/` | **copies** of the screens this app mounts |
| `src/schema/` | **a copy** of the schema |
| `src/tests.zig` | the split's tests: the boards, the picker, the partition |

## What it deliberately cannot do

Nothing that changes money. The kiosk mounts the boards and the order
detail a ticket opens; `rbac.allows` refuses every other screen, and
`src/tests.zig` walks the whole enum to prove it.
