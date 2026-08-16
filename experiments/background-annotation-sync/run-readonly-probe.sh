#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    printf 'usage: %s KINDLE_IP SSH_PORT\n' "$0" >&2
    exit 2
fi

kindle_ip="$1"
kindle_port="$2"
case "$kindle_ip" in
    *[!0-9A-Fa-f:.]*) printf 'invalid Kindle IP address\n' >&2; exit 2 ;;
esac
case "$kindle_port" in
    ''|*[!0-9]*) printf 'invalid SSH port\n' >&2; exit 2 ;;
esac

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe_jar="$project_root/agent/build/experiments/background-annotation-capability-v1.jar"
launcher="$project_root/goodreads.koplugin/bin/classes/AttachLauncher.class"
ssh_options=(-p "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new)
scp_options=(-P "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new)

[[ -r "$probe_jar" && -r "$launcher" ]] || {
    printf 'build the probe before running it\n' >&2
    exit 3
}

scp "${scp_options[@]}" "$probe_jar" "$launcher" \
    "root@$kindle_ip:/tmp/"
ssh "${ssh_options[@]}" "root@$kindle_ip" '
    set -eu
    framework_pid="$(ps -eo pid,args | awk '\''/ch.ethz.iks.concierge.framework.Framework/ && !/awk/ { print $1; exit }'\'')"
    case "$framework_pid" in ""|*[!0-9]*) exit 5 ;; esac
    rm -f /tmp/goodreads-background-capabilities.log
    /usr/java/bin/java --add-modules jdk.attach -cp /tmp \
        AttachLauncher "$framework_pid" \
        /tmp/background-annotation-capability-v1.jar readonly
    attempt=0
    while [ "$attempt" -lt 10 ] && [ ! -s /tmp/goodreads-background-capabilities.log ]; do
        attempt=$((attempt + 1))
        sleep 1
    done
    grep -E '\''^(probe_version|instrumentation_present|reader_sdk_present|journaling_service_present|whispersync_service_present|journal_book_factory_present|journal_entry_factory_present|reader_active_book_method_present|native_book_active|ksdk_enabled|whisperstore_enabled|mutation_attempted|probe_ok|error_class)='\'' \
        /tmp/goodreads-background-capabilities.log
    rm -f /tmp/background-annotation-capability-v1.jar \
        /tmp/AttachLauncher.class \
        /tmp/goodreads-background-capabilities.log
'
