# shellcheck shell=bash
rw_token_catalog() {
    rw_api GET /api/tokens '' "$RW_TMP/tokens.json" || rw_die 'Не удалось прочитать каталог токенов; изменения остановлены.'
    jq -e '.response.tokens|type=="array"' "$RW_TMP/tokens.json" >/dev/null || rw_die 'Неизвестный формат каталога токенов.'
}
rw_token_revoke() {
    local uuid=$1
    [[ $uuid =~ ^[a-f0-9-]{36}$ ]] || rw_die 'Некорректный UUID токена.'
    rw_token_catalog
    if jq -e --arg uuid "$uuid" '.response.tokens|any(.uuid==$uuid)' "$RW_TMP/tokens.json" >/dev/null; then
        # DELETE may have completed before its response was lost. Confirm absence.
        rw_api DELETE "/api/tokens/$uuid" '' "$RW_TMP/revoked.json" || true
        rw_token_catalog
        ! jq -e --arg uuid "$uuid" '.response.tokens|any(.uuid==$uuid)' "$RW_TMP/tokens.json" >/dev/null || rw_die 'Отзыв токена не подтверждён; повторите tokens rotate.'
    fi
}
rw_token_epoch() { date -u -d "$1" +%s; }
rw_token_record() {
    local key=$1 file=$2 epoch
    epoch=$(rw_token_epoch "$(jq -er '.expireAt' "$file")") || rw_die 'Неизвестный срок действия токена.'
    jq -e --argjson epoch "$epoch" '.uuid|test("^[a-f0-9-]{36}$")' "$file" >/dev/null || rw_die 'Некорректный UUID токена.'
    rw_manifest_set '.tokens[$key]=($t[0]|{uuid,name,scopes,expires_at:$epoch})' --arg key "$key" --argjson epoch "$epoch" --slurpfile t "$file"
}
rw_token_replace() {
    local key=$1 scopes=$2 mode=${3:-rotate} name old uuid count next=$RW_OUT/private/$1.next.json epoch namespace
    [[ $key == installer || $key == subscription ]] || rw_die 'Неизвестное назначение токена.'
    rw_panel_login
    rw_token_catalog
    namespace=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    if [[ $(jq -r --arg key "$key" '.token_operations[$key].stage // empty' "$RW_OUT/manifest.json") == complete ]]; then
        rw_managed_remove "private/$key.next.json"
        rw_managed_remove "private/$key.previous.token"
        rw_manifest_set 'del(.token_operations[$key],.token_intents[$key])' --arg key "$key"
        return
    fi
    old=$(jq -r --arg key "$key" '.tokens[$key].uuid // empty' "$RW_OUT/manifest.json")
    # A stored UUID may never refer to another installation's token.
    if [[ -n $old ]]; then
        jq --arg uuid "$old" '.response.tokens|map(select(.uuid==$uuid))' "$RW_TMP/tokens.json" > "$RW_TMP/old-token.json"
        if jq -e 'length>0' "$RW_TMP/old-token.json" >/dev/null; then
            jq -e --arg key "$key" --arg owner "${namespace:0:8}" --slurpfile m "$RW_OUT/manifest.json" '
              length==1 and (.[0].name==($m[0].tokens[$key].name // ($key+"-"+$owner)))
              and (($m[0].tokens[$key].scopes // .[0].scopes)|sort)==(.[0].scopes|sort)' "$RW_TMP/old-token.json" >/dev/null || rw_die 'Владение старым токеном не подтверждено.'
        fi
    fi
    if ! jq -e --arg key "$key" '.token_operations[$key]!=null' "$RW_OUT/manifest.json" >/dev/null; then
        [[ ! -f $next ]] || rw_die 'Обнаружен пакет токена без журнала; автоматическая замена запрещена.'
        name="$key-${RW_OWNER:0:8}-$(openssl rand -hex 4)"
        # Support the old interrupted bootstrap, whose token was never published.
        if [[ $(jq -r --arg key "$key" '.token_intents[$key] // false' "$RW_OUT/manifest.json") == true && -z $old ]]; then name="$key-${namespace:0:8}"; fi
        rw_manifest_set '.token_operations[$key]={name:$name,old_uuid:$old,old_record:(.tokens[$key] // null),scopes:$scopes[0],mode:$mode,stage:"creating"}' --arg key "$key" --arg name "$name" --arg old "$old" --arg mode "$mode" --slurpfile scopes "$scopes"
    fi
    name=$(jq -r --arg key "$key" '.token_operations[$key].name' "$RW_OUT/manifest.json")
    old=$(jq -r --arg key "$key" '.token_operations[$key].old_uuid' "$RW_OUT/manifest.json")
    if [[ -n $old && ! -f $RW_OUT/private/$key.previous.token ]]; then
        [[ $(jq -r --arg key "$key" '.tokens[$key].uuid' "$RW_OUT/manifest.json") == "$old" && -s $RW_OUT/private/$key.token ]] || rw_die 'Не сохранился прежний токен для отката активации.'
        cat "$RW_OUT/private/$key.token" | rw_atomic "$RW_OUT/private/$key.previous.token"
    fi
    jq -e --arg key "$key" --slurpfile scopes "$scopes" '(.token_operations[$key].scopes|sort)==($scopes[0]|sort)' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Права изменились во время операции; требуется сверка.'
    if [[ ! -f $next ]]; then
        jq --arg name "$name" '.response.tokens|map(select(.name==$name))' "$RW_TMP/tokens.json" > "$RW_TMP/token-matches.json"
        count=$(jq 'length' "$RW_TMP/token-matches.json")
        (( count<=1 )) || rw_die 'Несколько токенов совпали с журналом; автоматический отзыв запрещён.'
        if (( count==1 )); then
            jq -e --slurpfile s "$scopes" '.[0].scopes|sort==($s[0]|sort)' "$RW_TMP/token-matches.json" >/dev/null || rw_die 'Права потерянного токена не совпали с журналом.'
            uuid=$(jq -r '.[0].uuid' "$RW_TMP/token-matches.json")
            [[ $uuid != "$old" ]] || rw_die 'Токен замены совпал с действующим.'
            rw_token_revoke "$uuid"
        fi
        jq -n --arg name "$name" --slurpfile s "$scopes" '{name:$name,expiresInDays:90,scopes:$s[0]}' > "$RW_TMP/token-request.json"
        rw_api POST /api/tokens "$RW_TMP/token-request.json" "$RW_TMP/token-response.json" || rw_die 'Ответ выпуска потерян. Повторите эту команду: журнал позволит отозвать только собственный неопубликованный токен.'
        jq -e --arg name "$name" --slurpfile s "$scopes" '.response.name==$name and (.response.scopes|sort)==($s[0]|sort) and (.response.token|type=="string" and test("^[A-Za-z0-9._=+/-]+$"))' "$RW_TMP/token-response.json" >/dev/null || rw_die 'Неполный ответ выпуска токена; продолжение остановлено.'
        jq '.response' "$RW_TMP/token-response.json" | rw_atomic "$next"
    fi
    jq -e --arg name "$name" --slurpfile s "$scopes" '.name==$name and (.scopes|sort)==($s[0]|sort) and (.token|test("^[A-Za-z0-9._=+/-]+$"))' "$next" >/dev/null || rw_die 'Пакет замены не соответствует журналу.'
    epoch=$(rw_token_epoch "$(jq -r '.expireAt' "$next")")
    (( epoch>$(date +%s) )) || rw_die 'Подготовленный токен истёк; требуется сверка перед новым выпуском.'
    rw_token_catalog
    jq -e --slurpfile t "$next" '.response.tokens|any(.uuid==$t[0].uuid and .name==$t[0].name and .expireAt==$t[0].expireAt and (.scopes|sort)==($t[0].scopes|sort))' "$RW_TMP/tokens.json" >/dev/null || rw_die 'Токен замены отсутствует или изменён в панели.'
    jq -er '.token' "$next" | rw_atomic "$RW_TMP/candidate.token"
    rw_auth_header "$RW_TMP/candidate.token"
    if [[ $key == subscription ]]; then
        rw_api GET /api/system/metadata '' "$RW_TMP/token-probe.json" || rw_die 'Новый токен подписок не прошёл API-проверку; старый не отозван.'
    else rw_api GET /api/nodes '' "$RW_TMP/token-probe.json" || rw_die 'Новый токен управления не прошёл API-проверку; старый не отозван.'; fi
    cat "$RW_TMP/candidate.token" | rw_atomic "$RW_OUT/private/$key.token"
    rw_token_record "$key" "$next"
    if [[ $key == subscription ]]; then
        rw_subscription_env
        if [[ -n $old || $(jq -r --arg key "$key" '.token_operations[$key].mode' "$RW_OUT/manifest.json") != bootstrap ]]; then
            if ! rw_compose --profile public up -d --wait --wait-timeout 90 rw_subscription || ! rw_compose --profile public exec -T rw_subscription curl -fsS --max-time 10 http://127.0.0.1:3010/internal/health >/dev/null; then
                rw_token_activation_rollback "$key"
                rw_die 'Активация подписок не прошла; прежний токен возвращён. Повторите tokens rotate.'
            fi
        fi
    fi
    rw_panel_login
    [[ -z $old ]] || rw_token_revoke "$old"
    rw_manifest_set '.token_operations[$key].stage="complete"' --arg key "$key"
    rw_managed_remove "private/$key.next.json"
    rw_managed_remove "private/$key.previous.token"
    rw_manifest_set 'del(.token_operations[$key],.token_intents[$key])' --arg key "$key"
    rw_info "Токен $key заменён и проверен; прежний отозван."
}
rw_token_activation_rollback() {
    local key=$1
    [[ -f $RW_OUT/private/$key.previous.token ]] || return 0
    cat "$RW_OUT/private/$key.previous.token" | rw_atomic "$RW_OUT/private/$key.token"
    rw_manifest_set '.tokens[$key]=.token_operations[$key].old_record' --arg key "$key"
    rw_subscription_env
    rw_compose --profile public up -d --wait --wait-timeout 90 rw_subscription || rw_info 'Прежний токен восстановлен в файлах, но сервис требует диагностики.'
}
rw_tokens_status() {
    local key uuid expiry remaining bad=0
    rw_panel_login; rw_token_catalog
    for key in installer subscription; do
        uuid=$(jq -r --arg key "$key" '.tokens[$key].uuid // empty' "$RW_OUT/manifest.json")
        expiry=$(jq -r --arg uuid "$uuid" '.response.tokens[]|select(.uuid==$uuid)|.expireAt' "$RW_TMP/tokens.json")
        if [[ -z $uuid || -z $expiry || ! -s $RW_OUT/private/$key.token ]]; then
            rw_info "Токен $key отсутствует: выполните rwctl tokens rotate --token $key."; bad=1; continue
        fi
        remaining=$(( $(rw_token_epoch "$expiry")-$(date +%s) ))
        jq -n --arg purpose "$key" --arg expire_at "$expiry" --argjson remaining "$remaining" '{purpose:$purpose,expire_at:$expire_at,remaining_seconds:$remaining,rotation_due:($remaining<604800)}'
        if (( remaining<604800 )); then rw_info "Токен $key истекает или истёк: rwctl tokens rotate --token $key."; fi
        (( remaining>0 )) || bad=1
    done
    return "$bad"
}
rw_tokens_rotate() {
    rw_root; rw_owned; rw_lock; rw_resume_writes; rw_verify_files; rw_ssh_idle
    [[ $RW_ROLE != node ]] || rw_die 'У отдельной ноды нет токенов панели.'
    [[ ${RW_TOKEN_PURPOSE:-all} == all || $RW_TOKEN_PURPOSE == installer || $RW_TOKEN_PURPOSE == subscription ]] || rw_die '--token: all, installer или subscription.'
    if (( RW_DRY_RUN )); then rw_tokens_status; return; fi
    RW_MUTATING=1
    rw_panel_login; rw_token_scopes
    local key
    for key in subscription installer; do
        [[ ${RW_TOKEN_PURPOSE:-all} == all || $RW_TOKEN_PURPOSE == "$key" ]] || continue
        rw_token_replace "$key" "$RW_TMP/$key-scopes.json"
    done
    rw_track_files
}
