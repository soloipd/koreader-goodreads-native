#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$project_root/agent/src"
build_dir="$project_root/agent/build/jdk"
classes_dir="$build_dir/classes"
agent_jar="$project_root/goodreads.koplugin/bin/goodreads-progress-agent-v2.jar"
annotation_agent_jar="$project_root/goodreads.koplugin/bin/goodreads-annotation-agent-v31.jar"
annotation_export_jar="$project_root/goodreads.koplugin/bin/goodreads-annotation-export-agent-v3.jar"
launcher_class="$project_root/goodreads.koplugin/bin/classes/AttachLauncher.class"

# shellcheck source=java-toolchain.sh
source "$project_root/scripts/java-toolchain.sh"
javac_bin="$(goodreads_find_java_tool "${JAVAC:-}" javac)" || {
    printf 'error: a working JDK is required (set JAVAC or JAVA_HOME)\n' >&2
    exit 1
}
jar_bin="${JAR:-$(dirname "$javac_bin")/jar}"
[ -x "$jar_bin" ] || {
    printf 'error: the selected JDK has no jar tool (set JAR)\n' >&2
    exit 1
}

reproducible_jar() {
    output="$1"
    manifest="$2"
    shift 2
    if "$jar_bin" --help 2>&1 | grep -q -- '--date'; then
        "$jar_bin" --create --file "$output" --manifest "$manifest" \
            --date=1980-01-01T00:00:02Z "$@"
        return
    fi

    # JDK 8 has no --date flag. Build once with jar so manifest normalization
    # remains standards-compliant, then repack sorted files with fixed mtimes
    # and no host-specific ZIP metadata.
    raw="$output.raw.$$"
    stage="$build_dir/reproducible-$(basename "$output").$$"
    rm -rf "$stage"
    mkdir -p "$stage"
    "$jar_bin" cfm "$raw" "$manifest" "$@"
    unzip -qq "$raw" -d "$stage"
    find "$stage" -exec touch -t 198001010000.02 {} +
    rm -f "$output"
    (
        cd "$stage"
        {
            printf '%s\n' META-INF/MANIFEST.MF
            find . -type f ! -path './META-INF/MANIFEST.MF' -print \
                | sed 's#^\./##' | LC_ALL=C sort
        } | zip -Xq "$output" -@
    )
    rm -rf "$stage"
    rm -f "$raw"
}

rm -rf "$build_dir"
mkdir -p "$classes_dir" "$(dirname "$agent_jar")" "$(dirname "$launcher_class")"
find "$(dirname "$annotation_agent_jar")" -maxdepth 1 -type f \
    -name 'goodreads-annotation-agent-v*.jar' \
    ! -name "$(basename "$annotation_agent_jar")" -delete
find "$(dirname "$annotation_export_jar")" -maxdepth 1 -type f \
    -name 'goodreads-annotation-export-agent-v*.jar' \
    ! -name "$(basename "$annotation_export_jar")" -delete

"$javac_bin" --release 8 -d "$classes_dir" \
    "$source_dir/AttachLauncher.java" \
    "$source_dir/GoodreadsProgressAgentV2.java" \
    "$source_dir/GoodreadsAnnotationAgentV31.java" \
    "$source_dir/GoodreadsAnnotationExportAgentV3.java"

reproducible_jar "$agent_jar" "$project_root/agent/manifest-progress.mf" \
    -C "$classes_dir" GoodreadsProgressAgentV2.class \
    -C "$classes_dir" 'GoodreadsProgressAgentV2$RequestArguments.class'

reproducible_jar "$annotation_agent_jar" "$project_root/agent/manifest-annotations.mf" \
    -C "$classes_dir" GoodreadsAnnotationAgentV31.class \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$1.class' \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$CloudAnnotationHandler.class' \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$Record.class' \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$RangeEndpoint.class' \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$RangeIdentity.class' \
    -C "$classes_dir" 'GoodreadsAnnotationAgentV31$Counters.class'

reproducible_jar "$annotation_export_jar" "$project_root/agent/manifest-annotation-export.mf" \
    -C "$classes_dir" GoodreadsAnnotationExportAgentV3.class \
    -C "$classes_dir" 'GoodreadsAnnotationExportAgentV3$ExportRecord.class'

cp "$classes_dir/AttachLauncher.class" "$launcher_class"
chmod 0644 "$agent_jar" "$annotation_agent_jar" "$annotation_export_jar" "$launcher_class"
chmod 0755 "$project_root/goodreads.koplugin/bin/sync-progress" \
    "$project_root/goodreads.koplugin/bin/sync-annotations" \
    "$project_root/goodreads.koplugin/bin/export-native-annotations" \
    "$project_root/goodreads.koplugin/bin/capture-native-annotations" \
    "$project_root/goodreads.koplugin/bin/watch-native-annotations" \
    "$project_root/goodreads.koplugin/bin/exit-koreader-after-native-handoff" \
    "$project_root/goodreads.koplugin/bin/watch-pending-annotations" \
    "$project_root/goodreads.koplugin/bin/manage-sync-receipts" \
    "$project_root/goodreads.koplugin/bin/acknowledge-annotation-outbox" \
    "$project_root/goodreads.koplugin/bin/persist-annotation-identities"
chmod 0755 "$project_root/goodreads.koplugin/bin/goodreads-doctor" \
    "$project_root/tests/test_doctor.sh"
chmod 0755 "$project_root/tests/test_release_stress.sh"

printf 'Built %s\n' "$agent_jar"
printf 'Built %s\n' "$annotation_agent_jar"
printf 'Built %s\n' "$annotation_export_jar"
