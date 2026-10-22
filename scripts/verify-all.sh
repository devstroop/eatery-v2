#!/usr/bin/env bash
# Validate and test every app, and every package, in the repository.
#
#   scripts/verify-all.sh
#
# Runs `native check` (manifest, markup, schema) and `native test`
# (headless update-logic and repository tests) for every app, and
# `zig build test` for every package - a dependency module's tests are
# not collected by the apps that depend on it, so the package has to
# prove itself. Reports a summary and exits non-zero if anything fails.
set -u

cd "$(dirname "$0")/.." || exit 1

if ! command -v native >/dev/null 2>&1; then
  printf 'ros: the native CLI is not on PATH - run scripts/setup.sh\n' >&2
  exit 1
fi

# The apps that carry copies of the shared screens and schema must agree
# before either is built: a drifted copy is a bug the tests cannot see.
if ! bash scripts/check-copies.sh; then
  exit 1
fi

failed=0

for package in packages/*/; do
  [ -f "$package/build.zig" ] || continue
  name="$(basename "$package")"
  printf '==> %s (package)\n' "$name"
  if ! (cd "$package" && zig build test); then
    printf '  package test: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  printf '  test ok\n'
done

for app in apps/*/; do
  name="$(basename "$app")"
  printf '==> %s\n' "$name"
  if ! native check "$app"; then
    printf '  check: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  if ! native test "$app" --yes; then
    printf '  test: FAILED\n'
    failed=$((failed + 1))
    continue
  fi
  printf '  check+test ok\n'
done

if [ "$failed" -ne 0 ]; then
  printf '%d target(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all targets verified\n'
