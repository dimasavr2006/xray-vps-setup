#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-opt.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_OUT=$TEST_ROOT/install; RW_MUTATING=0
rw_config_load "$ROOT/installer/examples/panel-node.json"
rw_lock; rw_manifest preparing; rw_render
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail_expected() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected rejection\n' >&2; exit 1; fi; }
printf 'operator data\n' > "$RW_OUT/operator.txt"
printf 'managed data\n' > "$RW_OUT/private/with space.txt"
printf 'private/with space.txt\n' > "$RW_OUT/private/.managed-paths"
ln -s "$RW_OUT/operator.txt" "$RW_OUT/private/link"
printf 'private/link\n../foreign\n' >> "$RW_OUT/private/.managed-paths"
rw_track_files
jq -e 'all(.managed_files[]; .path!="operator.txt" and .path!="private/link" and .path!="../foreign") and any(.managed_files[]; .path=="private/with space.txt")' "$RW_OUT/manifest.json" >/dev/null
while IFS=$'\t' read -r file sum; do [[ $(sha256sum "$RW_OUT/$file" | cut -d' ' -f1) == "$sum" ]]; done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$RW_OUT/manifest.json")
passed 'batched hashes match each file; unknown files and symlinks stay unmanaged'
rw_verify_files
printf 'tampered\n' >> "$RW_OUT/private/with space.txt"
fail_expected rw_verify_files
passed 'batched tracking retains tamper detection'
ln -s "$RW_OUT/private" "$TEST_ROOT/linked-parent"
fail_expected rw_safe_parents "$TEST_ROOT/linked-parent/child"
(cd "$TEST_ROOT"; rw_safe_parents relative/path/file; rw_safe_parents file)
passed 'parent traversal supports relative paths and still rejects symlinks'
docker() {
    case $1 in
        ps) printf 'one\ntwo\n';;
        inspect) jq -nc --arg owner "$RW_OWNER" --arg project "$RW_PROJECT" --arg config "$RW_OUT/compose.json" '{"io.pdm.remnawave.installation":$owner,"com.docker.compose.project":$project,"com.docker.compose.project.config_files":$config}' | tee "$RW_TMP/labels"; cat "$RW_TMP/labels";;
        *) return 1;;
    esac
}
rw_docker_ownership
passed 'batched ownership accepts every correctly labelled container'
docker() { case $1 in ps) printf 'one\ntwo\n';; inspect) printf '{}\n{}\n';; esac; }
fail_expected rw_docker_ownership
docker() { return 1; }
fail_expected rw_docker_ownership
docker() { case $1 in ps) printf 'one\n';; inspect) return 1;; esac; }
fail_expected rw_docker_ownership
unset -f docker
passed 'foreign ownership and Docker listing or inspection failures block execution'
RW_OUT=$TEST_ROOT/dns; rw_config_load "$ROOT/installer/examples/fi-compact-single-domain.json"
# Use the normalized fixture address, not any external DNS server.
fixture_ip=$(jq -r '.public_addresses[0]' "$RW_CFG")
dig() { printf '%s\n' "${*: -1}" >> "$RW_TMP/dns-calls"; printf ';; status: NOERROR\n'; [[ ${*: -1} != A ]] || printf 'fi.example.com. 300 IN A %s\n' "$fixture_ip"; }
rw_dns_checks
[[ $(wc -l < "$RW_TMP/dns-calls") == 2 ]]
passed 'shared panel/subscription/node hostname needs exactly one A and AAAA lookup'
dig() { printf ';; status: SERVFAIL\n'; }
fail_expected rw_dns_checks
unset -f dig
passed 'failed DNS answers still stop installation'
docker() { :; }
ss() { printf 'called\n' >> "$RW_TMP/ss-calls"; }
rw_port_checks
[[ $(wc -l < "$RW_TMP/ss-calls") == 1 ]]
ss() { return 1; }
fail_expected rw_port_checks
unset -f docker ss
passed 'port checks use one listener snapshot and reject capture failures'
apt-get() { printf '%s\n' "$*" >> "$RW_TMP/apt-calls"; }
RW_APT_UPDATED=0; rw_apt_update; rw_apt_update
[[ $(wc -l < "$RW_TMP/apt-calls") == 1 ]]
RW_APT_UPDATED=0; rw_apt_update
[[ $(wc -l < "$RW_TMP/apt-calls") == 2 ]]
unset -f apt-get
passed 'APT refresh is reused until repository changes invalidate it'
ip() { printf '[]\n'; }
curl() {
    local family=${1#-} peer=4 attempt
    [[ $family != 4 ]] || peer=6
    touch "$RW_TMP/probe-$family"
    for attempt in {1..100}; do [[ ! -f $RW_TMP/probe-$peer ]] || break; sleep 0.01; done
    [[ -f $RW_TMP/probe-$peer ]] || return 1
    if [[ $family == 4 ]]; then printf '203.0.113.20'; else printf '2001:db8::20'; fi
}
rw_detect_addresses > "$RW_TMP/parallel-addresses.json"
jq -e 'length==2 and index("203.0.113.20")!=null' "$RW_TMP/parallel-addresses.json" >/dev/null
unset -f ip curl
passed 'IPv4/IPv6 probes overlap and join responses without trailing newlines safely'
(
    rw_os() { :; }
    rw_resource_checks() { printf 'resource\n' >> "$RW_TMP/preflight-calls"; }
    rw_dns_checks() { printf 'dns\n' >> "$RW_TMP/preflight-calls"; }
    rw_docker_ownership() { :; }
    rw_port_checks() { :; }
    rw_network_check() { :; }
    timedatectl() { printf 'yes\n'; }
    nft() { :; }
    RW_MODE=clean; RW_DOCKER_INSTALLED=0
    : > "$RW_TMP/preflight-calls"
    rw_preflight --host-checked >/dev/null 2>&1
    [[ ! -s $RW_TMP/preflight-calls ]]
    RW_DOCKER_INSTALLED=1
    rw_preflight --host-checked >/dev/null 2>&1
    [[ $(cat "$RW_TMP/preflight-calls") == resource ]]
    : > "$RW_TMP/preflight-calls"
    rw_preflight >/dev/null 2>&1
    [[ $(cat "$RW_TMP/preflight-calls") == $'resource\ndns' ]]
)
passed 'fresh Docker installation rechecks RAM; standalone preflight retains all host checks'
(
    RW_APT_UPDATED=0
    apt-get() { return 1; }
    fail_expected rw_apt_update
)
passed 'failed APT refresh cannot be treated as a successful cached update'
printf '%s optimization checks passed.\n' "$count"
