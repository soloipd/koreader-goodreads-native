#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/goodreads-lock-test.XXXXXX)"
payload="/tmp/goodreads-annotations-$$.properties"
request_result="/tmp/goodreads-annotation-result-$$.log"
trap 'rm -rf "$test_root"; rm -f "$payload" "$request_result"' EXIT HUP INT TERM

plugin_dir="$test_root/plugin"
state_dir="$test_root/state"
receipt_dir="$test_root/receipts"
lock_dir="$test_root/held.lock"
published_result="$test_root/published-result.log"
helper="$test_root/sync-annotations"
fake_java="$test_root/java"
mkdir -p "$plugin_dir/bin/classes" "$receipt_dir" "$lock_dir"
: >"$plugin_dir/bin/goodreads-annotation-agent-v29.jar"
: >"$plugin_dir/bin/classes/AttachLauncher.class"
: >"$fake_java"
chmod 0755 "$fake_java"

sed \
    -e "s|^JAVA_BIN=.*|JAVA_BIN=\"$fake_java\"|" \
    -e "s|^PLUGIN_DIR=.*|PLUGIN_DIR=\"$plugin_dir\"|" \
    -e "s|^STATE_DIR=.*|STATE_DIR=\"$state_dir\"|" \
    -e "s|^RECEIPT_DIR=.*|RECEIPT_DIR=\"$receipt_dir\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$lock_dir\"|" \
    -e "s|^PUBLISHED_RESULT=.*|PUBLISHED_RESULT=\"$published_result\"|" \
    "$project_root/goodreads.koplugin/bin/sync-annotations" >"$helper"
chmod 0755 "$helper"

cat >"$payload" <<EOF
version=1
asin=B012345678
request_id=$$
outbox_sequence=legacy
outbox_checksum=legacy
retry_count=0
trigger=reader_ready
desired_count=0
previous_count=0
EOF

started_at="$(date +%s)"
if "$helper" "$payload"; then
    printf 'error: lock contention was reported as success\n' >&2
    exit 1
else
    status=$?
fi
elapsed="$(( $(date +%s) - started_at ))"
[ "$status" -eq 75 ]
[ "$elapsed" -lt 5 ]
grep -Fqx "request_id=$$" "$published_result"
grep -Fqx 'failed_stage=lock_busy' "$published_result"
grep -Fqx 'success=false' "$published_result"
grep -Fqx 'outbox_acknowledged=false' "$published_result"
grep -Fqx 'state=failed' "$receipt_dir/B012345678"
grep -Fqx 'retry_reason=lock_busy' "$receipt_dir/B012345678"

printf 'Annotation lock-contention test passed.\n'
