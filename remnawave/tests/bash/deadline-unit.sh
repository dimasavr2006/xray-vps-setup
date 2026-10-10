#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-deadline.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT; RW_API_ROOT=http://127.0.0.1:39099
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail_expected() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected failure\n' >&2; exit 1; fi; }
rw_port() { printf '39099\n'; }
curl() {
    local arg previous='' max=''
    for arg in "$@"; do [[ $previous != --max-time ]] || max=$arg; previous=$arg; done
    printf '%s\n' "$max" >> "$RW_TMP/timeouts"
    return 1
}
start=$SECONDS; fail_expected rw_wait_panel 2
(( SECONDS-start<=3 ))
awk '$1<1 || $1>2 {exit 1}' "$RW_TMP/timeouts"
passed 'panel readiness retries remain inside one total deadline'
: > "$RW_TMP/timeouts"
start=$SECONDS; fail_expected rw_wait_node fixture "$RW_TMP/node.json" 2
(( SECONDS-start<=3 ))
awk '$1<1 || $1>2 {exit 1}' "$RW_TMP/timeouts"
passed 'node readiness retries remain inside one total deadline'
: > "$RW_TMP/timeouts"
rw_api POST /api/fixture '' "$RW_TMP/response.json" || true
[[ $(cat "$RW_TMP/timeouts") == 30 ]]
passed 'readiness timeout scope does not shorten later mutating API requests'
rw_api() { printf '{"response":{"isConnected":true,"isDisabled":false,"xrayUptime":1}}' > "$4"; }
rw_wait_node fixture "$RW_TMP/node.json" 1
rw_wait_panel 1
passed 'already ready services return without sleeping'
rw_api() { printf '{"response":{"isConnected":true,"isDisabled":true,"xrayUptime":1}}' > "$4"; }
fail_expected rw_wait_node fixture "$RW_TMP/node.json" 1
passed 'disabled or disconnected node cannot pass readiness'
RW_PROJECT=fixture; RW_OUT=$TEST_ROOT
timeout() { printf '%s\n' "$*" > "$RW_TMP/pull-command"; return 124; }
fail_expected rw_pull
grep -q '^--foreground 900 docker compose .* pull --policy missing$' "$RW_TMP/pull-command"
passed 'pull timeout is bounded and remains a failing result'
printf '%s deadline checks passed.\n' "$count"
