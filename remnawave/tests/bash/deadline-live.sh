#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
server=
cleanup_deadline() { [[ -z $server ]] || docker rm -f "$server" >/dev/null 2>&1 || true; }
trap 'cleanup_deadline; rw_cleanup' EXIT
image=$(rw_versions | jq -r '.components.node.image')
server=$(docker run -d --rm --memory 64m --label io.pdm.test=deadline-live --publish 127.0.0.1:39099:39099 --entrypoint node "$image" -e '
const http=require("http");http.createServer((req,res)=>{if(req.url==="/ready"){res.setHeader("Content-Type","application/json");res.end(JSON.stringify({response:{ready:true}}));}}).listen(39099,"0.0.0.0");')
for attempt in {1..30}; do curl -fsS --max-time 1 http://127.0.0.1:39099/ready >/dev/null 2>&1 && break; sleep 1; done
port_definition=$(declare -f rw_port)
rw_port() { printf '39099\n'; }
RW_API_ROOT=http://127.0.0.1:39099
start=$SECONDS
if (rw_wait_panel 3) > "$RW_TMP/panel-timeout.log" 2>&1; then exit 1; fi
(( SECONDS-start>=2 && SECONDS-start<=4 ))
grep -q 'panel did not become ready' "$RW_TMP/panel-timeout.log"
start=$SECONDS
if (rw_wait_node fixture "$RW_TMP/slow-node.json" 3) > "$RW_TMP/node-timeout.log" 2>&1; then exit 1; fi
(( SECONDS-start>=2 && SECONDS-start<=4 ))
grep -q 'panel did not confirm' "$RW_TMP/node-timeout.log"
rw_api GET /ready '' "$RW_TMP/ready.json"
jq -e '.response.ready==true' "$RW_TMP/ready.json" >/dev/null
eval "$port_definition"
RW_OUT=$RW_TMP/installation
jq '.environment_id="ci-deadline"|.security={enabled:false}' "$ROOT/installer/examples/node.json" > "$RW_TMP/node-input.json"
rw_config_load "$RW_TMP/node-input.json"; rw_lock; rw_manifest preparing; rw_render; rw_manifest_set '.status="prepared"'; rw_track_files
key_hash=$(sha256sum "$RW_OUT/private/secrets.json")
rw_resource_checks() { :; }; rw_dns_checks() { :; }; rw_docker_install() { :; }; rw_preflight() { :; }
rw_pull() { return 124; }
if (rw_apply) > "$RW_TMP/pull-failure.log" 2>&1; then exit 1; fi
[[ $key_hash == "$(sha256sum "$RW_OUT/private/secrets.json")" ]]
[[ -z $(docker ps -aq --filter "label=com.docker.compose.project=$RW_PROJECT") ]]
rw_verify_files
exec 9>&-; RW_LOCK_DIR=
bash "$ROOT/uninstall.sh" --output "$RW_OUT" --prepared-only --yes > "$RW_TMP/removal.log" 2>&1
printf 'Real stalled HTTP respects total panel/node deadlines; ready request succeeds; failed pull retains keys and starts no containers.\n'
