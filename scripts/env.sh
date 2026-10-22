#!/usr/bin/env bash
# Put the right toolchain on PATH.
#
#   source scripts/env.sh
#
# Zig 0.16.0 (the SDK's pin), Node 24 (the schema generator's floor) and
# the Native SDK CLI. Sourcing this is better than exporting the variables
# yourself: it also tells you when something is missing.
set -u

ros_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# --- Zig: the SDK is pinned to 0.16. Homebrew's 0.17 shadows it on PATH,
# so the pinned path goes FIRST, not last.
zig_homebrew="/opt/homebrew/opt/zig/bin"
if [ -x "$zig_homebrew/zig" ]; then
  export PATH="$zig_homebrew:$PATH"
fi

# --- Node 24: the relational schema generator is TypeScript and needs it.
node_homebrew="/opt/homebrew/opt/node@24/bin"
if [ -x "$node_homebrew/node" ]; then
  export PATH="$node_homebrew:$PATH"
fi

# --- The Native SDK CLI.
if [ -x "$HOME/native-sdk/zig-out/bin/native" ]; then
  export PATH="$HOME/native-sdk/zig-out/bin:$PATH"
fi

missing=0
for tool in zig node native; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'ros: %s is not on PATH\n' "$tool" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  printf 'ros: run scripts/setup.sh first\n' >&2
fi

zig_version="$(command -v zig >/dev/null 2>&1 && zig version || echo none)"
case "$zig_version" in
  0.16.*) ;;
  *) printf 'ros: zig %s is on PATH; the Native SDK needs 0.16.0\n' "$zig_version" >&2 ;;
esac
