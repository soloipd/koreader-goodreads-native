#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$project_root/goodreads.koplugin"
agent_jar="$plugin_dir/bin/goodreads-progress-agent-v2.jar"
annotation_agent_jar="$plugin_dir/bin/goodreads-annotation-agent-v28.jar"
annotation_export_jar="$plugin_dir/bin/goodreads-annotation-export-agent-v3.jar"

sh -n "$plugin_dir/bin/sync-progress"
sh -n "$plugin_dir/bin/sync-rating"
sh -n "$plugin_dir/bin/sync-annotations"
sh -n "$plugin_dir/bin/export-native-annotations"
sh -n "$plugin_dir/bin/capture-native-annotations"
sh -n "$plugin_dir/bin/watch-native-annotations"
sh -n "$plugin_dir/bin/exit-koreader-after-native-handoff"
sh -n "$plugin_dir/bin/watch-pending-annotations"
sh -n "$plugin_dir/bin/manage-sync-receipts"
sh -n "$plugin_dir/bin/acknowledge-annotation-outbox"
sh -n "$plugin_dir/bin/goodreads-doctor"
test -x "$plugin_dir/bin/manage-sync-receipts"
test -x "$plugin_dir/bin/acknowledge-annotation-outbox"
test -x "$plugin_dir/bin/export-native-annotations"
test -x "$plugin_dir/bin/capture-native-annotations"
test -x "$plugin_dir/bin/watch-native-annotations"
test -x "$plugin_dir/bin/exit-koreader-after-native-handoff"
test -x "$plugin_dir/bin/goodreads-doctor"
cmp -s "$project_root/VERSION" "$plugin_dir/VERSION" \
    || { printf 'error: packaged plugin version does not match release version\n' >&2; exit 1; }
"$project_root/tests/test_doctor.sh"
grep -Fq 'write_receipt saved_locally' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotation sync does not persist its local-save receipt\n' >&2; exit 1; }
grep -Fq 'write_receipt waiting_native' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: inactive annotation sync does not persist its waiting receipt\n' >&2; exit 1; }
grep -Fq 'write_receipt queued_amazon' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: accepted annotation sync does not persist its queue receipt\n' >&2; exit 1; }
grep -Fq "'cloud_observed=unavailable'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: upload acceptance may be mislabeled as cloud observation\n' >&2; exit 1; }
grep -Fq '"$WATCHER" --once "$2"' "$plugin_dir/bin/manage-sync-receipts" \
    || { printf 'error: retry action does not request a one-shot replay\n' >&2; exit 1; }
grep -Fq 'self:persistAnnotationOutbox(snapshot)' "$plugin_dir/main.lua" \
    || { printf 'error: captured annotations are not persisted before translation\n' >&2; exit 1; }
grep -Fq 'self:pollAnnotationTranslation(snapshot)' "$plugin_dir/main.lua" \
    || { printf 'error: annotation position translation is not polled asynchronously\n' >&2; exit 1; }
if sed -n '/function Goodreads:startAnnotationReconcile/,/function Goodreads:resumeAnnotationOutbox/p' \
    "$plugin_dir/main.lua" | grep -Fq 'io.popen'; then
    printf 'error: annotation position translation still blocks the KOReader UI thread\n' >&2
    exit 1
fi
grep -Fq 'translate-native-positions' "$plugin_dir/main.lua" \
    || { printf 'error: native annotation import lacks batch reverse translation\n' >&2; exit 1; }
if sed -n '/function Goodreads:queueNativeAnnotationImport/,/function Goodreads:scheduleAnnotationReconcile/p' \
    "$plugin_dir/main.lua" | grep -Fq 'io.popen'; then
    printf 'error: native annotation import blocks the KOReader UI thread\n' >&2
    exit 1
fi
grep -Fq 'com.lab126.appmgrd appStarted' "$plugin_dir/bin/watch-native-annotations" \
    || { printf 'error: native import watcher does not observe native-reader starts\n' >&2; exit 1; }
grep -Fq 'native-import-enabled' "$plugin_dir/bin/watch-native-annotations" \
    || { printf 'error: native import watcher ignores the opt-in setting\n' >&2; exit 1; }
grep -Fq 'exit-koreader-after-native-handoff' "$plugin_dir/bin/watch-native-annotations" \
    || { printf 'error: native import watcher leaves KOReader behind KPP\n' >&2; exit 1; }
if grep -Fq 'kill -KILL' "$plugin_dir/bin/exit-koreader-after-native-handoff"; then
    printf 'error: native handoff helper may force-kill KOReader\n' >&2
    exit 1
fi
grep -Fq 'result.outbox_acknowledged == "true"' "$plugin_dir/main.lua" \
    || { printf 'error: annotation success does not require outbox acknowledgement\n' >&2; exit 1; }
grep -Fq 'failed_stage=outbox_superseded' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: superseded outbox requests are not rejected\n' >&2; exit 1; }
lock_busy_block="$(sed -n '/if ! mkdir "$LOCK_DIR"/,/^[[:space:]]*fi$/p' \
    "$plugin_dir/bin/sync-annotations")"
grep -Fq 'failed_stage=lock_busy' <<<"$lock_busy_block" \
    || { printf 'error: annotation lock contention has no immediate result\n' >&2; exit 1; }
grep -Fq 'publish_result' <<<"$lock_busy_block" \
    || { printf 'error: annotation lock contention waits for the result timeout\n' >&2; exit 1; }
grep -Fq 'write_receipt failed "$request_result" lock_busy' <<<"$lock_busy_block" \
    || { printf 'error: annotation lock contention has no durable retry receipt\n' >&2; exit 1; }
grep -Fq 'chown "$framework_uid:$framework_gid" "$payload"' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotation payload is not transferred to the framework JVM user\n' >&2; exit 1; }
grep -Fq 'KSDKAnnotationsEnqueueForSync' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: native annotation sync is not explicitly enqueued\n' >&2; exit 1; }
grep -Fq 'KPPACShadowModeManagerShouldSyncLegacySidecarAndJournal' \
    "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: WhisperStore legacy journal sync is not explicitly triggered\n' >&2; exit 1; }
grep -Fq 'KPPACShadowModeManagerShouldSyncKSDKAnnotations' \
    "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: KSDK shadow sync is not enabled before reconciliation\n' >&2; exit 1; }
grep -Fq 'WHISPERSYNC_START_PROPERTY="startSync"' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: WhisperSync is not explicitly started after reconciliation\n' >&2; exit 1; }
grep -Fq "grep -Fqx 'local_verified=true'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: unverified native annotations may be queued\n' >&2; exit 1; }
grep -Fq "grep -Fqx 'native_notified=true'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotations not sent to KPP/KSDK may be queued\n' >&2; exit 1; }
grep -Fq "grep -Eq '^ksdk_synced=(true|unavailable)$'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotations not dual-written to KSDK may be queued\n' >&2; exit 1; }
grep -Fq "grep -Fqx 'native_cloud_queued=true'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotations without a native cloud queue may be accepted\n' >&2; exit 1; }
grep -Fq "grep -Eq '^legacy_journaled=(true|unavailable)$'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: legacy journaling status is not validated\n' >&2; exit 1; }
grep -Fq "grep -Eq '^cloud_snapshot_synced=(true|unavailable)$'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: firmware-specific snapshot status is not validated\n' >&2; exit 1; }
grep -Fq "grep -Eq '^agent_generation=(18|19|20|21|22|23|24|25|26|27|28)$'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: completed legacy migration is not preserved across agent upgrades\n' >&2; exit 1; }
grep -Fq 'failed_stage=wait_for_active_book' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: inactive native-book requests are not queued for replay\n' >&2; exit 1; }
grep -Fq 'com.lab126.appmgrd appStarted' "$plugin_dir/bin/watch-pending-annotations" \
    || { printf 'error: pending annotation watcher does not wait for native-reader activation\n' >&2; exit 1; }
grep -Fq "'local_success=true' 'sync_enqueued=false' 'success=false'" \
    "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: enqueue failure is not reflected in overall success\n' >&2; exit 1; }

if command -v shellcheck >/dev/null 2>&1; then
    # ShellCheck's informational findings include false positives for the
    # trap-only cleanup function and literal JVM inner-class filenames.
    shellcheck --severity=warning "$plugin_dir/bin/sync-progress" \
        "$plugin_dir/bin/sync-rating" \
        "$plugin_dir/bin/sync-annotations" \
        "$plugin_dir/bin/exit-koreader-after-native-handoff" \
        "$plugin_dir/bin/watch-pending-annotations" \
        "$plugin_dir/bin/manage-sync-receipts" \
        "$plugin_dir/bin/acknowledge-annotation-outbox" \
        "$project_root/tests/test_lifecycle_stress.sh" \
        "$project_root/scripts/build.sh" \
        "$project_root/scripts/check.sh" \
        "$project_root/scripts/package.sh"
fi

"$project_root/tests/test_sync_receipts.sh"
"$project_root/tests/test_annotation_lock.sh"

lua_checker=""
for candidate in luac5.1 luac lua5.1 luajit; do
    if command -v "$candidate" >/dev/null 2>&1; then
        lua_checker="$candidate"
        break
    fi
done

case "$lua_checker" in
    luac5.1|luac)
        "$lua_checker" -p "$plugin_dir/main.lua"
        "$lua_checker" -p "$plugin_dir/_meta.lua"
        "$lua_checker" -p "$plugin_dir/annotationoutbox.lua"
        ;;
    lua5.1|luajit)
        LUA_CHECK_FILE="$plugin_dir/main.lua" \
            "$lua_checker" -e 'assert(loadfile(os.getenv("LUA_CHECK_FILE")))'
        LUA_CHECK_FILE="$plugin_dir/_meta.lua" \
            "$lua_checker" -e 'assert(loadfile(os.getenv("LUA_CHECK_FILE")))'
        LUA_CHECK_FILE="$plugin_dir/annotationoutbox.lua" \
            "$lua_checker" -e 'assert(loadfile(os.getenv("LUA_CHECK_FILE")))'
        ;;
    '')
        printf 'warning: no Lua syntax checker found\n' >&2
        ;;
esac

lua_runtime=""
for candidate in lua5.1 luajit lua; do
    if command -v "$candidate" >/dev/null 2>&1; then
        lua_runtime="$candidate"
        break
    fi
done

if [ -n "$lua_runtime" ]; then
    outbox_test_root="$(mktemp -d)"
    trap 'rm -rf "$outbox_test_root"' EXIT HUP INT TERM
    PROJECT_ROOT="$project_root" GOODREADS_PRIVATE_STATE_DIR="$outbox_test_root" \
        GOODREADS_SHA256_TOOL="$(command -v sha256sum)" \
        "$lua_runtime" "$project_root/tests/test_main.lua"
    PROJECT_ROOT="$project_root" "$lua_runtime" "$project_root/tests/test_annotation_outbox.lua"
    rm -rf "$outbox_test_root"
    trap - EXIT HUP INT TERM
else
    printf 'warning: no Lua runtime found; behavior tests were skipped\n' >&2
fi

test -s "$agent_jar"
test -s "$annotation_agent_jar"
test -s "$annotation_export_jar"
test -s "$plugin_dir/bin/classes/AttachLauncher.class"
unzip -tq "$agent_jar"
unzip -tq "$annotation_agent_jar"
unzip -tq "$annotation_export_jar"
progress_manifest="$(unzip -p "$agent_jar" META-INF/MANIFEST.MF | tr -d '\r')"
annotation_manifest="$(unzip -p "$annotation_agent_jar" META-INF/MANIFEST.MF | tr -d '\r')"
annotation_export_manifest="$(unzip -p "$annotation_export_jar" META-INF/MANIFEST.MF | tr -d '\r')"
progress_entries="$(unzip -Z1 "$agent_jar")"
annotation_entries="$(unzip -Z1 "$annotation_agent_jar")"
annotation_export_entries="$(unzip -Z1 "$annotation_export_jar")"
annotation_agent_count="$(find "$plugin_dir/bin" -maxdepth 1 -type f \
    -name 'goodreads-annotation-agent-v*.jar' | wc -l | tr -d '[:space:]')"
annotation_export_agent_count="$(find "$plugin_dir/bin" -maxdepth 1 -type f \
    -name 'goodreads-annotation-export-agent-v*.jar' | wc -l | tr -d '[:space:]')"

[ "$annotation_agent_count" = "1" ] \
    || { printf 'error: stale annotation agent JARs would be packaged\n' >&2; exit 1; }
[ "$annotation_export_agent_count" = "1" ] \
    || { printf 'error: stale annotation export agent JARs would be packaged\n' >&2; exit 1; }

grep -Fqx 'Agent-Class: GoodreadsProgressAgentV2' <<<"$progress_manifest" \
    || { printf 'error: agent manifest has the wrong Agent-Class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its main class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2$RequestArguments.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its argument parser class\n' >&2; exit 1; }
grep -Fqx 'Agent-Class: GoodreadsAnnotationAgentV28' <<<"$annotation_manifest" \
    || { printf 'error: annotation agent manifest is invalid\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV28.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks its main class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV28$CloudAnnotationHandler.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks its cloud proxy handler\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV28$RangeIdentity.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks exact range identities\n' >&2; exit 1; }
grep -Fqx 'Agent-Class: GoodreadsAnnotationExportAgentV3' <<<"$annotation_export_manifest" \
    || { printf 'error: annotation export agent manifest is invalid\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationExportAgentV3.class' <<<"$annotation_export_entries" \
    || { printf 'error: annotation export agent JAR lacks its main class\n' >&2; exit 1; }

javac_bin="${JAVAC:-javac}"
java_bin="${JAVA:-java}"
annotation_test_dir="$project_root/agent/build/annotation-tests"
annotation_test_sources=()
while IFS= read -r source; do
    annotation_test_sources+=("$source")
done < <(find "$project_root/agent/testsrc" -type f -name '*.java' \
    ! -name 'GoodreadsAnnotationAgentV27Test.java' \
    ! -name 'GoodreadsAnnotationExportAgentV2Test.java' | sort)

if command -v "$javac_bin" >/dev/null 2>&1 && command -v "$java_bin" >/dev/null 2>&1; then
    rm -rf "$annotation_test_dir"
    mkdir -p "$annotation_test_dir"
    "$javac_bin" --release 8 -Xlint:-options -d "$annotation_test_dir" \
        "$project_root/agent/src/GoodreadsAnnotationAgentV3.java" \
        "$project_root/agent/src/GoodreadsAnnotationAgentV28.java" \
        "$project_root/agent/src/GoodreadsAnnotationExportAgentV3.java" \
        "${annotation_test_sources[@]}"
    "$java_bin" -cp "$annotation_test_dir" GoodreadsAnnotationAgentV28Test
    "$java_bin" -cp "$annotation_test_dir" GoodreadsAnnotationExportAgentV3Test
else
    printf 'warning: Java toolchain unavailable; annotation agent behavior tests were skipped\n' >&2
fi

if grep -R -E -q \
    'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}' \
    --exclude-dir=.git --exclude-dir=kindle-plugin-fork \
    --exclude-dir=kindle-position-roadmap-work \
    --exclude='*.jar' --exclude='*.class' "$project_root"; then
    printf 'error: possible credential committed in project files\n' >&2
    exit 1
fi

printf 'All checks passed.\n'
