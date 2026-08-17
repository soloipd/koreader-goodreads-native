#!/usr/bin/env bash

# Resolve a real Java tool instead of accepting macOS's executable placeholders,
# which exist in PATH but fail when no Apple-registered JDK is present.
goodreads_find_java_tool() {
    local requested="${1:-}"
    local tool="${2:?Java tool name is required}"
    local path_candidate=""
    path_candidate="$(command -v "$tool" 2>/dev/null || true)"
    local candidates=(
        "$requested"
        "${JAVA_HOME:+$JAVA_HOME/bin/$tool}"
        "$path_candidate"
        "/opt/homebrew/opt/openjdk@21/bin/$tool"
        "/opt/homebrew/opt/openjdk@17/bin/$tool"
        "/opt/homebrew/opt/openjdk@11/bin/$tool"
        "/opt/homebrew/opt/openjdk@8/bin/$tool"
        "/opt/homebrew/opt/openjdk/bin/$tool"
        "/usr/local/opt/openjdk@21/bin/$tool"
        "/usr/local/opt/openjdk@17/bin/$tool"
        "/usr/local/opt/openjdk@11/bin/$tool"
        "/usr/local/opt/openjdk@8/bin/$tool"
        "/usr/local/opt/openjdk/bin/$tool"
        "/usr/lib/jvm/default-java/bin/$tool"
    )
    local candidate=""
    local resolved=""
    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        case "$candidate" in
            */*) resolved="$candidate" ;;
            *) resolved="$(command -v "$candidate" 2>/dev/null || true)" ;;
        esac
        if [ -n "$resolved" ] && [ -x "$resolved" ] \
            && "$resolved" -version >/dev/null 2>&1
        then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}
