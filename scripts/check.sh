#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$project_root/goodreads.koplugin"
agent_jar="$plugin_dir/bin/goodreads-progress-agent-v2.jar"

sh -n "$plugin_dir/bin/sync-progress"
sh -n "$plugin_dir/bin/sync-rating"

if command -v shellcheck >/dev/null 2>&1; then
    # ShellCheck's informational findings include false positives for the
    # trap-only cleanup function and literal JVM inner-class filenames.
    shellcheck --severity=warning "$plugin_dir/bin/sync-progress" \
        "$plugin_dir/bin/sync-rating" \
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

test -s "$agent_jar"
test -s "$plugin_dir/bin/classes/AttachLauncher.class"
unzip -tq "$agent_jar"
unzip -p "$agent_jar" META-INF/MANIFEST.MF \
    | tr -d '\r' \
    | grep -Fqx 'Agent-Class: GoodreadsProgressAgentV2' \
    || { printf 'error: agent manifest has the wrong Agent-Class\n' >&2; exit 1; }
unzip -Z1 "$agent_jar" \
    | grep -Fqx 'GoodreadsProgressAgentV2.class' \
    || { printf 'error: agent JAR lacks its main class\n' >&2; exit 1; }
unzip -Z1 "$agent_jar" \
    | grep -Fqx 'GoodreadsProgressAgentV2$RequestArguments.class' \
    || { printf 'error: agent JAR lacks its argument parser class\n' >&2; exit 1; }

if grep -R -E -q \
    'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}' \
    --exclude-dir=.git --exclude='*.jar' --exclude='*.class' "$project_root"; then
    printf 'error: possible credential committed in project files\n' >&2
    exit 1
fi

printf 'All checks passed.\n'
