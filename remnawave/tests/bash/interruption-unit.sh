#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-interrupt.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_OUT=$TEST_ROOT/fixture; rw_config_load "$ROOT/installer/examples/panel.json"
rw_lock; rw_manifest preparing; rw_render; rw_track_files
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
for phase in before-rename after-rename after-manifest; do
    printf 'before\n' | rw_atomic "$RW_OUT/private/probe.txt"
    (
        crash_pid=$BASHPID
        rw_resume_writes() {
            if [[ $phase == after-rename || $phase == after-manifest ]]; then
                temp=$(jq -r '.temp' "$RW_OUT/.rw-write.json")
                mv "$RW_OUT/$temp" "$RW_OUT/private/probe.txt"
            fi
            if [[ $phase == after-manifest ]]; then
                hash=$(sha256sum "$RW_OUT/private/probe.txt" | cut -d' ' -f1)
                jq --arg hash "$hash" '.managed_files|=map(if .path=="private/probe.txt" then .sha256=$hash else . end)' "$RW_OUT/manifest.json" | rw_plain_atomic "$RW_OUT/manifest.json"
            fi
            kill -KILL "$crash_pid"
        }
        printf 'after\n' | rw_atomic "$RW_OUT/private/probe.txt"
    ) >/dev/null 2>&1 && exit 1
    rw_resume_writes; rw_verify_files
    [[ $(cat "$RW_OUT/private/probe.txt") == after && ! -e $RW_OUT/.rw-write.json ]]
    passed "SIGKILL recovery $phase"
done
printf 'expected\n' | rw_atomic "$RW_OUT/private/probe.txt"
(
    crash_pid=$BASHPID
    rw_resume_writes() { kill -KILL "$crash_pid"; }
    printf 'candidate\n' | rw_atomic "$RW_OUT/private/probe.txt"
) >/dev/null 2>&1 && exit 1
printf 'foreign\n' > "$RW_OUT/private/probe.txt"
if (rw_resume_writes) >/dev/null 2>&1; then exit 1; fi
[[ $(cat "$RW_OUT/private/probe.txt") == foreign ]]
passed 'recovery rejects an external file change'
printf 'expected\n' > "$RW_OUT/private/probe.txt"; rw_resume_writes; rw_verify_files
rw_write_begin "$RW_OUT/private/probe.txt"
rm "$RW_OUT/private/probe.txt"
rw_resume_writes; rw_verify_files
passed 'interrupted managed deletion recovers'
rw_choose_public_addresses() { printf '["192.0.2.20"]\n'; }
rw_interactive < <(printf '3\nci-wizard\n2\nfi.example.com\n\nowner\nowner@example.com\n\n/opt/old/Caddyfile\ncaddy\nhttps://fi.example.com\n\n')
RW_OUT=$TEST_ROOT/wizard; rw_config_load "$RW_CONFIG"
jq -e '.domains.panel==.domains.subscription and .domains.node==.domains.panel and .resources.profile=="compact-test" and .existing_caddy.container=="caddy" and .ports.subscription_https==9444' "$RW_CFG" >/dev/null
passed 'interactive parallel install collects full config and defaults to one domain'
printf '{"users":[{"username":"owner","mfa_tokens":[{"type":"totp","disabled":true}]}]}' > "$RW_TMP/mfa.json"
rw_mfa_summary owner "$RW_TMP/mfa.json" | jq -e '.owner_action_required' >/dev/null
printf '{"users":[{"username":"owner","mfa_tokens":[{"type":"totp"}]}]}' > "$RW_TMP/mfa.json"
rw_mfa_summary owner "$RW_TMP/mfa.json" | jq -e '.authenticator_enrolled' >/dev/null
passed 'MFA status distinguishes active TOTP from disabled enrollment'
printf '%s interruption/wizard/MFA checks passed.\n' "$count"
