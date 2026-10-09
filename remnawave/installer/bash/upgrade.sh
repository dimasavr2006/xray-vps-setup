# shellcheck shell=bash
rw_upgrade_candidate() {
    local file=${RW_VERSION_FILE:-} old_major new_major
    if [[ -n $file ]]; then cat "$file" > "$RW_TMP/upgrade-versions.json"; else rw_versions > "$RW_TMP/upgrade-versions.json"; fi
    rw_versions_check "$RW_TMP/upgrade-versions.json"
    old_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json")
    new_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_TMP/upgrade-versions.json")
    [[ $old_major == "$new_major" ]] || rw_die 'Смена major PostgreSQL требует отдельного переноса данных.'
    jq -e --slurpfile old "$RW_OUT/versions.lock.json" '(.components.postgres.source_tag|split(".")|map(tonumber)) >= ($old[0].components.postgres.source_tag|split(".")|map(tonumber))' "$RW_TMP/upgrade-versions.json" >/dev/null || rw_die 'Понижение PostgreSQL выполняется восстановлением backup, а не upgrade.'
    jq --arg e "$RW_ENV" '.environment_id=$e' "$RW_TMP/upgrade-versions.json" > "$RW_TMP/upgrade-lock.json"
    rw_render_compose "$RW_TMP/upgrade-compose.json" "$RW_TMP/upgrade-lock.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node config --quiet || rw_die 'Некорректный Compose обновления.'
}
rw_upgrade_activate() {
    cat "$RW_TMP/upgrade-lock.json" | rw_atomic "$RW_OUT/versions.lock.json" || rw_die 'Не удалось записать lock обновления.'
    cat "$RW_TMP/upgrade-compose.json" | rw_atomic "$RW_OUT/compose.json" || rw_die 'Не удалось записать Compose обновления.'
    rw_manifest_set '.status="upgrading"'
    rw_track_files
    rw_start_existing
}
rw_upgrade_rollback() {
    local source=$RW_UPGRADE_SOURCE path
    rw_stop_writers
    # A failed addon activation may have introduced a service absent from the snapshot.
    if ! jq -e '.stats.enabled==true' "$source/manifest.json" >/dev/null; then
        local id
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]] || rw_die 'Чужой stats container при откате.'
            docker rm -f "$id" >/dev/null
        done < <(docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" --filter label=com.docker.compose.service=rw_stats)
    fi
    while IFS= read -r path; do
        [[ $path != rwctl && $path != private/.managed-paths ]] || continue
        cat "$source/$path" | rw_atomic "$RW_OUT/$path" || rw_die 'Не удалось вернуть файл отката.'
    done < <(jq -r '.managed_files[].path' "$source/manifest.json")
    cat "$source/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
    rw_stats_assets; rw_stats_patch
    rw_restore_data "${source%/installation}"
    rw_start_existing
    rw_install_ctl
    rw_manifest_set '.status="running-awaiting-acceptance"|.last_upgrade="rolled-back"'
    jq -n --arg archive "$RW_UPGRADE_ARCHIVE" '{status:"rolled-back",backup:$archive}' | rw_atomic "$RW_OUT/private/upgrade.json"
    rw_track_files
}
rw_upgrade_abort() {
    RW_UPGRADE_PENDING=0
    if (rw_upgrade_rollback > "$RW_TMP/rollback.log" 2>&1); then
        rw_info 'Обновление не прошло: прежние версии, БД и Caddy восстановлены из backup.'
    else
        cat "$RW_TMP/rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_info "Автоматический откат не завершён. Backup: $RW_UPGRADE_ARCHIVE; диагностика: private/rollback-error.log."
        return 1
    fi
}
rw_upgrade() {
    rw_owned; rw_verify_files; rw_ssh_idle; rw_versions_check "$RW_OUT/versions.lock.json"
    rw_upgrade_candidate
    if (( RW_DRY_RUN )); then
        jq -n --slurpfile old "$RW_OUT/versions.lock.json" --slurpfile new "$RW_TMP/upgrade-lock.json" '{before:($old[0].components|map_values(.image)),after:($new[0].components|map_values(.image)),backup_required:true,rollback_includes_database:true,read_only:true}'; return
    fi
    rw_root; rw_os; rw_docker_ownership; rw_resource_checks; rw_lock
    if [[ $RW_ROLE != node && $(jq -r '.components.panel.image' "$RW_OUT/versions.lock.json") != $(jq -r '.components.panel.image' "$RW_TMP/upgrade-lock.json") ]]; then
        [[ $(rw_compose exec -T rw_db psql -At -U postgres -d remnawave -c "SELECT EXISTS(SELECT FROM information_schema.schemata WHERE schema_name='pdm_stats')") == f ]] || rw_die 'Для обновления панели с pdm_stats нужна проверенная миграция статистики.'
    fi
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node pull || rw_die 'Образы обновления не загружены; текущие сервисы не остановлены.'
    # Validate against isolated Caddy stores; a candidate cannot migrate live MFA state before backup.
    local validation
    validation=$(mktemp -d "$RW_TMP/validation.XXXXXX")
    mkdir "$validation/data" "$validation/config" || rw_die 'Не удалось создать изолированное хранилище проверки.'
    jq --arg data "$validation/data" --arg config "$validation/config" '.services.rw_caddy.network_mode="none" | .services.rw_caddy.volumes|=map(if startswith("caddy_data:") then $data+":/data" elif startswith("caddy_config:") then $config+":/config" else . end)' "$RW_TMP/upgrade-compose.json" > "$RW_TMP/validate-compose.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/validate-compose.json" --profile public run --rm --no-deps --entrypoint caddy rw_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$RW_TMP/candidate-validation.log" 2>&1 || rw_die 'Caddy-кандидат не прошёл проверку; текущий стек не остановлен.'
    RW_MUTATING=1
    # Freeze writers for a rollback point that does not discard concurrent user edits.
    rw_stop_writers
    RW_UPGRADE_ARCHIVE=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).tgz}
    RW_ARCHIVE=$RW_UPGRADE_ARCHIVE
    if ! (rw_backup > "$RW_TMP/upgrade-backup.log" 2>&1); then
        (rw_start_existing) || true
        rw_die 'Backup обновления не создан; запуск прежнего стека выполнен повторно.'
    fi
    rw_backup_open "$RW_UPGRADE_ARCHIVE"
    RW_UPGRADE_SOURCE=$RW_BACKUP/installation
    RW_UPGRADE_PENDING=1
    if (rw_upgrade_activate > "$RW_TMP/upgrade-activate.log" 2>&1); then
        RW_UPGRADE_PENDING=0
        rw_manifest_set '.status="running-awaiting-acceptance"|.last_upgrade="verified"'
        rw_install_ctl
        jq -n --arg archive "$RW_UPGRADE_ARCHIVE" '{status:"verified",backup:$archive}' | rw_atomic "$RW_OUT/private/upgrade.json"
        rw_track_files
        rw_info "Обновление проверено. Backup для отката: $RW_UPGRADE_ARCHIVE"
    else
        cat "$RW_TMP/upgrade-activate.log" | rw_atomic "$RW_OUT/private/upgrade-error.log"
        rw_upgrade_abort
        rw_die 'Кандидат не прошёл приёмку; выполнен откат.'
    fi
}
rw_rollback() {
    [[ -n ${RW_ARCHIVE:-} ]] || rw_die 'rollback требует --archive FILE.'
    rw_owned; rw_verify_files
    rw_backup_open "$RW_ARCHIVE"
    local source=$RW_BACKUP/installation destination=$RW_OUT archive=$RW_ARCHIVE safety
    jq -e --arg owner "$RW_OWNER" --arg env "$RW_ENV" '.ownership_label==$owner and .environment_id==$env' "$source/manifest.json" >/dev/null || rw_die 'Backup отката принадлежит другой установке.'
    jq -Sc . "$RW_CFG" > "$RW_TMP/rollback-current-config.json"
    jq -Sc . "$source/config.json" > "$RW_TMP/rollback-source-config.json"
    cmp -s "$RW_TMP/rollback-current-config.json" "$RW_TMP/rollback-source-config.json" || rw_die 'Config backup отката не совпадает с установкой.'
    [[ $(jq -r '.components.postgres.source_tag|split(".")[0]' "$source/versions.lock.json") == $(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json") ]] || rw_die 'Major PostgreSQL в backup отката не совпадает.'
    if (( RW_DRY_RUN )); then jq -n --arg archive "$archive" '{backup:$archive,database_replaced:true,safety_backup_required:true,read_only:true}'; return; fi
    rw_root; rw_os; rw_docker_ownership; rw_lock
    rw_stop_writers
    safety=/var/backups/pdm-remnawave/$RW_ENV-pre-rollback-$(date -u +%Y%m%dT%H%M%SZ).tgz
    RW_ARCHIVE=$safety
    if ! (rw_backup); then (rw_start_existing) || true; rw_die 'Снимок перед откатом не создан.'; fi
    RW_OUT=$destination; RW_UPGRADE_SOURCE=$source; RW_UPGRADE_ARCHIVE=$archive
    RW_MUTATING=1
    if (rw_upgrade_rollback > "$RW_TMP/manual-rollback.log" 2>&1); then
        rw_info "Откат проверен. Снимок состояния перед откатом: $safety"
    else
        cat "$RW_TMP/manual-rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_die "Откат не завершён. Снимок до операции: $safety"
    fi
}
