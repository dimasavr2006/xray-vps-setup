# shellcheck shell=bash
rw_resource_checks() {
    local total available free required minram mincpu cpus image cached=0 path=$RW_OUT id limits credit=0
    total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    available=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    cpus=$(getconf _NPROCESSORS_ONLN)
    minram=1536; mincpu=1
    if [[ $RW_ROLE == node ]]; then minram=1024
    elif [[ $(rw_cfg '.resources.purpose') == production ]]; then minram=4096; mincpu=2; fi
    (( total >= minram && cpus >= mincpu )) || rw_die 'Недостаточно RAM/CPU для выбранного назначения.'
    limits=$(rw_memory_limits | jq --arg role "$RW_ROLE" 'if $role=="node" then {rw_caddy,rw_node}
      elif $role=="panel" then del(.rw_node) else . end')
    if rw_stats_enabled; then limits=$(jq '.rw_stats=96' <<< "$limits"); fi
    required=$(jq '[.[]]|add' <<< "$limits")
    # A prepared manifest has no running memory reservation. Credit only this
    # installation's running containers, up to each requested hard limit.
    if [[ -f $RW_OUT/manifest.json ]] && command -v docker >/dev/null 2>&1; then
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            credit=$(docker inspect "$id" | jq --arg owner "$RW_OWNER" --arg cfg "$RW_OUT/compose.json" --argjson limits "$limits" '
              [.[0]|select(.State.Running and .Config.Labels["io.pdm.remnawave.installation"]==$owner
              and .Config.Labels["com.docker.compose.project.config_files"]==$cfg) |
              (.Config.Labels["com.docker.compose.service"]) as $s |
              select($limits[$s]!=null and .HostConfig.Memory>0) |
              [(.HostConfig.Memory/1048576|floor),$limits[$s]]|min]|add // 0')
            required=$((required-credit))
        done < <(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    fi
    # Compact tests reserve host headroom as well as every container's hard limit.
    if [[ $(rw_cfg '.resources.profile') == compact-test ]]; then required=$((required+128));
    elif [[ $RW_ROLE == node ]]; then required=$((required+128)); fi
    (( available >= required )) || rw_die "Для новых контейнеров требуется $required MiB свободной RAM сверх действующих служб."
    while [[ ! -d $path ]]; do path=$(dirname -- "$path"); done
    free=$(df -PB1 "$path" | awk 'NR==2 {print $4}')
    required=$(jq -r '(.resources|.image_gib+.data_gib+.restore_gib+.reserve_gib) * 1073741824 | ceil' "$RW_CFG")
    # Cached pinned images already consume disk space and need no second copy.
    # Credit their budget only after checking every image needed by this role.
    if command -v docker >/dev/null 2>&1; then
        cached=1
        while IFS= read -r image; do
            docker image inspect "$image" >/dev/null 2>&1 || cached=0
        done < <(rw_versions | jq -r --arg role "$RW_ROLE" '.components|to_entries[]|select(if $role=="node" then .key=="node" or .key=="caddy_auth" elif $role=="panel" then .key!="node" else true end)|.value.image')
    fi
    if (( cached )); then required=$(jq -r '(.resources|.data_gib+.restore_gib+.reserve_gib)*1073741824|ceil' "$RW_CFG"); fi
    if [[ $RW_ROLE != node && $(rw_cfg '.resources.purpose') == production ]]; then (( required >= 21474836480 )) || required=21474836480; fi
    (( free >= required )) || rw_die 'Недостаточно места для образов, данных, восстановления и резерва; чужие данные не очищаются.'
}
rw_dns_checks() {
    local domain family
    while IFS= read -r domain; do
        : > "$RW_TMP/dns.txt"
        for family in A AAAA; do
            dig +time=3 +tries=1 +noall +answer +comments "$domain" "$family" > "$RW_TMP/dig-answer.txt" || rw_die "DNS недоступен: $domain"
            grep -q 'status: NOERROR' "$RW_TMP/dig-answer.txt" || rw_die "Ответ DNS для $domain/$family не подтверждён."
            awk '$4=="A" || $4=="AAAA" {print $5}' "$RW_TMP/dig-answer.txt" >> "$RW_TMP/dns.txt"
        done
        # CNAMEs are excluded, but every A/AAAA address must match the declared set.
        { rw_config_filter | sed '/^\.$/,$d'; printf '\n[inputs|select(ip)|ipnorm]|unique\n'; } > "$RW_TMP/dns.jq"
        jq -Rn -f "$RW_TMP/dns.jq" < "$RW_TMP/dns.txt" > "$RW_TMP/dns.json"
        jq -e --slurpfile actual "$RW_TMP/dns.json" '.public_addresses == $actual[0]' "$RW_CFG" >/dev/null || rw_die "A/AAAA домена $domain не совпадают с public_addresses."
    done < <(jq -r '.domains[]' "$RW_CFG")
}
rw_docker_ownership() {
    local id owner project configs
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        owner=$(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id")
        project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$id")
        configs=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$id")
        [[ $owner == "$RW_OWNER" && $project == "$RW_PROJECT" && $configs == "$RW_OUT/compose.json" ]] || rw_die 'Одноимённый Compose-проект принадлежит другой установке.'
    done < <(docker ps -aq --filter "label=com.docker.compose.project=$RW_PROJECT")
}
rw_port_checks() {
    local name port id pids row socket_pids owned_ids publication
    owned_ids=$(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    : > "$RW_TMP/owned-pids"
    for id in $owned_ids; do docker top "$id" -eo pid | awk 'NR>1 && $1~/^[0-9]+$/ {print $1}' >> "$RW_TMP/owned-pids"; done
    while IFS=$'\t' read -r name port; do
        while IFS= read -r row; do
            [[ -n $row ]] || continue
            socket_pids=$(grep -oE 'pid=[0-9]+' <<< "$row" | cut -d= -f2 || true)
            [[ -n $socket_pids ]] || rw_die "Неизвестный владелец TCP $port ($name)."
            for pids in $socket_pids; do
                if ! grep -qx "$pids" "$RW_TMP/owned-pids"; then
                    publication=0
                    if [[ $name == panel_api || $name == metrics || $name == subscription_api || $name == stats_api ]]; then
                        for id in $owned_ids; do
                            docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" | jq -e --arg port "$port" 'to_entries | any(.[]|.value[]?; .HostIp=="127.0.0.1" and .HostPort==$port)' >/dev/null && publication=1
                        done
                    fi
                    (( publication )) || rw_die "TCP $port ($name) занят другим сервисом."
                fi
            done
        done < <(ss -H -lntp | awk -v p="$port" '$4 ~ (":" p "$") {print}')
    done < <(jq -r '.ports|to_entries[]|[.key,.value]|@tsv' "$RW_CFG"; if rw_stats_enabled; then printf 'stats_api\t%s\n' "$(rw_stats_port)"; fi)
    # Docker NAT publications can exist without a listening docker-proxy process.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]] && continue
        docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" > "$RW_TMP/docker-ports.json"
        jq -e --slurpfile c "$RW_CFG" '[to_entries[]|select(.key|endswith("/tcp"))|.value[]?.HostPort|tonumber] as $used | ($c[0].ports|[.[]]) as $wanted | all($used[]; . as $port | ($wanted|index($port))==null)' "$RW_TMP/docker-ports.json" >/dev/null || rw_die 'Порт нового окружения уже опубликован другим Docker-контейнером.'
    done < <(docker ps -q)
}
rw_network_check() {
    [[ $RW_ROLE != node ]] || return 0
    local id
    : > "$RW_TMP/networks"
    : > "$RW_TMP/owned-bridges"
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        if [[ $(docker network inspect --format '{{index .Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]]; then
            docker network inspect "$id" | jq -r '.[0]|select(.Driver=="bridge")|.Options["com.docker.network.bridge.name"] // ("br-"+.Id[0:12])' >> "$RW_TMP/owned-bridges"
            continue
        fi
        docker network inspect --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$id" >> "$RW_TMP/networks"
    done < <(docker network ls -q)
    jq -Rn '[inputs]' < "$RW_TMP/owned-bridges" > "$RW_TMP/owned-bridges.json"
    ip -j route show | jq -r --arg subnet "$RW_SUBNET" --slurpfile bridges "$RW_TMP/owned-bridges.json" '.[]|select(.dst!="default")|select((.dst==$subnet and (.dev as $dev|$bridges[0]|index($dev)!=null))|not)|.dst' >> "$RW_TMP/networks"
    jq -Rn --arg subnet "$RW_SUBNET" '
      def number: split(".")|map(tonumber)|reduce .[] as $n (0;.*256+$n);
      def bounds: split("/") as $p | ($p[0]|number) as $n | pow(2;32-($p[1]|tonumber)) as $size | [($n/$size|floor)*$size,(($n/$size|floor)+1)*$size-1];
      ($subnet|bounds) as $wanted | [inputs|select(test("^[0-9.]+/[0-9]+$"))|bounds] | all(.[]; .[1]<$wanted[0] or .[0]>$wanted[1])' < "$RW_TMP/networks" | grep -qx true || rw_die 'docker_subnet пересекается с действующей сетью; задайте другой subnet явно.'
}
rw_preflight() {
    rw_os; rw_resource_checks; rw_dns_checks
    /usr/sbin/sshd -t || rw_die 'sshd -t не прошёл; SSH не изменялся.'
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || rw_die 'Не подтверждена синхронизация времени.'
    nft -j list ruleset >/dev/null || rw_die 'Невозможно прочитать текущий firewall.'
    rw_docker_ownership; rw_port_checks; rw_network_check
    if [[ $RW_MODE == fi-parallel ]]; then rw_existing_caddy_check; fi
    rw_info 'Preflight пройден: ОС, DNS A/AAAA, RAM/диск, порты, Docker и сети.'
}
