#!/usr/bin/env bash
# Validate and test every app in the repository.
#
#   scripts/verify.sh
#
# Runs `native check` (manifest, markup, schema) and `native test`
# (headless update-logic and repository tests) for every app, and reports
# a summary. Exits non-zero if anything fails.
set -u

cd "$(dirname "$0")/.." || exit 1

if ! command -v native >/dev/null 2>&1; then
  printf 'eatery: the native CLI is not on PATH - run scripts/setup.sh\n' >&2
  exit 1
fi

failed=0
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
  printf '%d app(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all apps verified\n'
