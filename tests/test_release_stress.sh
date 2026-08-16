#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stress_root="$(mktemp -d /tmp/goodreads-release-stress.XXXXXX)"
trap 'rm -rf "$stress_root"' EXIT HUP INT TERM

lua_runtime=""
for candidate in lua5.1 luajit lua; do
    if command -v "$candidate" >/dev/null 2>&1; then
        lua_runtime="$candidate"
        break
    fi
done
[ -n "$lua_runtime" ] || {
    printf 'error: release stress requires a Lua 5.1-compatible runtime\n' >&2
    exit 1
}

sha256_tool="$(command -v sha256sum || command -v shasum || true)"
[ -n "$sha256_tool" ] || {
    printf 'error: release stress requires a SHA-256 tool\n' >&2
    exit 1
}

# Repeat the complete behavior suite in fresh private state. This includes the
# maximum 1,000-annotation reconciliation, 500 protected local conflicts,
# incomplete-snapshot fail-closed behavior, retries, and idempotency.
PROJECT_ROOT="$project_root" \
    GOODREADS_PRIVATE_STATE_DIR="$stress_root/annotation-state" \
    GOODREADS_SHA256_TOOL="$sha256_tool" \
    "$lua_runtime" "$project_root/tests/test_main.lua"

"$project_root/tests/test_lifecycle_stress.sh"

printf '%s\n' 'Release stress gate passed: annotation, lifecycle, concurrency, and process-selection stress.'
