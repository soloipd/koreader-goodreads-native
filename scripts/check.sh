#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$project_root/goodreads.koplugin"
agent_jar="$plugin_dir/bin/goodreads-progress-agent-v2.jar"
annotation_agent_jar="$plugin_dir/bin/goodreads-annotation-agent-v15.jar"

sh -n "$plugin_dir/bin/sync-progress"
sh -n "$plugin_dir/bin/sync-rating"
sh -n "$plugin_dir/bin/sync-annotations"
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
grep -Fq 'annotationsDualWriteToKSDK' "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: firmware KSDK dual-write availability is not probed\n' >&2; exit 1; }
grep -Fq "grep -Fqx 'cloud_synced=true'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: annotations not journaled to WhisperStore may be queued\n' >&2; exit 1; }
grep -Fq "grep -Fqx 'cloud_snapshot_synced=true'" "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: un-ingested native sidecars may be reported as synced\n' >&2; exit 1; }
grep -Fq "'local_success=true' 'sync_enqueued=false' 'success=false'" \
    "$plugin_dir/bin/sync-annotations" \
    || { printf 'error: enqueue failure is not reflected in overall success\n' >&2; exit 1; }

if command -v shellcheck >/dev/null 2>&1; then
    # ShellCheck's informational findings include false positives for the
    # trap-only cleanup function and literal JVM inner-class filenames.
    shellcheck --severity=warning "$plugin_dir/bin/sync-progress" \
        "$plugin_dir/bin/sync-rating" \
        "$plugin_dir/bin/sync-annotations" \
        "$project_root/scripts/build.sh" \
        "$project_root/scripts/check.sh" \
        "$project_root/scripts/package.sh"
fi

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
        ;;
    lua5.1|luajit)
        LUA_CHECK_FILE="$plugin_dir/main.lua" \
            "$lua_checker" -e 'assert(loadfile(os.getenv("LUA_CHECK_FILE")))'
        LUA_CHECK_FILE="$plugin_dir/_meta.lua" \
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
    PROJECT_ROOT="$project_root" "$lua_runtime" "$project_root/tests/test_main.lua"
else
    printf 'warning: no Lua runtime found; behavior tests were skipped\n' >&2
fi

test -s "$agent_jar"
test -s "$annotation_agent_jar"
test -s "$plugin_dir/bin/classes/AttachLauncher.class"
unzip -tq "$agent_jar"
unzip -tq "$annotation_agent_jar"
progress_manifest="$(unzip -p "$agent_jar" META-INF/MANIFEST.MF | tr -d '\r')"
annotation_manifest="$(unzip -p "$annotation_agent_jar" META-INF/MANIFEST.MF | tr -d '\r')"
progress_entries="$(unzip -Z1 "$agent_jar")"
annotation_entries="$(unzip -Z1 "$annotation_agent_jar")"
annotation_agent_count="$(find "$plugin_dir/bin" -maxdepth 1 -type f \
    -name 'goodreads-annotation-agent-v*.jar' | wc -l | tr -d '[:space:]')"

[ "$annotation_agent_count" = "1" ] \
    || { printf 'error: stale annotation agent JARs would be packaged\n' >&2; exit 1; }

grep -Fqx 'Agent-Class: GoodreadsProgressAgentV2' <<<"$progress_manifest" \
    || { printf 'error: agent manifest has the wrong Agent-Class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its main class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2$RequestArguments.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its argument parser class\n' >&2; exit 1; }
grep -Fqx 'Agent-Class: GoodreadsAnnotationAgentV15' <<<"$annotation_manifest" \
    || { printf 'error: annotation agent manifest is invalid\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV15.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks its main class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV15$CloudAnnotationHandler.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks its cloud proxy handler\n' >&2; exit 1; }

javac_bin="${JAVAC:-javac}"
java_bin="${JAVA:-java}"
annotation_test_dir="$project_root/agent/build/annotation-tests"
annotation_test_sources=()
while IFS= read -r source; do
    annotation_test_sources+=("$source")
done < <(find "$project_root/agent/testsrc" -type f -name '*.java' | sort)

if command -v "$javac_bin" >/dev/null 2>&1 && command -v "$java_bin" >/dev/null 2>&1; then
    rm -rf "$annotation_test_dir"
    mkdir -p "$annotation_test_dir"
    "$javac_bin" --release 8 -Xlint:-options -d "$annotation_test_dir" \
        "$project_root/agent/src/GoodreadsAnnotationAgentV3.java" \
        "$project_root/agent/src/GoodreadsAnnotationAgentV15.java" \
        "${annotation_test_sources[@]}"
    "$java_bin" -cp "$annotation_test_dir" GoodreadsAnnotationAgentV15Test
else
    printf 'warning: Java toolchain unavailable; annotation agent behavior tests were skipped\n' >&2
fi

if grep -R -E -q \
    'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}' \
    --exclude-dir=.git --exclude='*.jar' --exclude='*.class' "$project_root"; then
    printf 'error: possible credential committed in project files\n' >&2
    exit 1
fi

printf 'All checks passed.\n'
