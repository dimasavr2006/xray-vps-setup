# shellcheck shell=bash
rw_summary_url() {
    local domain=$1 port=$2 path=${3:-}
    printf 'https://%s' "$domain"
    [[ $port == 443 ]] || printf ':%s' "$port"
    printf '%s' "$path"
}
rw_summary_render() {
    local show_secrets=${1:-0} status domain panel_url sub_url cover_url prepared=0 host
    status=$(jq -r '.status' "$RW_OUT/manifest.json")
    [[ $status != node-prepared-awaiting-attachment ]] || prepared=1
    printf '\n=== Remnawave installation summary ===\n'
    printf 'Installation: %s\nRole: %s\nStatus: %s\nDirectory: %s\n' "$RW_ENV" "$RW_ROLE" "$status" "$RW_OUT"
    if [[ $RW_ROLE != node ]]; then
        panel_url=$(rw_summary_url "$(rw_cfg '.domains.panel')" "$(rw_port https)")
        sub_url=$(rw_summary_url "$(rw_cfg '.domains.subscription')" "$(rw_subscription_port)")
        printf '\nPanel URL: %s/\nMFA login URL: %s/r\nSubscription base URL: %s/\n' "$panel_url" "$panel_url" "$sub_url"
        printf 'Remnawave username: %s\nCaddy Auth username: %s\n' "$(jq -r '.username' "$RW_OUT/private/admin.json")" "$(rw_cfg '.admin.username')"
        if (( show_secrets )); then
            printf 'Saved Remnawave password: %s\nSaved Caddy Auth password: %s\n' "$(jq -r '.password' "$RW_OUT/private/admin.json")" "$(jq -r '.auth_password' "$RW_OUT/private/secrets.json")"
        else
            printf 'Passwords are hidden in this summary. To display them in your terminal:\n  bash %q info --show-secrets\n' "$RW_OUT/rwctl"
        fi
        printf 'Credentials: %s/private/admin.json and %s/private/secrets.json\n' "$RW_OUT" "$RW_OUT"
        printf 'Enroll MFA at the login URL, then verify a fresh browser login.\n'
        printf 'Personal subscription links are issued per user in the panel.\n'
    fi
    if [[ $RW_ROLE != panel ]]; then
        domain=$(rw_cfg '.domains.node')
        cover_url=$(rw_summary_url "$domain" "$(rw_port reality)")
        printf '\nNode domain / SNI: %s\n' "$domain"
        if (( prepared )); then
            printf 'Node is prepared; management, cover and transports start after attachment.\nPlanned cover URL: %s/\n' "$cover_url"
        else printf 'Cover URL: %s/\n' "$cover_url"; fi
        printf 'VLESS TCP Reality: %s:%s\nVLESS XHTTP Reality: %s:%s\n' "$domain" "$(rw_port reality)" "$domain" "$(rw_port xhttp)"
        printf 'Reality public key: %s\nReality Short ID: %s\nXHTTP path: %s\nClient fingerprint: chrome\n' \
            "$(jq -r '.reality_public' "$RW_OUT/private/secrets.json")" "$(jq -r '.short_id' "$RW_OUT/private/secrets.json")" "$(jq -r '.xhttp_path' "$RW_OUT/private/secrets.json")"
        printf 'Node management port: TCP %s (panel -> node)\n' "$(rw_port node_api)"
        if [[ $RW_ROLE == node ]]; then
            printf 'Management address: %s\nAllowed panel source IPs: %s\n' "$(rw_cfg '.management_address')" "$(jq -r '.panel_addresses|join(", ")' "$RW_CFG")"
        else printf 'Management is restricted to this installation\x27s panel container and loopback.\n'; fi
        printf 'Native management key file: %s/private/node.env\n' "$RW_OUT"
        if (( prepared )); then
            host=$(rw_cfg '.management_address')
            # scp requires brackets around an IPv6 address; ssh uses USER@ADDRESS.
            [[ $host != *:* ]] || host=[$host]
            printf '\nOn the panel server, copy this public node configuration:\n  scp %q %q\n' "root@$host:$RW_OUT/config.json" "/root/$RW_ENV.json"
            printf 'Then attach from the panel server (replace PANEL_INSTALLATION):\n  bash /opt/pdm-remnawave/PANEL_INSTALLATION/rwctl node attach --ssh %q --node-config %q\n' "root@$(rw_cfg '.management_address')" "/root/$RW_ENV.json"
            printf 'SSH must already trust this host and permit key-based login; a sudo admin may replace root.\n'
        fi
    fi
    printf '\nConfiguration: %s/config.json\nInventory: %s/inventory.json\n' "$RW_OUT" "$RW_OUT"
    if [[ -f $RW_OUT/private/install-info.txt ]]; then printf 'Full access card (root-only): %s/private/install-info.txt\n' "$RW_OUT"; fi
    printf 'Show this summary: bash %q info\n' "$RW_OUT/rwctl"
    if (( ! prepared )); then printf 'Health check: bash %q doctor\n' "$RW_OUT/rwctl"; fi
    printf 'Backup: bash %q backup --archive %q\n' "$RW_OUT/rwctl" "/var/backups/pdm-remnawave/$RW_ENV-manual.tgz"
    printf 'Keep a private backup off the VPS.\n'
}
rw_install_summary() {
    rw_summary_render 1 | rw_atomic "$RW_OUT/private/install-info.txt"
    # A normal SSH installation shows the owner credentials. CI and redirected
    # logs receive public connection details and credential file paths only.
    if [[ -t 1 ]]; then rw_summary_render 1; else rw_summary_render 0; fi
}
rw_show_summary() {
    rw_owned; rw_verify_files
    if (( ${RW_SHOW_SECRETS:-0} )); then
        rw_root
        [[ -t 1 ]] || rw_die '--show-secrets requires an interactive terminal.'
    fi
    rw_summary_render "${RW_SHOW_SECRETS:-0}"
}
