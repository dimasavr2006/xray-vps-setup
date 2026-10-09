#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fixture() {
    exec 9>&-; RW_LOCK_DIR=
    RW_OUT=$RW_TMP/$1
    rw_config_load "$2"
    rw_manifest preparing; rw_render
    jq '.auth_password="ci-auth-only-sentinel"|.reality_private="ci-reality-private-sentinel"|.postgres_password="ci-database-only-sentinel"' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/secrets.json"
    if [[ $RW_ROLE != node ]]; then
        jq '.password="ci-panel-only-sentinel"' "$RW_OUT/private/admin.json" | rw_atomic "$RW_OUT/private/admin.json"
    fi
    rw_track_files
}
fixture combined "$ROOT/installer/examples/panel-node.json"
rw_manifest_set '.status="running-awaiting-acceptance"'
rw_install_summary > "$RW_TMP/public-summary.txt"
grep -q 'Panel URL: https://panel.example.com:9443/' "$RW_TMP/public-summary.txt"
grep -q 'MFA login URL: https://panel.example.com:9443/r' "$RW_TMP/public-summary.txt"
grep -q 'Subscription base URL: https://sub.example.com:9443/' "$RW_TMP/public-summary.txt"
grep -q 'Cover URL: https://node.example.com/' "$RW_TMP/public-summary.txt"
! grep -q 'ci-.*sentinel' "$RW_TMP/public-summary.txt"
passed 'combined summary uses actual ports and keeps private values out of redirected output'
grep -q 'Saved Remnawave password: ci-panel-only-sentinel' "$RW_OUT/private/install-info.txt"
grep -q 'Saved Caddy Auth password: ci-auth-only-sentinel' "$RW_OUT/private/install-info.txt"
! grep -q 'ci-reality-private-sentinel\|ci-database-only-sentinel' "$RW_OUT/private/install-info.txt"
[[ $(stat -c %a "$RW_OUT/private/install-info.txt") == 600 && $(stat -c %a "$RW_OUT/private") == 700 ]]
rw_verify_files
passed 'root-only access card contains login passwords but excludes database and private Reality keys'
before=$(sha256sum "$RW_OUT/manifest.json")
RW_SHOW_SECRETS=0; rw_show_summary > "$RW_TMP/info.txt"
[[ $before == "$(sha256sum "$RW_OUT/manifest.json")" ]]
if bash "$RW_OUT/rwctl" info --show-secrets > "$RW_TMP/rejected.txt" 2>&1; then exit 1; fi
! grep -q 'ci-.*sentinel' "$RW_TMP/rejected.txt"
passed 'info is read-only and explicit password display rejects a redirected terminal'
printf '%s\n' "source <(sed '\$d' '$ROOT/rwctl')" 'rw_init_tmp' "RW_OUT='$RW_OUT'" 'rw_config_load "$RW_OUT/config.json"' 'rw_install_summary' > "$RW_TMP/terminal-test.sh"
script -qec "bash '$RW_TMP/terminal-test.sh'" /dev/null > "$RW_TMP/terminal.txt"
grep -q 'Saved Remnawave password: ci-panel-only-sentinel' "$RW_TMP/terminal.txt"
grep -q 'Saved Caddy Auth password: ci-auth-only-sentinel' "$RW_TMP/terminal.txt"
script -qec "bash '$RW_OUT/rwctl' info --show-secrets" /dev/null > "$RW_TMP/explicit-terminal.txt"
grep -q 'Saved Remnawave password: ci-panel-only-sentinel' "$RW_TMP/explicit-terminal.txt"
passed 'installation and explicit info show separate owner passwords in a real terminal'
fixture shared "$ROOT/installer/examples/fi-compact-single-domain.json"
rw_summary_render 0 > "$RW_TMP/shared.txt"
grep -q 'Panel URL: https://fi.example.com:9443/' "$RW_TMP/shared.txt"
grep -q 'Subscription base URL: https://fi.example.com:9444/' "$RW_TMP/shared.txt"
grep -q 'Cover URL: https://fi.example.com:24443/' "$RW_TMP/shared.txt"
passed 'single-hostname FI card distinguishes all actual public ports'
fixture panel "$ROOT/installer/examples/panel.json"
rw_summary_render 0 > "$RW_TMP/panel.txt"
grep -q 'Panel URL: https://panel.example.com/' "$RW_TMP/panel.txt"
! grep -q 'Reality public key:\|Cover URL:\|Node management port:' "$RW_TMP/panel.txt"
passed 'panel-only card has no fabricated local-node details'
jq '.ports={node_api:32222}|.management_address="2001:db8::20"' "$ROOT/installer/examples/node.json" > "$RW_TMP/custom-node.json"
fixture node "$RW_TMP/custom-node.json"
rw_manifest_set '.status="node-prepared-awaiting-attachment"'
rw_install_summary > "$RW_TMP/node.txt"
grep -q 'Node management port: TCP 32222 (panel -> node)' "$RW_TMP/node.txt"
grep -q 'Planned cover URL: https://node.example.com/' "$RW_TMP/node.txt"
grep -q 'node attach --ssh root@2001:db8:' "$RW_TMP/node.txt"
grep -Fq 'root@\[2001:db8:' "$RW_TMP/node.txt"
! grep -q 'Remnawave password:\|Caddy Auth password:\|Panel URL:\|Health check:' "$RW_TMP/node.txt"
passed 'prepared node reports actual management port, IPv6-safe copy and attachment rather than a running service'
rw_manifest_set '.status="running-awaiting-acceptance"'
rw_install_summary > "$RW_TMP/attached.txt"
! grep -q 'Planned cover URL:' "$RW_TMP/attached.txt"
grep -q 'Health check:' "$RW_TMP/attached.txt"
rw_verify_files
passed 'attached-node card changes state and remains tracked for backup and scoped removal'
printf '%s installation-summary checks passed.\n' "$count"
