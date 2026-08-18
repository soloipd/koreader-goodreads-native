#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$project_root/goodreads.koplugin/bin/manage-sync-receipts"
test_root="$(mktemp -d)"
ack_root="$(mktemp -d /tmp/goodreads-outbox-test.XXXXXX)"
identity_payload="/tmp/goodreads-annotation-pending-12345$$"
trap 'rm -rf "$test_root" "$ack_root"; rm -f "$identity_payload"' EXIT HUP INT TERM

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
native_range_count=2
retry_count=2
retry_reason=wait_for_active_book
agent_generation=31
trigger=close
local_verified=false
native_notified=false
journal_lane=unavailable
upload_requested=false
sync_enqueued=false
outbox_sequence=7
outbox_acknowledged=false
cloud_observed=unavailable
EOF
printf '%s\n' 'private annotation text must never be exported' >"$pending_dir/$asin"

status="$(
    GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
        GOODREADS_LOCK_DIR="$test_root" \
        "$helper" status "$asin"
)"
grep -Fqx 'state=saved_locally' <<<"$status"
grep -Fqx 'native_range_count=2' <<<"$status"
grep -Fqx 'pending_present=true' <<<"$status"
grep -Fqx 'effective_state=waiting_native' <<<"$status"

GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" retry "$asin" >/dev/null
for _ in $(seq 1 30); do
    [ -s "$test_root/retry-called" ] && break
    sleep 0.1
done
[ -s "$test_root/retry-called" ] || {
    printf 'error: detached retry helper did not start within 3 seconds\n' >&2
    exit 1
}
grep -Fqx -- "--once $asin" "$test_root/retry-called"

# The real one-shot watcher must replay only the selected ASIN and increment
# its bounded retry counter before invoking the sync helper.
watch_plugin="$test_root/watch-plugin"
watch_settings="$test_root/watch-settings"
watch_private="$test_root/watch-private"
watch_pending="$watch_private/annotation-pending"
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
    GOODREADS_PRIVATE_STATE_DIR="$watch_private" \
    GOODREADS_LOCK_DIR="$test_root" GOODREADS_TMP_DIR="$test_root/watch-tmp" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations" --once "$asin"
grep -Fqx 'retry_count=3' "$test_root/watcher-payload"
test -e "$watch_pending/$asin"

# Some firmware keeps KPPMainApp alive and therefore emits no appStarted event
# when a native book opens. A timed activeApp check must still replay the
# pending snapshot, while retaining it after the initial inactive attempt.
poll_plugin="$test_root/poll-plugin"
poll_private="$test_root/poll-private"
poll_pending="$poll_private/annotation-pending"
mkdir -p "$poll_plugin/bin" "$poll_pending" "$test_root/poll-tmp" \
    "$test_root/poll-lock"
cat >"$poll_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
printf 'sync\n' >>'$test_root/poll-sync-calls'
rm -f "\$1"
[ "\$(wc -l <'$test_root/poll-sync-calls' | tr -d '[:space:]')" -ge 2 ]
EOF
cat >"$test_root/poll-wait-event" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$test_root/poll-get-prop" <<EOF
#!/bin/sh
case "\$2" in
    activeApp) printf '%s\n' com.lab126.booklet.reader ;;
    activeContext) printf '%s\n' ':1:file:///mnt/us/documents/Test_'$asin'.kfx' ;;
esac
EOF
chmod 0755 "$poll_plugin/bin/sync-annotations" "$test_root/poll-wait-event" \
    "$test_root/poll-get-prop"
cat >"$poll_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
EOF
GOODREADS_PLUGIN_DIR="$poll_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$poll_private" \
    GOODREADS_LOCK_DIR="$test_root/poll-lock" GOODREADS_TMP_DIR="$test_root/poll-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/missing-dbus-monitor" \
    GOODREADS_LIPC_WAIT_EVENT="$test_root/poll-wait-event" \
    GOODREADS_LIPC_GET_PROP="$test_root/poll-get-prop" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations"
test "$(wc -l <"$test_root/poll-sync-calls" | tr -d '[:space:]')" = 2
test ! -e "$poll_pending/$asin"

# KPP firmware emits the useful reader start over system DBus while the Java
# ReaderSDK handle is still exact. The filtered listener must wake immediately,
# retry a failed initial probe, and consume the snapshot without LIPC polling.
dbus_plugin="$test_root/dbus-plugin"
dbus_private="$test_root/dbus-private"
dbus_pending="$dbus_private/annotation-pending"
mkdir -p "$dbus_plugin/bin" "$dbus_pending" "$test_root/dbus-tmp" \
    "$test_root/dbus-lock"
cat >"$dbus_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
printf 'sync\n' >>'$test_root/dbus-sync-calls'
printf 'sync\n' >>'$test_root/dbus-order'
rm -f "\$1"
[ "\$(wc -l <'$test_root/dbus-sync-calls' | tr -d '[:space:]')" -ge 3 ]
EOF
cat >"$test_root/dbus-monitor" <<'EOF'
#!/bin/sh
printf '%s\n' \
    'signal sender=:1.14 -> dest=(null destination) serial=1 path=/default; interface=com.lab126.appmgrd; member=appStarted' \
    '   string "com.lab126.booklet.reader"' \
    '   string ""'
EOF
cat >"$test_root/dbus-timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat >"$test_root/dbus-usleep" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >>'$test_root/dbus-sleep-calls'
printf 'sleep:%s\n' "\$1" >>'$test_root/dbus-order'
exit 0
EOF
cat >"$test_root/dbus-get-prop" <<EOF
#!/bin/sh
case "\$2" in
    activeApp)
        count=0
        [ ! -f '$test_root/dbus-active-calls' ] \
            || count=\$(cat '$test_root/dbus-active-calls')
        count=\$((count + 1))
        printf '%s\n' "\$count" >'$test_root/dbus-active-calls'
        if [ "\$count" -le 2 ]; then
            printf '%s\n' com.lab126.KPPMainApp
        else
            printf '%s\n' com.lab126.booklet.reader
        fi
        ;;
    activeContext)
        printf '%s\n' ':1:file:///mnt/us/documents/Test_'$asin'.kfx'
        ;;
esac
EOF
chmod 0755 "$dbus_plugin/bin/sync-annotations" "$test_root/dbus-monitor" \
    "$test_root/dbus-timeout" "$test_root/dbus-usleep" \
    "$test_root/dbus-get-prop"
cat >"$dbus_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
EOF
GOODREADS_PLUGIN_DIR="$dbus_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$dbus_private" \
    GOODREADS_LOCK_DIR="$test_root/dbus-lock" GOODREADS_TMP_DIR="$test_root/dbus-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/dbus-monitor" \
    GOODREADS_TIMEOUT_BIN="$test_root/dbus-timeout" \
    GOODREADS_USLEEP_BIN="$test_root/dbus-usleep" \
    GOODREADS_LIPC_GET_PROP="$test_root/dbus-get-prop" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations"
test "$(wc -l <"$test_root/dbus-sync-calls" | tr -d '[:space:]')" = 3
printf '%s\n' 200000 600000 >"$test_root/expected-dbus-sleeps"
cmp -s "$test_root/expected-dbus-sleeps" "$test_root/dbus-sleep-calls"
printf '%s\n' sync sleep:200000 sync sleep:600000 sync \
    >"$test_root/expected-dbus-order"
cmp -s "$test_root/expected-dbus-order" "$test_root/dbus-order"
test ! -e "$dbus_pending/$asin"

# The native reader may start in the short gap between two bounded DBus
# monitor subscriptions. On the next loop, an exact activeContext URI for a
# pending ASIN must replay immediately instead of waiting for another open.
gap_plugin="$test_root/gap-plugin"
gap_private="$test_root/gap-private"
gap_pending="$gap_private/annotation-pending"
mkdir -p "$gap_plugin/bin" "$gap_pending" "$test_root/gap-tmp" \
    "$test_root/gap-lock"
cat >"$gap_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
printf 'sync\n' >>'$test_root/gap-sync-calls'
rm -f "\$1"
[ "\$(wc -l <'$test_root/gap-sync-calls' | tr -d '[:space:]')" -ge 2 ]
EOF
cat >"$test_root/gap-dbus-monitor" <<EOF
#!/bin/sh
printf 'monitor\n' >>'$test_root/gap-monitor-calls'
printf '%s\n' \
    'signal sender=org.freedesktop.DBus -> dest=:1.1; interface=org.freedesktop.DBus; member=NameAcquired'
EOF
cat >"$test_root/gap-get-prop" <<EOF
#!/bin/sh
case "\$2" in
    activeApp)
        count=0
        [ ! -f '$test_root/gap-active-calls' ] \
            || count=\$(cat '$test_root/gap-active-calls')
        count=\$((count + 1))
        printf '%s\n' "\$count" >'$test_root/gap-active-calls'
        if [ "\$count" -le 2 ]; then
            printf '%s\n' com.lab126.KPPMainApp
        else
            printf '%s\n' com.lab126.booklet.reader
        fi
        ;;
    activeContext)
        count=\$(cat '$test_root/gap-active-calls')
        if [ "\$count" -le 2 ]; then
            printf '%s\n' ':0:app://com.lab126.KPPMainApp?view=KPP_HOME'
        else
            printf '%s\n' ':1:file:///mnt/us/documents/Test_'$asin'.kfx'
        fi
        ;;
esac
EOF
chmod 0755 "$gap_plugin/bin/sync-annotations" \
    "$test_root/gap-dbus-monitor" "$test_root/gap-get-prop"
cat >"$gap_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
EOF
GOODREADS_PLUGIN_DIR="$gap_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$gap_private" \
    GOODREADS_LOCK_DIR="$test_root/gap-lock" GOODREADS_TMP_DIR="$test_root/gap-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/gap-dbus-monitor" \
    GOODREADS_TIMEOUT_BIN="$test_root/dbus-timeout" \
    GOODREADS_USLEEP_BIN="$test_root/dbus-usleep" \
    GOODREADS_LIPC_GET_PROP="$test_root/gap-get-prop" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations"
test "$(wc -l <"$test_root/gap-sync-calls" | tr -d '[:space:]')" = 2
test "$(wc -l <"$test_root/gap-monitor-calls" | tr -d '[:space:]')" = 1
test ! -e "$gap_pending/$asin"

# A matching URI can remain visible after ReaderSDK releases its transient
# exact handle. Starting the long-lived DBus listener must not launch another
# three retries for the same pending sequence and unchanged active context.
bounded_plugin="$test_root/bounded-plugin"
bounded_private="$test_root/bounded-private"
bounded_pending="$bounded_private/annotation-pending"
mkdir -p "$bounded_plugin/bin" "$bounded_pending" "$test_root/bounded-tmp" \
    "$test_root/bounded-lock"
cat >"$bounded_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
printf 'sync\n' >>'$test_root/bounded-sync-calls'
rm -f "\$1"
exit 1
EOF
cat >"$test_root/bounded-dbus-monitor" <<EOF
#!/bin/sh
rm -f '$bounded_pending/$asin'
printf '%s\n' \
    'signal sender=org.freedesktop.DBus -> dest=:1.1; interface=org.freedesktop.DBus; member=NameAcquired'
EOF
cat >"$test_root/bounded-get-prop" <<EOF
#!/bin/sh
case "\$2" in
    activeApp) printf '%s\n' com.lab126.booklet.reader ;;
    activeContext) printf '%s\n' ':1:file:///mnt/us/documents/Test_'$asin'.kfx' ;;
esac
EOF
chmod 0755 "$bounded_plugin/bin/sync-annotations" \
    "$test_root/bounded-dbus-monitor" "$test_root/bounded-get-prop"
cat >"$bounded_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
outbox_sequence=9
EOF
GOODREADS_PLUGIN_DIR="$bounded_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$bounded_private" \
    GOODREADS_LOCK_DIR="$test_root/bounded-lock" \
    GOODREADS_TMP_DIR="$test_root/bounded-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/bounded-dbus-monitor" \
    GOODREADS_TIMEOUT_BIN="$test_root/dbus-timeout" \
    GOODREADS_USLEEP_BIN="$test_root/dbus-usleep" \
    GOODREADS_LIPC_GET_PROP="$test_root/bounded-get-prop" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations"
test "$(wc -l <"$test_root/bounded-sync-calls" | tr -d '[:space:]')" = 3

# Attaching the native helper can itself emit another reader appStarted signal
# on this firmware. Those echo signals must not recursively replay the same
# snapshot. A genuine Home event clears the atomic marker and lets the next
# reader activation consume the pending snapshot.
echo_plugin="$test_root/echo-plugin"
echo_private="$test_root/echo-private"
echo_pending="$echo_private/annotation-pending"
mkdir -p "$echo_plugin/bin" "$echo_pending" "$test_root/echo-tmp" \
    "$test_root/echo-lock"
cat >"$echo_plugin/bin/sync-annotations" <<EOF
#!/bin/sh
printf 'sync\n' >>'$test_root/echo-sync-calls'
rm -f "\$1"
[ "\$(wc -l <'$test_root/echo-sync-calls' | tr -d '[:space:]')" -ge 4 ]
EOF
cat >"$test_root/echo-dbus-monitor" <<'EOF'
#!/bin/sh
printf '%s\n' \
    'signal sender=:1.14 -> dest=(null destination) serial=1 path=/default; interface=com.lab126.appmgrd; member=appStarted' \
    '   string "com.lab126.booklet.reader"' \
    '   string ""' \
    'signal sender=:1.14 -> dest=(null destination) serial=2 path=/default; interface=com.lab126.appmgrd; member=appStarted' \
    '   string "com.lab126.booklet.reader"' \
    '   string ""' \
    'signal sender=:1.14 -> dest=(null destination) serial=3 path=/default; interface=com.lab126.appmgrd; member=appStarted' \
    '   string "com.lab126.KPPMainApp"' \
    '   string ""' \
    'signal sender=:1.14 -> dest=(null destination) serial=4 path=/default; interface=com.lab126.appmgrd; member=appStarted' \
    '   string "com.lab126.booklet.reader"' \
    '   string ""'
EOF
cat >"$test_root/echo-get-prop" <<EOF
#!/bin/sh
case "\$2" in
    activeApp)
        count=0
        [ ! -f '$test_root/echo-active-calls' ] \
            || count=\$(cat '$test_root/echo-active-calls')
        count=\$((count + 1))
        printf '%s\n' "\$count" >'$test_root/echo-active-calls'
        if [ "\$count" -le 2 ]; then
            printf '%s\n' com.lab126.KPPMainApp
        else
            printf '%s\n' com.lab126.booklet.reader
        fi
        ;;
    activeContext)
        printf '%s\n' ':1:file:///mnt/us/documents/Test_'$asin'.kfx'
        ;;
esac
EOF
chmod 0755 "$echo_plugin/bin/sync-annotations" \
    "$test_root/echo-dbus-monitor" "$test_root/echo-get-prop"
cat >"$echo_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
outbox_sequence=10
EOF
GOODREADS_PLUGIN_DIR="$echo_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$echo_private" \
    GOODREADS_LOCK_DIR="$test_root/echo-lock" \
    GOODREADS_TMP_DIR="$test_root/echo-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/echo-dbus-monitor" \
    GOODREADS_TIMEOUT_BIN="$test_root/dbus-timeout" \
    GOODREADS_USLEEP_BIN="$test_root/dbus-usleep" \
    GOODREADS_LIPC_GET_PROP="$test_root/echo-get-prop" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations"
test "$(wc -l <"$test_root/echo-sync-calls" | tr -d '[:space:]')" = 4
test ! -e "$echo_pending/$asin"
test ! -d "$test_root/echo-lock/goodreads-annotation-watcher.lock"

# TERM during a blocked DBus listen must exit the watcher and release its
# singleton lock; upgrade/restart must never leave an untracked old listener.
signal_plugin="$test_root/signal-plugin"
signal_private="$test_root/signal-private"
signal_pending="$signal_private/annotation-pending"
signal_lock="$test_root/signal-lock"
mkdir -p "$signal_plugin/bin" "$signal_pending" "$signal_lock" \
    "$test_root/signal-tmp"
cat >"$signal_plugin/bin/sync-annotations" <<'EOF'
#!/bin/sh
rm -f "$1"
exit 1
EOF
cat >"$test_root/signal-dbus-monitor" <<'EOF'
#!/bin/sh
trap 'exit 0' HUP INT TERM
while :; do
    printf '%s\n' \
        'signal sender=org.freedesktop.DBus -> dest=:1.1; interface=org.freedesktop.DBus; member=NameAcquired'
    sleep 1
done
EOF
cat >"$signal_pending/$asin" <<EOF
version=1
asin=$asin
request_id=1
retry_count=0
desired_count=0
EOF
chmod 0755 "$signal_plugin/bin/sync-annotations" "$test_root/signal-dbus-monitor"
GOODREADS_PLUGIN_DIR="$signal_plugin" GOODREADS_SETTINGS_DIR="$watch_settings" \
    GOODREADS_PRIVATE_STATE_DIR="$signal_private" \
    GOODREADS_LOCK_DIR="$signal_lock" GOODREADS_TMP_DIR="$test_root/signal-tmp" \
    GOODREADS_DBUS_MONITOR="$test_root/signal-dbus-monitor" \
    GOODREADS_TIMEOUT_BIN="$test_root/dbus-timeout" \
    GOODREADS_USLEEP_BIN="$test_root/dbus-usleep" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations" &
signal_watcher_pid=$!
for _ in {1..100}; do
    [ -d "$signal_lock/goodreads-annotation-watcher.lock" ] && break
    sleep 0.01
done
test -d "$signal_lock/goodreads-annotation-watcher.lock"
kill -TERM "$signal_watcher_pid"
for _ in {1..100}; do
    ! kill -0 "$signal_watcher_pid" 2>/dev/null && break
    sleep 0.01
done
if kill -0 "$signal_watcher_pid" 2>/dev/null; then
    printf 'error: annotation watcher survived TERM\n' >&2
    exit 1
fi
wait "$signal_watcher_pid"
test ! -d "$signal_lock/goodreads-annotation-watcher.lock"

# Acknowledgement is compare-and-delete: a matching snapshot is removed, a
# superseding snapshot is restored, and a snapshot created after the atomic
# move survives successful acknowledgement of the older request.
ack_helper="$project_root/goodreads.koplugin/bin/acknowledge-annotation-outbox"
ack_outbox="$ack_root/annotation-outbox"
barrier="$ack_root/barrier"
checksum_a="$(printf 'a%.0s' {1..64})"
checksum_b="$(printf 'b%.0s' {1..64})"
mkdir -p "$ack_outbox" "$barrier"
printf '%s\n' 'sequence=1' "checksum=$checksum_a" >"$ack_outbox/$asin"
GOODREADS_PRIVATE_STATE_DIR="$ack_root" \
    "$ack_helper" "$asin" 1 "$checksum_a" >/dev/null
test ! -e "$ack_outbox/$asin"

printf '%s\n' 'sequence=2' "checksum=$checksum_b" >"$ack_outbox/$asin"
if GOODREADS_PRIVATE_STATE_DIR="$ack_root" \
    "$ack_helper" "$asin" 1 "$checksum_a" >/dev/null 2>&1; then
    printf 'error: superseding outbox was acknowledged as an older request\n' >&2
    exit 1
fi
grep -Fqx 'sequence=2' "$ack_outbox/$asin"

printf '%s\n' 'sequence=3' "checksum=$checksum_a" >"$ack_outbox/$asin"
GOODREADS_PRIVATE_STATE_DIR="$ack_root" GOODREADS_ACK_TEST_BARRIER_DIR="$barrier" \
    "$ack_helper" "$asin" 3 "$checksum_a" >"$ack_root/ack-result" &
ack_pid=$!
for _ in {1..500}; do
    [ -e "$barrier/ready" ] && break
    sleep 0.01
done
test -e "$barrier/ready"
printf '%s\n' 'sequence=4' "checksum=$checksum_b" >"$ack_outbox/$asin"
: >"$barrier/continue"
wait "$ack_pid"
grep -Fqx 'outbox_acknowledged=true' "$ack_root/ack-result"
grep -Fqx 'sequence=4' "$ack_outbox/$asin"

# Successful outbound delivery retains only a text-free XPointer-to-KFX
# identity receipt. The receipt must pair entries by index, survive endpoint
# direction changes, reject malformed replacements, and never retain notes.
identity_helper="$project_root/goodreads.koplugin/bin/persist-annotation-identities"
identity_root="$test_root/identity-private"
identity_outbox="$identity_root/annotation-outbox"
mkdir -p "$identity_outbox"
cat >"$identity_outbox/$asin.body" <<EOF
outbox_version=1
asin=$asin
sequence=7
desired_count=2
desired.0.start_hex=2f6563686f2f7465787428292e3130
desired.0.end_hex=2f6563686f2f7465787428292e3231
desired.0.note_hex=70726976617465206e6f7465
desired.1.start_hex=2f6f746865722e39
desired.1.end_hex=2f6f746865722e35
desired.1.note_hex=
EOF
identity_outbox_checksum="$(sha256sum "$identity_outbox/$asin.body" | awk '{print $1}')"
cp "$identity_outbox/$asin.body" "$identity_outbox/$asin"
printf 'checksum=%s\n' "$identity_outbox_checksum" >>"$identity_outbox/$asin"
cat >"$identity_payload" <<EOF
version=1
asin=$asin
desired_count=2
desired.0.start=AAAAAAAAAAA1
desired.0.start_short=100
desired.0.end=AAAAAAAAAAA2
desired.0.end_short=200
desired.0.note_hex=70726976617465206e6f7465
desired.1.start=AAAAAAAAAAA4
desired.1.start_short=400
desired.1.end=AAAAAAAAAAA3
desired.1.end_short=300
desired.1.note_hex=
EOF
GOODREADS_PRIVATE_STATE_DIR="$identity_root" \
    GOODREADS_SHA256_TOOL="$(command -v sha256sum)" \
    "$identity_helper" "$asin" 7 "$identity_outbox_checksum" "$identity_payload"
identity_file="$identity_root/annotation-identities/$asin"
grep -Fqx 'identity_version=1' "$identity_file"
grep -Fqx 'count=2' "$identity_file"
grep -Fqx 'item.0.native_start_short=100' "$identity_file"
grep -Fqx 'item.1.native_end_short=300' "$identity_file"
if grep -Eq 'note|70726976617465206e6f7465' "$identity_file"; then
    printf 'error: annotation identity receipt retained private note content\n' >&2
    exit 1
fi
identity_verify="$test_root/identity-body"
sed '$d' "$identity_file" >"$identity_verify"
identity_digest="$(sed -n 's/^checksum=//p' "$identity_file")"
test "$(sha256sum "$identity_verify" | awk '{print $1}')" = "$identity_digest"
identity_before="$(sha256sum "$identity_file" | awk '{print $1}')"
sed -i.bak 's/^desired_count=2$/desired_count=3/' "$identity_payload"
if GOODREADS_PRIVATE_STATE_DIR="$identity_root" \
    GOODREADS_SHA256_TOOL="$(command -v sha256sum)" \
    "$identity_helper" "$asin" 7 "$identity_outbox_checksum" "$identity_payload" \
        >/dev/null 2>&1; then
    printf 'error: malformed identity payload replaced a valid receipt\n' >&2
    exit 1
fi
test "$(sha256sum "$identity_file" | awk '{print $1}')" = "$identity_before"

support_path="$(
    GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
        GOODREADS_LOCK_DIR="$test_root" \
        "$helper" export
)"
test "$support_path" = "$settings_dir/goodreads_native_support.txt"
test -s "$support_path"
grep -Fqx '[book_001]' "$support_path"
grep -Fqx 'pending_present=true' "$support_path"
grep -Fqx 'native_range_count=2' "$support_path"
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
grep -Fqx 'native_range_count=2' "$receipt_dir/$asin"

private_state="$test_root/private-state"
mkdir -p "$private_state/annotation-outbox"
printf '%s\n' 'source snapshot' >"$private_state/annotation-outbox/$asin"
source_status="$(
    GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
        GOODREADS_PRIVATE_STATE_DIR="$private_state" GOODREADS_LOCK_DIR="$test_root" \
        "$helper" status "$asin"
)"
grep -Fqx 'pending_present=true' <<<"$source_status"
GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_PRIVATE_STATE_DIR="$private_state" GOODREADS_LOCK_DIR="$test_root" \
    "$helper" discard "$asin" >/dev/null
test ! -e "$private_state/annotation-outbox/$asin"

if GOODREADS_PLUGIN_DIR="$plugin_dir" GOODREADS_SETTINGS_DIR="$settings_dir" \
    GOODREADS_LOCK_DIR="$test_root" \
    "$helper" status 'not-an-asin' >/dev/null 2>&1; then
    printf 'error: invalid ASIN was accepted\n' >&2
    exit 1
fi

# Native-reader capture must atomically retain the newest private snapshot and
# remove all transient request/result files. The fake exporter performs no
# native mutation and returns one coordinate-only range plus a private note.
import_plugin="$test_root/import-plugin"
import_private="$test_root/import-private"
import_tmp="$test_root/import-tmp"
mkdir -p "$import_plugin/bin" "$import_private" "$import_tmp"
cat >"$import_plugin/bin/export-native-annotations" <<'EOF'
#!/bin/sh
payload="$1"
request_id="$(sed -n 's/^request_id=//p' "$payload" | sed -n '1p')"
result="${GOODREADS_TMP_DIR:-/tmp}/goodreads-native-export-$request_id.result"
printf '%s\n' version=1 "request_id=$request_id" asin=B012345678 \
    native_path_hex=2f6d6e742f75732f646f63756d656e74732f546573742e6b6678 count=1 \
    item.0.start=AAAAAAAAAAAA item.0.start_short=1 \
    item.0.end=AAAAAAAAAAAB item.0.end_short=2 \
    item.0.note_hex=70726976617465 snapshot_complete=true success=true >"$result"
rm -f "$payload"
EOF
chmod 0755 "$import_plugin/bin/export-native-annotations"
GOODREADS_PLUGIN_DIR="$import_plugin" GOODREADS_PRIVATE_STATE_DIR="$import_private" \
    GOODREADS_TMP_DIR="$import_tmp" \
    "$project_root/goodreads.koplugin/bin/capture-native-annotations"
test -s "$import_private/native-import/$asin"
grep -Fqx 'success=true' "$import_private/native-import/$asin"
grep -Fqx 'snapshot_complete=true' "$import_private/native-import/$asin"
grep -Fqx 'item.0.note_hex=70726976617465' "$import_private/native-import/$asin"
test "$(find "$import_tmp" -type f | wc -l | tr -d '[:space:]')" = 0

# A nominally successful export without the explicit completeness attestation
# must fail closed and must not replace the last complete inbox snapshot.
cat >"$import_plugin/bin/export-native-annotations" <<'EOF'
#!/bin/sh
payload="$1"
request_id="$(sed -n 's/^request_id=//p' "$payload" | sed -n '1p')"
result="${GOODREADS_TMP_DIR:-/tmp}/goodreads-native-export-$request_id.result"
printf '%s\n' version=1 "request_id=$request_id" asin=B012345678 \
    native_path_hex=2f6d6e742f75732f646f63756d656e74732f546573742e6b6678 count=0 \
    success=true >"$result"
rm -f "$payload"
EOF
chmod 0755 "$import_plugin/bin/export-native-annotations"
if GOODREADS_PLUGIN_DIR="$import_plugin" GOODREADS_PRIVATE_STATE_DIR="$import_private" \
    GOODREADS_TMP_DIR="$import_tmp" \
    "$project_root/goodreads.koplugin/bin/capture-native-annotations"; then
    printf 'error: incomplete native snapshot was accepted\n' >&2
    exit 1
fi
grep -Fqx 'snapshot_complete=true' "$import_private/native-import/$asin"

# A confirmed native-reader handoff must select only the main KOReader process
# and use its normal SIGTERM path. Forked reader.lua helpers are excluded by
# their reader.lua parent, even though they inherit the same command line.
fake_proc="$test_root/proc"
fake_koreader="$test_root/fake-koreader"
mkdir -p "$fake_proc/50" "$fake_proc/101" "$fake_proc/102" "$fake_koreader"
printf '%s\n' 'Name: sh' 'PPid: 1' >"$fake_proc/50/status"
printf '%s\n' 'Name: reader.lua' 'PPid: 50' >"$fake_proc/101/status"
printf '%s\n' 'Name: reader.lua' 'PPid: 101' >"$fake_proc/102/status"
printf '%s\n' './luajit ./reader.lua /book.epub' >"$fake_proc/101/cmdline"
printf '%s\n' './luajit ./reader.lua /book.epub' >"$fake_proc/102/cmdline"
ln -s "$fake_koreader" "$fake_proc/101/cwd"
ln -s "$fake_koreader" "$fake_proc/102/cwd"
selected_pid="$(
    GOODREADS_PROC_ROOT="$fake_proc" GOODREADS_KOREADER_ROOT="$fake_koreader" \
        GOODREADS_HANDOFF_DRY_RUN=1 \
        "$project_root/goodreads.koplugin/bin/exit-koreader-after-native-handoff"
)"
test "$selected_pid" = 101

# The initial already-active capture must not close KOReader. Exactly one
# graceful handoff follows the next appStarted event and successful capture.
watch_import_private="$test_root/watch-import-private"
watch_import_lock="$test_root/watch-import-lock"
mkdir -p "$watch_import_private" "$watch_import_lock"
: >"$watch_import_private/native-import-enabled"
cat >"$test_root/fake-capture" <<EOF
#!/bin/sh
printf 'capture\n' >>'$test_root/capture-calls'
exit 0
EOF
cat >"$test_root/fake-handoff" <<EOF
#!/bin/sh
printf 'handoff\n' >>'$test_root/handoff-calls'
EOF
cat >"$test_root/fake-wait-event" <<EOF
#!/bin/sh
if [ ! -e '$test_root/event-delivered' ]; then
    : >'$test_root/event-delivered'
    exit 0
fi
exit 1
EOF
chmod 0755 "$test_root/fake-capture" "$test_root/fake-handoff" \
    "$test_root/fake-wait-event"
GOODREADS_CAPTURE="$test_root/fake-capture" \
    GOODREADS_HANDOFF_HELPER="$test_root/fake-handoff" \
    GOODREADS_PRIVATE_STATE_DIR="$watch_import_private" \
    GOODREADS_LOCK_DIR="$watch_import_lock" \
    GOODREADS_LIPC_WAIT_EVENT="$test_root/fake-wait-event" \
    "$project_root/goodreads.koplugin/bin/watch-native-annotations"
test "$(wc -l <"$test_root/capture-calls" | tr -d '[:space:]')" = 2
test "$(wc -l <"$test_root/handoff-calls" | tr -d '[:space:]')" = 1

printf 'Sync receipt tests passed.\n'
