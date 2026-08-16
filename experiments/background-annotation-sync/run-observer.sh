#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 7 || "$7" != "--read-only" ]]; then
    printf 'usage: %s IP PORT ASIN NATIVE_PATH START END --read-only\n' "$0" >&2
    exit 2
fi
kindle_ip="$1"; kindle_port="$2"; asin="$3"; native_path="$4"
start_long="$5"; end_long="$6"
[[ "$kindle_ip" != *[!0-9A-Fa-f:.]* && "$kindle_port" =~ ^[0-9]+$ \
    && "$asin" =~ ^B[A-Z0-9]{9}$ \
    && "$native_path" == /mnt/us/documents/*.kfx \
    && "$start_long" =~ ^A[A-Za-z0-9+/]{11}$ \
    && "$end_long" =~ ^A[A-Za-z0-9+/]{11}$ ]] || { printf 'invalid input\n' >&2; exit 2; }

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
jar="$project_root/agent/build/experiments/background-annotation-observer-v1.jar"
launcher="$project_root/goodreads.koplugin/bin/classes/AttachLauncher.class"
request_id="$(date +%s)$$"; payload="$(mktemp)"; trap 'rm -f "$payload"' EXIT
chmod 0600 "$payload"
path_hex="$(printf '%s' "$native_path" | od -An -tx1 | tr -d ' \n')"
printf 'version=1\nrequest_id=%s\nasin=%s\nnative_path_hex=%s\nstart=%s\nend=%s\n' \
    "$request_id" "$asin" "$path_hex" "$start_long" "$end_long" >"$payload"
remote_payload="/tmp/goodreads-background-observer-$request_id.properties"
scp -P "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new "$jar" "$launcher" "$payload" \
    "root@$kindle_ip:/tmp/"
ssh -p "$kindle_port" -o BatchMode=yes -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new "root@$kindle_ip" \
    "mv /tmp/$(basename "$payload") '$remote_payload'; \
    pid=\$(ps -eo pid,args | awk '/ch.ethz.iks.concierge.framework.Framework/ && !/awk/ {print \$1; exit}'); \
    uid=\$(awk '/^Uid:/ {print \$2; exit}' /proc/\$pid/status); gid=\$(awk '/^Gid:/ {print \$2; exit}' /proc/\$pid/status); \
    chown \"\$uid:\$gid\" '$remote_payload'; chmod 0600 '$remote_payload'; \
    result='/tmp/goodreads-background-observer-result-$request_id.log'; rm -f \"\$result\"; \
    /usr/java/bin/java --add-modules jdk.attach -cp /tmp AttachLauncher \"\$pid\" /tmp/background-annotation-observer-v1.jar '$remote_payload'; \
    attempt=0; while [ \"\$attempt\" -lt 15 ] && [ ! -s \"\$result\" ]; do attempt=\$((attempt+1)); sleep 1; done; \
    grep -E '^(request_id|native_book_active|exact_book_active|native_highlights|native_notes|canary_matches|canary_present|mutation_attempted|success|failed_stage|error_class)=' \"\$result\"; \
    ok=1; grep -Fqx 'success=true' \"\$result\" || ok=0; rm -f '$remote_payload' \"\$result\" /tmp/background-annotation-observer-v1.jar; [ \"\$ok\" -eq 1 ]"
