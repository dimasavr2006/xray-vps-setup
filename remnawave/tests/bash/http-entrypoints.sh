#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
work=$(mktemp -d /tmp/pdm-rw-http.XXXXXX)
server=
cleanup() {
    [[ -z $server ]] || docker rm -f "$server" >/dev/null 2>&1 || true
    [[ $work == /tmp/pdm-rw-http.* ]] && rm -rf -- "$work"
}
trap cleanup EXIT
image=$(jq -r '.components.node.image' "$ROOT/installer/versions.lock.json")
server=$(docker run -d --rm --label io.pdm.test=rw-http-20261008 --publish 127.0.0.1:39019:39019 \
    --mount "type=bind,src=$ROOT,dst=/source,readonly" --entrypoint node "$image" -e '
const http=require("http"),fs=require("fs");
http.createServer((req,res)=>{if(!["/rw-setup.sh","/uninstall.sh"].includes(req.url)){res.statusCode=404;return res.end();}fs.createReadStream("/source"+req.url).pipe(res);}).listen(39019,"0.0.0.0");')
for attempt in {1..30}; do curl -fsS http://127.0.0.1:39019/rw-setup.sh >/dev/null 2>&1 && break; sleep 1; done
cd "$work"
bash <(wget -qO- http://127.0.0.1:39019/rw-setup.sh) --config "$ROOT/installer/examples/node.json" --output "$work/remote" --dry-run > "$work/plan.json"
jq -e '.role=="node" and .environment_id=="node-test"' "$work/plan.json" >/dev/null
[[ ! -d $work/remote ]]
printf 'Remote Bash plan passed.\n'
source <(sed '$d' "$ROOT/rwctl")
RW_TMP=$work/tmp; mkdir "$RW_TMP"; RW_OUT=$work/remote; RW_MUTATING=0
rw_config_load "$ROOT/installer/examples/node.json"; rw_lock; rw_manifest preparing; rw_render; rw_manifest_set '.status="prepared"'; rw_track_files
exec 9>&-
printf 'Prepared Node fixture built.\n'
rw_config_filter > "$work/check-config.jq"
jq -ef "$work/check-config.jq" "$work/remote/config.json" >/dev/null
bash <(wget -qO- http://127.0.0.1:39019/uninstall.sh) --output "$work/remote" --prepared-only --yes
[[ ! -d $work/remote ]]
printf 'Actual wget/process-substitution plan and scoped uninstall passed without a checkout or Python runtime.\n'
