#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
dist_dir="$project_root/dist"
archive="$dist_dir/goodreads-native-koreader-v$version.zip"
checksum_file="$archive.sha256"

mkdir -p "$dist_dir"
rm -f "$archive" "$checksum_file"

(
    cd "$project_root"
    zip -qr "$archive" goodreads.koplugin \
        -x '*/.DS_Store' '*.bak' '*.log'
)

unzip -tq "$archive"

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
