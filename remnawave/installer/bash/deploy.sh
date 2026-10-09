# shellcheck shell=bash
rw_api() {
    local method=$1 path=$2 body=${3:-} target=$4 code
    local -a args=(--silent --show-error --connect-timeout 5 --max-time 30 --request "$method" --header 'Content-Type: application/json' --header 'X-Forwarded-Proto: https' --header 'X-Forwarded-For: 127.0.0.1')
    [[ -z ${RW_AUTH_CONF:-} ]] || args+=(--config "$RW_AUTH_CONF")
    [[ ${RW_AUTH_KIND:-} != admin ]] || args+=(--header 'X-Remnawave-Client-Type: browser')
    [[ -z $body ]] || args+=(--data-binary "@$body")
    code=$(curl "${args[@]}" --output "$target" --write-out '%{http_code}' "$RW_API_ROOT$path") || return 1
    [[ $code =~ ^2[0-9][0-9]$ ]] || return 1
    jq -e 'type=="object" and has("response")' "$target" >/dev/null
}
rw_auth_header() {
    local file=$1
    [[ -f $file && ! -L $file && $(stat -c %a "$file") == 600 ]] || rw_die 'Токен должен находиться в отдельном файле с правами 0600.'
    grep -qxE '[A-Za-z0-9._=+/-]+' "$file" || rw_die 'Неподдерживаемый формат токена.'
    { printf 'header = "Authorization: Bearer '; tr -d '\n' < "$file"; printf '"\n'; } | rw_atomic "$RW_TMP/auth.curl"
    RW_AUTH_CONF=$RW_TMP/auth.curl
    RW_AUTH_KIND=${2:-api}
}
rw_wait_panel() {
    local attempt
    RW_API_ROOT=http://127.0.0.1:$(rw_port panel_api); RW_AUTH_CONF=
    for ((attempt=0; attempt<60; attempt++)); do rw_api GET /api/auth/status '' "$RW_TMP/status.json" 2>/dev/null && return 0; sleep 2; done
    rw_die 'Панель не вышла в готовность; новые контейнеры сохранены для диагностики.'
}
rw_panel_login() {
    RW_API_ROOT=http://127.0.0.1:$(rw_port panel_api); RW_AUTH_CONF=
    rw_api GET /api/auth/status '' "$RW_TMP/status.json" || rw_die 'API панели недоступен.'
    if jq -e '.response.isRegisterAllowed == true' "$RW_TMP/status.json" >/dev/null; then
        rw_info 'Создание первого администратора через закрытый API панели.'
        rw_api POST /api/auth/register "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || {
            # Registration may have succeeded before a lost response. Reconcile by login, not another register.
            rw_api POST /api/auth/login "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || rw_die 'Не удалось подтвердить создание администратора.'
        }
    else rw_api POST /api/auth/login "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || rw_die 'Существующий администратор не соответствует сохранённым данным; перезапись запрещена.'; fi
    jq -er '.response.accessToken' "$RW_TMP/login.json" | rw_atomic "$RW_TMP/admin.jwt"
    rw_auth_header "$RW_TMP/admin.jwt" admin
    if [[ ${RW_MUTATING:-0} == 1 ]]; then rw_manifest_set '.admin_bootstrapped=true'; fi
}
rw_token() {
    local key=$1 scopes=$2 body=$RW_TMP/token-request.json response=$RW_TMP/token-response.json uuid
    if [[ -s $RW_OUT/private/$key.token ]]; then return; fi
    # A lost create-token response cannot recover the token value. Stop for explicit revocation/rotation.
    [[ $(jq -r --arg key "$key" '.token_intents[$key] // false' "$RW_OUT/manifest.json") == false ]] || rw_die 'Ранее начат выпуск API-токена без сохранённого ответа; нужна проверка/ротация этого токена.'
    jq -n --arg name "${key}-${RW_OWNER:0:8}" --slurpfile scopes "$scopes" '{name:$name,expiresInDays:90,scopes:$scopes[0]}' | rw_atomic "$body"
    rw_manifest_set '.token_intents[$key]=true' --arg key "$key"
    rw_api POST /api/tokens "$body" "$response" || rw_die 'Выпуск токена не подтверждён; публикация не выполнялась.'
    jq -er '.response.token' "$response" | rw_atomic "$RW_OUT/private/$key.token"
    uuid=$(jq -er '.response.uuid' "$response")
    jq --arg uuid "$uuid" --arg key "$key" '.tokens[$key]={uuid:$uuid,expires_at:(now+90*86400)}' "$RW_OUT/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
}
rw_panel_tokens() {
    rw_api GET /api/tokens/scopes '' "$RW_TMP/scopes.json" || rw_die 'Не удалось проверить каталог прав API.'
    jq '[.response.resources[].endpoints[]|select(.kind=="read" and (.path|test("/api/system/metadata$|/api/sub(/|$)|/api/subscriptions?(/|$)|/api/(subscription-page-configs?|subpage-configs?)(/|$)")))|.key]|unique' "$RW_TMP/scopes.json" > "$RW_TMP/subscription-scopes.json"
    jq -e 'length>0 and all(.!="*")' "$RW_TMP/subscription-scopes.json" >/dev/null || rw_die 'Не найдены минимальные права subscription-page; общий токен не выдаётся.'
    rw_token subscription "$RW_TMP/subscription-scopes.json"
    jq '[.response.resources[].endpoints[]|select((.method|ascii_upcase)=="GET" or (.method|ascii_upcase)=="POST")|select(.path|test("^/api/(nodes|config-profiles|hosts|internal-squads)(/\\{[^/]+\\})?$|^/api/keygen$"))|.key]|unique' "$RW_TMP/scopes.json" > "$RW_TMP/installer-scopes.json"
    jq -e 'length>0 and all(.!="*")' "$RW_TMP/installer-scopes.json" >/dev/null || rw_die 'Не получены права управления нодой.'
    rw_token installer "$RW_TMP/installer-scopes.json"
    {
        printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nTRUST_PROXY=1\nREMNAWAVE_API_TOKEN='
        tr -d '\n' < "$RW_OUT/private/subscription.token"; printf '\n'
    } | rw_atomic "$RW_OUT/private/subscription.env"
    rw_auth_header "$RW_OUT/private/installer.token"
}
rw_api_object() {
    local key=$1 endpoint=$2 collection=$3 name=$4 request=$5 uuid intent count
    uuid=$(jq -r --arg key "$key" '.api[$key].uuid // empty' "$RW_OUT/manifest.json")
    if [[ -n $uuid ]]; then
        rw_api GET "$endpoint/$uuid" '' "$RW_TMP/object.json" || rw_die 'Ранее зарегистрированный API-объект недоступен.'
        jq -e --arg name "$name" '.response.name==$name or .response.remark==$name' "$RW_TMP/object.json" >/dev/null || rw_die 'API UUID больше не соответствует собственной установке.'
        return
    fi
    rw_api GET "$endpoint" '' "$RW_TMP/objects.json" || rw_die 'Не удалось прочитать каталог API.'
    jq --arg name "$name" "$collection | map(select(.name==\$name or .remark==\$name))" "$RW_TMP/objects.json" > "$RW_TMP/matches.json"
    count=$(jq 'length' "$RW_TMP/matches.json")
    intent=$(jq -r --arg key "$key" '.api[$key].intent // empty' "$RW_OUT/manifest.json")
    if (( count > 0 )); then
        [[ -n $intent && $count == 1 && $intent == $(sha256sum "$request" | cut -d' ' -f1) ]] || rw_die 'Одноимённый чужой API-объект: установка остановлена.'
        jq -e --slurpfile request "$request" '.[0] as $actual | $request[0] | to_entries | all(.[]; . as $entry | $actual[$entry.key]==$entry.value)' "$RW_TMP/matches.json" >/dev/null || rw_die 'Ответ после потери соединения не совпадает с фиксированной целью.'
        jq '{response:.[0]}' "$RW_TMP/matches.json" > "$RW_TMP/object.json"
    else
        intent=$(sha256sum "$request" | cut -d' ' -f1)
        rw_manifest_set '.api[$key].intent=$intent' --arg key "$key" --arg intent "$intent"
        rw_api POST "$endpoint" "$request" "$RW_TMP/object.json" || rw_die 'Создание API-объекта не подтверждено; повтор сверит результат по журналу.'
    fi
    uuid=$(jq -er '.response.uuid' "$RW_TMP/object.json")
    [[ $uuid =~ ^[a-f0-9-]{36}$ ]] || rw_die 'Некорректный UUID API.'
    rw_manifest_set '.api[$key].uuid=$uuid' --arg key "$key" --arg uuid "$uuid"
}
rw_register_node() {
    local config=$1 package=$2 address=$3 profile_file=${4:-$RW_OUT/private/xray-profile.json} prefix profile_uuid node_uuid transport inbound
    local env owner
    local api_owner
    api_owner=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    env=$(jq -r '.environment_id' "$config"); owner=$(printf '%s' "$env:$api_owner" | sha256sum | cut -c1-8)
    prefix=PDM-${env:0:10}-$owner
    jq --arg name "$prefix" '{name:$name,config:.}' "$profile_file" > "$RW_TMP/profile-request.json"
    rw_api_object "profile-$env" /api/config-profiles '.response.configProfiles' "$prefix" "$RW_TMP/profile-request.json"
    profile_uuid=$(jq -r --arg key "profile-$env" '.api[$key].uuid' "$RW_OUT/manifest.json")
    rw_api GET "/api/config-profiles/$profile_uuid" '' "$RW_TMP/profile.json" || rw_die 'Не удалось получить inbounds профиля.'
    jq -e '.response.inbounds|length==2' "$RW_TMP/profile.json" >/dev/null || rw_die 'Не получены оба TCP/XHTTP inbound.'
    jq -n --arg name "$prefix" --arg address "$address" --arg profile "$profile_uuid" --arg owner "$api_owner" \
      --slurpfile c "$config" --slurpfile p "$RW_TMP/profile.json" '{name:$name,address:$address,port:$c[0].ports.node_api,countryCode:$c[0].node_country,note:("pdm-install:"+$owner),configProfile:{activeConfigProfileUuid:$profile,activeInbounds:[$p[0].response.inbounds[].uuid]}}' > "$RW_TMP/node-request.json"
    rw_api_object "node-$env" /api/nodes '.response' "$prefix" "$RW_TMP/node-request.json"
    node_uuid=$(jq -r --arg key "node-$env" '.api[$key].uuid' "$RW_OUT/manifest.json")
    for transport in tcp xhttp; do
        inbound=$(jq -er --arg tag "PDM-$env-${transport^^}" '.response.inbounds[]|select(.tag==$tag)|.uuid' "$RW_TMP/profile.json")
        jq -n --arg remark "$prefix-$transport" --arg profile "$profile_uuid" --arg inbound "$inbound" --arg node "$node_uuid" --arg transport "$transport" --slurpfile c "$config" --slurpfile xray "$profile_file" \
          '{remark:$remark,inbound:{configProfileUuid:$profile,configProfileInboundUuid:$inbound},address:$c[0].domains.node,port:(if $transport=="tcp" then $c[0].ports.reality else $c[0].ports.xhttp end),sni:$c[0].domains.node,fingerprint:"chrome",nodes:[$node]} | if $transport=="xhttp" then .path=($xray[0].inbounds[]|select(.streamSettings.network=="xhttp")|.streamSettings.xhttpSettings.path) else . end' > "$RW_TMP/host-request.json"
        rw_api_object "host-$env-$transport" /api/hosts '.response' "$prefix-$transport" "$RW_TMP/host-request.json"
        jq -n --arg name "$prefix-$transport" --arg inbound "$inbound" '{name:$name,inbounds:[$inbound]}' > "$RW_TMP/squad-request.json"
        rw_api_object "squad-$env-$transport" /api/internal-squads '.response.internalSquads' "$prefix-$transport" "$RW_TMP/squad-request.json"
        local squad_uuid
        squad_uuid=$(jq -r --arg key "squad-$env-$transport" '.api[$key].uuid' "$RW_OUT/manifest.json")
        jq --arg env "$env" --arg transport "$transport" --arg node "$node_uuid" --arg uuid "$squad_uuid" \
          '.access_groups=([.access_groups[]?|select(.environment_id!=$env or .transport!=$transport)]+[{environment_id:$env,transport:$transport,node_uuid:$node,uuid:$uuid}])' "$RW_OUT/inventory.json" | rw_atomic "$RW_OUT/inventory.json"
    done
    rw_api GET /api/keygen '' "$RW_TMP/node-secret.json" || rw_die 'Штатный SECRET_KEY панели не получен.'
    jq -e '.response.secretKey|type=="string" and test("^[A-Za-z0-9+/=_-]+$")' "$RW_TMP/node-secret.json" >/dev/null || rw_die 'Некорректный SECRET_KEY панели.'
    local node_fp
    node_fp=$(jq -Sc . "$config" | sha256sum | cut -d' ' -f1)
    jq -n --slurpfile c "$config" --slurpfile k "$RW_TMP/node-secret.json" --arg node "$node_uuid" --arg profile "$profile_uuid" --arg fp "$node_fp" \
      '{schema_version:1,environment_id:$c[0].environment_id,config_fingerprint:$fp,expires_at:(now+3600),node_uuid:$node,config_profile_uuid:$profile,secret_key:$k[0].response.secretKey}' | rw_atomic "$package"
    jq --arg node "$node_uuid" --arg profile "$profile_uuid" --slurpfile p "$RW_TMP/profile.json" '.nodes=([.nodes[]?|select(.node_uuid!=$node)]+[{node_uuid:$node,config_profile_uuid:$profile,inbound_uuids:[$p[0].response.inbounds[].uuid]}])' "$RW_OUT/inventory.json" | rw_atomic "$RW_OUT/inventory.json"
}
rw_node_connection() {
    local package=$1
    [[ -f $package && ! -L $package && $(stat -c %a "$package") == 600 ]] || rw_die 'Файл подключения ноды должен иметь права 0600.'
    jq -e --arg env "$RW_ENV" --arg fp "$RW_FINGERPRINT" '.schema_version==1 and .environment_id==$env and .config_fingerprint==$fp and .expires_at>now and (.secret_key|test("^[A-Za-z0-9+/=_-]+$"))' "$package" >/dev/null || rw_die 'Файл подключения просрочен или относится к другим параметрам ноды.'
    if [[ $package == "$RW_OUT/private/connection.json" ]]; then cat "$package" | rw_atomic "$package"; fi
    if grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then
        jq -e --slurpfile package "$package" '.node_uuid==$package[0].node_uuid and .config_profile_uuid==$package[0].config_profile_uuid' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Существующий ключ относится к другой записи ноды.'
        return
    fi
    jq -r --arg port "$(rw_port node_api)" '"NODE_PORT="+$port+"\nSECRET_KEY="+.secret_key' "$package" | rw_atomic "$RW_OUT/private/node.env"
    rw_manifest_set '.node_uuid=$node|.config_profile_uuid=$profile' --arg node "$(jq -r '.node_uuid' "$package")" --arg profile "$(jq -r '.config_profile_uuid' "$package")"
}
rw_firewall() {
    local port sources4 sources6 id rules=$RW_OUT/private/firewall.nft
    port=$(rw_port node_api)
    if [[ $RW_ROLE == node ]]; then
        sources4=$(jq -r '[.panel_addresses[]|select(contains(":")|not)]|join(", ")' "$RW_CFG")
        sources6=$(jq -r '[.panel_addresses[]|select(contains(":"))]|join(", ")' "$RW_CFG")
    else sources4=$RW_NET_PREFIX.10; sources6=; fi
    {
        if nft -j list table inet "$RW_TABLE" > "$RW_TMP/existing-table.json" 2>/dev/null; then
            jq -e --arg owner "$RW_OWNER" '.nftables | any(.table.comment==$owner)' "$RW_TMP/existing-table.json" >/dev/null || rw_die 'Одноимённая nftables table принадлежит другой установке.'
            printf 'delete table inet %s\n' "$RW_TABLE"
        fi
        printf 'table inet %s {\n comment "%s"\n chain input { type filter hook input priority -5; policy accept;\n' "$RW_TABLE" "$RW_OWNER"
        if [[ -n $port ]]; then
            printf ' iifname "lo" tcp dport %s accept\n' "$port"
            [[ -z $sources4 ]] || printf ' ip saddr { %s } tcp dport %s accept\n' "$sources4" "$port"
            [[ -z $sources6 ]] || printf ' ip6 saddr { %s } tcp dport %s accept\n' "$sources6" "$port"
            printf ' tcp dport %s drop\n' "$port"
        fi
        printf '}\n'
        if [[ $RW_ROLE != node ]]; then
            printf ' chain forward { type filter hook forward priority -5; policy accept;\n ip daddr %s ip saddr != %s tcp dport { 3000, 3001, 3010, 5432, 6379, 13100 } drop\n }\n' "$RW_SUBNET" "$RW_SUBNET"
        fi
        printf '}\n'
    } | rw_atomic "$rules"
    nft --check -f "$rules" || rw_die 'Проверка собственной nftables-конфигурации не прошла.'
    nft -f "$rules"
    # On reboot the table is absent; load only the table declaration, not its previous deletion.
    sed '/^delete table /d' "$rules" | rw_atomic "$RW_OUT/private/firewall-boot.nft"
    local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
    if [[ -f $unit ]] && ! grep -qF "$RW_OWNER" "$unit"; then rw_die 'Конфликт systemd unit firewall.'; fi
    {
        printf '# %s\n[Unit]\nDescription=Remnawave scoped firewall\nBefore=docker.service\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nExecStart=/usr/sbin/nft -f %s/private/firewall-boot.nft\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' "$RW_OWNER" "$RW_OUT"
    } > "$unit"
    chmod 644 "$unit"; systemctl daemon-reload; systemctl enable "$RW_PROJECT-firewall.service" >/dev/null
    rw_manifest_set '.firewall_installed=true'
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        while IFS= read -r port; do ufw allow "$port/tcp" comment "$RW_PROJECT" >/dev/null; done < <(jq -r '.ports | [.http,.https,.subscription_https,.reality,.xhttp] | map(select(.!=null and .!=18080)) | unique[]' "$RW_CFG")
        port=$(rw_port node_api)
        if [[ -n $port ]]; then
            for id in $sources4 $sources6; do ufw allow from "${id%,}" to any port "$port" proto tcp comment "$RW_PROJECT" >/dev/null; done
        fi
        rw_manifest_set '.ufw_rules_added=true'
    fi
}
rw_existing_caddy_check() {
    local file container health
    file=$(rw_cfg '.existing_caddy.config_file // empty'); container=$(rw_cfg '.existing_caddy.container // empty'); health=$(rw_cfg '.existing_caddy.health_url // empty')
    [[ $file == /* && -f $file && ! -L $file && $container =~ ^[A-Za-z0-9_.-]+$ && $health =~ ^https://[A-Za-z0-9.:-]+/?$ ]] || rw_die 'Для FI задайте existing_caddy: config_file, container, health_url.'
    docker inspect --format '{{.State.Running}}' "$container" | grep -qx true || rw_die 'Существующий Caddy не работает.'
    curl -f --silent --show-error --connect-timeout 5 --max-time 10 "$health" >/dev/null || rw_die 'Исходный сайт FI недоступен до изменений.'
}
rw_existing_caddy_candidate() {
    local file=$1 candidate=$2 kind domain https matcher=pdm_rw_${RW_ENV//-/_}_redirect
    cat "$file" > "$candidate"
    while IFS=$'\t' read -r kind domain; do
        if grep -Fxq "http://$domain {" "$candidate"; then
            # The FI HTTP site already serves this hostname. Scope the existing
            # redirect away from ACME, preserving its target and other directives.
            # Unrecognised layouts stop here instead of guessing at Caddy syntax.
            awk -v site="http://$domain {" -v domain="$domain" -v project="$RW_PROJECT" -v matcher="$matcher" -v port="$(rw_port http)" '
              $0==site {active=1}
              active && $1=="redir" {
                if (NF!=3 || index($2,"https://" domain)!=1) exit 42;
                print "\t# BEGIN " project;
                print "\t@" matcher " not path /.well-known/acme-challenge/*";
                print "\thandle /.well-known/acme-challenge/* {";
                print "\t\treverse_proxy 127.0.0.1:" port;
                print "\t}";
                print "\tredir @" matcher " " $2 " " $3;
                print "\t# END " project;
                changed++; next
              }
              active && $0=="}" {active=0}
              {print}
              END {if (changed!=1) exit 42}' "$candidate" > "$RW_TMP/existing-caddy.site" || rw_die 'Существующий HTTP site требует явной сверки; его конфиг не изменён.'
            cat "$RW_TMP/existing-caddy.site" > "$candidate"
        else
            case $kind in node) https=$(rw_port reality);; subscription) https=$(rw_subscription_port);; *) https=$(rw_port https);; esac
            printf '\n# BEGIN %s\nhttp://%s {\n handle /.well-known/acme-challenge/* {\n  reverse_proxy 127.0.0.1:%s\n }\n handle {\n  redir https://%s:%s{uri} 308\n }\n}\n# END %s\n' "$RW_PROJECT" "$domain" "$(rw_port http)" "$domain" "$https" "$RW_PROJECT" >> "$candidate"
        fi
    done < <(rw_http_sites)
}
rw_existing_caddy_apply() {
    [[ $RW_MODE == fi-parallel ]] || return 0
    local file container kind domain https code candidate=$RW_TMP/existing-caddy.new
    file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
    if grep -qF "# BEGIN $RW_PROJECT" "$file"; then
        [[ -f $RW_OUT/private/existing-caddy.applied.sha256 ]] || rw_die 'Неизвестный маршрут существующего Caddy.'
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'Существующий Caddy изменён после установки; нужна сверка.'
        rw_manifest_set '.existing_caddy_updated=true'
        return
    fi
    cp -p -- "$file" "$RW_OUT/private/existing-caddy.before"; chmod 600 "$RW_OUT/private/existing-caddy.before"
    rw_existing_caddy_candidate "$file" "$candidate"
    docker cp "$candidate" "$container:/tmp/$RW_PROJECT.Caddyfile"
    docker exec --user 0 "$container" caddy validate --config "/tmp/$RW_PROJECT.Caddyfile" --adapter caddyfile >/dev/null || rw_die 'Полный конфиг старого Caddy не прошёл проверку.'
    RW_EXISTING_CADDY_FILE=$file; RW_EXISTING_CADDY_CONTAINER=$container; RW_CADDY_ROLLBACK_PENDING=1
    # Preserve the inode of a single-file Docker bind mount; atomic rename would leave the old file mounted.
    cat "$candidate" > "$file"
    if ! docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || ! curl -f --silent --max-time 10 "$(rw_cfg '.existing_caddy.health_url')" >/dev/null; then
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || true
        rw_die 'Проверка reload старого Caddy не прошла; исходный файл восстановлен.'
    fi
    sha256sum "$file" | cut -d' ' -f1 | rw_atomic "$RW_OUT/private/existing-caddy.applied.sha256"
    rw_manifest_set '.existing_caddy_updated=true'
    RW_CADDY_ROLLBACK_PENDING=0
}
rw_apply() {
    rw_root; rw_os; rw_resource_checks; rw_dns_checks; rw_docker_install; rw_preflight
    if [[ -f $RW_OUT/manifest.json ]]; then
        [[ -z ${RW_VERSION_FILE:-} ]] || rw_die 'Для смены версий существующей установки используйте upgrade.'
        rw_owned
        rw_verify_files; rw_ssh_idle
        [[ $(jq -r '.config_fingerprint' "$RW_OUT/manifest.json") == "$RW_FINGERPRINT" ]] || rw_die 'Параметры изменились; ключи и конфиги не перезаписываются.'
    else
        [[ ! -d $RW_OUT || -z $(find "$RW_OUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || rw_die 'Каталог не пуст и не принадлежит установщику.'
    fi
    rw_lock
    RW_MUTATING=1
    if [[ ! -f $RW_OUT/manifest.json ]]; then rw_manifest preparing; fi
    if [[ $(jq -r '.status' "$RW_OUT/manifest.json") == preparing ]]; then rw_render; rw_manifest_set '.status="prepared"'; fi
    if [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared && -z $(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER") ]]; then
        # A never-started package can receive template fixes without replacing secrets or pinned images.
        rw_render_compose; rw_render_caddy; rw_install_ctl; rw_track_files
    fi
    rw_owned; rw_compose config --quiet
    rw_info 'Загрузка закреплённых Docker-образов.'
    rw_compose --profile public --profile node pull
    if ! rw_compose --profile public run --rm --no-deps --entrypoint caddy rw_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$RW_TMP/caddy-check.log" 2>&1; then
        cat "$RW_TMP/caddy-check.log" | rw_atomic "$RW_OUT/private/caddy-validation.log"
        rw_die 'Конфигурация Caddy не прошла проверку; публикация не выполнена. Диагностика сохранена в private/caddy-validation.log.'
    fi
    rw_firewall
    if [[ $RW_ROLE != node ]]; then
        rw_info 'Запуск PostgreSQL, Valkey и Remnawave.'
        rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey rw_panel
        rw_wait_panel; rw_panel_login; rw_panel_tokens
    fi
    if [[ $RW_ROLE == panel-node ]]; then
        rw_register_node "$RW_CFG" "$RW_OUT/private/connection.json" "$RW_PANEL_ADDRESS"
        rw_node_connection "$RW_OUT/private/connection.json"
    elif [[ $RW_ROLE == node ]]; then
        if [[ -n ${RW_CONNECTION:-} ]]; then rw_node_connection "$RW_CONNECTION";
        elif ! grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then
            rw_manifest_set '.status="node-prepared-awaiting-attachment"'
            rw_info "Нода подготовлена в $RW_OUT. Подключите её командой rwctl node attach на панели; SECRET_KEY не генерируется локально."
            return
        fi
    fi
    rw_existing_caddy_apply
    rw_info 'Запуск Caddy/MFA и публичной страницы подписок.'
    rw_compose --profile public up -d rw_caddy
    [[ $RW_ROLE == node ]] || rw_compose --profile public up -d rw_subscription
    if [[ $RW_ROLE != panel ]]; then rw_compose --profile node up -d rw_node; fi
    rw_manifest_set '.status="running-awaiting-acceptance"'
    rw_doctor
    rw_info "Контейнеры запущены в $RW_OUT."
    if [[ $RW_ROLE != node ]]; then rw_info 'Админские данные: private/admin.json; пароль Caddy Auth: private/secrets.json. Завершите MFA при первом входе.'; fi
}
