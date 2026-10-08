# shellcheck shell=bash
rw_archive_check() {
    local archive=$1 names=$RW_TMP/tar-names types=$RW_TMP/tar-types path normalized size free
    [[ -f $archive && ! -L $archive ]] || rw_die 'Архив должен быть обычным файлом.'
    tar --absolute-names -tzf "$archive" > "$names" || rw_die 'Архив повреждён.'
    tar --absolute-names -tvzf "$archive" > "$types" || rw_die 'Не удалось проверить типы записей архива.'
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' "$types" || rw_die 'Ссылки и специальные файлы в архиве запрещены.'
    : > "$RW_TMP/tar-normalized"
    while IFS= read -r path; do
        [[ $path =~ ^[A-Za-z0-9_./@+:-]+$ && $path != /* && $path != *$'\r'* ]] || rw_die 'Небезопасное имя в архиве.'
        normalized=$path
        while [[ $normalized == ./* ]]; do normalized=${normalized#./}; done
        normalized=${normalized%/}
        [[ $normalized != .. && $normalized != ../* && $normalized != */../* && $normalized != */.. ]] || rw_die 'Выход из каталога в архиве.'
        [[ $normalized != *//* && $normalized != */./* && $normalized != */. ]] || rw_die 'Неоднозначный путь в архиве.'
        printf '%s\n' "$normalized" >> "$RW_TMP/tar-normalized"
    done < "$names"
    [[ -z $(LC_ALL=C sort "$RW_TMP/tar-normalized" | uniq -d) ]] || rw_die 'Повторяющиеся пути в архиве.'
    size=$(awk '{sum+=$3} END {printf "%.0f",sum}' "$types")
    free=$(df -PB1 "$RW_TMP" | awk 'NR==2 {print $4}')
    (( free > size + 134217728 )) || rw_die 'Недостаточно места для распаковки архива.'
}
rw_versions_check() {
    jq -e '
      .schema_version==1 and (.components|keys)==["caddy_auth","node","panel","postgres","subscription","valkey"] and
      ([.components|to_entries[]|(.key as $key|.value.image|type=="string" and test(
        (if $key=="panel" then "^remnawave/backend" elif $key=="node" then "^remnawave/node"
         elif $key=="postgres" then "^(library/)?postgres" elif $key=="valkey" then "^valkey/valkey"
         elif $key=="caddy_auth" then "^remnawave/caddy-with-auth" else "^remnawave/subscription-page" end)+"@sha256:[a-f0-9]{64}$"))]|all) and
      (.components.postgres.source_tag|type=="string" and test("^[0-9]+\\.[0-9]+$"))' "$1" >/dev/null || rw_die 'Нужны закреплённые digest официальных образов и версия PostgreSQL.'
}
rw_backup_open() {
    local archive=$1 expected path sum source
    [[ -f $archive && ! -L $archive ]] || rw_die 'Backup должен быть обычным файлом, не ссылкой.'
    archive=$(realpath -e -- "$archive")
    [[ -f $archive.sha256 && ! -L $archive.sha256 ]] || rw_die 'Рядом с backup нужен файл .sha256.'
    expected=$(awk 'NR==1 {print $1}' "$archive.sha256")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ && $(wc -l < "$archive.sha256") == 1 ]] || rw_die 'Некорректный checksum backup.'
    [[ $(sha256sum "$archive" | cut -d' ' -f1) == "${expected,,}" ]] || rw_die 'Checksum backup не совпадает.'
    rw_archive_check "$archive"
    RW_BACKUP=$(mktemp -d "$RW_TMP/recovery.XXXXXX")
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$RW_BACKUP"
    source=$RW_BACKUP/installation
    [[ -f $source/config.json && -f $source/manifest.json && -f $source/private/secrets.json ]] || rw_die 'Backup не содержит установку.'
    jq -e '.schema_version==2 and .implementation=="bash-docker" and (.managed_files|type=="array")' "$source/manifest.json" >/dev/null || rw_die 'Несовместимый manifest backup.'
    while IFS=$'\t' read -r path sum; do
        [[ $path =~ ^[A-Za-z0-9_./-]+$ && $path != /* && $path != *'..'* && $sum =~ ^[a-f0-9]{64}$ ]] || rw_die 'Небезопасный manifest backup.'
        [[ -f $source/$path && $(sha256sum "$source/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Повреждён файл backup: $path"
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$source/manifest.json")
    rw_versions_check "$source/versions.lock.json"
    jq -e '
      ([.app_secret,.postgres_password,.metrics_password,.webhook_secret,.auth_password]|all(type=="string" and test("^[a-f0-9]{64}$"))) and
      (.admin_password|type=="string" and test("^Aa1[a-f0-9]{64}$")) and
      ([.reality_private,.reality_public]|all(type=="string" and test("^[A-Za-z0-9_-]{43}$"))) and
      (.short_id|test("^[a-f0-9]{16}$")) and (.xhttp_path|test("^/[a-f0-9]{32}$"))' "$source/private/secrets.json" >/dev/null || rw_die 'Несовместимые секреты backup.'
    for path in caddy_data caddy_config; do rw_archive_check "$RW_BACKUP/$path.tgz"; done
    if [[ $(jq -r '.role' "$source/config.json") != panel ]]; then
        grep -vEx 'NODE_PORT=[0-9]+|SECRET_KEY=[A-Za-z0-9+/=_-]+' "$source/private/node.env" > "$RW_TMP/bad-node-env" || true
        [[ ! -s $RW_TMP/bad-node-env && $(grep -c '^NODE_PORT=' "$source/private/node.env") == 1 && $(grep -c '^SECRET_KEY=' "$source/private/node.env") -le 1 ]] || rw_die 'Некорректный node.env в backup.'
        [[ $(sed -n 's/^NODE_PORT=//p' "$source/private/node.env") == $(jq -r '.ports.node_api' "$source/config.json") ]] || rw_die 'Порт node.env не совпадает с config.'
    fi
    RW_BACKUP_SHA=${expected,,}
}
rw_restore_config() {
    local requested=${RW_CONFIG:-} source=$RW_BACKUP/installation normalized
    rw_config_filter > "$RW_TMP/config.jq"
    jq -ef "$RW_TMP/config.jq" "$source/config.json" > "$RW_TMP/source-config.json" || rw_die 'Некорректный config backup.'
    if [[ -n $requested ]]; then
        jq -ef "$RW_TMP/config.jq" "$requested" > "$RW_TMP/target-config.json" || rw_die 'Некорректный config восстановления.'
        # IP/DNS ownership and the existing proxy may differ on a replacement host.
        for normalized in source target; do jq 'del(.public_addresses,.panel_addresses,.existing_caddy)' "$RW_TMP/$normalized-config.json" > "$RW_TMP/$normalized-comparable.json"; done
        cmp -s "$RW_TMP/source-comparable.json" "$RW_TMP/target-comparable.json" || rw_die 'При restore сохраняйте ID, роль, домены, порты и subnet; можно изменить только адреса и existing_caddy.'
    else requested=$RW_TMP/source-config.json; fi
    rw_config_load "$requested"
    [[ $(jq -r '.environment_id' "$source/manifest.json") == "$RW_ENV" ]] || rw_die 'ID backup не совпадает с config.'
}
rw_restore_files() {
    local source=$RW_BACKUP/installation path
    if [[ -f $RW_OUT/manifest.json ]]; then
        rw_owned
        jq -e --arg sha "$RW_BACKUP_SHA" '.status=="restoring" and .restore_archive_sha256==$sha' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Restore предназначен для пустой установки; существующую систему не перезаписываем.'
    else [[ ! -d $RW_OUT || -z $(find "$RW_OUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || rw_die 'Каталог восстановления не пуст.'; fi
    rw_lock; RW_MUTATING=1
    while IFS= read -r path; do
        [[ $path != rwctl && $path != compose.json && $path != config.json && $path != private/.managed-paths && $path != private/ssh-* ]] || continue
        cat "$source/$path" | rw_atomic "$RW_OUT/$path"
    done < <(jq -r '.managed_files[].path' "$source/manifest.json")
    # Never execute archived shell code or trust an archived Compose with host mounts.
    jq --arg owner "$RW_OWNER" --arg fp "$RW_FINGERPRINT" --arg sha "$RW_BACKUP_SHA" \
      '.api_namespace_owner //= .ownership_label | .ownership_label=$owner | .config_fingerprint=$fp | .status="restoring" | .restore_archive_sha256=$sha | .firewall_installed=false | .ufw_rules_added=false | .existing_caddy_updated=false | .managed_files=[] | del(.ssh)' "$source/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
    cat "$RW_CFG" | rw_atomic "$RW_OUT/config.json"
    if [[ $RW_ROLE != node ]]; then
        local token=$source/private/subscription.token
        [[ -s $token ]] && grep -qxE '[A-Za-z0-9._=+/-]+' "$token" || rw_die 'Нет проверенного API-токена подписок в backup.'
        { printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nREMNAWAVE_API_TOKEN='; cat "$token"; printf '\nTRUST_PROXY=1\n'; } | rw_atomic "$RW_OUT/private/subscription.env"
    fi
    rw_render_compose; rw_render_env; rw_render_caddy; rw_install_ctl
    rw_track_files
}
rw_stop_writers() {
    local -a services=()
    mapfile -t services < <(jq -r '.services|keys[]|select(.!="rw_db" and .!="rw_valkey")' "$RW_OUT/compose.json")
    rw_compose --profile public --profile node stop "${services[@]}" || rw_die 'Не удалось остановить пишущие сервисы.'
}
rw_restore_data() {
    local backup=$1 name image volume
    rw_docker_ownership
    rw_compose --profile public --profile node create || rw_die 'Не удалось создать контейнеры восстановления.'
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    for name in caddy_data caddy_config; do
        volume=${RW_PROJECT}_$name
        [[ $(docker volume inspect "$volume" --format '{{index .Labels "io.pdm.remnawave.installation"}}') == "$RW_OWNER" ]] || rw_die 'Чужой volume восстановления.'
        rw_archive_check "$backup/$name.tgz"
        # Only this validated, stopped volume is replaced; no host paths are mounted.
        docker run --rm --network none --cap-drop ALL --entrypoint sh --mount "type=volume,src=$volume,dst=/data" "$image" -c 'find /data -mindepth 1 -delete' || rw_die 'Не удалось очистить собственный Caddy volume.'
        docker run --rm -i --network none --cap-drop ALL --entrypoint tar --mount "type=volume,src=$volume,dst=/data" "$image" -C /data --no-same-owner --no-same-permissions -xzf - < "$backup/$name.tgz" || rw_die 'Не удалось восстановить Caddy volume.'
    done
    if [[ $RW_ROLE != node ]]; then
        [[ -s $backup/database.dump ]] || rw_die 'Нет dump PostgreSQL.'
        rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey || rw_die 'База/кеш восстановления не запустились.'
        rw_compose exec -T rw_db pg_restore --list < "$backup/database.dump" >/dev/null || rw_die 'Невалидный PostgreSQL dump.'
        # pg_restore --clean alone leaves objects introduced by a failed migration.
        # Writers are stopped; replace only this installation's database completely.
        rw_compose exec -T rw_db dropdb --if-exists --force -U postgres remnawave || rw_die 'Не удалось пересоздать собственную БД.'
        rw_compose exec -T rw_db createdb -U postgres -T template0 remnawave || rw_die 'Не удалось создать БД восстановления.'
        rw_compose exec -T rw_db pg_restore --exit-on-error --single-transaction -U postgres -d remnawave < "$backup/database.dump" || rw_die 'Восстановление PostgreSQL не завершилось.'
    fi
}
rw_start_existing() {
    if [[ $RW_ROLE != node ]]; then rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey rw_panel || rw_die 'Панель не прошла запуск.'; rw_wait_panel; rw_panel_login; fi
    rw_compose --profile public up -d rw_caddy || rw_die 'Caddy не запустился.'
    if [[ $RW_ROLE != node ]]; then rw_compose --profile public up -d rw_subscription || rw_die 'Подписки не запустились.'; fi
    if [[ $RW_ROLE != panel ]] && grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then rw_compose --profile node up -d rw_node || rw_die 'Нода не запустилась.'; fi
    rw_doctor
}
rw_restore() {
    [[ -n ${RW_ARCHIVE:-} ]] || rw_die 'restore требует --archive FILE.'
    rw_backup_open "$RW_ARCHIVE"; rw_restore_config
    if (( RW_DRY_RUN )); then
        jq -n --arg e "$RW_ENV" --arg dir "$RW_OUT" --arg sha "$RW_BACKUP_SHA" '{environment_id:$e,directory:$dir,archive_sha256:$sha,archive_verified:true,read_only:true}'; return
    fi
    rw_root; rw_os; rw_deps; rw_docker_install; rw_preflight
    rw_restore_files
    rw_compose --profile public --profile node pull
    rw_stop_writers; rw_restore_data "$RW_BACKUP"
    rw_firewall; rw_existing_caddy_apply
    rw_start_existing
    rw_manifest_set '.status="running-awaiting-acceptance"|.restored_at_utc=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))'
    rw_track_files
    rw_info 'Restore завершён: ключи, API ID, база, MFA и сертификаты сохранены.'
}
