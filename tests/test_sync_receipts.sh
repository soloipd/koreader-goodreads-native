#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_root/goodreads.koplugin/bin/manage-sync-receipts"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

plugin_dir="$test_root/plugins/goodreads.koplugin"
settings_dir="$test_root/settings"
receipt_dir="$settings_dir/goodreads_native_sync_receipts"
pending_dir="$settings_dir/goodreads_native_annotations_pending"
asin="B012345678"
mkdir -p "$plugin_dir/bin" "$receipt_dir" "$pending_dir"
cp "$project_root/goodreads.koplugin/VERSION" "$plugin_dir/VERSION"
cat >"$plugin_dir/bin/watch-pending-annotations" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$test_root/retry-called"
EOF
chmod 0755 "$plugin_dir/bin/watch-pending-annotations"

cat >"$receipt_dir/$asin" <<'EOF'
version=1
asin=B012345678
state=saved_locally
updated_at=100
saved_at=100
waiting_at=
queued_at=
desired_count=3
note_count=1
retry_count=2
retry_reason=wait_for_active_book
agent_generation=27
trigger=close
local_verified=false
native_notified=false
journal_lane=unavailable
upload_requested=false
sync_enqueued=false
cloud_observed=unavailable
EOF
printf '%s\n' 'private annotation text must never be exported' >"$pending_dir/$asin"

status="$(
    GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
        GOODREADS_LOCK_DIR="$test_root" \
        "$helper" status "$asin"
)"
grep -Fqx 'state=saved_locally' <<<"$status"
grep -Fqx 'pending_present=true' <<<"$status"
grep -Fqx 'effective_state=waiting_native' <<<"$status"

GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" retry "$asin" >/dev/null
for _ in 1 2 3 4 5; do
    [ -s "$test_root/retry-called" ] && break
    sleep 0.1
done
grep -Fqx -- "--once $asin" "$test_root/retry-called"

# The real one-shot watcher must replay only the selected ASIN and increment
# its bounded retry counter before invoking the sync helper.
watch_plugin="$test_root/watch-plugin"
watch_settings="$test_root/watch-settings"
watch_pending="$watch_settings/goodreads_native_annotations_pending"
mkdir -p "$watch_plugin/bin" "$watch_pending" "$test_root/watch-tmp"
cat >"$watch_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
cp "\$1" "$test_root/watcher-payload"
exit 1
EOF
chmod 0755 "$watch_plugin/bin/sync-annotations"
cat >"$watch_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=2
desired_count=0
EOF
GOODREADS_PLUGIN_DIR="$watch_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_LOCK_DIR="$test_root" GOODREADS_TMP_DIR="$test_root/watch-tmp" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations" --once "$asin"
grep -Fqx 'retry_count=3' "$test_root/watcher-payload"
test -e "$watch_pending/$asin"

support_path="$(
    GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
        GOODREADS_LOCK_DIR="$test_root" \
        "$helper" export
)"
test "$support_path" = "$settings_dir/goodreads_native_support.txt"
test -s "$support_path"
grep -Fqx '[book_001]' "$support_path"
grep -Fqx 'pending_present=true' "$support_path"
if grep -Fq "$asin" "$support_path" \
    || grep -Fq 'private annotation text' "$support_path"; then
    printf 'error: support summary leaked an ASIN or annotation text\n' >&2
    exit 1
fi

mkdir "$test_root/goodreads-annotation-book-$asin.lock"
if GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" discard "$asin" >/dev/null 2>&1; then
    printf 'error: pending snapshot was discarded during an active replay\n' >&2
    exit 1
fi
test -e "$pending_dir/$asin"
rmdir "$test_root/goodreads-annotation-book-$asin.lock"

GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" discard "$asin" >/dev/null
test ! -e "$pending_dir/$asin"
grep -Fqx 'state=discarded' "$receipt_dir/$asin"
grep -Fqx 'retry_reason=user_discarded' "$receipt_dir/$asin"

if GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" status 'not-an-asin' >/dev/null 2>&1; then
    printf 'error: invalid ASIN was accepted\n' >&2
    exit 1
fi

printf 'Sync receipt tests passed.\n'
