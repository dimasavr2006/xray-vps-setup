#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
RW_OUT=$RW_TMP/panel
rw_config_load "$ROOT/installer/examples/panel.json"
rw_lock; rw_manifest preparing; rw_render; rw_manifest_set '.status="prepared"'
rw_manifest_set '.stats={enabled:true,schema_version:1,port:13100}'
jq -n --arg owner "$RW_OWNER" '{schema_version:1,api_namespace_owner:$owner,reader_password:("a"*64),api_token:("b"*64)}' | rw_atomic "$RW_OUT/private/stats.json"
rw_stats_assets; rw_render_compose; rw_track_files
jq -e '.services.rw_stats.read_only and .services.rw_stats.mem_limit==100663296 and .services.rw_stats.cap_drop==["ALL"] and .services.rw_stats.ports==["127.0.0.1:13100:13100"] and (.services.rw_panel.volumes|any(endswith("/opt/pdm-stats/panel-hook.cjs:ro")))' "$RW_OUT/compose.json" >/dev/null
rw_verify_files
fail_expected() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected rejection: %s\n' "$*"; exit 1; fi; }
jq '.reader_password="x"' "$RW_OUT/private/stats.json" > "$RW_TMP/bad.json"
fail_expected rw_stats_secrets_check "$RW_TMP/bad.json" "$RW_OWNER"
fail_expected rw_stats_secrets_check "$RW_OUT/private/stats.json" "$(printf '%064d' 0)"
jq '.components.panel.image="remnawave/backend@sha256:"+("f"*64)' "$RW_OUT/versions.lock.json" > "$RW_TMP/wrong-version.json"
fail_expected rw_stats_version "$RW_TMP/wrong-version.json"
rw_stats_schema > "$RW_TMP/schema.sql"
cmp -s "$ROOT/stats/schema.sql" <(head -n -1 "$RW_TMP/schema.sql")
rw_stats_hook > "$RW_TMP/hook.cjs"
cmp -s "$ROOT/stats/panel-hook.cjs" <(head -n -1 "$RW_TMP/hook.cjs")
rw_manifest_set '.stats.port=.ports.panel_api' # missing in manifest is rejected
fail_expected rw_stats_compose "$RW_TMP/compose.json" "$RW_OUT/versions.lock.json"
rw_manifest_set '.stats.port=$port' --argjson port "$(rw_port panel_api)"
fail_expected rw_stats_compose "$RW_TMP/compose.json" "$RW_OUT/versions.lock.json"
printf '7 stats rendering/ownership/version/embedded-source safety checks passed.\n'
