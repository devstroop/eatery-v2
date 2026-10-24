#!/usr/bin/env bash
# Run the app in debug mode with markup hot reload.
#
#   scripts/dev.sh              # the Restaurant OS app
#   scripts/dev.sh apps/gallery # another app
#
# `native dev` builds a Debug binary: fine for editing, noticeably slower
# at painting than the ReleaseFast binary from `native build`.
set -u

cd "$(dirname "$0")/.." || exit 1

app="${1:-apps/admin}"

if ! command -v native >/dev/null 2>&1; then
  printf 'ros: the native CLI is not on PATH - run scripts/setup.sh\n' >&2
  exit 1
fi

exec native dev "$app"
