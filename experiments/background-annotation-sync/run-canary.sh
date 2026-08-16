#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -lt 9 || "$#" -gt 10 ]]; then
    printf 'usage: %s MODE IP PORT ASIN NATIVE_PATH START START_SHORT END END_SHORT [--confirm-background-write]\n' "$0" >&2
    exit 2
fi

mode="$1"
kindle_ip="$2"
kindle_port="$3"
asin="$4"
native_path="$5"
start_long="$6"
start_short="$7"
end_long="$8"
end_short="$9"
confirmation="${10:-}"

case "$mode" in validate|status) ;; create|delete)
    [[ "$confirmation" == "--confirm-background-write" ]] || {
        printf 'create/delete requires --confirm-background-write\n' >&2
        exit 2
    } ;;
    *) printf 'invalid mode\n' >&2; exit 2 ;;
esac
[[ "$kindle_ip" != *[!0-9A-Fa-f:.]* ]] || { printf 'invalid IP\n' >&2; exit 2; }
[[ "$kindle_port" =~ ^[0-9]+$ ]] || { printf 'invalid port\n' >&2; exit 2; }
[[ "$asin" =~ ^B[A-Z0-9]{9}$ ]] || { printf 'invalid ASIN\n' >&2; exit 2; }
[[ "$native_path" == /mnt/us/documents/*.kfx ]] || { printf 'invalid native path\n' >&2; exit 2; }
[[ "$start_long" =~ ^A[A-Za-z0-9+/]{11}$ ]] || { printf 'invalid start\n' >&2; exit 2; }
[[ "$end_long" =~ ^A[A-Za-z0-9+/]{11}$ ]] || { printf 'invalid end\n' >&2; exit 2; }
[[ "$start_short" =~ ^[0-9]+$ && "$end_short" =~ ^[0-9]+$ ]] \
    || { printf 'invalid short position\n' >&2; exit 2; }

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
canary_jar="$project_root/agent/build/experiments/background-annotation-canary-v1.jar"
launcher="$project_root/goodreads.koplugin/bin/classes/AttachLauncher.class"
request_id="$(date +%s)$$"
payload="$(mktemp)"
remote_payload="/tmp/goodreads-background-canary-$request_id.properties"
trap 'rm -f "$payload"' EXIT
chmod 0600 "$payload"
native_path_hex="$(printf '%s' "$native_path" | od -An -tx1 | tr -d ' \n')"
{
    printf 'version=1\nrequest_id=%s\nmode=%s\nasin=%s\n' \
        "$request_id" "$mode" "$asin"
    printf 'native_path_hex=%s\nstart=%s\nstart_short=%s\n' \
        "$native_path_hex" "$start_long" "$start_short"
    printf 'end=%s\nend_short=%s\n' "$end_long" "$end_short"
    if [[ "$mode" == "create" || "$mode" == "delete" ]]; then
        printf 'confirm=BACKGROUND_CANARY_V1\n'
    fi
} >"$payload"

ssh_options=(-p "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new)
scp_options=(-P "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new)
scp "${scp_options[@]}" "$canary_jar" "$launcher" \
    "$payload" "root@$kindle_ip:/tmp/"
ssh "${ssh_options[@]}" "root@$kindle_ip" \
    "mv /tmp/$(basename "$payload") '$remote_payload'; \
    framework_pid=\$(ps -eo pid,args | awk '/ch.ethz.iks.concierge.framework.Framework/ && !/awk/ { print \$1; exit }'); \
    case \"\$framework_pid\" in ''|*[!0-9]*) exit 5;; esac; \
    framework_uid=\$(awk '/^Uid:/ { print \$2; exit }' /proc/\$framework_pid/status); \
    framework_gid=\$(awk '/^Gid:/ { print \$2; exit }' /proc/\$framework_pid/status); \
    chown \"\$framework_uid:\$framework_gid\" '$remote_payload'; chmod 0600 '$remote_payload'; \
    if [ '$mode' = create ] || [ '$mode' = delete ]; then \
      lipc-set-prop com.lab126.CVMShadowModeManager KPPACShadowModeManagerShouldSyncLegacySidecarAndJournal 1 >/dev/null; \
      lipc-set-prop com.lab126.CVMShadowModeManager KPPACShadowModeManagerShouldSyncKSDKAnnotations 1 >/dev/null; \
    fi; \
    rm -f '/tmp/goodreads-background-canary-result-$request_id.log'; \
    /usr/java/bin/java --add-modules jdk.attach -cp /tmp AttachLauncher \"\$framework_pid\" \
      /tmp/background-annotation-canary-v1.jar '$remote_payload'; \
    attempt=0; while [ \"\$attempt\" -lt 15 ] && [ ! -s '/tmp/goodreads-background-canary-result-$request_id.log' ]; do attempt=\$((attempt+1)); sleep 1; done; \
    result='/tmp/goodreads-background-canary-result-$request_id.log'; \
    if grep -Fqx 'success=true' \"\$result\" && { [ '$mode' = create ] || [ '$mode' = delete ]; }; then \
      lipc-set-prop com.lab126.KPPAnnotationController KSDKAnnotationsEnqueueForSync background-canary >/dev/null; \
      lipc-set-prop com.lab126.whispersync startSync background-canary >/dev/null; \
      printf '%s\\n' 'shell_enqueue=true' >>\"\$result\"; \
    fi; \
    grep -E '^(request_id|mode|native_book_active|canary_state_present|detached_book_opened|position_verified|journal_entry_accepted|upload_requested|local_manager_mutated|mutation_attempted|shell_enqueue|success|failed_stage|error_class)=' \"\$result\"; \
    success=1; grep -Fqx 'success=true' \"\$result\" || success=0; \
    rm -f '$remote_payload' \"\$result\"; \
    if [ '$mode' = delete ] && [ \"\$success\" -eq 1 ]; then rm -f /tmp/background-annotation-canary-v1.jar /tmp/AttachLauncher.class; fi; \
    [ \"\$success\" -eq 1 ]"
