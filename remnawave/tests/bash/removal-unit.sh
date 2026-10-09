#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-remove.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_OUT=$TEST_ROOT/install; RW_MUTATING=0
rw_config_load "$ROOT/installer/examples/panel-node.json"
rw_lock; rw_manifest preparing; rw_render; rw_manifest_set '.status="prepared"'; rw_track_files
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail_expected() { if ( "$@" ) > "$RW_TMP/rejection" 2>&1; then printf 'Expected rejection\n' >&2; exit 1; fi; }
ufw() {
    if [[ $* == 'show added' ]]; then
        printf "Added user rules:\nufw allow 9443/tcp comment '%s'\nufw allow from 2001:db8::1 to any port 2222 proto tcp comment '%s'\nufw allow 443/tcp comment '%s-other'\nufw allow 22/tcp comment 'foreign'\n" "$RW_PROJECT" "$RW_PROJECT" "$RW_PROJECT"
    else printf '%s\n' "$*" >> "$RW_TMP/deleted-rules"; fi
}
rw_security_remove_rules
[[ $(wc -l < "$RW_TMP/deleted-rules") == 2 ]]
grep -qx -- '--force delete allow 9443/tcp' "$RW_TMP/deleted-rules"
grep -qx -- '--force delete allow from 2001:db8::1 to any port 2222 proto tcp' "$RW_TMP/deleted-rules"
passed 'stored UFW rules removed exactly by owner; IPv6 and similarly named foreign rules preserved'
ufw() { if [[ $* == 'show added' ]]; then printf "ufw allow 9443/tcp comment '%s'\nufw allow 9999/tcp; touch /tmp/unsafe comment '%s'\n" "$RW_PROJECT" "$RW_PROJECT"; else touch "$RW_TMP/changed"; fi; }
fail_expected rw_security_remove_rules
[[ ! -f $RW_TMP/changed ]]
unset -f ufw
passed 'unknown rule shape blocks all removals before executing any text'
jq -n '{status:"armed"}' | rw_atomic "$RW_OUT/private/ssh-state.json"; rw_track_files
RW_PREPARED_ONLY=1; RW_PURGE=0; RW_DRY_RUN=0; RW_YES=1
fail_expected rw_uninstall
[[ -f $RW_OUT/manifest.json ]]
rw_managed_remove private/ssh-state.json
passed 'armed SSH blocks deletion'
cp "$RW_OUT/site/index.html" "$RW_TMP/site-before"
printf 'external edit\n' >> "$RW_OUT/site/index.html"
fail_expected rw_uninstall
[[ -f $RW_OUT/manifest.json ]]
cp "$RW_TMP/site-before" "$RW_OUT/site/index.html"
passed 'changed managed file blocks deletion without removing the installation'
docker() { case $1 in volume) return 1;; *) touch "$RW_TMP/mutation";; esac; }
fail_expected rw_resource_plan volume
[[ ! -f $RW_TMP/mutation ]]
unset -f docker
passed 'resource listing failure is rejected rather than treated as an empty list'
for conflict in container network volume; do
    (
        RW_PREPARED_ONLY=0
        docker() {
            case $1 in
                info) return 0;;
                ps) printf 'container-one\n'; [[ $conflict != container || ! -f $RW_TMP/after-confirm ]] || printf 'container-two\n';;
                network|volume) printf '%s-one\n' "$1"; [[ $conflict != "$1" || ! -f $RW_TMP/after-confirm ]] || printf '%s-two\n' "$1";;
                inspect)
                    if [[ $* == *'.Config.Labels'* ]]; then
                        for id in "${@:4}"; do
                            jq -nc --arg owner "$RW_OWNER" --arg project "$RW_PROJECT" --arg config "$RW_OUT/compose.json" '{"io.pdm.remnawave.installation":$owner,"com.docker.compose.project":$project,"com.docker.compose.project.config_files":$config}'
                        done
                    else
                        for id in "${@:6}"; do jq -nc --arg owner "$RW_OWNER" '{"io.pdm.remnawave.installation":$owner}'; done
                    fi;;
                *) touch "$RW_TMP/mutation";;
            esac
        }
        rw_lock() { touch "$RW_TMP/after-confirm"; }
        rm -f "$RW_TMP/after-confirm" "$RW_TMP/mutation"
        fail_expected rw_uninstall
        grep -q 'inventory changed after confirmation' "$RW_TMP/rejection"
        [[ ! -f $RW_TMP/mutation && -f $RW_OUT/manifest.json ]]
    )
    passed "$conflict inventory race blocks removal"
done
printf '%s removal checks passed.\n' "$count"
