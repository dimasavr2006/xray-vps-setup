# shellcheck shell=bash
rw_stats_enabled() { [[ -f ${RW_STATS_SOURCE_MANIFEST:-$RW_OUT/manifest.json} ]] && jq -e '.stats.enabled==true' "${RW_STATS_SOURCE_MANIFEST:-$RW_OUT/manifest.json}" >/dev/null; }
rw_stats_port() { jq -er '.stats.port|select(type=="number" and .==floor and .>=1024 and .<=65535)' "${RW_STATS_SOURCE_MANIFEST:-$RW_OUT/manifest.json}"; }
rw_stats_version() {
    [[ $RW_ROLE != node && $(jq -r '.components.panel.image' "$1") == remnawave/backend@sha256:b16d724b90fd7c9fec2df04bd28938a671cafc62894105068e11550ee3449c56 ]] || rw_die 'The statistics addon requires the verified Panel 3.4.5 image and a panel role.'
}
rw_stats_secrets_check() {
    local file=$1 owner=$2
    jq -e --arg owner "$owner" '
      .schema_version==1 and .api_namespace_owner==$owner and
      (keys==["api_namespace_owner","api_token","reader_password","schema_version"]) and
      ([.api_token,.reader_password,.api_namespace_owner]|all(type=="string" and test("^[a-f0-9]{64}$")))' "$file" >/dev/null || rw_die 'Invalid statistics addon secrets or namespace.'
}
rw_stats_assets() {
    rw_stats_enabled || return 0
    rw_stats_version "$RW_OUT/versions.lock.json"
    local namespace
    namespace=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    rw_stats_secrets_check "$RW_OUT/private/stats.json" "$namespace"
    rw_stats_hook | rw_atomic "$RW_OUT/plugins/stats/panel-hook.cjs"
    rw_stats_server | rw_atomic "$RW_OUT/plugins/stats/server.cjs"
    jq -r .api_token "$RW_OUT/private/stats.json" | rw_atomic "$RW_OUT/private/stats.token"
    jq -r '"DATABASE_URL=postgresql://pdm_stats_api:"+.reader_password+"@rw_db:5432/remnawave?connection_limit=1&pool_timeout=2\nPDM_STATS_TOKEN_FILE=/run/secrets/stats-token\nPDM_STATS_PORT=13100\nNODE_OPTIONS=--max-old-space-size=32"' "$RW_OUT/private/stats.json" | rw_atomic "$RW_OUT/private/stats.env"
}
rw_stats_compose() {
    local target=$1 versions=$2
    rw_stats_enabled || return 0
    rw_stats_version "$versions"
    local port image
    port=$(rw_stats_port) || rw_die 'Invalid statistics API port.'
    [[ $(jq -r --argjson port "$port" '.ports|[.[]]|index($port)' "$RW_CFG") == null ]] || rw_die 'The statistics API port conflicts with an installation port.'
    image=$(jq -r '.components.panel.image' "$versions")
    jq --arg image "$image" --arg owner "$RW_OWNER" --argjson port "$port" --arg profile "$(rw_cfg '.resources.profile')" '
      (if $profile=="compact-test" then .services.rw_panel.environment.NODE_OPTIONS="--max-old-space-size=160" else . end) |
      .services.rw_panel.volumes += ["./plugins/stats/processors.patched.js:/opt/app/dist/processors.js:ro","./plugins/stats/panel-hook.cjs:/opt/pdm-stats/panel-hook.cjs:ro"] |
      .services.rw_stats={image:$image,entrypoint:["node","/opt/pdm-stats/server.cjs"],restart:"unless-stopped",
        mem_limit:100663296,memswap_limit:100663296,cpus:0.15,read_only:true,cap_drop:["ALL"],
        security_opt:["no-new-privileges:true"],tmpfs:["/tmp:size=32m,mode=1777"],
        env_file:[{path:"private/stats.env",format:"raw"}],profiles:["public"],ports:[("127.0.0.1:"+($port|tostring)+":13100")],
        volumes:["./plugins/stats/server.cjs:/opt/pdm-stats/server.cjs:ro","./private/stats.token:/run/secrets/stats-token:ro"],
        labels:{"io.pdm.remnawave.installation":$owner},logging:{driver:"json-file",options:{"max-size":"5m","max-file":"2"}},
        depends_on:{rw_db:{condition:"service_healthy"}},
        healthcheck:{test:["CMD","node","-e","const fs=require(\"fs\"),http=require(\"http\");const r=http.get(\"http://127.0.0.1:13100/health\",{headers:{Authorization:\"Bearer \"+fs.readFileSync(process.env.PDM_STATS_TOKEN_FILE,\"utf8\").trim()}},s=>process.exit(s.statusCode===200?0:1));r.setTimeout(2500,()=>process.exit(1));r.on(\"error\",()=>process.exit(1));"],interval:"10s",timeout:"3s",retries:12,start_period:"20s"}}' "$target" | rw_atomic "$target"
}
rw_stats_patch() {
    rw_stats_enabled || return 0
    rw_stats_version "$RW_OUT/versions.lock.json"
    local image
    image=$(jq -r '.components.panel.image' "$RW_OUT/versions.lock.json")
    rw_stats_patcher > "$RW_TMP/stats-patcher.cjs"
    docker run --rm --network none --read-only --cap-drop ALL --entrypoint cat "$image" /opt/app/dist/processors.js > "$RW_TMP/processors.original.js"
    docker run --rm --network none --memory 256m --memory-swap 256m --cpus 0.5 --cap-drop ALL --entrypoint node \
      --mount "type=bind,src=$RW_TMP,dst=/work" "$image" /work/stats-patcher.cjs /work/processors.original.js /work/processors.patched.js || rw_die 'Statistics bundle SHA or syntax validation failed.'
    rw_atomic "$RW_OUT/plugins/stats/processors.patched.js" < "$RW_TMP/processors.patched.js"
}
rw_stats_roles() {
    rw_stats_enabled || return 0
    local namespace exists comment password
    namespace=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    rw_stats_secrets_check "$RW_OUT/private/stats.json" "$namespace"
    IFS='|' read -r exists comment < <(rw_compose exec -T rw_db psql -At -U postgres -d postgres -c "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='pdm_stats_api'),coalesce((SELECT shobj_description(oid,'pg_authid') FROM pg_roles WHERE rolname='pdm_stats_api'),'');")
    [[ $exists == f || ( $exists == t && $comment == "pdm-remnawave:$namespace" ) ]] || rw_die 'PostgreSQL role pdm_stats_api is not owned by this addon.'
    password=$(jq -r .reader_password "$RW_OUT/private/stats.json")
    {
        if [[ $exists == f ]]; then printf "CREATE ROLE pdm_stats_api LOGIN PASSWORD '%s';\n" "$password";
        else printf "ALTER ROLE pdm_stats_api PASSWORD '%s';\n" "$password"; fi
        printf "COMMENT ON ROLE pdm_stats_api IS 'pdm-remnawave:%s';\n" "$namespace"
        printf 'ALTER ROLE pdm_stats_api NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;\nALTER ROLE pdm_stats_api SET default_transaction_read_only=on;\n'
    } | rw_compose exec -T rw_db psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres || rw_die 'The statistics role could not be prepared.'
}
rw_stats_sql() {
    rw_stats_enabled || return 0
    rw_stats_schema | rw_compose exec -T rw_db psql -q -v ON_ERROR_STOP=1 -U postgres -d remnawave || rw_die 'Statistics schema validation failed.'
    printf 'GRANT CONNECT ON DATABASE remnawave TO pdm_stats_api;\nGRANT USAGE ON SCHEMA pdm_stats TO pdm_stats_api;\nREVOKE ALL ON ALL TABLES IN SCHEMA public,pdm_stats FROM pdm_stats_api;\nGRANT EXECUTE ON FUNCTION pdm_stats.status(),pdm_stats.usage(bigint,timestamptz,timestamptz) TO pdm_stats_api;\n' | rw_compose exec -T rw_db psql -q -v ON_ERROR_STOP=1 -U postgres -d remnawave || rw_die 'Statistics API permissions could not be configured.'
}
rw_stats_status() {
    rw_owned; rw_stats_enabled || rw_die 'The statistics addon is not installed.'
    rw_auth_header "$RW_OUT/private/stats.token"
    curl -fsS --connect-timeout 3 --max-time 10 --config "$RW_AUTH_CONF" "http://127.0.0.1:$(rw_stats_port)/health" | jq .
}
rw_stats_install() {
    rw_root; rw_os; rw_owned; rw_verify_files; rw_ssh_idle; rw_docker_ownership
    rw_stats_version "$RW_OUT/versions.lock.json"
    local port=${RW_STATS_PORT:-} namespace
    if rw_stats_enabled; then
        [[ -z $port || $port == "$(rw_stats_port)" ]] || rw_die 'Repeating installation cannot change the saved statistics API port.'
        port=$(rw_stats_port)
    else
        port=${port:-13100}
        [[ $port =~ ^[1-9][0-9]{3,4}$ ]] && ((port>=1024 && port<=65535)) || rw_die 'Statistics API port must be from 1024 to 65535 without leading zeroes.'
        [[ -z $(ss -H -lnt "sport = :$port") ]] || rw_die 'The statistics API port is already in use.'
    fi
    [[ $(jq -r --argjson port "$port" '.ports|[.[]]|index($port)' "$RW_CFG") == null ]] || rw_die 'The statistics API port conflicts with an installation port.'
    if (( RW_DRY_RUN )); then jq -n --argjson port "$port" '{stats_schema:1,loopback_port:$port,read_only_api:true,no_additional_xray_queries:true,backup_required:true,read_only:true}'; return; fi
    rw_lock
    local available required=384
    available=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    if ! rw_stats_enabled; then required=$((required+96)); fi
    (( available>=required )) || rw_die "Statistics installation and bundle validation require $required MiB of available RAM."
    namespace=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    RW_ARCHIVE=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-pre-stats-$(date -u +%Y%m%dT%H%M%SZ).tgz}
    rw_stop_writers
    if ! (rw_backup); then (rw_start_existing) || true; rw_die 'The pre-statistics backup was not created.'; fi
    rw_backup_open "$RW_ARCHIVE"
    RW_UPGRADE_SOURCE=$RW_BACKUP/installation; RW_UPGRADE_ARCHIVE=$RW_ARCHIVE; RW_UPGRADE_PENDING=1; RW_MUTATING=1
    if (rw_stats_activate "$port" "$namespace" > "$RW_TMP/stats-install.log" 2>&1); then
        RW_UPGRADE_PENDING=0; rw_install_ctl; rw_track_files
        rw_info 'Statistics addon installed. History before the first confirmed sample remains unknown.'
    else
        rw_atomic "$RW_OUT/private/stats-install-error.log" < "$RW_TMP/stats-install.log"
        rw_upgrade_abort
        rw_die 'Statistics addon acceptance failed; rollback completed.'
    fi
}
rw_stats_activate() {
    local port=$1 namespace=$2
    rw_manifest_set '.stats={enabled:true,schema_version:1,port:$port}' --argjson port "$port"
    if [[ ! -f $RW_OUT/private/stats.json ]]; then
        jq -n --arg namespace "$namespace" --arg password "$(openssl rand -hex 32)" --arg token "$(openssl rand -hex 32)" \
          '{schema_version:1,api_namespace_owner:$namespace,reader_password:$password,api_token:$token}' | rw_atomic "$RW_OUT/private/stats.json"
    fi
    rw_stats_assets; rw_stats_patch; rw_render_compose; rw_stats_roles; rw_stats_sql; rw_firewall; rw_track_files
    rw_start_existing; rw_stats_status
}
