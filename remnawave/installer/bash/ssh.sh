# shellcheck shell=bash
rw_ssh_idle() {
    [[ ! -f $RW_OUT/private/ssh-state.json ]] || [[ $(jq -r '.status' "$RW_OUT/private/ssh-state.json") != armed ]] || rw_die 'Завершите проверку нового SSH-входа или дождитесь автоматического возврата SSH.'
}
rw_ssh_prepare() {
    rw_root; rw_os; rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    local user=${RW_SSH_ADMIN:-} keyfile=${RW_SSH_PUBLIC_KEY:-} keytype keydata _ fingerprint home marker sudoers nonce
    [[ $user =~ ^[a-z][a-z0-9_-]{2,30}$ && $user != root && -f $keyfile && ! -L $keyfile ]] || rw_die 'ssh prepare требует --admin-user USER и --public-key FILE.'
    [[ $(wc -l < "$keyfile") == 1 ]] || rw_die 'Нужен один публичный SSH-ключ.'
    read -r keytype keydata _ < "$keyfile"
    [[ $keytype == ssh-ed25519 || $keytype == ssh-rsa || $keytype == ecdsa-sha2-nistp256 ]] || rw_die 'Неподдерживаемый тип SSH-ключа.'
    [[ $keydata =~ ^[A-Za-z0-9+/=]+$ ]] || rw_die 'Некорректный публичный ключ.'
    ssh-keygen -l -f "$keyfile" >/dev/null || rw_die 'SSH-ключ не прошёл проверку.'
    fingerprint=$(printf '%s %s' "$keytype" "$keydata" | sha256sum | cut -d' ' -f1)
    marker=/var/lib/pdm-remnawave-ssh/$user.json
    rw_safe_parents "$marker"
    if id "$user" >/dev/null 2>&1; then
        [[ -f $marker && ! -L $marker ]] && jq -e --arg owner "$RW_OWNER" '.owner==$owner' "$marker" >/dev/null || rw_die 'Учётная запись SSH уже существует и не принадлежит этой установке.'
    else
        useradd --create-home --shell /bin/bash "$user"
        jq -n --arg owner "$RW_OWNER" --arg user "$user" '{owner:$owner,user:$user}' | rw_atomic "$marker"
    fi
    if ! command -v sudo >/dev/null 2>&1; then apt-get install -y --no-install-recommends sudo; fi
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ $home == /home/$user ]] || rw_die 'Неожиданный home администратора.'
    rw_safe_parents "$home/.ssh/authorized_keys"
    [[ ! -L $home/.ssh/authorized_keys ]] || rw_die 'authorized_keys является ссылкой.'
    install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$user" "$home/.ssh/authorized_keys"
    # Add the new key while keeping existing keys until a fresh login proves it works.
    if ! grep -qF "$keytype $keydata " "$home/.ssh/authorized_keys"; then printf '%s %s %s:%s\n' "$keytype" "$keydata" "$RW_PROJECT" "${fingerprint:0:12}" >> "$home/.ssh/authorized_keys"; fi
    sudoers=/etc/sudoers.d/$RW_PROJECT-$user
    if [[ -e $sudoers ]]; then [[ ! -L $sudoers ]] && grep -qF "$RW_OWNER" "$sudoers" || rw_die 'Чужой sudoers-файл.'; fi
    printf '# %s\n%s ALL=(ALL) NOPASSWD: ALL\n' "$RW_OWNER" "$user" > "$RW_TMP/sudoers"
    visudo -cf "$RW_TMP/sudoers" >/dev/null || rw_die 'Проверка sudoers не прошла.'
    install -m 440 "$RW_TMP/sudoers" "$sudoers"
    if [[ -f $RW_OUT/private/ssh-state.json ]] && jq -e --arg user "$user" --arg fp "$fingerprint" '.status=="confirmed" and .user==$user and .public_key_fingerprint==$fp' "$RW_OUT/private/ssh-state.json" >/dev/null; then
        local dropin
        dropin=$(rw_ssh_dropin)
        if [[ -f $dropin && ! -L $dropin && $(sha256sum "$dropin" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]]; then
            rw_info 'Проверенный SSH-администратор уже настроен.'; return
        fi
    fi
    nonce=$(openssl rand -hex 32)
    jq -n --arg user "$user" --arg nonce "$nonce" --arg fp "$fingerprint" '{status:"prepared",user:$user,nonce:$nonce,public_key_fingerprint:$fp}' | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh={status:"prepared",user:$user}' --arg user "$user"
    rw_track_files
    rw_info "Администратор $user подготовлен. С оператора выполните ssh harden --ssh USER@HOST с этим ключом и проверенным known_hosts."
}
rw_ssh_session() {
    rw_root; rw_owned
    [[ -f $RW_OUT/private/ssh-state.json && ${SUDO_USER:-} == $(jq -r '.user' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'Проверка выполняется через sudo нового SSH-администратора.'
}
rw_ssh_status() {
    rw_ssh_session
    jq --arg owner "$RW_OWNER" '.+{owner:$owner}' "$RW_OUT/private/ssh-state.json"
}
rw_ssh_dropin() { printf '/etc/ssh/sshd_config.d/00-%s.conf\n' "$RW_PROJECT"; }
rw_ssh_commit() {
    rw_ssh_session; rw_lock
    local file nonce previous=false
    file=$(rw_ssh_dropin); nonce=$(jq -r '.nonce' "$RW_OUT/private/ssh-state.json")
    [[ ${RW_SSH_NONCE:-} == "$nonce" && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == prepared ]] || rw_die 'Неподтверждённая операция SSH.'
    rw_safe_parents "$file"
    if [[ -e $file ]]; then
        [[ ! -L $file ]] && grep -qF "$RW_OWNER" "$file" || rw_die 'SSH drop-in принадлежит другой установке.'
        cat "$file" | rw_atomic "$RW_OUT/private/ssh-before.conf"; previous=true
    fi
    # Keep pre-existing restricted machine keys working; ordinary root login is disabled.
    printf '# %s\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin forced-commands-only\n' "$RW_OWNER" > "$RW_TMP/ssh-dropin"
    install -m 644 "$RW_TMP/ssh-dropin" "$file"
    if ! /usr/sbin/sshd -t; then
        if [[ $previous == true ]]; then cat "$RW_OUT/private/ssh-before.conf" > "$file"; else rm -f -- "$file"; fi
        rw_die 'SSH config не прошёл проверку; исходный файл возвращён.'
    fi
    jq --argjson previous "$previous" --arg hash "$(sha256sum "$file" | cut -d' ' -f1)" '.status="armed"|.previous_dropin=$previous|.applied_sha256=$hash' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_track_files
    systemd-run --quiet --unit "$RW_PROJECT-ssh-revert" --on-active=60s --timer-property=AccuracySec=1s /bin/bash "$RW_OUT/rwctl" ssh revert --nonce "$nonce" || { rw_ssh_revert; rw_die 'Таймер возврата SSH не запущен.'; }
    systemctl reload ssh.service || { rw_ssh_revert; rw_die 'SSH reload не прошёл.'; }
    rw_info 'SSH изменён; ожидается свежий вход нового администратора, иначе через 60 секунд будет возврат.'
}
rw_ssh_revert() {
    rw_root; rw_owned
    local file nonce
    file=$(rw_ssh_dropin); nonce=$(jq -r '.nonce' "$RW_OUT/private/ssh-state.json")
    [[ ${RW_SSH_NONCE:-} == "$nonce" && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == armed ]] || return 0
    [[ -f $file && ! -L $file && $(sha256sum "$file" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'SSH drop-in изменён извне; возврат не перезаписывает чужие изменения.'
    if [[ $(jq -r '.previous_dropin' "$RW_OUT/private/ssh-state.json") == true ]]; then cat "$RW_OUT/private/ssh-before.conf" > "$file"; else rm -f -- "$file"; fi
    /usr/sbin/sshd -t && systemctl reload ssh.service || rw_die 'Не удалось вернуть SSH.'
    jq '.status="reverted"' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh.status="reverted"'; rw_track_files
}
rw_ssh_confirm() {
    rw_ssh_session; rw_lock
    [[ ${RW_SSH_NONCE:-} == $(jq -r '.nonce' "$RW_OUT/private/ssh-state.json") && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == armed ]] || rw_die 'Нет ожидающей операции SSH.'
    local file
    file=$(rw_ssh_dropin)
    [[ -f $file && ! -L $file && $(sha256sum "$file" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'SSH drop-in изменился до подтверждения.'
    /usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 > "$RW_TMP/ssh-effective"
    grep -qx 'permitrootlogin forced-commands-only' "$RW_TMP/ssh-effective" && grep -qx 'passwordauthentication no' "$RW_TMP/ssh-effective" && grep -qx 'kbdinteractiveauthentication no' "$RW_TMP/ssh-effective" || rw_die 'Итоговая SSH-политика не совпала с ожидаемой.'
    systemctl stop "$RW_PROJECT-ssh-revert.timer"
    jq '.status="confirmed"' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh.status="confirmed"'; rw_track_files
    rw_info 'Свежий SSH-вход проверен; обычный root-вход и пароли отключены.'
}
rw_ssh_harden() {
    local host=${RW_SSH:-} nonce state remote=$RW_OUT
    [[ $host =~ ^[A-Za-z0-9_.@:-]+$ && $host != -* ]] || rw_die 'ssh harden требует --ssh USER@HOST.'
    local -a options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh status" > "$RW_TMP/ssh-status.json"
    jq -e --arg owner "$RW_OWNER" '.owner==$owner and (.nonce|test("^[a-f0-9]{64}$"))' "$RW_TMP/ssh-status.json" >/dev/null || rw_die 'SSH host не совпал с установкой.'
    state=$(jq -r '.status' "$RW_TMP/ssh-status.json")
    if [[ $state == confirmed ]]; then rw_info 'Новый SSH-вход уже проверен.'; return; fi
    [[ $state == prepared ]] || rw_die 'Сначала выполните ssh prepare на сервере.'
    nonce=$(jq -r '.nonce' "$RW_TMP/ssh-status.json")
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh commit --nonce '$nonce'"
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh confirm --nonce '$nonce'" || rw_die 'Свежий вход не прошёл; таймер возвращает прежний SSH.'
}
