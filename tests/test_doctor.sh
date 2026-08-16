#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doctor="$project_root/goodreads.koplugin/bin/goodreads-doctor"
test_root="$(mktemp -d /tmp/goodreads-doctor-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

plugin="$test_root/plugin"
state="$test_root/state"
proc="$test_root/proc"
mkdir -p "$plugin/bin" "$state/annotation-outbox" "$state/native-import" \
    "$state/pending" "$proc"
printf '%s\n' '0.9.0' >"$plugin/VERSION"
: >"$plugin/bin/goodreads-annotation-export-agent-v3.jar"
: >"$state/native-import-enabled"

# Filenames and contents deliberately contain values that must never escape in
# the redacted report.
printf '%s\n' 'private annotation text' >"$state/annotation-outbox/B012345678"
printf '%s\n' 'private note text' >"$state/native-import/B087654321"
printf '%s\n' 'account-secret-token' >"$state/pending/B000000001"

make_process() {
    pid="$1"
    name="$2"
    parent="$3"
    cwd="$4"
    cmdline="$5"
    mkdir -p "$proc/$pid"
    printf 'Name:\t%s\nPPid:\t%s\n' "$name" "$parent" >"$proc/$pid/status"
    ln -s "$cwd" "$proc/$pid/cwd"
    printf '%s' "$cmdline" >"$proc/$pid/cmdline"
}

make_process 100 framework 1 / 'ch.ethz.iks.concierge.framework.Framework'
make_process 200 reader.lua 1 /mnt/us/koreader 'reader.lua'
make_process 201 reader.lua 200 /mnt/us/koreader 'reader.lua helper'
make_process 202 reader.lua 201 /mnt/us/koreader 'reader.lua helper'
make_process 300 sh 1 / '/mnt/us/koreader/plugins/goodreads.koplugin/bin/watch-native-annotations'

output="$test_root/report"
GOODREADS_PLUGIN_DIR="$plugin" GOODREADS_PRIVATE_STATE_DIR="$state" \
    GOODREADS_DOCTOR_PROC_ROOT="$proc" GOODREADS_DOCTOR_JAVA_BIN=/bin/sh \
    GOODREADS_DOCTOR_ARCH=armv7l "$doctor" >"$output"

grep -Fqx 'single_instance=ok' "$output"
grep -Fqx 'reader_processes=3' "$output"
grep -Fqx 'reader_roots=1' "$output"
grep -Fqx 'native_import_watchers=1' "$output"
grep -Fqx 'annotation_outbox_books=1' "$output"
grep -Fqx 'native_import_books=1' "$output"
grep -Fqx 'pending_annotation_books=1' "$output"
grep -Fqx 'reader_launch_attempted=false' "$output"
grep -Fqx 'overall=healthy' "$output"
if grep -Eq 'B0[0-9]+|private|secret|token' "$output"; then
    printf 'error: doctor leaked private fixture data\n' >&2
    exit 1
fi

# A second independent reader root is a hard error with a machine-readable
# nonzero status, but it still must not print process arguments or identifiers.
make_process 400 reader.lua 1 /mnt/us/koreader 'reader.lua second-root private-secret'
set +e
GOODREADS_PLUGIN_DIR="$plugin" GOODREADS_PRIVATE_STATE_DIR="$state" \
    GOODREADS_DOCTOR_PROC_ROOT="$proc" GOODREADS_DOCTOR_JAVA_BIN=/bin/sh \
    GOODREADS_DOCTOR_ARCH=armv7l "$doctor" >"$output"
status=$?
set -e
[ "$status" -eq 2 ]
grep -Fqx 'reader_roots=2' "$output"
grep -Fqx 'single_instance=error' "$output"
grep -Fqx 'overall=error' "$output"
if grep -Eq 'B0[0-9]+|private|secret|token|second-root' "$output"; then
    printf 'error: doctor leaked data in error mode\n' >&2
    exit 1
fi

# Static launch-safety guard: the command may identify reader.lua by name but
# must contain no reader launcher, LIPC mutation, kill, or reboot primitive.
if grep -Eq 'koreader\.sh|lipc-set-prop|(^|[^[:alpha:]])kill([^[:alpha:]]|$)|reboot|poweroff' \
    "$doctor"; then
    printf 'error: doctor contains a reader-launch or mutation primitive\n' >&2
    exit 1
fi

if [ "${1:-}" = "--stress" ]; then
    rm -rf "$proc/400"
    parent=202
    for offset in $(seq 0 999); do
        pid=$((500 + offset))
        make_process "$pid" reader.lua "$parent" /mnt/us/koreader 'reader.lua helper'
        parent="$pid"
    done
    GOODREADS_PLUGIN_DIR="$plugin" GOODREADS_PRIVATE_STATE_DIR="$state" \
        GOODREADS_DOCTOR_PROC_ROOT="$proc" GOODREADS_DOCTOR_JAVA_BIN=/bin/sh \
        GOODREADS_DOCTOR_ARCH=armv7l "$doctor" >"$output"
    grep -Fqx 'reader_processes=1003' "$output"
    grep -Fqx 'reader_roots=1' "$output"
    grep -Fqx 'single_instance=ok' "$output"
    grep -Fqx 'overall=healthy' "$output"
fi

printf '%s\n' 'Doctor privacy and fault-injection tests passed.'
