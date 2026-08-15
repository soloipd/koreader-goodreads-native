#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$project_root/goodreads.koplugin"
agent_jar="$plugin_dir/bin/goodreads-progress-agent-v2.jar"
annotation_agent_jar="$plugin_dir/bin/goodreads-annotation-agent-v1.jar"

sh -n "$plugin_dir/bin/sync-progress"
sh -n "$plugin_dir/bin/sync-rating"
sh -n "$plugin_dir/bin/sync-annotations"

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

grep -Fqx 'Agent-Class: GoodreadsProgressAgentV2' <<<"$progress_manifest" \
    || { printf 'error: agent manifest has the wrong Agent-Class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its main class\n' >&2; exit 1; }
grep -Fqx 'GoodreadsProgressAgentV2$RequestArguments.class' <<<"$progress_entries" \
    || { printf 'error: agent JAR lacks its argument parser class\n' >&2; exit 1; }
grep -Fqx 'Agent-Class: GoodreadsAnnotationAgentV1' <<<"$annotation_manifest" \
    || { printf 'error: annotation agent manifest is invalid\n' >&2; exit 1; }
grep -Fqx 'GoodreadsAnnotationAgentV1.class' <<<"$annotation_entries" \
    || { printf 'error: annotation agent JAR lacks its main class\n' >&2; exit 1; }

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
        "$project_root/agent/src/GoodreadsAnnotationAgentV1.java" \
        "${annotation_test_sources[@]}"
    "$java_bin" -cp "$annotation_test_dir" GoodreadsAnnotationAgentV1Test
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
