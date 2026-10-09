# shellcheck shell=bash
rw_track_files() {
    local file relative sum
    : > "$RW_TMP/managed.jsonl"
    while IFS= read -r relative; do
        [[ -n $relative && $relative != manifest.json && $relative != .rw.lock && $relative != /* && $relative != *'..'* ]] || continue
        file=$RW_OUT/$relative
        [[ -f $file && ! -L $file ]] || continue
        sum=$(sha256sum "$file" | cut -d' ' -f1)
        jq -n --arg path "$relative" --arg sum "$sum" '{path:$path,sha256:$sum}' >> "$RW_TMP/managed.jsonl"
    done < <({ [[ ! -f $RW_OUT/private/.managed-paths ]] || cat "$RW_OUT/private/.managed-paths"; jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf '%s\n' 'private/.managed-paths'; } | LC_ALL=C sort -u)
    jq -s '.' "$RW_TMP/managed.jsonl" > "$RW_TMP/managed.json"
    rw_manifest_set '.managed_files=$files[0]' --slurpfile files "$RW_TMP/managed.json"
}
rw_verify_files() {
    local path sum parent
    while IFS=$'\t' read -r path sum; do
        [[ $path != /* && $path != *'..'* && $path != *$'\n'* ]] || rw_die 'Небезопасный путь в manifest.'
        parent=$RW_OUT/$path
        while [[ $parent != "$RW_OUT" ]]; do [[ ! -L $parent ]] || rw_die 'Symlink в управляемом пути.'; parent=$(dirname -- "$parent"); done
        [[ -f $RW_OUT/$path && $(sha256sum "$RW_OUT/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Изменён управляемый файл $path; требуется сверка."
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$RW_OUT/manifest.json")
}
rw_doctor() {
    local id state service node_uuid attempts
    : > "$RW_TMP/doctor-tokens.jsonl"
    printf 'null\n' > "$RW_TMP/doctor-mfa.json"
    rw_owned; rw_docker_ownership
    [[ $(jq -r '.status' "$RW_OUT/manifest.json") != node-prepared-awaiting-attachment ]] || rw_die 'Нода подготовлена, но ещё не подключена к панели.'
    while IFS= read -r service; do
        [[ -n $(rw_compose --profile public --profile node ps -q "$service") ]] || rw_die "Отсутствует работающий сервис $service."
    done < <(jq -r '.services|keys[]' "$RW_OUT/compose.json")
    [[ $(stat -c %a "$RW_OUT/private") == 700 ]] || rw_die 'private/ должен иметь права 0700.'
    while IFS= read -r -d '' id; do [[ $(stat -c %a "$id") == 600 ]] || rw_die 'Секретный файл имеет слишком широкие права.'; done < <(find "$RW_OUT/private" -type f -print0)
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        state=$(docker inspect --format '{{.State.Status}}' "$id"); service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
        [[ $state == running ]] || rw_die "Сервис $service находится в состоянии $state."
        for ((attempts=0; attempts<60; attempts++)); do
            state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
            [[ $state == starting ]] || break
            sleep 2
        done
        [[ $state == healthy || $state == none ]] || rw_die "Healthcheck $service: $state."
    done < <(docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    if [[ $RW_ROLE != node ]]; then
        rw_wait_panel; rw_panel_login
        rw_tokens_status > "$RW_TMP/doctor-tokens.jsonl" || rw_die 'Токены панели требуют восстановления: rwctl tokens rotate.'
        rw_mfa_status > "$RW_TMP/doctor-mfa.json"
        while IFS= read -r node_uuid; do
            for ((attempts=0; attempts<30; attempts++)); do
                rw_api GET "/api/nodes/$node_uuid" '' "$RW_TMP/node-health.json" && jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/node-health.json" >/dev/null && break
                sleep 2
            done
            jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/node-health.json" >/dev/null || rw_die 'Панель не подтвердила подключение ноды и работающий Xray.'
        done < <(jq -r '.nodes[].node_uuid' "$RW_OUT/inventory.json")
    fi
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" --slurpfile tokens "$RW_TMP/doctor-tokens.jsonl" --slurpfile mfa "$RW_TMP/doctor-mfa.json" '{schema_version:1,environment_id:$e,role:$role,containers_running:true,client_acceptance_required:true,tokens:$tokens,mfa:$mfa[0]}'
}
rw_resource_plan() {
    local kind=$1 command=$2 expression=$3 id owner
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        owner=$(docker inspect --type "$kind" --format "$expression" "$id")
        [[ $owner == "$RW_OWNER" ]] || rw_die 'Docker-ресурс принадлежит другой установке.'
        printf '%s\n' "$id"
    done < <(docker "$command" ls -q --filter "label=com.docker.compose.project=$RW_PROJECT")
}
rw_uninstall() {
    rw_owned
    rw_ssh_idle
    if [[ ${RW_PREPARED_ONLY:-0} == 1 ]]; then
        [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared ]] || rw_die 'prepared-only нельзя применять к запускавшейся системе.'
        [[ ${RW_PURGE:-0} == 0 ]] || rw_die 'prepared-only и purge несовместимы.'
        printf '[]\n' > "$RW_TMP/containers.json"
        : > "$RW_TMP/networks"; : > "$RW_TMP/volumes"
    else
        docker info >/dev/null 2>&1 || rw_die 'Docker недоступен; файлы установки сохранены.'
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]' > "$RW_TMP/containers.json"
        rw_resource_plan network network '{{index .Labels "io.pdm.remnawave.installation"}}' > "$RW_TMP/networks"
        rw_resource_plan volume volume '{{index .Labels "io.pdm.remnawave.installation"}}' > "$RW_TMP/volumes"
    fi
    rw_verify_files
    if [[ ${RW_DRY_RUN:-0} == 1 ]]; then
        jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --slurpfile containers "$RW_TMP/containers.json" --rawfile volumes "$RW_TMP/volumes" --argjson purge "${RW_PURGE:-0}" '{environment_id:$e,directory:$path,containers:$containers[0],volumes:($volumes|split("\n")|map(select(length>0))),purge:($purge==1),read_only:true}'; return
    fi
    rw_root
    if [[ ${RW_YES:-0} != 1 ]]; then
        rw_info "Удаление только $RW_PROJECT в $RW_OUT. Данные Docker: $([[ ${RW_PURGE:-0} == 1 ]] && printf удалить || printf сохранить)."
        local confirm; read -r -p "Введите $RW_ENV для подтверждения: " confirm
        [[ $confirm == "$RW_ENV" ]] || { rw_info 'Отмена.'; return; }
    fi
    rw_lock; rw_verify_files
    if [[ ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]|sort' > "$RW_TMP/current-containers.json"
        jq 'sort' "$RW_TMP/containers.json" > "$RW_TMP/planned-containers.json"
        cmp -s "$RW_TMP/current-containers.json" "$RW_TMP/planned-containers.json" || rw_die 'Состав контейнеров изменился после подтверждения.'
    fi
    if [[ ${RW_PURGE:-0} != 1 && ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        local recovery
        recovery=/var/backups/pdm-remnawave/$RW_ENV-config-$(date -u +%Y%m%dT%H%M%SZ).tgz
        mkdir -p /var/backups/pdm-remnawave; chmod 700 /var/backups/pdm-remnawave
        tar -C "$RW_OUT" -czf "$recovery" --files-from <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf 'manifest.json\n')
        chmod 600 "$recovery"
        rw_info "Закрытая копия конфигов/ключей для сохранённых томов: $recovery"
    fi
    if [[ $(jq -r '.existing_caddy_updated // false' "$RW_OUT/manifest.json") == true ]]; then
        local file container
        file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'Существующий Caddy был изменён; автоматический откат маршрута остановлен.'
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    fi
    local id
    while IFS= read -r id; do docker stop -t 30 "$id" >/dev/null; docker rm "$id" >/dev/null; done < <(jq -r '.[]' "$RW_TMP/containers.json")
    while IFS= read -r id; do [[ -z $id ]] || docker network rm "$id" >/dev/null; done < "$RW_TMP/networks"
    if [[ ${RW_PURGE:-0} == 1 ]]; then while IFS= read -r id; do [[ -z $id ]] || docker volume rm "$id" >/dev/null; done < "$RW_TMP/volumes"; fi
    if [[ $(jq -r '.ufw_rules_added // false' "$RW_OUT/manifest.json") == true ]]; then
        while IFS= read -r id; do ufw --force delete "$id" >/dev/null; done < <(ufw status numbered | awk -v tag="# $RW_PROJECT" 'index($0,tag) {gsub(/[][]/,"",$1);print $1}' | sort -rn)
    fi
    if [[ $(jq -r '.firewall_installed // false' "$RW_OUT/manifest.json") == true ]]; then
        local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
        [[ -f $unit ]] && grep -qF "$RW_OWNER" "$unit" || rw_die 'Владение systemd firewall unit не подтверждено.'
        systemctl disable "$RW_PROJECT-firewall.service" >/dev/null; rm -f -- "$unit"; systemctl daemon-reload
        nft list table inet "$RW_TABLE" >/dev/null 2>&1 && nft delete table inet "$RW_TABLE"
    fi
    # Delete only recorded files. Unknown backups/operator files and nonempty directories remain.
    while IFS= read -r id; do rm -f -- "$RW_OUT/$id"; done < <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json")
    rm -f -- "$RW_OUT/manifest.json" "$RW_OUT/.rw.lock"
    find "$RW_OUT" -depth -type d -empty -delete
    rw_info 'Удаление завершено. Чужие контейнеры, образы, Docker Engine, SSH и общий firewall сохранены.'
}
rw_backup() {
    local archive=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-$(date -u +%Y%m%dT%H%M%SZ).tgz} id name image build
    archive=$(realpath -m -- "$archive")
    [[ $archive != "$RW_OUT"/* && ! -e $archive ]] || rw_die 'Backup должен быть новым файлом вне каталога установки.'
    rw_owned; rw_root; rw_lock; rw_docker_ownership; rw_verify_files; rw_ssh_idle
    mkdir -p -- "$(dirname -- "$archive")"
    build=$(mktemp -d "$RW_TMP/backup.XXXXXX")
    [[ -z $(find "$RW_OUT" -type l -print -quit) ]] || rw_die 'Symlink в каталоге установки; backup остановлен.'
    cp -a -- "$RW_OUT" "$build/installation"
    jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --arg owner "$RW_OWNER" --arg time "$(date -u +%FT%TZ)" '{schema_version:1,environment_id:$e,installation_path:$path,ownership_label:$owner,created_at_utc:$time}' > "$build/metadata.json"
    if [[ $RW_ROLE != node ]]; then rw_compose exec -T rw_db pg_dump -U postgres -d remnawave -Fc > "$build/database.dump"; fi
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    id=$(rw_compose --profile public ps -q rw_caddy)
    if [[ -n $id ]]; then docker pause "$id" >/dev/null; RW_PAUSED_CADDY=$id; fi
    for name in caddy_data caddy_config; do
        docker volume inspect "${RW_PROJECT}_$name" --format '{{index .Labels "io.pdm.remnawave.installation"}}' | grep -qx "$RW_OWNER" || rw_die 'Владение Caddy volume не подтверждено.'
        docker run --rm --network none --read-only --cap-drop ALL --entrypoint tar --mount "type=volume,src=${RW_PROJECT}_$name,dst=/data,readonly" "$image" -C /data -czf - . > "$build/$name.tgz"
    done
    if [[ -n ${RW_PAUSED_CADDY:-} ]]; then docker unpause "$RW_PAUSED_CADDY" >/dev/null; RW_PAUSED_CADDY=; fi
    tar -C "$build" -czf "$archive" .; chmod 600 "$archive"; tar -tzf "$archive" >/dev/null
    sha256sum "$archive" > "$archive.sha256"; chmod 600 "$archive.sha256"
    rw_info "Backup проверен: $archive. До рабочего переключения скопируйте его вне VPS."
}
rw_node_attach() {
    local host=${RW_SSH:-} config=${RW_NODE_CONFIG:-} env remote
    [[ $RW_ROLE != node && $host =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*$ && -f $config ]] || rw_die 'node attach: нужны --ssh USER@HOST и --node-config FILE на стороне панели.'
    rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    rw_wait_panel; rw_panel_login
    jq -ef "$RW_TMP/config.jq" "$config" > "$RW_TMP/node-config.json"
    [[ $(jq -r '.role' "$RW_TMP/node-config.json") == node ]] || rw_die 'Ожидается config роли node.'
    env=$(jq -r '.environment_id' "$RW_TMP/node-config.json"); remote=/opt/pdm-remnawave/$env
    local -a ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    local remote_uid prefix=
    remote_uid=$(ssh "${ssh_options[@]}" "$host" 'id -u')
    [[ $remote_uid =~ ^[0-9]+$ ]] || rw_die 'Не подтверждён UID SSH-пользователя.'
    if [[ $remote_uid != 0 ]]; then prefix='sudo -n '; ssh "${ssh_options[@]}" "$host" 'sudo -n true'; fi
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' preflight --config '$remote/config.json' --output '$remote'"
    local local_fp remote_fp
    local_fp=$(jq -Sc . "$RW_TMP/node-config.json" | sha256sum | cut -d' ' -f1)
    remote_fp=$(ssh "${ssh_options[@]}" "$host" "${prefix}jq -r .config_fingerprint '$remote/manifest.json'")
    [[ $local_fp == "$remote_fp" ]] || rw_die 'Локальные параметры ноды не совпадают с подготовленным SSH-хостом.'
    ssh "${ssh_options[@]}" "$host" "${prefix}cat '$remote/private/xray-profile.json'" > "$RW_TMP/remote-profile.json"
    RW_MUTATING=1
    rw_register_node "$RW_TMP/node-config.json" "$RW_TMP/connection.json" "$(jq -r '.management_address' "$RW_TMP/node-config.json")" "$RW_TMP/remote-profile.json"
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' node receive --output '$remote'" < "$RW_TMP/connection.json"
    local uuid attempt
    uuid=$(jq -er '.node_uuid' "$RW_TMP/connection.json")
    for ((attempt=0; attempt<30; attempt++)); do
        rw_api GET "/api/nodes/$uuid" '' "$RW_TMP/attached-node.json" && jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/attached-node.json" >/dev/null && break
        sleep 2
    done
    jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/attached-node.json" >/dev/null || rw_die 'Панель не подтвердила подключение ноды и работающий Xray.'
    rw_info 'Нода подключена; выдача доступа существующим пользователям не выполнялась.'
}
rw_node_receive() {
    rw_root; rw_owned
    [[ $RW_ROLE == node ]] || rw_die 'node receive предназначен для отдельной ноды.'
    rw_lock; RW_MUTATING=1
    cat > "$RW_TMP/received-connection.json"
    RW_CONNECTION=$RW_TMP/received-connection.json
    rw_apply; rw_track_files
}
