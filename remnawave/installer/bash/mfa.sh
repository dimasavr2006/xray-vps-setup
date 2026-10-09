# shellcheck shell=bash
rw_mfa_status() {
    rw_owned
    [[ $RW_ROLE != node ]] || rw_die 'A standalone node has no administrative MFA portal.'
    local user
    user=$(rw_cfg '.admin.username')
    rw_compose --profile public exec -T rw_caddy cat /data/.local/caddy/users.json > "$RW_TMP/mfa-users.json" || rw_die 'Caddy Auth storage is unavailable.'
    jq -e --arg user "$user" '[.users[]|select(.username==$user)]|length==1' "$RW_TMP/mfa-users.json" >/dev/null || rw_die 'Exactly one Caddy Auth owner account is required.'
    rw_mfa_summary "$user" "$RW_TMP/mfa-users.json"
}
rw_mfa_summary() {
    jq --arg user "$1" '.users[]|select(.username==$user)|([.mfa_tokens[]?|select(.type=="totp" and .disabled!=true and .expired!=true)]) as $tokens | {username,authenticator_enrolled:($tokens|length>0),owner_action_required:($tokens|length==0)}' "$2"
}
rw_mfa_guide() {
    rw_owned
    [[ $RW_ROLE != node ]] || rw_die 'A standalone node has no administrative MFA portal.'
    printf 'Administrative login: https://%s:%s/r\n' "$(rw_cfg '.domains.panel')" "$(rw_port https)"
    printf 'Username: %s. Caddy Auth password: auth_password in private/secrets.json.\n' "$(rw_cfg '.admin.username')"
    printf '%s\n' 'After entering your password, add an MFA application, scan the QR code with your authenticator and confirm the current code.' \
      'Sign out and test a fresh login in another browser window; both password and code are required.' \
      'Remnawave credentials are stored separately in private/admin.json. Keep the QR code, secret and backup private.' \
      'Keep a private backup off the VPS; it contains MFA enrollment. Restore it with rwctl restore while retaining MFA.'
}
