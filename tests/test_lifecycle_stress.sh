#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watcher="$project_root/goodreads.koplugin/bin/watch-native-annotations"
selector="$project_root/goodreads.koplugin/bin/exit-koreader-after-native-handoff"
stress_root="$(mktemp -d /tmp/goodreads-lifecycle-stress.XXXXXX)"
trap 'rm -rf "$stress_root"' EXIT HUP INT TERM

# Exercise 1,000 serialized native-reader starts. The initial probe captures
# once but must never close KOReader; every subsequent confirmed start captures
# once and requests exactly one graceful handoff.
private_state="$stress_root/private"
lock_root="$stress_root/locks"
mkdir -p "$private_state" "$lock_root"
: >"$private_state/native-import-enabled"
: >"$stress_root/event-count"
printf '%s\n' 0 >"$stress_root/event-count"
cat >"$stress_root/capture" <<EOF
#!/bin/sh
printf 'capture\n' >>'$stress_root/capture-calls'
EOF
cat >"$stress_root/handoff" <<EOF
#!/bin/sh
printf 'handoff\n' >>'$stress_root/handoff-calls'
EOF
cat >"$stress_root/wait-event" <<EOF
#!/bin/sh
count=\$(sed -n '1p' '$stress_root/event-count')
if [ "\$count" -ge 1000 ]; then exit 1; fi
printf '%s\n' \$((count + 1)) >'$stress_root/event-count'
exit 0
EOF
chmod 0755 "$stress_root/capture" "$stress_root/handoff" "$stress_root/wait-event"
GOODREADS_CAPTURE="$stress_root/capture" \
    GOODREADS_HANDOFF_HELPER="$stress_root/handoff" \
    GOODREADS_PRIVATE_STATE_DIR="$private_state" \
    GOODREADS_LOCK_DIR="$lock_root" \
    GOODREADS_LIPC_WAIT_EVENT="$stress_root/wait-event" \
    GOODREADS_HANDOFF_DELAY_SECONDS=0 \
    "$watcher"
test "$(wc -l <"$stress_root/capture-calls" | tr -d '[:space:]')" = 1001
test "$(wc -l <"$stress_root/handoff-calls" | tr -d '[:space:]')" = 1000

# Hold one watcher inside its wait call while 50 competitors attempt startup.
# The lock must permit one initial capture and no duplicate watcher workload.
singleton_private="$stress_root/singleton-private"
singleton_lock="$stress_root/singleton-lock"
mkdir -p "$singleton_private" "$singleton_lock"
: >"$singleton_private/native-import-enabled"
cat >"$stress_root/singleton-capture" <<EOF
#!/bin/sh
printf 'capture\n' >>'$stress_root/singleton-captures'
EOF
cat >"$stress_root/singleton-wait" <<EOF
#!/bin/sh
: >'$stress_root/singleton-ready'
while [ ! -e '$stress_root/singleton-release' ]; do sleep 0.01; done
exit 1
EOF
chmod 0755 "$stress_root/singleton-capture" "$stress_root/singleton-wait"
GOODREADS_CAPTURE="$stress_root/singleton-capture" \
    GOODREADS_PRIVATE_STATE_DIR="$singleton_private" \
    GOODREADS_LOCK_DIR="$singleton_lock" \
    GOODREADS_LIPC_WAIT_EVENT="$stress_root/singleton-wait" \
    GOODREADS_HANDOFF_DELAY_SECONDS=0 \
    "$watcher" &
singleton_pid=$!
for _ in {1..500}; do
    [ -e "$stress_root/singleton-ready" ] && break
    sleep 0.01
done
test -e "$stress_root/singleton-ready"
competitors=()
for _ in {1..50}; do
    GOODREADS_CAPTURE="$stress_root/singleton-capture" \
        GOODREADS_PRIVATE_STATE_DIR="$singleton_private" \
        GOODREADS_LOCK_DIR="$singleton_lock" \
        GOODREADS_LIPC_WAIT_EVENT="$stress_root/singleton-wait" \
        GOODREADS_HANDOFF_DELAY_SECONDS=0 \
        "$watcher" &
    competitors+=("$!")
done
for pid in "${competitors[@]}"; do wait "$pid"; done
: >"$stress_root/singleton-release"
wait "$singleton_pid"
test "$(wc -l <"$stress_root/singleton-captures" | tr -d '[:space:]')" = 1

# A TERM must interrupt the blocking event child, exit promptly, and release
# only a lock still owned by that watcher. A dead owner is then recovered
# without allowing the departing process to remove its successor's lock.
terminate_private="$stress_root/terminate-private"
terminate_lock_root="$stress_root/terminate-lock"
terminate_lock="$terminate_lock_root/goodreads-native-import-watcher.lock"
mkdir -p "$terminate_private" "$terminate_lock_root"
: >"$terminate_private/native-import-enabled"
cat >"$stress_root/terminate-capture" <<EOF
#!/bin/sh
exit 0
EOF
cat >"$stress_root/terminate-wait" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" >'$stress_root/terminate-child'
: >'$stress_root/terminate-ready'
exec sleep 30
EOF
chmod 0755 "$stress_root/terminate-capture" "$stress_root/terminate-wait"

wait_for_watcher_exit() {
    watcher_pid="$1"
    wait_child="$2"
    for _ in {1..200}; do
        kill -0 "$watcher_pid" 2>/dev/null || break
        sleep 0.01
    done
    if kill -0 "$watcher_pid" 2>/dev/null; then
        kill -TERM "$wait_child" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
        printf 'error: native watcher ignored TERM while blocked on its event child\n' >&2
        exit 1
    fi
    wait "$watcher_pid" 2>/dev/null || true
    ! kill -0 "$wait_child" 2>/dev/null
}

GOODREADS_CAPTURE="$stress_root/terminate-capture" \
    GOODREADS_PRIVATE_STATE_DIR="$terminate_private" \
    GOODREADS_LOCK_DIR="$terminate_lock_root" \
    GOODREADS_LIPC_WAIT_EVENT="$stress_root/terminate-wait" \
    GOODREADS_HANDOFF_DELAY_SECONDS=0 \
    "$watcher" &
terminate_pid=$!
for _ in {1..500}; do
    [ -e "$stress_root/terminate-ready" ] && break
    sleep 0.01
done
test -e "$stress_root/terminate-ready"
terminate_child="$(sed -n '1p' "$stress_root/terminate-child")"
test "$(sed -n '1p' "$terminate_lock/pid")" = "$terminate_pid"

# Simulate an atomic successor lock appearing before the old process cleans up.
printf '%s\n' 99999999 >"$terminate_lock/pid"
kill -TERM "$terminate_pid"
wait_for_watcher_exit "$terminate_pid" "$terminate_child"
test "$(sed -n '1p' "$terminate_lock/pid")" = 99999999

rm -f "$stress_root/terminate-ready" "$stress_root/terminate-child"
GOODREADS_CAPTURE="$stress_root/terminate-capture" \
    GOODREADS_PRIVATE_STATE_DIR="$terminate_private" \
    GOODREADS_LOCK_DIR="$terminate_lock_root" \
    GOODREADS_LIPC_WAIT_EVENT="$stress_root/terminate-wait" \
    GOODREADS_HANDOFF_DELAY_SECONDS=0 \
    "$watcher" &
replacement_pid=$!
for _ in {1..500}; do
    [ -e "$stress_root/terminate-ready" ] && break
    sleep 0.01
done
test -e "$stress_root/terminate-ready"
replacement_child="$(sed -n '1p' "$stress_root/terminate-child")"
test "$(sed -n '1p' "$terminate_lock/pid")" = "$replacement_pid"
kill -TERM "$replacement_pid"
wait_for_watcher_exit "$replacement_pid" "$replacement_child"
test ! -e "$terminate_lock"

# Put 1,000 inherited reader.lua helper processes ahead of the real process in
# the fake /proc tree. Selection must skip every child and return only the main
# process with a non-reader parent and exact KOReader working directory.
proc_root="$stress_root/proc"
koreader_root="$stress_root/koreader"
mkdir -p "$proc_root/2" "$proc_root/9999" "$koreader_root"
printf '%s\n' 'Name: sh' 'PPid: 1' >"$proc_root/2/status"
printf '%s\n' 'Name: reader.lua' 'PPid: 2' >"$proc_root/9999/status"
printf '%s\n' './luajit ./reader.lua /book.epub' >"$proc_root/9999/cmdline"
ln -s "$koreader_root" "$proc_root/9999/cwd"
for index in $(seq 1000 1999); do
    mkdir -p "$proc_root/$index"
    printf '%s\n' 'Name: reader.lua' 'PPid: 9999' >"$proc_root/$index/status"
    printf '%s\n' './luajit ./reader.lua /book.epub' >"$proc_root/$index/cmdline"
    ln -s "$koreader_root" "$proc_root/$index/cwd"
done
selected="$(
    GOODREADS_PROC_ROOT="$proc_root" GOODREADS_KOREADER_ROOT="$koreader_root" \
        GOODREADS_HANDOFF_DRY_RUN=1 "$selector"
)"
test "$selected" = 9999

printf 'Lifecycle stress tests passed: 1,000 handoffs, 50 contenders, clean TERM/recovery, 1,000 helper processes.\n'
