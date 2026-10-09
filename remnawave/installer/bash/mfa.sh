# shellcheck shell=bash
rw_mfa_status() {
    rw_owned
    [[ $RW_ROLE != node ]] || rw_die 'У отдельной ноды нет административного входа MFA.'
    local user
    user=$(rw_cfg '.admin.username')
    rw_compose --profile public exec -T rw_caddy cat /data/.local/caddy/users.json > "$RW_TMP/mfa-users.json" || rw_die 'Хранилище Caddy Auth недоступно.'
    jq -e --arg user "$user" '[.users[]|select(.username==$user)]|length==1' "$RW_TMP/mfa-users.json" >/dev/null || rw_die 'Не найдена единственная учётная запись владельца Caddy Auth.'
    rw_mfa_summary "$user" "$RW_TMP/mfa-users.json"
}
rw_mfa_summary() {
    jq --arg user "$1" '.users[]|select(.username==$user)|([.mfa_tokens[]?|select(.type=="totp" and .disabled!=true and .expired!=true)]) as $tokens | {username,authenticator_enrolled:($tokens|length>0),owner_action_required:($tokens|length==0)}' "$2"
}
rw_mfa_guide() {
    rw_owned
    [[ $RW_ROLE != node ]] || rw_die 'У отдельной ноды нет административного входа MFA.'
    printf 'Административный вход: https://%s:%s/r\n' "$(rw_cfg '.domains.panel')" "$(rw_port https)"
    printf 'Логин: %s. Пароль Caddy Auth: поле auth_password в private/secrets.json.\n' "$(rw_cfg '.admin.username')"
    printf '%s\n' 'После ввода пароля выберите добавление приложения MFA, сканируйте QR своим аутентификатором и подтвердите текущий код.' \
      'Затем выйдите и проверьте новый вход в отдельном окне браузера: пароль и код обязательны.' \
      'Пароль Remnawave хранится отдельно в private/admin.json. Не передавайте QR, секрет или резервную копию в чат.' \
      'Сохраните закрытый backup вне VPS: он содержит привязку MFA. Для восстановления используйте rwctl restore; отключение MFA не требуется.'
}
