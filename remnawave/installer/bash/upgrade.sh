# shellcheck shell=bash
rw_upgrade_candidate() {
    local file=${RW_VERSION_FILE:-} old_major new_major key
    if [[ -n $file ]]; then cat "$file" > "$RW_TMP/upgrade-versions.json"; else rw_versions > "$RW_TMP/upgrade-versions.json"; fi
    rw_versions_check "$RW_TMP/upgrade-versions.json"
    case ${RW_COMPONENT:-all} in
        all) :;;
        panel|subscription) [[ $RW_ROLE != node ]] || rw_die 'This installation has no panel or subscription component.'; key=$RW_COMPONENT;;
        node) [[ $RW_ROLE != panel ]] || rw_die 'This installation has no node component.'; key=node;;
        caddy) key=caddy_auth;;
        *) rw_die '--component must be all, panel, node, caddy or subscription.';;
    esac
    if [[ -n ${key:-} ]]; then
        jq --arg key "$key" --slurpfile candidate "$RW_TMP/upgrade-versions.json" '.components[$key]=$candidate[0].components[$key]' "$RW_OUT/versions.lock.json" > "$RW_TMP/component-versions.json"
        mv "$RW_TMP/component-versions.json" "$RW_TMP/upgrade-versions.json"
    fi
    old_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json")
    new_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_TMP/upgrade-versions.json")
    [[ $old_major == "$new_major" ]] || rw_die 'Changing the PostgreSQL major version requires a separate data migration.'
    jq -e --slurpfile old "$RW_OUT/versions.lock.json" '(.components.postgres.source_tag|split(".")|map(tonumber)) >= ($old[0].components.postgres.source_tag|split(".")|map(tonumber))' "$RW_TMP/upgrade-versions.json" >/dev/null || rw_die 'Downgrade PostgreSQL by restoring a backup, not by running upgrade.'
    jq --arg e "$RW_ENV" '.environment_id=$e' "$RW_TMP/upgrade-versions.json" > "$RW_TMP/upgrade-lock.json"
    rw_render_compose "$RW_TMP/upgrade-compose.json" "$RW_TMP/upgrade-lock.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node config --quiet || rw_die 'Invalid upgrade Compose configuration.'
}
rw_upgrade_activate() {
    cat "$RW_TMP/upgrade-lock.json" | rw_atomic "$RW_OUT/versions.lock.json" || rw_die 'Cannot write the upgrade version lock.'
    cat "$RW_TMP/upgrade-compose.json" | rw_atomic "$RW_OUT/compose.json" || rw_die 'Cannot write the upgrade Compose configuration.'
    rw_manifest_set '.status="upgrading"'
    rw_track_files
    if [[ ${RW_COMPONENT:-all} == node || ${RW_COMPONENT:-all} == subscription ]]; then
        rw_compose --profile public --profile node up -d --no-deps --force-recreate --wait --wait-timeout 90 "rw_$RW_COMPONENT" || return 1
        rw_doctor
    else rw_start_existing; fi
}
rw_upgrade_component_rollback() {
    # The panel kept accepting writes. Never restore its old database snapshot
    # while rolling back a node or read-only subscription service.
    cat "$RW_UPGRADE_SOURCE/versions.lock.json" | rw_atomic "$RW_OUT/versions.lock.json" || return 1
    rw_render_compose || return 1
    rw_compose --profile public --profile node up -d --no-deps --force-recreate --wait --wait-timeout 90 "rw_$RW_COMPONENT" || return 1
    rw_doctor || return 1
    rw_manifest_set '.status="running-awaiting-acceptance"|.last_upgrade="rolled-back"' || return 1
    rw_track_files || return 1
}
rw_upgrade_rollback() {
    local source=$RW_UPGRADE_SOURCE path
    rw_stop_writers
    # A failed addon activation may have introduced a service absent from the snapshot.
    if ! jq -e '.stats.enabled==true' "$source/manifest.json" >/dev/null; then
        local id
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]] || rw_die 'The statistics container belongs to another installation.'
            docker rm -f "$id" >/dev/null
        done < <(docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" --filter label=com.docker.compose.service=rw_stats)
    fi
    while IFS= read -r path; do
        [[ $path != rwctl && $path != private/.managed-paths ]] || continue
        cat "$source/$path" | rw_atomic "$RW_OUT/$path" || rw_die 'Cannot restore a rollback file.'
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
    if [[ ${RW_COMPONENT:-all} == node || ${RW_COMPONENT:-all} == subscription ]]; then
        if (rw_upgrade_component_rollback > "$RW_TMP/rollback.log" 2>&1); then
            rw_info 'Component upgrade failed; previous images restored without replacing panel data.'
            return
        fi
        cat "$RW_TMP/rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_info 'Component rollback failed; see private/rollback-error.log.'
        return 1
    fi
    if (rw_upgrade_rollback > "$RW_TMP/rollback.log" 2>&1); then
        rw_info 'Upgrade failed: previous images, database and Caddy were restored from backup.'
    else
        cat "$RW_TMP/rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_info "Automatic rollback did not complete. Backup: $RW_UPGRADE_ARCHIVE; diagnostics: private/rollback-error.log."
        return 1
    fi
}
rw_upgrade() {
    rw_owned; rw_verify_files; rw_ssh_idle; rw_versions_check "$RW_OUT/versions.lock.json"
    rw_upgrade_candidate
    if (( RW_DRY_RUN )); then
        jq -n --arg component "${RW_COMPONENT:-all}" --slurpfile old "$RW_OUT/versions.lock.json" --slurpfile new "$RW_TMP/upgrade-lock.json" '{component:$component,before:($old[0].components|map_values(.image)),after:($new[0].components|map_values(.image)),backup_required:true,rollback_includes_database:($component!="node" and $component!="subscription"),read_only:true}'; return
    fi
    rw_root; rw_os; rw_docker_ownership; rw_resource_checks; rw_lock
    if [[ $RW_ROLE != node && $(jq -r '.components.panel.image' "$RW_OUT/versions.lock.json") != $(jq -r '.components.panel.image' "$RW_TMP/upgrade-lock.json") ]]; then
        [[ $(rw_compose exec -T rw_db psql -At -U postgres -d remnawave -c "SELECT EXISTS(SELECT FROM information_schema.schemata WHERE schema_name='pdm_stats')") == f ]] || rw_die 'Updating a panel with pdm_stats requires a verified statistics migration.'
    fi
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node pull || rw_die 'Upgrade images could not be pulled; current services were not stopped.'
    # Validate against isolated Caddy stores; a candidate cannot migrate live MFA state before backup.
    local validation
    validation=$(mktemp -d "$RW_TMP/validation.XXXXXX")
    mkdir "$validation/data" "$validation/config" || rw_die 'Cannot create isolated validation storage.'
    jq --arg data "$validation/data" --arg config "$validation/config" '.services.rw_caddy.network_mode="none" | .services.rw_caddy.volumes|=map(if startswith("caddy_data:") then $data+":/data" elif startswith("caddy_config:") then $config+":/config" else . end)' "$RW_TMP/upgrade-compose.json" > "$RW_TMP/validate-compose.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/validate-compose.json" --profile public run --rm --no-deps --entrypoint caddy rw_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$RW_TMP/candidate-validation.log" 2>&1 || rw_die 'Candidate Caddy validation failed; the current stack was not stopped.'
    RW_MUTATING=1
    # Freeze writers for a rollback point that does not discard concurrent user edits.
    if [[ ${RW_COMPONENT:-all} != node && ${RW_COMPONENT:-all} != subscription ]]; then rw_stop_writers; fi
    RW_UPGRADE_ARCHIVE=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).tgz}
    RW_ARCHIVE=$RW_UPGRADE_ARCHIVE
    if ! (rw_backup > "$RW_TMP/upgrade-backup.log" 2>&1); then
        if [[ ${RW_COMPONENT:-all} != node && ${RW_COMPONENT:-all} != subscription ]]; then (rw_start_existing) || true; fi
        rw_die 'Upgrade backup failed; the previous stack remains active.'
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
        rw_info "Upgrade verified. Rollback backup: $RW_UPGRADE_ARCHIVE"
    else
        cat "$RW_TMP/upgrade-activate.log" | rw_atomic "$RW_OUT/private/upgrade-error.log"
        rw_upgrade_abort
        rw_die 'Candidate acceptance failed; rollback completed.'
    fi
}
rw_rollback() {
    [[ -n ${RW_ARCHIVE:-} ]] || rw_die 'rollback requires --archive FILE.'
    rw_owned; rw_verify_files
    rw_backup_open "$RW_ARCHIVE"
    local source=$RW_BACKUP/installation destination=$RW_OUT archive=$RW_ARCHIVE safety
    jq -e --arg owner "$RW_OWNER" --arg env "$RW_ENV" '.ownership_label==$owner and .environment_id==$env' "$source/manifest.json" >/dev/null || rw_die 'The rollback backup belongs to another installation.'
    jq -Sc . "$RW_CFG" > "$RW_TMP/rollback-current-config.json"
    jq -Sc . "$source/config.json" > "$RW_TMP/rollback-source-config.json"
    cmp -s "$RW_TMP/rollback-current-config.json" "$RW_TMP/rollback-source-config.json" || rw_die 'Rollback backup configuration does not match this installation.'
    [[ $(jq -r '.components.postgres.source_tag|split(".")[0]' "$source/versions.lock.json") == $(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json") ]] || rw_die 'PostgreSQL major version differs in the rollback backup.'
    if (( RW_DRY_RUN )); then jq -n --arg archive "$archive" '{backup:$archive,database_replaced:true,safety_backup_required:true,read_only:true}'; return; fi
    rw_root; rw_os; rw_docker_ownership; rw_lock
    rw_stop_writers
    safety=/var/backups/pdm-remnawave/$RW_ENV-pre-rollback-$(date -u +%Y%m%dT%H%M%SZ).tgz
    RW_ARCHIVE=$safety
    if ! (rw_backup); then (rw_start_existing) || true; rw_die 'The pre-rollback snapshot was not created.'; fi
    RW_OUT=$destination; RW_UPGRADE_SOURCE=$source; RW_UPGRADE_ARCHIVE=$archive
    RW_MUTATING=1
    if (rw_upgrade_rollback > "$RW_TMP/manual-rollback.log" 2>&1); then
        rw_info "Rollback verified. Pre-rollback snapshot: $safety"
    else
        cat "$RW_TMP/manual-rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_die "Rollback did not complete. Pre-operation snapshot: $safety"
    fi
}
