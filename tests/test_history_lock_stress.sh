#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/goodreads-history-lock.XXXXXX)"
state_root="$test_root/state"
lock_dir="$state_root/history.lock"
worker_script="$project_root/tests/history_lock_worker.lua"
worker_count="${GOODREADS_HISTORY_LOCK_WORKERS:-24}"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

lua_runtime=""
for candidate in lua5.1 luajit lua; do
    if command -v "$candidate" >/dev/null 2>&1; then
        lua_runtime="$candidate"
        break
    fi
done
[ -n "$lua_runtime" ] || {
    printf 'error: history lock stress requires a Lua 5.1-compatible runtime\n' >&2
    exit 1
}

sha256_tool="$(command -v sha256sum || true)"
[ -n "$sha256_tool" ] || {
    printf 'error: history lock stress requires sha256sum\n' >&2
    exit 1
}

mkdir -p "$state_root"

run_worker() {
    PROJECT_ROOT="$project_root" \
        GOODREADS_PRIVATE_STATE_DIR="$state_root" \
        GOODREADS_HISTORY_EXPORT_DIR="$test_root/exports" \
        GOODREADS_HISTORY_LOCK="$lock_dir" \
        GOODREADS_SHA256_TOOL="$sha256_tool" \
        "$lua_runtime" "$worker_script" "$@"
}

run_with_deadline() {
    run_worker "$@" &
    local child_pid=$!
    (
        sleep 3
        kill -TERM "$child_pid" >/dev/null 2>&1 || true
    ) &
    local watchdog_pid=$!
    local status=0
    wait "$child_pid" || status=$?
    kill -TERM "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    [ "$status" -eq 0 ] || {
        printf 'error: special-file lifecycle lock probe blocked or failed\n' >&2
        exit 1
    }
}

# A FIFO must never be opened by the UI path: it is treated as a busy lock.
mkdir "$lock_dir"
mkfifo "$lock_dir/owner"
run_with_deadline probe_busy
rm -f "$lock_dir/owner"
rmdir "$lock_dir"

# A symlink owner must neither be followed nor modify its target.
printf '%s\n' 'unchanged' >"$test_root/victim"
mkdir "$lock_dir"
ln -s "$test_root/victim" "$lock_dir/owner"
run_with_deadline probe_busy
grep -Fqx 'unchanged' "$test_root/victim"
rm -f "$lock_dir/owner"
rmdir "$lock_dir"

# Lifecycle data itself receives the same nonblocking treatment.
mkfifo "$state_root/reading-history-v1"
run_with_deadline probe_invalid_history
rm -f "$state_root/reading-history-v1"

ln -s "$test_root/victim" "$state_root/reading-history-v1"
run_with_deadline probe_invalid_history
grep -Fqx 'unchanged' "$test_root/victim"
rm -f "$state_root/reading-history-v1"

# All workers start behind one stale lock. Exactly one reaps it; every worker
# then commits a distinct book through the same bounded lifecycle store.
mkdir "$lock_dir"
printf '%s\n' "$(( $(date +%s) - 121 ))" >"$lock_dir/owner"
pids=()
for worker in $(seq 1 "$worker_count"); do
    run_worker write "$worker" >"$test_root/worker.$worker.log" 2>&1 &
    pids+=("$!")
done

failed=0
for index in "${!pids[@]}"; do
    if ! wait "${pids[$index]}"; then
        failed=1
        cat "$test_root/worker.$(( index + 1 )).log" >&2
    fi
done
[ "$failed" -eq 0 ] || exit 1

run_worker verify "$worker_count"
[ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ]
[ ! -e "$lock_dir.reap" ] && [ ! -L "$lock_dir.reap" ]

printf 'Reading-history lock stress passed (%s concurrent writers).\n' "$worker_count"
