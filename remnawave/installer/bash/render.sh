# shellcheck shell=bash
rw_secrets() {
    local file=$RW_OUT/private/secrets.json key
    if [[ -f $file ]]; then jq -e '.app_secret and .admin_password and .reality_private' "$file" >/dev/null || rw_die 'Файл секретов повреждён; новые ключи не создаются.'; return; fi
    if [[ -f $RW_OUT/manifest.json ]]; then
        [[ $(jq -r '.secrets_ready // false' "$RW_OUT/manifest.json") == false ]] || rw_die 'Секреты потеряны; остановка без генерации новых ключей.'
    fi
    for key in app_secret postgres_password metrics_password webhook_secret auth_password; do openssl rand -hex 32 > "$RW_TMP/$key"; done
    printf 'Aa1%s\n' "$(openssl rand -hex 32)" > "$RW_TMP/admin_password"
    openssl genpkey -algorithm X25519 -outform DER -out "$RW_TMP/key.der"
    openssl pkey -inform DER -in "$RW_TMP/key.der" -pubout -outform DER -out "$RW_TMP/pub.der"
    [[ $(wc -c < "$RW_TMP/key.der") == 48 && $(wc -c < "$RW_TMP/pub.der") == 44 ]] || rw_die 'Некорректный формат X25519 DER.'
    tail -c 32 "$RW_TMP/key.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=' > "$RW_TMP/reality_private"
    tail -c 32 "$RW_TMP/pub.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=' > "$RW_TMP/reality_public"
    openssl rand -hex 8 > "$RW_TMP/short_id"; printf '/%s\n' "$(openssl rand -hex 16)" > "$RW_TMP/xhttp_path"
    jq -n --rawfile app "$RW_TMP/app_secret" --rawfile pg "$RW_TMP/postgres_password" --rawfile met "$RW_TMP/metrics_password" \
      --rawfile wh "$RW_TMP/webhook_secret" --rawfile auth "$RW_TMP/auth_password" --rawfile admin "$RW_TMP/admin_password" \
      --rawfile priv "$RW_TMP/reality_private" --rawfile pub "$RW_TMP/reality_public" --rawfile sid "$RW_TMP/short_id" --rawfile path "$RW_TMP/xhttp_path" \
      '{app_secret:$app,postgres_password:$pg,metrics_password:$met,webhook_secret:$wh,auth_password:$auth,admin_password:$admin,reality_private:$priv,reality_public:$pub,short_id:$sid,xhttp_path:$path}|map_values(rtrimstr("\n"))' | rw_atomic "$file"
    if [[ -f $RW_OUT/manifest.json ]]; then rw_manifest_set '.secrets_ready=true'; fi
}
rw_render_compose() {
    local target=${1:-$RW_OUT/compose.json} versions=${2:-$RW_OUT/versions.lock.json}
    rw_memory_limits > "$RW_TMP/limits.json"
    jq -n --slurpfile c "$RW_CFG" --slurpfile v "$versions" --slurpfile limits "$RW_TMP/limits.json" --arg owner "$RW_OWNER" --arg project "$RW_PROJECT" --arg prefix "$RW_NET_PREFIX" '
      $c[0] as $c | $v[0].components as $v | $c.ports as $p |
      def service($image;$name): ($limits[0][$name]*1048576) as $memory |
        {image:$image,restart:"unless-stopped",mem_limit:$memory,cpus:(if $c.resources.profile=="compact-test" then 0.5 else 0.75 end),labels:{"io.pdm.remnawave.installation":$owner},logging:{driver:"json-file",options:{"max-size":"10m","max-file":"3"}}} |
        if $c.resources.profile=="compact-test" then .memswap_limit=$memory else . end;
      def env($path): [{path:$path,format:"raw"}];
      def health($test): {test:$test,interval:"5s",timeout:"3s",retries:20,start_period:"60s"};
      {name:$project,services:{},volumes:{caddy_data:{},caddy_config:{}},networks:{default:{labels:{"io.pdm.remnawave.installation":$owner},ipam:{config:[{subnet:$c.docker_subnet,gateway:($prefix+".1")}]}}}} |
      if $c.role != "node" then
        .services.rw_db=(service($v.postgres.image;"rw_db")+{shm_size:"128m",env_file:env("private/postgres.env"),volumes:["database:/var/lib/postgresql"],healthcheck:health(["CMD-SHELL","pg_isready -U postgres -d remnawave"])}) |
        (if $c.resources.profile=="compact-test" then .services.rw_db.command=["postgres","-c","shared_buffers=32MB","-c","max_connections=20","-c","work_mem=2MB","-c","maintenance_work_mem=16MB"] else . end) |
        .services.rw_valkey=(service($v.valkey.image;"rw_valkey")+{volumes:["valkey_socket:/var/run/valkey"],command:["valkey-server","--save","","--appendonly","no","--maxmemory",(if $c.resources.profile=="compact-test" then "16mb" else "96mb" end),"--maxmemory-policy","noeviction","--loglevel","warning","--unixsocket","/var/run/valkey/valkey.sock","--unixsocketperm","777","--port","0"],healthcheck:health(["CMD","valkey-cli","-s","/var/run/valkey/valkey.sock","ping"])}) |
        .services.rw_panel=(service($v.panel.image;"rw_panel")+{env_file:env("private/panel.env"),ports:[("127.0.0.1:"+($p.panel_api|tostring)+":3000"),("127.0.0.1:"+($p.metrics|tostring)+":3001")],networks:{default:{ipv4_address:($prefix+".10")}},volumes:["valkey_socket:/var/run/valkey"],depends_on:{rw_db:{condition:"service_healthy"},rw_valkey:{condition:"service_healthy"}},healthcheck:health(["CMD","curl","-f","http://127.0.0.1:3001/health"])}) |
        (if $c.resources.profile=="compact-test" then .services.rw_panel.environment={NODE_OPTIONS:"--max-old-space-size=256"} else . end) |
        .services.rw_subscription=(service($v.subscription.image;"rw_subscription")+{profiles:["public"],env_file:env("private/subscription.env"),ports:[("127.0.0.1:"+($p.subscription_api|tostring)+":3010")]}) |
        .volumes.database={} | .volumes.valkey_socket={}
      else . end |
      .services.rw_caddy=(service($v.caddy_auth.image;"rw_caddy")+{profiles:["public"],network_mode:"host",env_file:env("private/caddy.env"),volumes:["./Caddyfile:/etc/caddy/Caddyfile:ro","caddy_data:/data","caddy_config:/config","./site:/srv:ro"]}) |
      if $c.role != "panel" then .services.rw_node=(service($v.node.image;"rw_node")+{profiles:["node"],network_mode:"host",env_file:env("private/node.env")}) else . end |
      .volumes |= with_entries(.value.labels={"io.pdm.remnawave.installation":$owner})' | rw_atomic "$target"
    rw_stats_compose "$target" "$versions"
}
rw_render_env() {
    local panel_port sub_port authority sub_authority
    panel_port=$(rw_port https)
    sub_port=$(rw_subscription_port)
    authority=$(rw_cfg '.domains.panel // empty'); sub_authority=$(rw_cfg '.domains.subscription // empty')
    if [[ -n $panel_port && $panel_port != 443 ]]; then authority+=:$panel_port; fi
    if [[ -n $sub_port && $sub_port != 443 ]]; then sub_authority+=:$sub_port; fi
    if [[ $RW_ROLE != node ]]; then
        jq -r --slurpfile c "$RW_CFG" --arg front "https://$authority" --arg sub "$sub_authority" '
          "APP_PORT=3000\nMETRICS_PORT=3001\nAPI_INSTANCES=1\nDATABASE_URL=postgresql://postgres:"+.postgres_password+"@rw_db:5432/remnawave\nREDIS_SOCKET=/var/run/valkey/valkey.sock\nAPP_SECRET="+.app_secret+
          "\nPANEL_DOMAIN="+$c[0].domains.panel+"\nFRONT_END_DOMAIN="+$front+"\nSUB_PUBLIC_DOMAIN="+$sub+"\nMETRICS_USER=metrics\nMETRICS_PASS="+.metrics_password+
          "\nWEBHOOK_SECRET_HEADER="+.webhook_secret+"\nWEBHOOK_ENABLED=false\nIS_TELEGRAM_NOTIFICATIONS_ENABLED=false"' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/panel.env"
        jq -r '"POSTGRES_USER=postgres\nPOSTGRES_DB=remnawave\nTZ=UTC\nPOSTGRES_PASSWORD="+.postgres_password' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/postgres.env"
        jq --slurpfile c "$RW_CFG" '{username:$c[0].admin.username,password:.admin_password}' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/admin.json"
        jq -r --slurpfile c "$RW_CFG" '"AUTH_TOKEN_LIFETIME=3600\nREMNAWAVE_PANEL_DOMAIN="+$c[0].domains.panel+"\nAUTHP_ADMIN_USER="+$c[0].admin.username+"\nAUTHP_ADMIN_EMAIL="+$c[0].admin.email+"\nAUTHP_ADMIN_SECRET="+.auth_password' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/caddy.env"
    else printf '# Separate node, no admin identity store.\n' | rw_atomic "$RW_OUT/private/caddy.env"; fi
    if [[ ! -f $RW_OUT/private/subscription.env ]]; then printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nREMNAWAVE_API_TOKEN=\nTRUST_PROXY=1\n' | rw_atomic "$RW_OUT/private/subscription.env"; fi
    if [[ ! -f $RW_OUT/private/node.env ]]; then printf 'NODE_PORT=%s\n' "$(rw_port node_api)" | rw_atomic "$RW_OUT/private/node.env"; fi
}
rw_render_profile() {
    [[ $RW_ROLE != panel ]] || return 0
    jq --slurpfile c "$RW_CFG" '
      $c[0] as $c | . as $s |
      {log:{loglevel:"warning"},inbounds:(["tcp","xhttp"]|map(. as $transport |
        {tag:("PDM-"+$c.environment_id+"-"+ascii_upcase),listen:"::",port:(if .=="tcp" then $c.ports.reality else $c.ports.xhttp end),protocol:"vless",settings:{clients:[],decryption:"none"},
         streamSettings:{network:$transport,security:"reality",realitySettings:{dest:("127.0.0.1:"+($c.ports.reality_target|tostring)),xver:0,serverNames:[$c.domains.node],privateKey:$s.reality_private,shortIds:[$s.short_id]}}} |
        if $transport=="xhttp" then .streamSettings.xhttpSettings={mode:"auto",path:$s.xhttp_path} else . end)),
       outbounds:[{tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"block",protocol:"blackhole"}]}' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/xray-profile.json"
}
rw_render_caddy() {
    local http name kind port target ca
    http=$(rw_port http); ca=$(rw_cfg '.acme')
    {
        printf '{\n\tadmin 127.0.0.1:%s\n\tauto_https disable_redirects\n\thttp_port %s\n' "$(rw_port caddy_admin)" "$http"
        printf '\tcert_issuer acme {\n\t\tdisable_tlsalpn_challenge\n'
        [[ $ca != staging ]] || printf '\t\tdir https://acme-staging-v02.api.letsencrypt.org/directory\n'
        printf '\t}\n'
        [[ $RW_ROLE == node ]] || rw_auth_global
        printf '}\n'
        while IFS=$'\t' read -r kind name; do
            case $kind in node) port=$(rw_port reality_target);; subscription) port=$(rw_subscription_port);; *) port=$(rw_port https);; esac
            printf '\nhttps://%s:%s {\n' "$name" "$port"
            [[ $kind != node ]] || printf '\tbind 127.0.0.1\n'
            case $kind in
              panel)
                printf '\troute /api/* {\n\t\tauthorize with panelpolicy\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$(rw_port panel_api)"
                printf '\thandle /r {\n\t\trewrite * /auth\n\t\trequest_header +X-Forwarded-Prefix /r\n\t\tauthenticate with remnawaveportal\n\t}\n\troute /r* {\n\t\tauthenticate with remnawaveportal\n\t}\n'
                printf '\troute /* {\n\t\tauthorize with panelpolicy\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$(rw_port panel_api)";;
              subscription) printf '\treverse_proxy 127.0.0.1:%s\n' "$(rw_port subscription_api)";;
              node) printf '\troot * /srv\n\tfile_server\n';;
            esac
            printf '}\n'
        done < <(jq -r '.domains|to_entries[]|[.key,.value]|@tsv' "$RW_CFG")
        # A shared hostname has one HTTP listener, with the panel as its default redirect.
        while IFS=$'\t' read -r kind name; do
            printf 'http://%s:%s {\n' "$name" "$http"
            [[ $RW_MODE != fi-parallel ]] || printf '\tbind 127.0.0.1\n'
            case $kind in node) target=$(rw_port reality);; subscription) target=$(rw_subscription_port);; *) target=$(rw_port https);; esac
            printf '\tredir https://%s:%s{uri} 308\n}\n' "$name" "$target"
        done < <(rw_http_sites)
    } | rw_atomic "$RW_OUT/Caddyfile"
}
rw_render() {
    mkdir -p "$RW_OUT/site" "$RW_OUT/private"; chmod 700 "$RW_OUT" "$RW_OUT/site" "$RW_OUT/private"
    cat "$RW_CFG" | rw_atomic "$RW_OUT/config.json"
    if [[ -n ${RW_VERSION_FILE:-} ]]; then
        rw_versions_check "$RW_VERSION_FILE"
        jq --arg env "$RW_ENV" '.environment_id=$env' "$RW_VERSION_FILE" | rw_atomic "$RW_OUT/versions.lock.json"
    else rw_versions | jq --arg env "$RW_ENV" '.environment_id=$env' | rw_atomic "$RW_OUT/versions.lock.json"; fi
    rw_secrets; rw_render_compose; rw_render_env; rw_render_profile; rw_render_caddy
    printf '<!doctype html><html><title>Service</title><h1>Service online</h1></html>\n' | rw_atomic "$RW_OUT/site/index.html"
    rw_install_ctl
    jq -n --slurpfile c "$RW_CFG" --arg owner "$RW_OWNER" '{schema_version:1,environment_id:$c[0].environment_id,role:$c[0].role,domains:$c[0].domains,ports:$c[0].ports,ownership_label:$owner,nodes:[],access_groups:[],secret_files:["private/secrets.json","private/node.env"],grants_existing_users_access:false}' | rw_atomic "$RW_OUT/inventory.json"
}
