#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
experiment_dir="$project_root/experiments/background-annotation-sync"
build_dir="$project_root/agent/build/experiments/background-annotation-v1"
classes_dir="$build_dir/classes"
output_jar="$project_root/agent/build/experiments/background-annotation-capability-v1.jar"
canary_jar="$project_root/agent/build/experiments/background-annotation-canary-v1.jar"
javac_bin="${JAVAC:-javac}"
jar_bin="${JAR:-jar}"

rm -rf "$build_dir"
mkdir -p "$classes_dir" "$(dirname "$output_jar")"
"$javac_bin" --release 8 -d "$classes_dir" \
    "$experiment_dir/BackgroundAnnotationCapabilityProbeV1.java" \
    "$experiment_dir/BackgroundAnnotationCanaryAgentV1.java"
"$jar_bin" cfm "$output_jar" "$experiment_dir/manifest.mf" \
    -C "$classes_dir" BackgroundAnnotationCapabilityProbeV1.class
unzip -tq "$output_jar"
"$jar_bin" cfm "$canary_jar" "$experiment_dir/canary-manifest.mf" \
    -C "$classes_dir" BackgroundAnnotationCanaryAgentV1.class \
    -C "$classes_dir" 'BackgroundAnnotationCanaryAgentV1$CanaryState.class'
unzip -tq "$canary_jar"
printf 'Built %s\n' "$output_jar"
printf 'Built %s\n' "$canary_jar"
