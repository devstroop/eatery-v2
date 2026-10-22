#!/usr/bin/env bash
# Check the files the three apps share by copy.
#
#   scripts/check-copies.sh
#
# The Native SDK resolves an app's schema from `<app>/src/schema` and its
# markup imports from `<app>/src`, and it has no option to point either at
# a shared directory. So the apps carry copies, and a copy that drifts is
# a bug that only shows up on one device.
#
# `apps/admin` is the source: it is the superset app, and every copy in
# `apps/service` and `apps/kiosk` must be byte-identical to it.
#
# Exits non-zero if a copy differs or is missing.
set -u

cd "$(dirname "$0")/.." || exit 1

source_app="apps/admin"
copies="apps/service apps/kiosk"
failed=0

# --------------------------------------------------------------- screens

for app in $copies; do
  for file in "$app"/src/screens/*.native; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    source_file="$source_app/src/screens/$name"
    if [ ! -f "$source_file" ]; then
      printf 'copy: %s has no source in %s\n' "$file" "$source_app" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! cmp -s "$source_file" "$file"; then
      printf 'copy: %s drifted from %s\n' "$file" "$source_file" >&2
      failed=$((failed + 1))
    fi
  done
done

# ---------------------------------------------------------------- schema

# Every app carries the whole schema: the SDK opens a database per app,
# and a device that has one migration fewer cannot read the rows another
# device wrote.
for app in $copies; do
  source_list="$(cd "$source_app/src/schema" && ls)"
  copy_list="$(cd "$app/src/schema" && ls)"
  if [ "$source_list" != "$copy_list" ]; then
    printf 'schema: %s/src/schema does not list the same files as %s\n' "$app" "$source_app" >&2
    failed=$((failed + 1))
    continue
  fi
  for name in $source_list; do
    if ! cmp -s "$source_app/src/schema/$name" "$app/src/schema/$name"; then
      printf 'schema: %s/src/schema/%s drifted\n' "$app" "$name" >&2
      failed=$((failed + 1))
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  printf '%d shared file(s) drifted - edit %s and copy it across\n' "$failed" "$source_app" >&2
  exit 1
fi
printf 'shared files agree\n'
