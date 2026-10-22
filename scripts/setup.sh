#!/usr/bin/env bash
# One-time toolchain setup for Restaurant OS.
#
#   ./scripts/setup.sh
#
# Installs what the Native SDK needs and builds the CLI:
#   * Zig 0.16.0  - the SDK is pinned to it; 0.17 does not parse the SDK
#   * Node 24+    - the relational schema generator is TypeScript
#   * the SDK CLI - cloned to ~/native-sdk and built with `zig build`
#
# Safe to re-run: every step checks before it acts.
set -u

ros_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
sdk_dir="${NATIVE_SDK_DIR:-$HOME/native-sdk}"
sdk_tag="${NATIVE_SDK_TAG:-v0.11.0}"

say() { printf '\n== %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --------------------------------------------------------------- zig

say "Zig"
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "0.16.0" ]; then
  printf 'zig 0.16.0 is on PATH\n'
elif [ -x "/opt/homebrew/opt/zig/bin/zig" ] && [ "$(/opt/homebrew/opt/zig/bin/zig version)" = "0.16.0" ]; then
  printf 'zig 0.16.0 found at /opt/homebrew/opt/zig/bin/zig\n'
  printf 'note: /usr/local/bin/zig is usually 0.17 and shadows it - scripts/env.sh puts 0.16 first\n'
else
  printf 'installing zig 0.16.0 with Homebrew...\n'
  brew install zig || die "brew install zig failed"
  if [ "$(/opt/homebrew/opt/zig/bin/zig version 2>/dev/null)" != "0.16.0" ]; then
    warn "Homebrew's zig is not 0.16.0; install it manually if the SDK refuses to build"
  fi
fi

# -------------------------------------------------------------- node

say "Node"
node_major=0
if command -v node >/dev/null 2>&1; then
  node_major="$(node --version | sed -e 's/^v//' -e 's/\..*//')"
fi
if [ "$node_major" -ge 24 ] 2>/dev/null; then
  printf 'node %s is on PATH\n' "$(node --version)"
else
  printf 'installing node 24 with Homebrew...\n'
  brew install node@24 || warn "brew install node@24 failed; the relational schema generator needs node 24+"
  if [ -x "/opt/homebrew/opt/node@24/bin/node" ]; then
    printf 'node 24 is at /opt/homebrew/opt/node@24/bin/node\n'
  fi
fi

# --------------------------------------------------------- the SDK CLI

say "Native SDK ($sdk_tag)"
if [ -d "$sdk_dir/.git" ]; then
  printf 'already cloned at %s\n' "$sdk_dir"
else
  git clone --depth 1 --branch "$sdk_tag" https://github.com/vercel-labs/native.git "$sdk_dir" \
    || die "could not clone the Native SDK"
fi

say "SDK TypeScript toolchain (the schema generator needs it)"
if [ ! -d "$sdk_dir/packages/core/node_modules" ]; then
  ( cd "$sdk_dir/packages/core" && npm ci --include=dev ) \
    || die "npm ci failed in packages/core - without it the SQLite schema generator cannot run"
else
  printf 'already installed\n'
fi

say "Building the native CLI"
(
  cd "$sdk_dir" || exit 1
  # The CLI rejects any zig that is not the pinned minor version, and
  # 0.17 fails to parse the SDK at all.
  PATH="/opt/homebrew/opt/zig/bin:$PATH" zig build -Doptimize=ReleaseFast
) || die "the SDK build failed"

printf '\n== done\n'
printf 'the CLI is at %s/zig-out/bin/native\n' "$sdk_dir"
printf 'run:  source scripts/env.sh\n'
printf 'then: scripts/verify.sh\n'
