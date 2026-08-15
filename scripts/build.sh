#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$project_root/agent/src"
build_dir="$project_root/agent/build/jdk"
classes_dir="$build_dir/classes"
agent_jar="$project_root/goodreads.koplugin/bin/goodreads-progress-agent-v2.jar"
launcher_class="$project_root/goodreads.koplugin/bin/classes/AttachLauncher.class"

javac_bin="${JAVAC:-javac}"
jar_bin="${JAR:-jar}"

rm -rf "$build_dir"
mkdir -p "$classes_dir" "$(dirname "$agent_jar")" "$(dirname "$launcher_class")"

"$javac_bin" --release 8 -d "$classes_dir" \
    "$source_dir/AttachLauncher.java" \
    "$source_dir/GoodreadsProgressAgentV2.java"

"$jar_bin" cfm "$agent_jar" "$project_root/agent/manifest-progress.mf" \
    -C "$classes_dir" GoodreadsProgressAgentV2.class \
    -C "$classes_dir" 'GoodreadsProgressAgentV2$RequestArguments.class'

cp "$classes_dir/AttachLauncher.class" "$launcher_class"
chmod 0644 "$agent_jar" "$launcher_class"
chmod 0755 "$project_root/goodreads.koplugin/bin/sync-progress"

printf 'Built %s\n' "$agent_jar"
