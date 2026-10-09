#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-tokens.XXXXXX)
trap 'rm -rf -- "${TEST_ROOT:?}"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_OUT=$TEST_ROOT/fixture; rw_config_load "$ROOT/installer/examples/panel.json"
rw_lock; rw_manifest preparing; rw_render
rw_panel_login() { :; }
rw_token_catalog() { cp "$TEST_ROOT/catalog.json" "$RW_TMP/tokens.json"; }
rw_api() { touch "$TEST_ROOT/unexpected-mutation"; return 1; }
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
printf '["nodes:list"]' > "$RW_TMP/scopes.json"
uuid=11111111-1111-4111-8111-111111111111
rw_manifest_set '.tokens.installer={uuid:$uuid,name:$name,scopes:["nodes:list"],expires_at:0}' --arg uuid "$uuid" --arg name "installer-${RW_OWNER:0:8}"
printf 'synthetic-token\n' | rw_atomic "$RW_OUT/private/installer.token"
jq -n --arg uuid "$uuid" '{response:{tokens:[{uuid:$uuid,name:"foreign",scopes:["nodes:list"]}]}}' > "$TEST_ROOT/catalog.json"
if (rw_token_replace installer "$RW_TMP/scopes.json") >/dev/null 2>&1; then exit 1; fi
[[ ! -e $TEST_ROOT/unexpected-mutation ]]
passed 'foreign token UUID/name blocks before any API mutation'
jq -n --arg uuid "$uuid" --arg name "installer-${RW_OWNER:0:8}" '{response:{tokens:[{uuid:$uuid,name:$name,scopes:["users:create"]}]}}' > "$TEST_ROOT/catalog.json"
if (rw_token_replace installer "$RW_TMP/scopes.json") >/dev/null 2>&1; then exit 1; fi
[[ ! -e $TEST_ROOT/unexpected-mutation ]]
passed 'changed old token scopes block before revocation'
rw_manifest_set 'del(.tokens.installer) | .token_intents.installer=true'
if (rw_token_replace installer "$RW_TMP/scopes.json") >/dev/null 2>&1; then exit 1; fi
[[ ! -e $TEST_ROOT/unexpected-mutation ]]
passed 'legacy lost-token intent cannot revoke a token with different scopes'
jq -n --arg uuid "$uuid" --arg name "installer-${RW_OWNER:0:8}" '{response:{tokens:[{uuid:$uuid,name:$name,scopes:["nodes:list"]},{uuid:"22222222-2222-4222-8222-222222222222",name:$name,scopes:["nodes:list"]}]}}' > "$TEST_ROOT/catalog.json"
if (rw_token_replace installer "$RW_TMP/scopes.json") >/dev/null 2>&1; then exit 1; fi
[[ ! -e $TEST_ROOT/unexpected-mutation ]]
passed 'duplicate orphan matches halt instead of guessing ownership'
expiry=$(date -u -d '+3 days' +%FT%TZ)
jq -n --arg uuid "$uuid" --arg expireAt "$expiry" '{uuid:$uuid,name:"installer-test",scopes:["nodes:list"],expireAt:$expireAt}' > "$RW_TMP/record.json"
rw_token_record installer "$RW_TMP/record.json"
[[ $(jq -r '.tokens.installer.expires_at' "$RW_OUT/manifest.json") == "$(date -u -d "$expiry" +%s)" ]]
passed 'expiry is taken from the actual API response'
rw_manifest_set '.tokens.subscription=.tokens.installer'
printf 'synthetic-token\n' | rw_atomic "$RW_OUT/private/subscription.token"
jq -n --slurpfile t "$RW_TMP/record.json" '{response:{tokens:$t}}' > "$TEST_ROOT/catalog.json"
rw_tokens_status > "$RW_TMP/status.jsonl" 2> "$RW_TMP/warnings"
[[ $(jq -s 'all(.rotation_due==true)' "$RW_TMP/status.jsonl") == true ]]
! grep -q synthetic-token "$RW_TMP/status.jsonl"
passed 'status warns within seven days and never outputs token values'
expiry=$(date -u -d '-1 day' +%FT%TZ)
jq --arg expireAt "$expiry" '.response.tokens[0].expireAt=$expireAt' "$TEST_ROOT/catalog.json" > "$RW_TMP/expired.json"
cp "$RW_TMP/expired.json" "$TEST_ROOT/catalog.json"
if (rw_tokens_status) >/dev/null 2>&1; then exit 1; fi
passed 'expired live tokens return failure'
printf '%s token safety checks passed.\n' "$count"
