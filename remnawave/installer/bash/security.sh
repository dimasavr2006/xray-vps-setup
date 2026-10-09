# shellcheck shell=bash
rw_root_key_paths() {
    local home path client=${SSH_CONNECTION:-127.0.0.1}
    client=${client%% *}
    home=$(getent passwd root | cut -d: -f6)
    [[ $home == /* && $home != / ]] || rw_die 'Cannot determine the root home directory.'
    while IFS= read -r path; do
        [[ $path != none ]] || continue
        path=${path//%h/$home}; path=${path//%u/root}; path=${path//%U/0}; path=${path//%%/%}
        [[ $path == /* ]] || path=$home/$path
        printf '%s\n' "$path"
    done < <(/usr/sbin/sshd -T -C user=root,host=localhost,addr="$client" 2>/dev/null | awk '$1=="authorizedkeysfile" {for(i=2;i<=NF;i++)print $i}')
}
rw_root_key_present() {
    local file
    while IFS= read -r file; do
        if [[ -f $file ]] && ssh-keygen -lf "$file" >/dev/null 2>&1; then return 0; fi
    done < <(rw_root_key_paths)
    return 1
}
rw_public_key_check() {
    local key=$1 type data rest
    [[ $key != *$'\n'* && $key != *$'\r'* && ${#key} -le 8192 ]] || return 1
    read -r type data rest <<< "$key"
    [[ $type == ssh-ed25519 || $type == ssh-rsa || $type == ecdsa-sha2-nistp256 ]] || return 1
    [[ $data =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
    printf '%s %s\n' "$type" "$data" > "$RW_TMP/root-public-key"
    ssh-keygen -lf "$RW_TMP/root-public-key" >/dev/null 2>&1
}
rw_security_key_input() {
    if rw_root_key_present; then rw_info 'Root already has an SSH key; authorized_keys will be preserved.'; return; fi
    read -r -p 'Root public SSH key (one ssh-ed25519/ssh-rsa/ecdsa line): ' RW_ROOT_PUBLIC_KEY || rw_die 'Public key input was interrupted.'
    rw_public_key_check "$RW_ROOT_PUBLIC_KEY" || rw_die 'Provide a valid public SSH key, not a private key.'
}
rw_security_key_prepare() {
    local key file type data rest
    if rw_root_key_present; then rw_manifest_set '.security.root_key="existing-preserved"'; return; fi
    key=$(rw_cfg '.security.root_public_key // empty')
    [[ -n $key ]] && rw_public_key_check "$key" || rw_die 'Root has no valid file-based SSH key. Supply security.root_public_key in the config.'
    file=$(rw_root_key_paths | head -n1)
    [[ -n $file ]] || rw_die 'Root AuthorizedKeysFile is disabled; the current SSH policy was preserved.'
    rw_safe_parents "$file"
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || rw_die 'Unsafe root authorized_keys file.'
    [[ ! -f $file || $(stat -c %u "$file") == 0 ]] || rw_die 'Root authorized_keys has an unexpected owner.'
    if [[ ! -d $(dirname -- "$file") ]]; then install -d -m 700 -o root -g root "$(dirname -- "$file")"; fi
    touch "$file"; chmod 600 "$file"; chown root:root "$file"
    read -r type data rest <<< "$key"
    # Append only when no existing valid key was found; keep comments and other lines.
    printf '\n%s %s pdm-root-access\n' "$type" "$data" >> "$file"
    rw_manifest_set '.security.root_key="added"'
    rw_info 'Root public key added. Existing SSH authentication policy was preserved.'
}
rw_security_ports() {
    local id node_port
    node_port=$(rw_port node_api)
    ss -H -lntu > "$RW_TMP/host-listeners.txt"
    awk -v node="$node_port" '{
      endpoint=$5; sub(/^\[/,"",endpoint); sub(/\]:/,":",endpoint);
      port=endpoint; sub(/^.*:/,"",port); addr=endpoint; sub(/:[^:]*$/,"",addr);
      if (port !~ /^[0-9]+$/ || addr ~ /^127\./ || addr=="::1" || addr=="0:0:0:0:0:0:0:1") next;
      if ($1=="tcp" && port==node) next;
      if ($1=="tcp" || $1=="udp") print $1 " " port;
    }' "$RW_TMP/host-listeners.txt" > "$RW_TMP/preserved-ports.txt"
    if command -v docker >/dev/null 2>&1; then
        while IFS= read -r id; do
            [[ -n $id ]] || continue
            docker inspect "$id" | jq -r '.[0].NetworkSettings.Ports // {} | to_entries[] | .key as $key | .value[]? | select(((.HostIp // "")|startswith("127.")|not) and .HostIp!="::1") | ($key|split("/")[1])+" "+.HostPort' >> "$RW_TMP/preserved-ports.txt"
        done < <(docker ps -q)
    fi
    awk '$1~/^(tcp|udp)$/ && $2~/^[0-9]+$/ && $2>0 && $2<=65535' "$RW_TMP/preserved-ports.txt" | LC_ALL=C sort -u | jq -Rn '[inputs|split(" ")|{proto:.[0],port:(.[1]|tonumber)}]'
}
rw_security_capture() {
    [[ $(rw_cfg '.security.enabled != false') == true ]] || return 0
    /usr/sbin/sshd -t || rw_die 'SSH configuration is invalid; host security was not changed.'
    rw_security_key_prepare
    # Capture before starting new services; never preserve loopback APIs as public.
    rw_security_ports | rw_atomic "$RW_OUT/private/security-preserved-ports.json"
}
rw_ufw_files() {
    printf '%s\n' /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/after.rules /etc/ufw/after6.rules /etc/ufw/user.rules /etc/ufw/user6.rules
}
rw_ufw_hash() { local file; while IFS= read -r file; do sha256sum "$file" || return 1; done < <(rw_ufw_files) | sha256sum | cut -d' ' -f1; }
rw_ufw_snapshot() {
    local file
    while IFS= read -r file; do
        rw_safe_parents "$file"
        [[ -f $file && ! -L $file ]] || rw_die 'Unexpected UFW configuration file type.'
        cat "$file" | rw_atomic "$RW_OUT/private/ufw-before$file"
    done < <(rw_ufw_files)
}
rw_ufw_input_policy() {
    if [[ -f /etc/default/ufw ]]; then awk -F= '$1=="DEFAULT_INPUT_POLICY" {gsub(/"/,"",$2); print $2}' /etc/default/ufw
    else printf 'ACCEPT\n'; fi
}
rw_security_plan() {
    local active=false input=ACCEPT ssh_port connection=${SSH_CONNECTION:-} preserved=${1:-$RW_OUT/private/security-preserved-ports.json}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then active=true; fi
    input=$(rw_ufw_input_policy)
    /usr/sbin/sshd -T > "$RW_TMP/security-sshd.txt"
    awk '$1=="port" {print $2}' "$RW_TMP/security-sshd.txt" > "$RW_TMP/security-ssh-ports.txt"
    ssh_port=${connection##* }
    if [[ $ssh_port =~ ^[0-9]+$ ]]; then printf '%s\n' "$ssh_port" >> "$RW_TMP/security-ssh-ports.txt"; fi
    jq -Rn '[inputs|tonumber]|unique' < "$RW_TMP/security-ssh-ports.txt" > "$RW_TMP/security-ssh-ports.json"
    jq -n --argjson active "$active" --arg input "$input" --arg client "${connection%% *}" \
      --slurpfile config "$RW_CFG" --slurpfile preserved "$preserved" --slurpfile ssh "$RW_TMP/security-ssh-ports.json" '
      $config[0].ports as $p |
      ([$p.http,$p.https,$p.subscription_https,$p.reality,$p.xhttp]|map(select(.!=null and .!=18080))|unique|map({proto:"tcp",port:.})) as $tcp |
      ([$p.https,$p.subscription_https]|map(select(.!=null))|unique|map({proto:"udp",port:.})) as $udp |
      {active_before:$active,input_before:$input,ssh_ports:$ssh[0],ssh_source:(if $active and $input=="DROP" then $client else "" end),
       preserved_ports:(if $active and $input=="DROP" then [] else $preserved[0] end),
       public_ports:($tcp+$udp)}' > "$RW_TMP/security-plan.json"
}
rw_security_apply() {
    [[ $(rw_cfg '.security.enabled != false') == true ]] || return 0
    rw_root; rw_owned; rw_lock; rw_security_idle
    rw_safe_parents /var/lib/pdm-remnawave-security/ufw.lock
    [[ ! -L /var/lib/pdm-remnawave-security/ufw.lock ]] || rw_die 'Host firewall lock is a symbolic link.'
    install -d -m 700 /var/lib/pdm-remnawave-security
    exec 18>/var/lib/pdm-remnawave-security/ufw.lock
    flock -n 18 || rw_die 'Another installation is configuring the host firewall.'
    if [[ -f /var/lib/pdm-remnawave-security/ufw-owner.json ]] && jq -e '.status=="armed"' /var/lib/pdm-remnawave-security/ufw-owner.json >/dev/null; then
        rw_die 'A host firewall change is already awaiting a fresh SSH connection.'
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw
    fi
    [[ -f $RW_OUT/private/security-preserved-ports.json ]] || rw_security_capture
    rw_security_plan
    local active input port proto source guard=true
    active=$(jq -r '.active_before' "$RW_TMP/security-plan.json"); input=$(jq -r '.input_before' "$RW_TMP/security-plan.json")
    # With an active deny policy, only additive rules are needed; preserve its restrictions.
    [[ $active != true || $input != DROP ]] || guard=false
    if [[ $guard == true ]]; then
        rw_ufw_snapshot
        jq -n --arg connection "${SSH_CONNECTION:-}" --argjson active "$active" '{status:"armed",active_before:$active,ssh_connection:$connection}' | rw_atomic "$RW_OUT/private/security-state.json"
        jq -n --arg owner "$RW_OWNER" --arg dir "$RW_OUT" '{owner:$owner,installation_path:$dir,status:"armed"}' | rw_atomic /var/lib/pdm-remnawave-security/ufw-owner.json
        rw_track_files
        systemctl stop "$RW_PROJECT-ufw-revert.timer" "$RW_PROJECT-ufw-revert.service" >/dev/null 2>&1 || true
        systemctl reset-failed "$RW_PROJECT-ufw-revert.timer" "$RW_PROJECT-ufw-revert.service" >/dev/null 2>&1 || true
        rw_security_schedule || { rw_security_revert; rw_die 'UFW rollback timer could not be started; policy was not changed.'; }
        RW_UFW_MUTATING=1
    fi
    source=$(jq -r '.ssh_source' "$RW_TMP/security-plan.json")
    while IFS= read -r port; do
        if [[ -n $source ]]; then ufw allow from "$source" to any port "$port" proto tcp comment pdm-host-ssh >/dev/null
        elif [[ $active != true || $input != DROP ]]; then ufw allow "$port/tcp" comment pdm-host-ssh >/dev/null; fi
    done < <(jq -r '.ssh_ports[]' "$RW_TMP/security-plan.json")
    while IFS=$'\t' read -r proto port; do ufw allow "$port/$proto" comment pdm-host-preserved >/dev/null; done < <(jq -r '.preserved_ports[]|[.proto,.port]|@tsv' "$RW_TMP/security-plan.json")
    while IFS=$'\t' read -r proto port; do ufw allow "$port/$proto" comment "$RW_PROJECT" >/dev/null; done < <(jq -r '.public_ports[]|[.proto,.port]|@tsv' "$RW_TMP/security-plan.json")
    port=$(rw_port node_api)
    if [[ -n $port ]]; then
        if [[ $RW_ROLE == node ]]; then jq -r '.panel_addresses[]' "$RW_CFG" > "$RW_TMP/security-node-sources"
        else printf '%s\n' "$RW_NET_PREFIX.10" > "$RW_TMP/security-node-sources"; fi
        while IFS= read -r source; do ufw allow from "$source" to any port "$port" proto tcp comment "$RW_PROJECT" >/dev/null; done < "$RW_TMP/security-node-sources"
    fi
    if [[ $guard == true ]]; then
        ufw default deny incoming >/dev/null
        if [[ $active == false ]]; then ufw default allow outgoing >/dev/null; fi
        sed 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw > "$RW_TMP/ufw-default"
        cat "$RW_TMP/ufw-default" > /etc/default/ufw
        ufw --force enable >/dev/null || { rw_security_revert; rw_die 'UFW activation failed; previous settings restored.'; }
        rw_manifest_set '.security.ufw="awaiting-fresh-ssh"|.ufw_rules_added=true'
        jq --arg hash "$(rw_ufw_hash)" '.applied_sha256=$hash' "$RW_OUT/private/security-state.json" | rw_atomic "$RW_OUT/private/security-state.json"
        RW_UFW_MUTATING=0
        rw_info 'UFW enabled. Reconnect SSH and run rwctl security confirm within 5 minutes; otherwise UFW settings roll back.'
    else
        rw_manifest_set '.security.ufw="active-existing-policy"|.ufw_rules_added=true'
        rw_info 'Active UFW deny policy retained; installation ports added without resetting existing rules.'
    fi
    exec 18>&-
}
rw_security_idle() {
    [[ ! -f $RW_OUT/private/security-state.json ]] || [[ $(jq -r '.status' "$RW_OUT/private/security-state.json") != armed ]] || rw_die 'Verify a fresh SSH connection with security confirm or wait for UFW rollback.'
}
rw_security_schedule() {
    systemd-run --quiet --unit "$RW_PROJECT-ufw-revert" --on-active=300s --timer-property=AccuracySec=1s /bin/bash "$RW_OUT/rwctl" security revert
}
rw_security_confirm() {
    rw_root; rw_owned; rw_lock; rw_verify_files
    [[ -f $RW_OUT/private/security-state.json ]] && [[ $(jq -r '.status' "$RW_OUT/private/security-state.json") == armed ]] || rw_die 'No UFW change is awaiting confirmation.'
    [[ -n ${SSH_CONNECTION:-} && $SSH_CONNECTION != "$(jq -r '.ssh_connection' "$RW_OUT/private/security-state.json")" ]] || rw_die 'Confirm from a fresh SSH session, not the installation session.'
    ufw status | grep -q '^Status: active' || rw_die 'UFW is not active.'
    [[ $(rw_ufw_hash) == "$(jq -r '.applied_sha256' "$RW_OUT/private/security-state.json")" ]] || rw_die 'UFW settings changed before confirmation; review the new rules.'
    systemctl stop "$RW_PROJECT-ufw-revert.timer"
    rw_manifest_set '.security.ufw="confirmed"'
    jq '.status="confirmed"' "$RW_OUT/private/security-state.json" | rw_atomic "$RW_OUT/private/security-state.json"
    rw_security_host_state confirmed
    rw_track_files
    rw_info 'Fresh SSH connection verified; UFW settings retained.'
}
rw_security_revert() {
    rw_root; rw_owned; rw_lock
    [[ -f $RW_OUT/private/security-state.json ]] && [[ $(jq -r '.status' "$RW_OUT/private/security-state.json") == armed ]] || return 0
    local file active
    active=$(jq -r '.active_before' "$RW_OUT/private/security-state.json")
    local expected
    expected=$(jq -r '.applied_sha256 // empty' "$RW_OUT/private/security-state.json")
    [[ -z $expected || $(rw_ufw_hash) == "$expected" || ${RW_UFW_MUTATING:-0} == 1 ]] || rw_die 'UFW changed externally; rollback will not overwrite the new configuration.'
    # Restore only UFW configuration; Docker/nftables tables and SSH keys stay intact.
    while IFS= read -r file; do
        rw_safe_parents "$file"
        [[ -f $file && ! -L $file ]] || rw_die 'UFW configuration file type changed; rollback stopped.'
        cat "$RW_OUT/private/ufw-before$file" > "$file"
    done < <(rw_ufw_files)
    if [[ $active == true ]]; then ufw reload >/dev/null; else ufw --force disable >/dev/null; fi
    jq '.status="reverted"' "$RW_OUT/private/security-state.json" | rw_atomic "$RW_OUT/private/security-state.json"
    rw_manifest_set '.security.ufw="reverted"'
    rw_security_host_state reverted
    RW_UFW_MUTATING=0
    rw_track_files
    rw_info 'UFW settings restored because a fresh SSH connection was not confirmed.'
}
rw_security_host_state() {
    local state=$1 file=/var/lib/pdm-remnawave-security/ufw-owner.json
    [[ -f $file ]] || return 0
    jq -e --arg owner "$RW_OWNER" '.owner==$owner' "$file" >/dev/null || rw_die 'Host firewall operation ownership conflict.'
    jq --arg state "$state" '.status=$state' "$file" | rw_atomic "$file"
}
rw_security_configure() {
    if (( ${RW_DRY_RUN:-0} )); then
        rw_root; rw_owned; rw_verify_files
        rw_security_ports > "$RW_TMP/security-preview-ports.json"
        rw_security_plan "$RW_TMP/security-preview-ports.json"
        local key=false package=true
        if rw_root_key_present; then key=true; fi
        if command -v ufw >/dev/null 2>&1; then package=false; fi
        jq --argjson key "$key" --argjson package "$package" '.+{root_key_present:$key,ufw_package_install_required:$package,read_only:true}' "$RW_TMP/security-plan.json"
        return
    fi
    rw_root; rw_os; rw_owned; rw_lock; rw_resume_writes; rw_verify_files; rw_security_idle
    rw_security_capture; rw_security_apply; rw_track_files; rw_install_summary
}
rw_security_status() {
    rw_owned
    jq '{root_key:.security.root_key,ufw:.security.ufw}' "$RW_OUT/manifest.json"
    if command -v ufw >/dev/null 2>&1; then ufw status verbose; fi
}
