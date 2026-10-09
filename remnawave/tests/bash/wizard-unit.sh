#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2218
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-wizard.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_OUT=$TEST_ROOT/install
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
ip() { printf '[{"ifname":"eth0","addr_info":[{"scope":"global","local":"203.0.113.20"},{"scope":"global","local":"10.0.0.1"},{"scope":"global","local":"2001:db8::20"},{"scope":"global","local":"fd00::1"}]},{"ifname":"docker0","addr_info":[{"scope":"global","local":"172.17.0.1"}]}]\n'; }
curl() { case $1 in -4) printf '203.0.113.20\n';; -6) return 1;; *) exit 1;; esac; }
dig() {
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR\n'
    [[ ${*: -1} != A ]] || printf 'node.example.com. 300 IN A 203.0.113.20\n'
}
rw_detect_addresses > "$RW_TMP/detected.json"
jq -e '.==["2001:0db8:0000:0000:0000:0000:0000:0020","203.0.113.20"]' "$RW_TMP/detected.json" >/dev/null
passed 'detection excludes private, ULA and Docker addresses; failed IPv6 echo is optional'
rw_choose_public_addresses node.example.com < <(printf '\n') > "$RW_TMP/selected.json"
jq -e '.==["203.0.113.20"]' "$RW_TMP/selected.json" >/dev/null
passed 'verified DNS subset avoids requiring unused IPv6'
rw_choose_public_addresses node.example.com < <(printf 'n\nnot-an-ip\n203.0.113.21\n') > "$RW_TMP/selected.json"
jq -e '.==["203.0.113.21"]' "$RW_TMP/selected.json" >/dev/null
passed 'operator can reject detection and correct invalid manual input'
dig() { printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR\n'; [[ ${*: -1} != A ]] || printf 'node.example.com. 300 IN A 198.51.100.90\n'; }
rw_choose_public_addresses node.example.com < <(printf '\n') > "$RW_TMP/selected.json"
! jq -e 'index("198.51.100.90")!=null' "$RW_TMP/selected.json" >/dev/null
passed 'wrong DNS never replaces independently detected server addresses'
ip() { printf '[]\n'; }; curl() { return 1; }
rw_choose_public_addresses node.example.com < <(printf '203.0.113.20\n') > "$RW_TMP/selected.json"
jq -e '.==["203.0.113.20"]' "$RW_TMP/selected.json" >/dev/null
passed 'unavailable discovery requires manual input rather than trusting DNS alone'
rw_choose_panel_addresses < <(printf 'panel.example.com\n\n') > "$RW_TMP/selected.json"
jq -e '.==["198.51.100.90"]' "$RW_TMP/selected.json" >/dev/null
passed 'panel domain resolves to a separately confirmed management allowlist'
rw_choose_public_addresses() { printf '["203.0.113.20"]\n'; }
rw_choose_panel_addresses() { printf '["198.51.100.10"]\n'; }
RW_ROLE_ARG=
rw_root_key_present() { return 0; }
rw_interactive < <(printf '2\n\n1\nnode.example.com\n\n')
rw_config_load "$RW_CONFIG"
jq -e '.environment_id=="node-main" and .role=="node" and .panel_addresses==["198.51.100.10"] and .resources.purpose=="production"' "$RW_CFG" >/dev/null
passed 'standalone node wizard defaults to a meaningful name and production purpose'
rw_manifest preparing; rw_render; rw_track_files
grep -q '<html lang="en">' "$RW_OUT/site/index.html"
grep -q 'Log in to Confluence' "$RW_OUT/site/index.html"
! grep -q ' name="password"' "$RW_OUT/site/index.html"
passed 'default cover is the English static Confluence page'
RW_SITE_TEMPLATE=simple; RW_SITE_FILE=; RW_DRY_RUN=1
before=$(sha256sum "$RW_OUT/site/index.html")
rw_site_set > "$RW_TMP/preview.json"
[[ $before == "$(sha256sum "$RW_OUT/site/index.html")" ]]
RW_DRY_RUN=0; rw_site_set
grep -q 'Service online' "$RW_OUT/site/index.html"
rw_render
grep -q 'Service online' "$RW_OUT/site/index.html"
rw_verify_files
passed 'cover preview is read-only and rerender preserves a customized cover'
RW_SITE_TEMPLATE=confluence; rw_site_set
grep -q 'Log in to Confluence' "$RW_OUT/site/index.html"
RW_COMPONENT=node; RW_VERSION_FILE=$RW_TMP/candidate.json
jq '.components.node.image="remnawave/node@sha256:"+("a"*64)|.components.panel.image="remnawave/backend@sha256:"+("b"*64)' "$RW_OUT/versions.lock.json" > "$RW_VERSION_FILE"
rw_upgrade_candidate
jq -e --slurpfile old "$RW_OUT/versions.lock.json" '.components.panel==$old[0].components.panel and .components.caddy_auth==$old[0].components.caddy_auth and (.components.node.image|endswith("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))' "$RW_TMP/upgrade-lock.json" >/dev/null
passed 'node component selection cannot change panel or Caddy images'
RW_COMPONENT=panel
if (rw_upgrade_candidate) >/dev/null 2>&1; then exit 1; fi
passed 'standalone node rejects panel-only upgrade'
printf '%s wizard/cover/component checks passed.\n' "$count"
