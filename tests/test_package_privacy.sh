#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/goodreads-package-privacy.XXXXXX)"
fixture="$test_root/project"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

mkdir -p "$fixture/scripts" "$fixture/goodreads.koplugin"
cp "$project_root/scripts/package.sh" "$fixture/scripts/package.sh"
chmod 700 "$fixture/scripts/package.sh"
printf '%s\n' '9.9.9' >"$fixture/VERSION"
printf '%s\n' 'return {}' >"$fixture/goodreads.koplugin/main.lua"
mkdir -p "$fixture/goodreads.koplugin/bin"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$fixture/goodreads.koplugin/bin/helper"
chmod 755 "$fixture/goodreads.koplugin/bin/helper"

"$fixture/scripts/package.sh" >/dev/null
archive="$fixture/dist/goodreads-native-koreader-v9.9.9.zip"
unzip -tq "$archive" >/dev/null
unzip -Z1 "$archive" | grep -Fqx 'goodreads.koplugin/main.lua'
extract="$test_root/extract"
mkdir "$extract"
unzip -q "$archive" -d "$extract"
[ -x "$extract/goodreads.koplugin/bin/helper" ]

printf '%s\n' 'private' \
    >"$fixture/goodreads.koplugin/goodreads_reading_history.csv.tmp.ABCDEF"
if "$fixture/scripts/package.sh" >/dev/null 2>&1; then
    printf 'error: a suffixed private export passed package preflight\n' >&2
    exit 1
fi
rm -f "$fixture/goodreads.koplugin/goodreads_reading_history.csv.tmp.ABCDEF"

ln -s main.lua "$fixture/goodreads.koplugin/alias.lua"
if "$fixture/scripts/package.sh" >/dev/null 2>&1; then
    printf 'error: a plugin symlink passed package preflight\n' >&2
    exit 1
fi

printf '%s\n' 'Package privacy tests passed.'
