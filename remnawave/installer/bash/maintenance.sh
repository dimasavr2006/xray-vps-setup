# shellcheck shell=bash
rw_track_files() {
    local file relative
    local -a paths=()
    while IFS= read -r relative; do
        [[ -n $relative && $relative != manifest.json && $relative != .rw.lock && $relative != /* && $relative != *'..'* ]] || continue
        file=$RW_OUT/$relative
        [[ -f $file && ! -L $file ]] || continue
        paths+=("$relative")
    done < <({ [[ ! -f $RW_OUT/private/.managed-paths ]] || cat "$RW_OUT/private/.managed-paths"; jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf '%s\n' 'private/.managed-paths'; } | LC_ALL=C sort -u)
    : > "$RW_TMP/managed.sums"
    if (( ${#paths[@]} )); then
        (cd -- "$RW_OUT" && sha256sum --zero -- "${paths[@]}") > "$RW_TMP/managed.sums" || rw_die 'Cannot hash managed files.'
    fi
    jq -Rs 'split("\u0000")|map(select(length>0)|{path:.[66:],sha256:.[0:64]})' "$RW_TMP/managed.sums" > "$RW_TMP/managed.json"
    rw_manifest_set '.managed_files=$files[0]' --slurpfile files "$RW_TMP/managed.json"
}
rw_verify_files() {
    local path sum parent
    while IFS=$'\t' read -r path sum; do
        [[ $path != /* && $path != *'..'* && $path != *$'\n'* ]] || rw_die 'Unsafe path in the manifest.'
        parent=$RW_OUT/$path
        while [[ $parent != "$RW_OUT" ]]; do [[ ! -L $parent ]] || rw_die 'A managed path contains a symbolic link.'; parent=${parent%/*}; done
        [[ -f $RW_OUT/$path && $(sha256sum "$RW_OUT/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Managed file $path changed; review is required."
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$RW_OUT/manifest.json")
}
rw_doctor() {
    local id state service node_uuid attempts
    : > "$RW_TMP/doctor-tokens.jsonl"
    printf 'null\n' > "$RW_TMP/doctor-mfa.json"
    rw_owned; rw_docker_ownership
    [[ $(jq -r '.status' "$RW_OUT/manifest.json") != node-prepared-awaiting-attachment ]] || rw_die 'The node is prepared but is not attached to a panel yet.'
    rw_compose --profile public --profile node ps --services --status running > "$RW_TMP/running-services" || rw_die 'Cannot list running services.'
    while IFS= read -r service; do
        grep -Fxq "$service" "$RW_TMP/running-services" || rw_die "Running service $service is missing."
    done < <(jq -r '.services|keys[]' "$RW_OUT/compose.json")
    [[ $(stat -c %a "$RW_OUT/private") == 700 ]] || rw_die 'private/ must have mode 0700.'
    while IFS= read -r -d '' id; do [[ $(stat -c %a "$id") == 600 ]] || rw_die 'A secret file has overly permissive permissions.'; done < <(find "$RW_OUT/private" -type f -print0)
    local -a ids=()
    docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" > "$RW_TMP/doctor-ids" || rw_die 'Cannot list owned containers.'
    mapfile -t ids < "$RW_TMP/doctor-ids"
    (( ${#ids[@]} )) || rw_die 'No owned containers are running.'
    docker inspect --format '{{.Id}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{with index .State "Health"}}{{.Status}}{{else}}none{{end}}' "${ids[@]}" > "$RW_TMP/doctor-states" || rw_die 'Cannot inspect container health.'
    local health
    while read -r id service state health; do
        [[ $state == running ]] || rw_die "Service $service is in state $state."
        state=$health
        for ((attempts=0; attempts<60; attempts++)); do
            [[ $state == starting ]] || break
            sleep 2
            state=$(docker inspect --format '{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}' "$id")
        done
        [[ $state == healthy || $state == none ]] || rw_die "Healthcheck $service: $state."
    done < "$RW_TMP/doctor-states"
    if [[ $RW_ROLE != node ]]; then
        rw_wait_panel
        rw_tokens_status > "$RW_TMP/doctor-tokens.jsonl" || rw_die 'Panel tokens need recovery: run rwctl tokens rotate.'
        rw_mfa_status > "$RW_TMP/doctor-mfa.json"
        while IFS= read -r node_uuid; do
            rw_wait_node "$node_uuid" "$RW_TMP/node-health.json"
        done < <(jq -r '.nodes[].node_uuid' "$RW_OUT/inventory.json")
    fi
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" --slurpfile tokens "$RW_TMP/doctor-tokens.jsonl" --slurpfile mfa "$RW_TMP/doctor-mfa.json" '{schema_version:1,environment_id:$e,role:$role,containers_running:true,client_acceptance_required:true,tokens:$tokens,mfa:$mfa[0]}'
}
rw_resource_plan() {
    local kind=$1
    local -a ids=()
    docker "$kind" ls -q --filter "label=com.docker.compose.project=$RW_PROJECT" > "$RW_TMP/$kind-ids" || rw_die 'Cannot list Docker resources.'
    mapfile -t ids < "$RW_TMP/$kind-ids"
    (( ${#ids[@]} )) || return 0
    docker inspect --type "$kind" --format '{{json .Labels}}' "${ids[@]}" > "$RW_TMP/$kind-labels.jsonl" || rw_die 'Cannot inspect Docker resources.'
    jq -se --arg owner "$RW_OWNER" --argjson count "${#ids[@]}" 'length==$count and all(.[]; .["io.pdm.remnawave.installation"]==$owner)' "$RW_TMP/$kind-labels.jsonl" >/dev/null || rw_die 'The Docker resource belongs to another installation.'
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort
}
rw_uninstall() {
    rw_owned
    rw_ssh_idle
    if [[ ${RW_PREPARED_ONLY:-0} == 1 ]]; then
        [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared ]] || rw_die 'prepared-only cannot remove an installation that has been started.'
        [[ ${RW_PURGE:-0} == 0 ]] || rw_die 'prepared-only and purge cannot be combined.'
        printf '[]\n' > "$RW_TMP/containers.json"
        : > "$RW_TMP/networks"; : > "$RW_TMP/volumes"
    else
        docker info >/dev/null 2>&1 || rw_die 'Docker is unavailable; installation files were retained.'
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]' > "$RW_TMP/containers.json"
        rw_resource_plan network > "$RW_TMP/networks"
        rw_resource_plan volume > "$RW_TMP/volumes"
    fi
    rw_verify_files
    if [[ ${RW_DRY_RUN:-0} == 1 ]]; then
        jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --slurpfile containers "$RW_TMP/containers.json" --rawfile volumes "$RW_TMP/volumes" --argjson purge "${RW_PURGE:-0}" '{environment_id:$e,directory:$path,containers:$containers[0],volumes:($volumes|split("\n")|map(select(length>0))),purge:($purge==1),read_only:true}'; return
    fi
    rw_root
    if [[ ${RW_YES:-0} != 1 ]]; then
        rw_info "Remove only $RW_PROJECT in $RW_OUT. Docker data: $([[ ${RW_PURGE:-0} == 1 ]] && printf delete || printf retain)."
        local confirm; read -r -p "Type $RW_ENV to confirm: " confirm
        [[ $confirm == "$RW_ENV" ]] || { rw_info 'Cancelled.'; return; }
    fi
    rw_lock; rw_verify_files
    if [[ ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]|sort' > "$RW_TMP/current-containers.json"
        jq 'sort' "$RW_TMP/containers.json" > "$RW_TMP/planned-containers.json"
        cmp -s "$RW_TMP/current-containers.json" "$RW_TMP/planned-containers.json" || rw_die 'The container inventory changed after confirmation.'
        rw_resource_plan network > "$RW_TMP/current-networks"
        rw_resource_plan volume > "$RW_TMP/current-volumes"
        cmp -s "$RW_TMP/networks" "$RW_TMP/current-networks" && cmp -s "$RW_TMP/volumes" "$RW_TMP/current-volumes" || rw_die 'The network or volume inventory changed after confirmation.'
    fi
    if [[ -f $RW_OUT/private/security-state.json && $(jq -r '.status' "$RW_OUT/private/security-state.json") == armed ]]; then
        rw_security_revert
        systemctl stop "$RW_PROJECT-ufw-revert.timer" >/dev/null 2>&1 || true
    fi
    if [[ ${RW_PURGE:-0} != 1 && ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        local recovery
        recovery=/var/backups/pdm-remnawave/$RW_ENV-config-$(date -u +%Y%m%dT%H%M%SZ).tgz
        mkdir -p /var/backups/pdm-remnawave; chmod 700 /var/backups/pdm-remnawave
        tar -C "$RW_OUT" -czf "$recovery" --files-from <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf 'manifest.json\n')
        chmod 600 "$recovery"
        rw_info "Private configuration/key backup for retained volumes: $recovery"
    fi
    if [[ $(jq -r '.existing_caddy_updated // false' "$RW_OUT/manifest.json") == true ]]; then
        local file container
        file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'The existing Caddy configuration changed; automatic route restoration stopped.'
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    fi
    local id
    local -a containers=()
    mapfile -t containers < <(jq -r '.[]' "$RW_TMP/containers.json")
    if (( ${#containers[@]} )); then
        docker stop -t 30 "${containers[@]}" >/dev/null
        docker rm "${containers[@]}" >/dev/null
    fi
    while IFS= read -r id; do [[ -z $id ]] || docker network rm "$id" >/dev/null; done < "$RW_TMP/networks"
    if [[ ${RW_PURGE:-0} == 1 ]]; then while IFS= read -r id; do [[ -z $id ]] || docker volume rm "$id" >/dev/null; done < "$RW_TMP/volumes"; fi
    if [[ $(jq -r '.ufw_rules_added // false' "$RW_OUT/manifest.json") == true ]]; then
        rw_security_remove_rules
    fi
    if [[ $(jq -r '.firewall_installed // false' "$RW_OUT/manifest.json") == true ]]; then
        local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
        [[ -f $unit ]] && grep -qF "$RW_OWNER" "$unit" || rw_die 'Firewall systemd unit ownership could not be verified.'
        systemctl disable "$RW_PROJECT-firewall.service" >/dev/null; rm -f -- "$unit"; systemctl daemon-reload
        nft list table inet "$RW_TABLE" >/dev/null 2>&1 && nft delete table inet "$RW_TABLE"
    fi
    # Delete only recorded files. Unknown backups/operator files and nonempty directories remain.
    while IFS= read -r id; do rm -f -- "$RW_OUT/$id"; done < <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json")
    rm -f -- "$RW_OUT/manifest.json" "$RW_OUT/.rw.lock"
    find "$RW_OUT" -depth -type d -empty -delete
    rw_info 'Removal complete. Unrelated containers, images, Docker Engine, SSH and shared firewall rules were retained.'
}
rw_backup() {
    local archive=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-$(date -u +%Y%m%dT%H%M%SZ).tgz} id name image build
    archive=$(realpath -m -- "$archive")
    [[ $archive != "$RW_OUT"/* && ! -e $archive ]] || rw_die 'Backup must be a new file outside the installation directory.'
    rw_owned; rw_root; rw_lock; rw_docker_ownership; rw_verify_files; rw_ssh_idle
    mkdir -p -- "$(dirname -- "$archive")"
    build=$(mktemp -d "$RW_TMP/backup.XXXXXX")
    [[ -z $(find "$RW_OUT" -type l -print -quit) ]] || rw_die 'A symbolic link exists in the installation directory; backup stopped.'
    cp -a -- "$RW_OUT" "$build/installation"
    jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --arg owner "$RW_OWNER" --arg time "$(date -u +%FT%TZ)" '{schema_version:1,environment_id:$e,installation_path:$path,ownership_label:$owner,created_at_utc:$time}' > "$build/metadata.json"
    if [[ $RW_ROLE != node ]]; then rw_compose exec -T rw_db pg_dump -U postgres -d remnawave -Fc > "$build/database.dump"; fi
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    id=$(rw_compose --profile public ps -q rw_caddy)
    if [[ -n $id ]]; then docker pause "$id" >/dev/null; RW_PAUSED_CADDY=$id; fi
    for name in caddy_data caddy_config; do
        docker volume inspect "${RW_PROJECT}_$name" --format '{{index .Labels "io.pdm.remnawave.installation"}}' | grep -qx "$RW_OWNER" || rw_die 'Caddy volume ownership could not be verified.'
        docker run --rm --network none --read-only --cap-drop ALL --entrypoint tar --mount "type=volume,src=${RW_PROJECT}_$name,dst=/data,readonly" "$image" -C /data -czf - . > "$build/$name.tgz"
    done
    if [[ -n ${RW_PAUSED_CADDY:-} ]]; then docker unpause "$RW_PAUSED_CADDY" >/dev/null; RW_PAUSED_CADDY=; fi
    tar -C "$build" -czf "$archive" .; chmod 600 "$archive"; tar -tzf "$archive" >/dev/null
    sha256sum "$archive" > "$archive.sha256"; chmod 600 "$archive.sha256"
    rw_info "Backup verified: $archive. Copy it off the VPS before cutover."
}
rw_node_attach() {
    local host=${RW_SSH:-} config=${RW_NODE_CONFIG:-} env remote
    [[ $RW_ROLE != node && $host =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*$ && -f $config ]] || rw_die 'node attach requires --ssh USER@HOST and --node-config FILE on the panel server.'
    rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    rw_wait_panel; rw_panel_login
    jq -ef "$RW_TMP/config.jq" "$config" > "$RW_TMP/node-config.json"
    [[ $(jq -r '.role' "$RW_TMP/node-config.json") == node ]] || rw_die 'A node-role configuration is required.'
    env=$(jq -r '.environment_id' "$RW_TMP/node-config.json"); remote=/opt/pdm-remnawave/$env
    local -a ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    local remote_uid prefix=
    remote_uid=$(ssh "${ssh_options[@]}" "$host" 'id -u')
    [[ $remote_uid =~ ^[0-9]+$ ]] || rw_die 'The SSH user UID could not be verified.'
    if [[ $remote_uid != 0 ]]; then prefix='sudo -n '; ssh "${ssh_options[@]}" "$host" 'sudo -n true'; fi
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' preflight --config '$remote/config.json' --output '$remote'"
    local local_fp remote_fp
    local_fp=$(jq -Sc . "$RW_TMP/node-config.json" | sha256sum | cut -d' ' -f1)
    remote_fp=$(ssh "${ssh_options[@]}" "$host" "${prefix}jq -r .config_fingerprint '$remote/manifest.json'")
    [[ $local_fp == "$remote_fp" ]] || rw_die 'Local node parameters do not match the prepared SSH host.'
    ssh "${ssh_options[@]}" "$host" "${prefix}cat '$remote/private/xray-profile.json'" > "$RW_TMP/remote-profile.json"
    RW_MUTATING=1
    rw_register_node "$RW_TMP/node-config.json" "$RW_TMP/connection.json" "$(jq -r '.management_address' "$RW_TMP/node-config.json")" "$RW_TMP/remote-profile.json"
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' node receive --output '$remote'" < "$RW_TMP/connection.json"
    local uuid
    uuid=$(jq -er '.node_uuid' "$RW_TMP/connection.json")
    rw_wait_node "$uuid" "$RW_TMP/attached-node.json"
    rw_info 'Node attached. Existing users were not granted access automatically.'
}
rw_node_receive() {
    rw_root; rw_owned
    [[ $RW_ROLE == node ]] || rw_die 'node receive supports standalone nodes only.'
    rw_lock; RW_MUTATING=1
    cat > "$RW_TMP/received-connection.json"
    RW_CONNECTION=$RW_TMP/received-connection.json
    rw_apply; rw_track_files
}
