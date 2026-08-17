#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$project_root/goodreads.koplugin"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
dist_dir="$project_root/dist"
archive="$dist_dir/goodreads-native-koreader-v$version.zip"
checksum_file="$archive.sha256"

if find "$plugin_dir" -type l -print -quit | grep -q .; then
    printf 'error: plugin source contains a symbolic link\n' >&2
    exit 1
fi

if find "$plugin_dir" \
    \( -name 'reading-history-v1*' \
       -o -name 'goodreads_reading_history.csv*' \
       -o -name 'goodreads_reading_history.json*' \) \
    -print -quit | grep -q .; then
    printf 'error: plugin source contains private reading-history data\n' >&2
    exit 1
fi

mkdir -p "$dist_dir"
rm -f "$archive" "$checksum_file"

(
    cd "$project_root"
    find goodreads.koplugin -type f \
        ! -name '.DS_Store' \
        ! -name '*.bak' \
        ! -name '*.log' \
        ! -name 'reading-history-v1*' \
        ! -name 'goodreads_reading_history.csv*' \
        ! -name 'goodreads_reading_history.json*' \
        -print \
        | LC_ALL=C sort \
        | zip -Xq "$archive" -@
)

unzip -tq "$archive"
archive_entries="$(unzip -Z1 "$archive")"
if grep -Eq '(^|/)(reading-history-v1[^/]*|goodreads_reading_history\.(csv|json)[^/]*)$' \
    <<<"$archive_entries"; then
    printf 'error: private reading-history data would be packaged\n' >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$dist_dir"
        sha256sum "$(basename "$archive")" > "$(basename "$checksum_file")"
    )
else
    digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
    printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$checksum_file"
fi

printf 'Packaged %s\n' "$archive"
