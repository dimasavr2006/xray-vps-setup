#!/usr/bin/env bash
# Generated from installer/bash by installer/build-entrypoints.sh.
# Shared modules also define setup-only variables/helpers; full entrypoints lint them.
# shellcheck disable=SC2034,SC2120
set +x
set -euo pipefail
export LC_ALL=C
umask 077
rw_config_filter() {
cat <<'RW_CONFIG_JQ'
def ip4:
  type == "string" and test("^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}$") and
  (split(".") | all(tonumber <= 255));
def ip6:
  type == "string" and test("^[a-fA-F0-9:]+$") and
  (split("::") as $halves | ($halves|length) <= 2 and
   ([split(":")[] | select(length > 0)] as $parts |
    ($parts | all(length <= 4)) and
    (if ($halves|length) == 2 then ($parts|length) < 8
     else ($parts|length) == 8 end))) and
  ((startswith(":")|not) or startswith("::")) and
  ((endswith(":")|not) or endswith("::"));
def ip: ip4 or ip6;
def ipnorm:
  if contains(":") then
    ascii_downcase | split("::") as $halves |
    ($halves[0] | split(":") | map(select(length > 0))) as $left |
    (($halves[1] // "") | split(":") | map(select(length > 0))) as $right |
    (if ($halves|length) == 2 then $left + [range(8-($left|length)-($right|length))|"0"] + $right
     else $left end) | map(("0000"+.)|.[-4:]) | join(":")
  else . end;
def domain:
  type == "string" and length <= 253 and contains(".") and
  test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$") and (ip|not);
def port: type == "number" and . == floor and . >= 1 and . <= 65535;
def require($ok; $message): if $ok then . else error($message) end;
.
| require(type == "object"; "config must be a JSON object")
| require((keys - ["schema_version","environment_id","role","network_mode","domains","public_addresses","panel_addresses","management_address","ports","admin","resources","docker_subnet","acme","node_country","existing_caddy","security"]) == []; "unknown config field")
| require(.security==null or (.security|type=="object" and (keys-["enabled","root_public_key"]==[])); "unknown security field")
| require(.security.enabled==null or (.security.enabled|type=="boolean"); "security.enabled must be boolean")
| require(.security.root_public_key==null or (.security.root_public_key|type=="string" and length<=8192 and test("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+( [^\\r\\n]*)?$")); "root_public_key must be a public SSH key line")
| require(.schema_version == 1; "expected config schema_version 1")
| require(.environment_id | type == "string" and test("^[a-z][a-z0-9-]{2,19}$"); "environment_id: 3..20 letters/digits/hyphens")
| require(.role == "panel" or .role == "node" or .role == "panel-node"; "invalid role")
| .network_mode //= "clean"
| require(.network_mode == "clean" or .network_mode == "fi-parallel"; "invalid network_mode")
| require(.network_mode != "fi-parallel" or .role == "panel-node"; "FI parallel requires panel-node")
| .role as $role
| (if $role == "panel" then ["panel","subscription"] elif $role == "node" then ["node"] else ["node","panel","subscription"] end) as $names
| require((.domains|type) == "object" and (.domains|keys) == $names; "wrong domains for role")
| require(.domains | all(.[]; domain); "domains must be lower-case DNS names without URL/path/port")
| require(.public_addresses | type == "array" and length > 0 and all(ip); "public_addresses must contain literal A/AAAA IPs")
| .public_addresses |= (map(ipnorm)|unique)
| .panel_addresses //= []
| require(.panel_addresses | type == "array" and all(ip); "invalid panel_addresses")
| .panel_addresses |= (map(ipnorm)|unique)
| require(($role != "node" and (.panel_addresses|length) == 0) or ($role == "node" and (.panel_addresses|length) > 0); "standalone node requires panel source IPs")
| if $role=="node" then .management_address //= .domains.node | require(.management_address|ip or domain; "invalid node management_address")
  else require(.management_address==null; "management_address belongs to a standalone node") end
| .ports //= {}
| (if $role == "panel" then {http:80,https:443,panel_api:13000,metrics:13001,subscription_api:13010,caddy_admin:12019}
   elif $role == "node" then {http:80,reality:443,xhttp:8443,node_api:2222,reality_target:14123,caddy_admin:12019}
   elif .network_mode == "fi-parallel" then {http:18080,https:9443,panel_api:13000,metrics:13001,subscription_api:13010,reality:24443,xhttp:28443,node_api:2222,reality_target:14123,caddy_admin:12019}
   else {http:80,https:9443,panel_api:13000,metrics:13001,subscription_api:13010,reality:443,xhttp:8443,node_api:2222,reality_target:14123,caddy_admin:12019} end) as $defaults
| (if $role != "node" and .domains.panel == .domains.subscription then $defaults + {subscription_https:9444} else $defaults end) as $defaults
| require((.ports|type) == "object" and ((.ports|keys)-($defaults|keys)) == []; "unknown port for role")
| .ports = ($defaults + .ports)
| require(.ports | all(.[]; port); "ports must be integers 1..65535")
| require((.ports|[.[]]|unique|length) == (.ports|length); "duplicate ports")
| require(.network_mode != "fi-parallel" or ((.ports|[.[]]) - [80,443,8443,37241,4123,53042] | length) == (.ports|length); "FI port reserved by current system")
| .admin //= {}
| require($role == "node" or (.admin.username|type == "string" and test("^[a-z][a-z0-9_-]{2,31}$")); "invalid admin username")
| require($role == "node" or (.admin.email|type == "string" and test("^[A-Za-z0-9._+-]+@[a-z0-9.-]+\\.[a-z]{2,}$")); "invalid admin email")
| require((.admin|keys)-["username","email"] == []; "unknown admin field; no plaintext secrets in config")
| .resources //= {}
| .resources = ({purpose:"test",profile:"standard",image_gib:3,data_gib:1,restore_gib:2,reserve_gib:1} + .resources)
| require(.resources.purpose == "test" or .resources.purpose == "production"; "invalid purpose")
| require(.network_mode != "fi-parallel" or .resources.purpose == "test"; "FI parallel is only a test")
| require(.resources.profile == "standard" or (.resources.profile == "compact-test" and .resources.purpose == "test"); "compact-test profile is only for tests")
| require([.resources.image_gib,.resources.data_gib,.resources.restore_gib,.resources.reserve_gib] | all(type == "number" and . > 0 and . <= 10000); "positive disk budgets required")
| require((.resources|keys)-["purpose","profile","image_gib","data_gib","restore_gib","reserve_gib"] == []; "unknown resources field")
| .docker_subnet //= "172.29.240.0/24"
| require(.docker_subnet | type == "string" and test("^(10\\.[0-9]{1,3}\\.[0-9]{1,3}|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}|192\\.168\\.[0-9]{1,3})\\.0/24$") and (split("/")[0]|ip4); "docker_subnet must be a private IPv4 /24")
| .acme //= "production"
| require(.acme == "production" or .acme == "staging"; "acme must be production or staging")
| .node_country //= "XX"
| require(.node_country | type == "string" and test("^[A-Z]{2}$"); "invalid country code")
RW_CONFIG_JQ
}
# shellcheck shell=bash
rw_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
rw_info() { printf '%s\n' "$*" >&2; }
rw_linux() { [[ $(uname -s) == Linux ]] || rw_die 'This installer supports Linux only.'; }
rw_root() { (( EUID == 0 )) || rw_die 'Run installation and removal as root.'; }
rw_need() { command -v "$1" >/dev/null 2>&1 || rw_die "Required command: $1."; }
rw_safe_parents() {
    local parent
    parent=$(dirname -- "$1")
    while [[ $parent != / && $parent != . ]]; do
        [[ ! -L $parent ]] || rw_die 'A parent directory is a symbolic link.'
        if [[ $parent == */* ]]; then parent=${parent%/*}; [[ -n $parent ]] || parent=/; else parent=.; fi
    done
}
rw_atomic() {
    local target=$1 temp
    rw_safe_parents "$target"
    [[ ! -L $target ]] || rw_die 'A managed file is a symbolic link.'
    mkdir -p -- "$(dirname -- "$target")"
    temp=$(mktemp "${target}.tmp.XXXXXX")
    cat > "$temp"; chmod 600 "$temp"
    if [[ -f ${RW_OUT:-}/manifest.json && $target == "$RW_OUT/"* && $target != "$RW_OUT/manifest.json" && $target != "$RW_OUT/private/.managed-paths" ]]; then
        rw_write_begin "$target" "$temp"
        rw_resume_writes
    else mv -f -- "$temp" "$target"; fi
}
rw_plain_atomic() {
    local target=$1 temp
    [[ ! -L $target ]] || rw_die 'The journal is a symbolic link.'
    temp=$(mktemp "${target}.tmp.XXXXXX")
    cat > "$temp"; chmod 600 "$temp"; mv -f -- "$temp" "$target"
}
rw_write_begin() {
    local target=$1 temp=${2:-} previous='' next=''
    [[ ! -f $RW_OUT/.rw-write.json ]] || rw_die 'An unfinished write exists; recover the journal first.'
    [[ ! -f $target ]] || previous=$(sha256sum "$target" | cut -d' ' -f1)
    [[ -z $temp ]] || next=$(sha256sum "$temp" | cut -d' ' -f1)
    jq -n --arg owner "$RW_OWNER" --arg path "${target#"$RW_OUT/"}" --arg temp "${temp#"$RW_OUT/"}" --arg previous "$previous" --arg next "$next" \
      '{schema_version:1,owner:$owner,path:$path,temp:$temp,previous:$previous,next:$next}' | rw_plain_atomic "$RW_OUT/.rw-write.json"
}
rw_resume_writes() {
    [[ -f $RW_OUT/.rw-write.json ]] || return 0
    local path temp previous next current='' target
    [[ ! -L $RW_OUT/.rw-write.json && $(stat -c %a "$RW_OUT/.rw-write.json") == 600 ]] || rw_die 'The write journal must be a regular file with mode 0600.'
    jq -e --arg owner "$RW_OWNER" '.schema_version==1 and .owner==$owner and (.path|type=="string" and test("^[A-Za-z0-9_./-]+$") and startswith("/")==false and contains("..")==false) and (.path!="manifest.json" and .path!=".rw-write.json") and ([.previous,.next]|all(.=="" or test("^[a-f0-9]{64}$")))' "$RW_OUT/.rw-write.json" >/dev/null || rw_die 'The write journal does not belong to this installation.'
    path=$(jq -r '.path' "$RW_OUT/.rw-write.json"); temp=$(jq -r '.temp' "$RW_OUT/.rw-write.json")
    previous=$(jq -r '.previous' "$RW_OUT/.rw-write.json"); next=$(jq -r '.next' "$RW_OUT/.rw-write.json")
    target=$RW_OUT/$path; rw_safe_parents "$target"
    [[ ! -L $target && ( ! -e $target || -f $target ) ]] || rw_die 'Unexpected file type in an unfinished write.'
    [[ ! -f $target ]] || current=$(sha256sum "$target" | cut -d' ' -f1)
    [[ $current == "$previous" || $current == "$next" ]] || rw_die 'The file was changed externally during an unfinished write.'
    if [[ -n $next ]]; then
        [[ $temp == "$path.tmp."* && $temp != *'..'* && $temp != /* ]] || rw_die 'Invalid temporary path in the write journal.'
        rw_safe_parents "$RW_OUT/$temp"
        if [[ $current != "$next" ]]; then
            [[ -f $RW_OUT/$temp && ! -L $RW_OUT/$temp && $(sha256sum "$RW_OUT/$temp" | cut -d' ' -f1) == "$next" ]] || rw_die 'The unfinished write payload is missing or changed.'
            mv -f -- "$RW_OUT/$temp" "$target"
        fi
        jq --arg path "$path" --arg sum "$next" '.managed_files=([.managed_files[]|select(.path!=$path)]+[{path:$path,sha256:$sum}])' "$RW_OUT/manifest.json" | rw_plain_atomic "$RW_OUT/manifest.json"
        [[ ! -e $RW_OUT/$temp ]] || rm -f -- "$RW_OUT/$temp"
    else
        rm -f -- "$target"
        jq --arg path "$path" '.managed_files|=map(select(.path!=$path))' "$RW_OUT/manifest.json" | rw_plain_atomic "$RW_OUT/manifest.json"
    fi
    rm -f -- "$RW_OUT/.rw-write.json"
}
rw_managed_remove() { rw_write_begin "$RW_OUT/$1"; rw_resume_writes; }
rw_lock() {
    [[ ${RW_LOCK_DIR:-} != "$RW_OUT" ]] || return 0
    rw_safe_parents "$RW_OUT/private/.lock-check"
    mkdir -p -- "$RW_OUT/private"
    chmod 700 "$RW_OUT" "$RW_OUT/private"
    exec 9>"$RW_OUT/.rw.lock"
    flock -n 9 || rw_die 'Another operation is running for this installation.'
    RW_LOCK_DIR=$RW_OUT
}
rw_cleanup() {
    if [[ ${RW_TLS_PROXY_PENDING:-0} == 1 ]]; then rw_tls_restore_proxy || true; fi
    if [[ -n ${RW_TLS_CONTAINER:-} ]]; then rw_tls_cleanup || true; fi
    if [[ ${RW_UPGRADE_PENDING:-0} == 1 ]]; then rw_upgrade_abort || true; fi
    if [[ ${RW_UFW_MUTATING:-0} == 1 ]]; then rw_security_revert || true; fi
    if [[ ${RW_CADDY_ROLLBACK_PENDING:-0} == 1 ]]; then
        cat "$RW_OUT/private/existing-caddy.before" > "$RW_EXISTING_CADDY_FILE" || true
        docker exec "$RW_EXISTING_CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
    fi
    if [[ -n ${RW_PAUSED_CADDY:-} ]]; then docker unpause "$RW_PAUSED_CADDY" >/dev/null 2>&1 || true; fi
    if [[ ${RW_MUTATING:-0} == 1 && -f ${RW_OUT:-}/manifest.json ]]; then rw_track_files || true; fi
    [[ -z ${RW_TMP:-} ]] || rm -rf -- "${RW_TMP:?}"
}
rw_init_tmp() {
    RW_MUTATING=0
    RW_UPGRADE_PENDING=0
    RW_UFW_MUTATING=0
    RW_TMP=$(mktemp -d /tmp/pdm-rw.XXXXXX)
    trap rw_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
}
rw_deps() {
    local missing=0 cmd
    for cmd in curl jq openssl dig ss nft flock ssh-keygen; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
    if (( missing )); then
        rw_root
        rw_info 'Installing dependencies: curl jq openssl dnsutils iproute2 nftables util-linux ca-certificates openssh-client.'
        rw_apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl jq openssl dnsutils iproute2 nftables util-linux ca-certificates openssh-client
    fi
}
rw_apt_update() {
    [[ ${RW_APT_UPDATED:-0} != 1 ]] || return 0
    apt-get update -q || rw_die 'Cannot refresh APT package indexes.'
    RW_APT_UPDATED=1
}
rw_os() {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 && $(uname -m) == x86_64 ]] || rw_die 'Supported server: Debian 13 amd64.'
}
rw_docker_install() {
    RW_DOCKER_INSTALLED=0
    if ! command -v docker >/dev/null 2>&1; then
        RW_DOCKER_INSTALLED=1
        rw_info 'Installing Docker Engine and Compose from the official Docker APT repository.'
        apt-get install -y --no-install-recommends ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsS --proto '=https' --tlsv1.2 https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' 'Components: stable' 'Architectures: amd64' 'Signed-By: /etc/apt/keyrings/docker.asc' > /etc/apt/sources.list.d/docker.sources
        # Adding a repository invalidates the package index from rw_deps.
        RW_APT_UPDATED=0; rw_apt_update
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker.service
    fi
    docker info >/dev/null 2>&1 || rw_die 'Docker is unavailable; the existing daemon will not be reinstalled.'
    local version major minor
    version=$(docker compose version --short); version=${version#v}; IFS=. read -r major minor _ <<< "$version"
    (( major > 2 || (major == 2 && minor >= 30) )) || rw_die 'Docker Compose 2.30 or newer is required.'
}
rw_config_load() {
    local file=$1
    rw_config_filter > "$RW_TMP/config.jq"
    jq -ef "$RW_TMP/config.jq" "$file" > "$RW_TMP/config.json" 2>"$RW_TMP/config-error" || rw_die 'Invalid configuration JSON. Check the fields and installer/examples.'
    RW_CFG=$RW_TMP/config.json
    RW_ENV=$(jq -r '.environment_id' "$RW_CFG"); RW_ROLE=$(jq -r '.role' "$RW_CFG"); RW_MODE=$(jq -r '.network_mode' "$RW_CFG")
    RW_OUT=$(realpath -m -- "${RW_OUT:-/opt/pdm-remnawave/$RW_ENV}")
    [[ $RW_OUT =~ ^/[A-Za-z0-9_./-]+$ ]] || rw_die 'Installation directory must be an absolute path without spaces or control characters.'
    [[ $RW_OUT != / && $RW_OUT != /opt && $RW_OUT != /etc && $RW_OUT != /tmp && $RW_OUT != /root && $RW_OUT != /home ]] || rw_die 'Specify a dedicated installation directory.'
    local parent=$RW_OUT
    while [[ $parent != / ]]; do [[ ! -L $parent ]] || rw_die 'The installation directory contains a symbolic link.'; parent=${parent%/*}; [[ -n $parent ]] || parent=/; done
    RW_PROJECT=pdm-rw-$RW_ENV
    RW_OWNER=$(printf '%s' "$RW_ENV:$RW_OUT" | sha256sum | cut -d' ' -f1)
    RW_SUBNET=$(jq -r '.docker_subnet' "$RW_CFG"); RW_NET_PREFIX=${RW_SUBNET%.0/24}; RW_PANEL_ADDRESS=$RW_NET_PREFIX.1
    RW_TABLE=pdm_rw_${RW_ENV//-/_}
    RW_FINGERPRINT=$(jq -Sc . "$RW_CFG" | sha256sum | cut -d' ' -f1)
}
rw_cfg() { jq -r "$1" "$RW_CFG"; }
rw_port() { rw_cfg ".ports.$1 // empty"; }
rw_subscription_port() { rw_cfg '.ports.subscription_https // .ports.https // empty'; }
rw_http_sites() {
    jq -r '.domains|to_entries|group_by(.value)|map(sort_by(if .key=="panel" then 0 elif .key=="subscription" then 1 else 2 end)|.[0])|.[]|[.key,.value]|@tsv' "$RW_CFG"
}
rw_memory_limits() {
    jq 'if .resources.profile == "compact-test" then {rw_db:160,rw_valkey:32,rw_panel:512,rw_subscription:192,rw_caddy:96,rw_node:160}
        else {rw_db:512,rw_valkey:128,rw_panel:768,rw_subscription:128,rw_caddy:128,rw_node:256} end' "$RW_CFG"
}
rw_compose() { docker compose --project-name "$RW_PROJECT" -f "$RW_OUT/compose.json" "$@"; }
rw_pull() { timeout --foreground 900 docker compose --project-name "$RW_PROJECT" -f "$RW_OUT/compose.json" --profile public --profile node pull --policy missing "$@"; }
rw_manifest_set() { local filter=$1; shift; jq "$@" "$filter" "$RW_OUT/manifest.json" | rw_atomic "$RW_OUT/manifest.json"; }
rw_manifest() {
    local status=$1
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" --arg project "$RW_PROJECT" --arg owner "$RW_OWNER" --arg fp "$RW_FINGERPRINT" --arg status "$status" \
      '{schema_version:2,implementation:"bash-docker",environment_id:$e,role:$role,compose_project:$project,ownership_label:$owner,config_fingerprint:$fp,status:$status,api:{},managed_files:[]}' | rw_atomic "$RW_OUT/manifest.json"
}
rw_owned() {
    [[ -f $RW_OUT/manifest.json && ! -L $RW_OUT/manifest.json ]] || rw_die 'The installation manifest is missing.'
    jq -e --arg owner "$RW_OWNER" --arg e "$RW_ENV" --arg p "$RW_PROJECT" \
      '.schema_version==2 and .implementation=="bash-docker" and .environment_id==$e and .ownership_label==$owner and .compose_project==$p' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Installation ownership conflict.'
}
rw_install_ctl() {
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set +x' 'set -euo pipefail' 'export LC_ALL=C' 'umask 077'
        local fn
        while IFS= read -r fn; do declare -f "$fn"; done < <(compgen -A function | LC_ALL=C sort | awk '/^rw_/')
        printf '%s\n' 'rw_main ctl "$@"'
    } | rw_atomic "$RW_OUT/rwctl"
    chmod 700 "$RW_OUT/rwctl"
}
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
        rw_apt_update
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
rw_security_remove_rules() {
    # show added includes stored rules even when UFW is inactive after rollback.
    # Parse only the two rule shapes this installer creates; never evaluate text.
    local line body source port
    local -a rule=()
    ufw show added > "$RW_TMP/ufw-added" || rw_die 'Cannot read stored UFW rules.'
    : > "$RW_TMP/ufw-remove"
    while IFS= read -r line; do
        [[ $line == *" comment '$RW_PROJECT'" ]] || continue
        body=${line%" comment '$RW_PROJECT'"}; body=${body#ufw }
        read -r -a rule <<< "$body"
        if [[ ${#rule[@]} == 2 && ${rule[0]} == allow && ${rule[1]} =~ ^[0-9]{1,5}/(tcp|udp)$ ]]; then
            port=${rule[1]%/*}
        elif [[ ${#rule[@]} == 9 && ${rule[0]} == allow && ${rule[1]} == from && ${rule[3]} == to && ${rule[4]} == any && ${rule[5]} == port && ${rule[7]} == proto && ${rule[8]} == tcp ]]; then
            source=${rule[2]}; port=${rule[6]}
            [[ $source =~ ^[0-9a-fA-F:.]+$ ]] || rw_die 'Unexpected source in an owned UFW rule.'
        else rw_die 'An owned UFW rule changed shape; review it before removal.'; fi
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port<=65535 )) || rw_die 'Invalid port in an owned UFW rule.'
        printf '%s\n' "$body" >> "$RW_TMP/ufw-remove"
    done < "$RW_TMP/ufw-added"
    while IFS= read -r body; do
        read -r -a rule <<< "$body"
        ufw --force delete "${rule[@]}" >/dev/null || rw_die 'Cannot remove an owned UFW rule.'
    done < "$RW_TMP/ufw-remove"
}
# shellcheck shell=bash
rw_resource_checks() {
    local total available free required minram mincpu cpus image cached=0 path=$RW_OUT id limits credit=0
    total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    available=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    cpus=$(getconf _NPROCESSORS_ONLN)
    minram=1536; mincpu=1
    if [[ $RW_ROLE == node ]]; then minram=1024
    elif [[ $(rw_cfg '.resources.purpose') == production ]]; then minram=4096; mincpu=2; fi
    (( total >= minram && cpus >= mincpu )) || rw_die 'Insufficient RAM or CPU for the selected purpose.'
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
    (( available >= required )) || rw_die "New containers require $required MiB of available RAM in addition to existing services."
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
    (( free >= required )) || rw_die 'Insufficient disk space for images, data, recovery and reserve; unrelated data will not be removed.'
}
rw_dns_checks() {
    local domain family
    { rw_config_filter | sed '/^\.$/,$d'; printf '\n[inputs|select(ip)|ipnorm]|unique\n'; } > "$RW_TMP/dns.jq"
    while IFS= read -r domain; do
        : > "$RW_TMP/dns.txt"
        for family in A AAAA; do
            dig +time=3 +tries=1 +noall +answer +comments "$domain" "$family" > "$RW_TMP/dig-answer.txt" || rw_die "DNS lookup failed: $domain"
            grep -q 'status: NOERROR' "$RW_TMP/dig-answer.txt" || rw_die "DNS response for $domain/$family could not be verified."
            awk '$4=="A" || $4=="AAAA" {print $5}' "$RW_TMP/dig-answer.txt" >> "$RW_TMP/dns.txt"
        done
        # CNAMEs are excluded, but every A/AAAA address must match the declared set.
        jq -Rn -f "$RW_TMP/dns.jq" < "$RW_TMP/dns.txt" > "$RW_TMP/dns.json"
        jq -e --slurpfile actual "$RW_TMP/dns.json" '.public_addresses == $actual[0]' "$RW_CFG" >/dev/null || rw_die "A/AAAA records for $domain do not match public_addresses."
    done < <(jq -r '.domains|[.[]]|unique[]' "$RW_CFG")
}
rw_docker_ownership() {
    local -a ids=()
    docker ps -aq --filter "label=com.docker.compose.project=$RW_PROJECT" > "$RW_TMP/ownership-ids" || rw_die 'Cannot list installation containers.'
    mapfile -t ids < "$RW_TMP/ownership-ids"
    (( ${#ids[@]} )) || return 0
    docker inspect --format '{{json .Config.Labels}}' "${ids[@]}" > "$RW_TMP/ownership-labels.jsonl" || rw_die 'Cannot inspect installation containers.'
    jq -se --arg owner "$RW_OWNER" --arg project "$RW_PROJECT" --arg configs "$RW_OUT/compose.json" --argjson count "${#ids[@]}" '
      length==$count and all(.[]; .["io.pdm.remnawave.installation"]==$owner and .["com.docker.compose.project"]==$project and .["com.docker.compose.project.config_files"]==$configs)' "$RW_TMP/ownership-labels.jsonl" >/dev/null || rw_die 'A Compose project with this name belongs to another installation.'
}
rw_port_checks() {
    local name port id pids row socket_pids owned_ids publication
    owned_ids=$(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    : > "$RW_TMP/owned-pids"
    for id in $owned_ids; do docker top "$id" -eo pid | awk 'NR>1 && $1~/^[0-9]+$/ {print $1}' >> "$RW_TMP/owned-pids"; done
    ss -H -lntp > "$RW_TMP/tcp-listeners" || rw_die 'Cannot read TCP listeners.'
    while IFS=$'\t' read -r name port; do
        while IFS= read -r row; do
            [[ -n $row ]] || continue
            socket_pids=$(grep -oE 'pid=[0-9]+' <<< "$row" | cut -d= -f2 || true)
            [[ -n $socket_pids ]] || rw_die "Unknown owner of TCP port $port ($name)."
            for pids in $socket_pids; do
                if ! grep -qx "$pids" "$RW_TMP/owned-pids"; then
                    publication=0
                    if [[ $name == panel_api || $name == metrics || $name == subscription_api || $name == stats_api ]]; then
                        for id in $owned_ids; do
                            docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" | jq -e --arg port "$port" 'to_entries | any(.[]|.value[]?; .HostIp=="127.0.0.1" and .HostPort==$port)' >/dev/null && publication=1
                        done
                    fi
                    (( publication )) || rw_die "TCP port $port ($name) is used by another service."
                fi
            done
        done < <(awk -v p="$port" '$4 ~ (":" p "$") {print}' "$RW_TMP/tcp-listeners")
    done < <(jq -r '.ports|to_entries[]|[.key,.value]|@tsv' "$RW_CFG"; if rw_stats_enabled; then printf 'stats_api\t%s\n' "$(rw_stats_port)"; fi)
    # Docker NAT publications can exist without a listening docker-proxy process.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]] && continue
        docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" > "$RW_TMP/docker-ports.json"
        jq -e --slurpfile c "$RW_CFG" '[to_entries[]|select(.key|endswith("/tcp"))|.value[]?.HostPort|tonumber] as $used | ($c[0].ports|[.[]]) as $wanted | all($used[]; . as $port | ($wanted|index($port))==null)' "$RW_TMP/docker-ports.json" >/dev/null || rw_die 'An installation port is already published by another Docker container.'
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
      ($subnet|bounds) as $wanted | [inputs|select(test("^[0-9.]+/[0-9]+$"))|bounds] | all(.[]; .[1]<$wanted[0] or .[0]>$wanted[1])' < "$RW_TMP/networks" | grep -qx true || rw_die 'docker_subnet overlaps an existing network; specify another subnet.'
}
rw_preflight() {
    # apply already checked DNS/resources. A newly installed daemon consumes RAM,
    # so repeat resource admission in that case before starting any containers.
    rw_os
    if [[ ${1:-} != --host-checked ]]; then rw_resource_checks; rw_dns_checks
    elif [[ ${RW_DOCKER_INSTALLED:-0} == 1 ]]; then rw_resource_checks; fi
    /usr/sbin/sshd -t || rw_die 'sshd -t failed; SSH was not changed.'
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || rw_die 'Time synchronization could not be verified.'
    nft -j list ruleset >/dev/null || rw_die 'Cannot read the current firewall rules.'
    rw_docker_ownership; rw_port_checks; rw_network_check
    if [[ $RW_MODE == fi-parallel ]]; then rw_existing_caddy_check; fi
    rw_info 'Preflight passed: OS, DNS A/AAAA, RAM/disk, ports, Docker and networks.'
}
# shellcheck shell=bash
rw_track_files() {
    local file relative
    local -a paths=()
    while IFS= read -r relative; do
        [[ -n $relative && $relative != manifest.json && $relative != .rw.lock && $relative != /* && $relative != *'..'* ]] || continue
        file=$RW_OUT/$relative
        [[ -f $file && ! -L $file ]] || continue
        paths+=("$relative")
    done < <({ [[ ! -f $RW_OUT/private/.managed-paths ]] || cat "$RW_OUT/private/.managed-paths"; jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf '%s\n' 'private/.managed-paths'; } | LC_ALL=C sort -u)
    : > "$RW_TMP/managed.sums"
    if (( ${#paths[@]} )); then
        (cd -- "$RW_OUT" && sha256sum --zero -- "${paths[@]}") > "$RW_TMP/managed.sums" || rw_die 'Cannot hash managed files.'
    fi
    jq -Rs 'split("\u0000")|map(select(length>0)|{path:.[66:],sha256:.[0:64]})' "$RW_TMP/managed.sums" > "$RW_TMP/managed.json"
    rw_manifest_set '.managed_files=$files[0]' --slurpfile files "$RW_TMP/managed.json"
}
rw_verify_files() {
    local path sum parent
    while IFS=$'\t' read -r path sum; do
        [[ $path != /* && $path != *'..'* && $path != *$'\n'* ]] || rw_die 'Unsafe path in the manifest.'
        parent=$RW_OUT/$path
        while [[ $parent != "$RW_OUT" ]]; do [[ ! -L $parent ]] || rw_die 'A managed path contains a symbolic link.'; parent=${parent%/*}; done
        [[ -f $RW_OUT/$path && $(sha256sum "$RW_OUT/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Managed file $path changed; review is required."
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$RW_OUT/manifest.json")
}
rw_doctor() {
    local id state service node_uuid attempts
    : > "$RW_TMP/doctor-tokens.jsonl"
    printf 'null\n' > "$RW_TMP/doctor-mfa.json"
    rw_owned; rw_docker_ownership
    [[ $(jq -r '.status' "$RW_OUT/manifest.json") != node-prepared-awaiting-attachment ]] || rw_die 'The node is prepared but is not attached to a panel yet.'
    rw_compose --profile public --profile node ps --services --status running > "$RW_TMP/running-services" || rw_die 'Cannot list running services.'
    while IFS= read -r service; do
        grep -Fxq "$service" "$RW_TMP/running-services" || rw_die "Running service $service is missing."
    done < <(jq -r '.services|keys[]' "$RW_OUT/compose.json")
    [[ $(stat -c %a "$RW_OUT/private") == 700 ]] || rw_die 'private/ must have mode 0700.'
    while IFS= read -r -d '' id; do [[ $(stat -c %a "$id") == 600 ]] || rw_die 'A secret file has overly permissive permissions.'; done < <(find "$RW_OUT/private" -type f -print0)
    local -a ids=()
    docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" > "$RW_TMP/doctor-ids" || rw_die 'Cannot list owned containers.'
    mapfile -t ids < "$RW_TMP/doctor-ids"
    (( ${#ids[@]} )) || rw_die 'No owned containers are running.'
    docker inspect --format '{{.Id}} {{index .Config.Labels "com.docker.compose.service"}} {{.State.Status}} {{with index .State "Health"}}{{.Status}}{{else}}none{{end}}' "${ids[@]}" > "$RW_TMP/doctor-states" || rw_die 'Cannot inspect container health.'
    local health
    while read -r id service state health; do
        [[ $state == running ]] || rw_die "Service $service is in state $state."
        state=$health
        for ((attempts=0; attempts<60; attempts++)); do
            [[ $state == starting ]] || break
            sleep 2
            state=$(docker inspect --format '{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}' "$id")
        done
        [[ $state == healthy || $state == none ]] || rw_die "Healthcheck $service: $state."
    done < "$RW_TMP/doctor-states"
    if [[ $RW_ROLE != node ]]; then
        rw_wait_panel
        rw_tokens_status > "$RW_TMP/doctor-tokens.jsonl" || rw_die 'Panel tokens need recovery: run rwctl tokens rotate.'
        rw_mfa_status > "$RW_TMP/doctor-mfa.json"
        while IFS= read -r node_uuid; do
            rw_wait_node "$node_uuid" "$RW_TMP/node-health.json"
        done < <(jq -r '.nodes[].node_uuid' "$RW_OUT/inventory.json")
    fi
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" --slurpfile tokens "$RW_TMP/doctor-tokens.jsonl" --slurpfile mfa "$RW_TMP/doctor-mfa.json" '{schema_version:1,environment_id:$e,role:$role,containers_running:true,client_acceptance_required:true,tokens:$tokens,mfa:$mfa[0]}'
}
rw_resource_plan() {
    local kind=$1
    local -a ids=()
    docker "$kind" ls -q --filter "label=com.docker.compose.project=$RW_PROJECT" > "$RW_TMP/$kind-ids" || rw_die 'Cannot list Docker resources.'
    mapfile -t ids < "$RW_TMP/$kind-ids"
    (( ${#ids[@]} )) || return 0
    docker inspect --type "$kind" --format '{{json .Labels}}' "${ids[@]}" > "$RW_TMP/$kind-labels.jsonl" || rw_die 'Cannot inspect Docker resources.'
    jq -se --arg owner "$RW_OWNER" --argjson count "${#ids[@]}" 'length==$count and all(.[]; .["io.pdm.remnawave.installation"]==$owner)' "$RW_TMP/$kind-labels.jsonl" >/dev/null || rw_die 'The Docker resource belongs to another installation.'
    printf '%s\n' "${ids[@]}" | LC_ALL=C sort
}
rw_uninstall() {
    rw_owned
    rw_ssh_idle
    if [[ ${RW_PREPARED_ONLY:-0} == 1 ]]; then
        [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared ]] || rw_die 'prepared-only cannot remove an installation that has been started.'
        [[ ${RW_PURGE:-0} == 0 ]] || rw_die 'prepared-only and purge cannot be combined.'
        printf '[]\n' > "$RW_TMP/containers.json"
        : > "$RW_TMP/networks"; : > "$RW_TMP/volumes"
    else
        docker info >/dev/null 2>&1 || rw_die 'Docker is unavailable; installation files were retained.'
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]' > "$RW_TMP/containers.json"
        rw_resource_plan network > "$RW_TMP/networks"
        rw_resource_plan volume > "$RW_TMP/volumes"
    fi
    rw_verify_files
    if [[ ${RW_DRY_RUN:-0} == 1 ]]; then
        jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --slurpfile containers "$RW_TMP/containers.json" --rawfile volumes "$RW_TMP/volumes" --argjson purge "${RW_PURGE:-0}" '{environment_id:$e,directory:$path,containers:$containers[0],volumes:($volumes|split("\n")|map(select(length>0))),purge:($purge==1),read_only:true}'; return
    fi
    rw_root
    if [[ ${RW_YES:-0} != 1 ]]; then
        rw_info "Remove only $RW_PROJECT in $RW_OUT. Docker data: $([[ ${RW_PURGE:-0} == 1 ]] && printf delete || printf retain)."
        local confirm; read -r -p "Type $RW_ENV to confirm: " confirm
        [[ $confirm == "$RW_ENV" ]] || { rw_info 'Cancelled.'; return; }
    fi
    rw_lock; rw_verify_files
    if [[ ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]|sort' > "$RW_TMP/current-containers.json"
        jq 'sort' "$RW_TMP/containers.json" > "$RW_TMP/planned-containers.json"
        cmp -s "$RW_TMP/current-containers.json" "$RW_TMP/planned-containers.json" || rw_die 'The container inventory changed after confirmation.'
        rw_resource_plan network > "$RW_TMP/current-networks"
        rw_resource_plan volume > "$RW_TMP/current-volumes"
        cmp -s "$RW_TMP/networks" "$RW_TMP/current-networks" && cmp -s "$RW_TMP/volumes" "$RW_TMP/current-volumes" || rw_die 'The network or volume inventory changed after confirmation.'
    fi
    if [[ -f $RW_OUT/private/security-state.json && $(jq -r '.status' "$RW_OUT/private/security-state.json") == armed ]]; then
        rw_security_revert
        systemctl stop "$RW_PROJECT-ufw-revert.timer" >/dev/null 2>&1 || true
    fi
    if [[ ${RW_PURGE:-0} != 1 && ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        local recovery
        recovery=/var/backups/pdm-remnawave/$RW_ENV-config-$(date -u +%Y%m%dT%H%M%SZ).tgz
        mkdir -p /var/backups/pdm-remnawave; chmod 700 /var/backups/pdm-remnawave
        tar -C "$RW_OUT" -czf "$recovery" --files-from <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf 'manifest.json\n')
        chmod 600 "$recovery"
        rw_info "Private configuration/key backup for retained volumes: $recovery"
    fi
    if [[ $(jq -r '.existing_caddy_updated // false' "$RW_OUT/manifest.json") == true ]]; then
        local file container
        file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'The existing Caddy configuration changed; automatic route restoration stopped.'
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    fi
    local id
    local -a containers=()
    mapfile -t containers < <(jq -r '.[]' "$RW_TMP/containers.json")
    if (( ${#containers[@]} )); then
        docker stop -t 30 "${containers[@]}" >/dev/null
        docker rm "${containers[@]}" >/dev/null
    fi
    while IFS= read -r id; do [[ -z $id ]] || docker network rm "$id" >/dev/null; done < "$RW_TMP/networks"
    if [[ ${RW_PURGE:-0} == 1 ]]; then while IFS= read -r id; do [[ -z $id ]] || docker volume rm "$id" >/dev/null; done < "$RW_TMP/volumes"; fi
    if [[ $(jq -r '.ufw_rules_added // false' "$RW_OUT/manifest.json") == true ]]; then
        rw_security_remove_rules
    fi
    if [[ $(jq -r '.firewall_installed // false' "$RW_OUT/manifest.json") == true ]]; then
        local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
        [[ -f $unit ]] && grep -qF "$RW_OWNER" "$unit" || rw_die 'Firewall systemd unit ownership could not be verified.'
        systemctl disable "$RW_PROJECT-firewall.service" >/dev/null; rm -f -- "$unit"; systemctl daemon-reload
        nft list table inet "$RW_TABLE" >/dev/null 2>&1 && nft delete table inet "$RW_TABLE"
    fi
    # Delete only recorded files. Unknown backups/operator files and nonempty directories remain.
    while IFS= read -r id; do rm -f -- "$RW_OUT/$id"; done < <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json")
    rm -f -- "$RW_OUT/manifest.json" "$RW_OUT/.rw.lock"
    find "$RW_OUT" -depth -type d -empty -delete
    rw_info 'Removal complete. Unrelated containers, images, Docker Engine, SSH and shared firewall rules were retained.'
}
rw_backup() {
    local archive=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-$(date -u +%Y%m%dT%H%M%SZ).tgz} id name image build
    archive=$(realpath -m -- "$archive")
    [[ $archive != "$RW_OUT"/* && ! -e $archive ]] || rw_die 'Backup must be a new file outside the installation directory.'
    rw_owned; rw_root; rw_lock; rw_docker_ownership; rw_verify_files; rw_ssh_idle
    mkdir -p -- "$(dirname -- "$archive")"
    build=$(mktemp -d "$RW_TMP/backup.XXXXXX")
    [[ -z $(find "$RW_OUT" -type l -print -quit) ]] || rw_die 'A symbolic link exists in the installation directory; backup stopped.'
    cp -a -- "$RW_OUT" "$build/installation"
    jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --arg owner "$RW_OWNER" --arg time "$(date -u +%FT%TZ)" '{schema_version:1,environment_id:$e,installation_path:$path,ownership_label:$owner,created_at_utc:$time}' > "$build/metadata.json"
    if [[ $RW_ROLE != node ]]; then rw_compose exec -T rw_db pg_dump -U postgres -d remnawave -Fc > "$build/database.dump"; fi
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    id=$(rw_compose --profile public ps -q rw_caddy)
    if [[ -n $id ]]; then docker pause "$id" >/dev/null; RW_PAUSED_CADDY=$id; fi
    for name in caddy_data caddy_config; do
        docker volume inspect "${RW_PROJECT}_$name" --format '{{index .Labels "io.pdm.remnawave.installation"}}' | grep -qx "$RW_OWNER" || rw_die 'Caddy volume ownership could not be verified.'
        docker run --rm --network none --read-only --cap-drop ALL --entrypoint tar --mount "type=volume,src=${RW_PROJECT}_$name,dst=/data,readonly" "$image" -C /data -czf - . > "$build/$name.tgz"
    done
    if [[ -n ${RW_PAUSED_CADDY:-} ]]; then docker unpause "$RW_PAUSED_CADDY" >/dev/null; RW_PAUSED_CADDY=; fi
    tar -C "$build" -czf "$archive" .; chmod 600 "$archive"; tar -tzf "$archive" >/dev/null
    sha256sum "$archive" > "$archive.sha256"; chmod 600 "$archive.sha256"
    rw_info "Backup verified: $archive. Copy it off the VPS before cutover."
}
rw_node_attach() {
    local host=${RW_SSH:-} config=${RW_NODE_CONFIG:-} env remote
    [[ $RW_ROLE != node && $host =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*$ && -f $config ]] || rw_die 'node attach requires --ssh USER@HOST and --node-config FILE on the panel server.'
    rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    rw_wait_panel; rw_panel_login
    jq -ef "$RW_TMP/config.jq" "$config" > "$RW_TMP/node-config.json"
    [[ $(jq -r '.role' "$RW_TMP/node-config.json") == node ]] || rw_die 'A node-role configuration is required.'
    env=$(jq -r '.environment_id' "$RW_TMP/node-config.json"); remote=/opt/pdm-remnawave/$env
    local -a ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    local remote_uid prefix=
    remote_uid=$(ssh "${ssh_options[@]}" "$host" 'id -u')
    [[ $remote_uid =~ ^[0-9]+$ ]] || rw_die 'The SSH user UID could not be verified.'
    if [[ $remote_uid != 0 ]]; then prefix='sudo -n '; ssh "${ssh_options[@]}" "$host" 'sudo -n true'; fi
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' preflight --config '$remote/config.json' --output '$remote'"
    local local_fp remote_fp
    local_fp=$(jq -Sc . "$RW_TMP/node-config.json" | sha256sum | cut -d' ' -f1)
    remote_fp=$(ssh "${ssh_options[@]}" "$host" "${prefix}jq -r .config_fingerprint '$remote/manifest.json'")
    [[ $local_fp == "$remote_fp" ]] || rw_die 'Local node parameters do not match the prepared SSH host.'
    ssh "${ssh_options[@]}" "$host" "${prefix}cat '$remote/private/xray-profile.json'" > "$RW_TMP/remote-profile.json"
    RW_MUTATING=1
    rw_register_node "$RW_TMP/node-config.json" "$RW_TMP/connection.json" "$(jq -r '.management_address' "$RW_TMP/node-config.json")" "$RW_TMP/remote-profile.json"
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' node receive --output '$remote'" < "$RW_TMP/connection.json"
    local uuid
    uuid=$(jq -er '.node_uuid' "$RW_TMP/connection.json")
    rw_wait_node "$uuid" "$RW_TMP/attached-node.json"
    rw_info 'Node attached. Existing users were not granted access automatically.'
}
rw_node_receive() {
    rw_root; rw_owned
    [[ $RW_ROLE == node ]] || rw_die 'node receive supports standalone nodes only.'
    rw_lock; RW_MUTATING=1
    cat > "$RW_TMP/received-connection.json"
    RW_CONNECTION=$RW_TMP/received-connection.json
    rw_apply; rw_track_files
}
# shellcheck shell=bash
rw_ssh_idle() {
    [[ ! -f $RW_OUT/private/ssh-state.json ]] || [[ $(jq -r '.status' "$RW_OUT/private/ssh-state.json") != armed ]] || rw_die 'Finish verifying the new SSH login or wait for automatic SSH restoration.'
}
rw_ssh_prepare() {
    rw_root; rw_os; rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    local user=${RW_SSH_ADMIN:-} keyfile=${RW_SSH_PUBLIC_KEY:-} keytype keydata _ fingerprint home marker sudoers nonce
    [[ $user =~ ^[a-z][a-z0-9_-]{2,30}$ && $user != root && -f $keyfile && ! -L $keyfile ]] || rw_die 'ssh prepare requires --admin-user USER and --public-key FILE.'
    [[ $(wc -l < "$keyfile") == 1 ]] || rw_die 'Provide exactly one public SSH key.'
    read -r keytype keydata _ < "$keyfile"
    [[ $keytype == ssh-ed25519 || $keytype == ssh-rsa || $keytype == ecdsa-sha2-nistp256 ]] || rw_die 'Unsupported SSH key type.'
    [[ $keydata =~ ^[A-Za-z0-9+/=]+$ ]] || rw_die 'Invalid public SSH key.'
    ssh-keygen -l -f "$keyfile" >/dev/null || rw_die 'SSH key validation failed.'
    fingerprint=$(printf '%s %s' "$keytype" "$keydata" | sha256sum | cut -d' ' -f1)
    marker=/var/lib/pdm-remnawave-ssh/$user.json
    rw_safe_parents "$marker"
    if id "$user" >/dev/null 2>&1; then
        [[ -f $marker && ! -L $marker ]] && jq -e --arg owner "$RW_OWNER" '.owner==$owner' "$marker" >/dev/null || rw_die 'The SSH account already exists and is not owned by this installation.'
    else
        useradd --create-home --shell /bin/bash "$user"
        jq -n --arg owner "$RW_OWNER" --arg user "$user" '{owner:$owner,user:$user}' | rw_atomic "$marker"
    fi
    if ! command -v sudo >/dev/null 2>&1; then apt-get install -y --no-install-recommends sudo; fi
    home=$(getent passwd "$user" | cut -d: -f6)
    [[ $home == /home/$user ]] || rw_die 'Unexpected administrator home directory.'
    rw_safe_parents "$home/.ssh/authorized_keys"
    [[ ! -L $home/.ssh/authorized_keys ]] || rw_die 'authorized_keys is a symbolic link.'
    install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"; chown "$user:$user" "$home/.ssh/authorized_keys"
    # Add the new key while keeping existing keys until a fresh login proves it works.
    if ! grep -qF "$keytype $keydata " "$home/.ssh/authorized_keys"; then printf '%s %s %s:%s\n' "$keytype" "$keydata" "$RW_PROJECT" "${fingerprint:0:12}" >> "$home/.ssh/authorized_keys"; fi
    sudoers=/etc/sudoers.d/$RW_PROJECT-$user
    if [[ -e $sudoers ]]; then [[ ! -L $sudoers ]] && grep -qF "$RW_OWNER" "$sudoers" || rw_die 'The sudoers file belongs to another installation.'; fi
    printf '# %s\n%s ALL=(ALL) NOPASSWD: ALL\n' "$RW_OWNER" "$user" > "$RW_TMP/sudoers"
    visudo -cf "$RW_TMP/sudoers" >/dev/null || rw_die 'sudoers validation failed.'
    install -m 440 "$RW_TMP/sudoers" "$sudoers"
    if [[ -f $RW_OUT/private/ssh-state.json ]] && jq -e --arg user "$user" --arg fp "$fingerprint" '.status=="confirmed" and .user==$user and .public_key_fingerprint==$fp' "$RW_OUT/private/ssh-state.json" >/dev/null; then
        local dropin
        dropin=$(rw_ssh_dropin)
        if [[ -f $dropin && ! -L $dropin && $(sha256sum "$dropin" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]]; then
            rw_info 'A verified SSH administrator is already configured.'; return
        fi
    fi
    nonce=$(openssl rand -hex 32)
    jq -n --arg user "$user" --arg nonce "$nonce" --arg fp "$fingerprint" '{status:"prepared",user:$user,nonce:$nonce,public_key_fingerprint:$fp}' | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh={status:"prepared",user:$user}' --arg user "$user"
    rw_track_files
    rw_info "Administrator $user prepared. Run ssh harden --ssh USER@HOST from the operator host using this key and verified known_hosts."
}
rw_ssh_session() {
    rw_root; rw_owned
    [[ -f $RW_OUT/private/ssh-state.json && ${SUDO_USER:-} == $(jq -r '.user' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'Verification requires sudo from the new SSH administrator.'
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
    [[ ${RW_SSH_NONCE:-} == "$nonce" && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == prepared ]] || rw_die 'Unconfirmed SSH operation.'
    rw_safe_parents "$file"
    if [[ -e $file ]]; then
        [[ ! -L $file ]] && grep -qF "$RW_OWNER" "$file" || rw_die 'The SSH drop-in belongs to another installation.'
        cat "$file" | rw_atomic "$RW_OUT/private/ssh-before.conf"; previous=true
    fi
    # Keep pre-existing restricted machine keys working; ordinary root login is disabled.
    printf '# %s\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin forced-commands-only\n' "$RW_OWNER" > "$RW_TMP/ssh-dropin"
    install -m 644 "$RW_TMP/ssh-dropin" "$file"
    if ! /usr/sbin/sshd -t; then
        if [[ $previous == true ]]; then cat "$RW_OUT/private/ssh-before.conf" > "$file"; else rm -f -- "$file"; fi
        rw_die 'SSH configuration validation failed; the original file was restored.'
    fi
    jq --argjson previous "$previous" --arg hash "$(sha256sum "$file" | cut -d' ' -f1)" '.status="armed"|.previous_dropin=$previous|.applied_sha256=$hash' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_track_files
    systemd-run --quiet --unit "$RW_PROJECT-ssh-revert" --on-active=60s --timer-property=AccuracySec=1s /bin/bash "$RW_OUT/rwctl" ssh revert --nonce "$nonce" || { rw_ssh_revert; rw_die 'The SSH rollback timer did not start.'; }
    systemctl reload ssh.service || { rw_ssh_revert; rw_die 'SSH reload failed.'; }
    rw_info 'SSH changed. Verify a fresh administrator login; otherwise settings roll back in 60 seconds.'
}
rw_ssh_revert() {
    rw_root; rw_owned
    local file nonce
    file=$(rw_ssh_dropin); nonce=$(jq -r '.nonce' "$RW_OUT/private/ssh-state.json")
    [[ ${RW_SSH_NONCE:-} == "$nonce" && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == armed ]] || return 0
    [[ -f $file && ! -L $file && $(sha256sum "$file" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'The SSH drop-in changed externally; rollback will not overwrite unrelated changes.'
    if [[ $(jq -r '.previous_dropin' "$RW_OUT/private/ssh-state.json") == true ]]; then cat "$RW_OUT/private/ssh-before.conf" > "$file"; else rm -f -- "$file"; fi
    /usr/sbin/sshd -t && systemctl reload ssh.service || rw_die 'Cannot restore SSH settings.'
    jq '.status="reverted"' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh.status="reverted"'; rw_track_files
}
rw_ssh_confirm() {
    rw_ssh_session; rw_lock
    [[ ${RW_SSH_NONCE:-} == $(jq -r '.nonce' "$RW_OUT/private/ssh-state.json") && $(jq -r '.status' "$RW_OUT/private/ssh-state.json") == armed ]] || rw_die 'No SSH operation is awaiting confirmation.'
    local file
    file=$(rw_ssh_dropin)
    [[ -f $file && ! -L $file && $(sha256sum "$file" | cut -d' ' -f1) == $(jq -r '.applied_sha256' "$RW_OUT/private/ssh-state.json") ]] || rw_die 'The SSH drop-in changed before confirmation.'
    /usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 > "$RW_TMP/ssh-effective"
    grep -qx 'permitrootlogin forced-commands-only' "$RW_TMP/ssh-effective" && grep -qx 'passwordauthentication no' "$RW_TMP/ssh-effective" && grep -qx 'kbdinteractiveauthentication no' "$RW_TMP/ssh-effective" || rw_die 'The effective SSH policy does not match the expected settings.'
    systemctl stop "$RW_PROJECT-ssh-revert.timer"
    jq '.status="confirmed"' "$RW_OUT/private/ssh-state.json" | rw_atomic "$RW_OUT/private/ssh-state.json"
    rw_manifest_set '.ssh.status="confirmed"'; rw_track_files
    rw_info 'Fresh SSH login verified; ordinary root login and password authentication disabled.'
}
rw_ssh_harden() {
    local host=${RW_SSH:-} nonce state remote=$RW_OUT
    [[ $host =~ ^[A-Za-z0-9_.@:-]+$ && $host != -* ]] || rw_die 'ssh harden requires --ssh USER@HOST.'
    local -a options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh status" > "$RW_TMP/ssh-status.json"
    jq -e --arg owner "$RW_OWNER" '.owner==$owner and (.nonce|test("^[a-f0-9]{64}$"))' "$RW_TMP/ssh-status.json" >/dev/null || rw_die 'The SSH host does not match this installation.'
    state=$(jq -r '.status' "$RW_TMP/ssh-status.json")
    if [[ $state == confirmed ]]; then rw_info 'The new SSH login is already verified.'; return; fi
    [[ $state == prepared ]] || rw_die 'Run ssh prepare on the server first.'
    nonce=$(jq -r '.nonce' "$RW_TMP/ssh-status.json")
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh commit --nonce '$nonce'"
    ssh "${options[@]}" "$host" "sudo -n bash '$remote/rwctl' ssh confirm --nonce '$nonce'" || rw_die 'Fresh SSH login failed; the timer will restore the previous settings.'
}
# shellcheck shell=bash
rw_interactive() {
    local role=${RW_ROLE_ARG:-} env default_name mode panel='' sub='' node='' ips sources='[]' user='' email='' file='' container='' health='' profile=standard purpose
    if [[ -z $role ]]; then
        printf '\nRemnawave: 1) panel  2) standalone node  3) panel and node\n' >&2
        read -r -p 'Role [3]: ' role; case ${role:-3} in 1) role=panel;; 2) role=node;; 3) role='panel-node';; *) rw_die 'Invalid role selection.';; esac
    fi
    case $role in node) default_name='node-main';; panel) default_name='panel-main';; panel-node) default_name='vpn-main';; *) rw_die 'Invalid role.';; esac
    read -r -p "Installation name [$default_name]: " env; env=${env:-$default_name}
    rw_info 'Layout: 1) standard installation  2) parallel test beside an existing stack'
    read -r -p 'Layout [1]: ' mode
    case ${mode:-1} in 1|clean|standard) mode=clean;; 2|parallel|fi-parallel) mode=fi-parallel;; *) rw_die 'Invalid installation layout.';; esac
    [[ $mode != fi-parallel || $role == panel-node ]] || rw_die 'Parallel test layout requires panel and node.'
    if [[ $role != node ]]; then
        read -r -p 'Panel domain: ' panel
        read -r -p "Subscription domain [$panel]: " sub; sub=${sub:-$panel}
        read -r -p 'Administrator username: ' user; read -r -p 'Administrator email: ' email
    fi
    if [[ $role != panel ]]; then
        read -r -p "Node and cover domain${panel:+ [$panel]}: " node; node=${node:-$panel}
    fi
    local -a domains=()
    [[ -z $panel ]] || domains+=("$panel")
    [[ -z $sub || $sub == "$panel" ]] || domains+=("$sub")
    [[ -z $node || $node == "$panel" || $node == "$sub" ]] || domains+=("$node")
    ips=$(rw_choose_public_addresses "${domains[@]}")
    [[ $role != node ]] || sources=$(rw_choose_panel_addresses)
    if [[ $mode == fi-parallel ]]; then
        read -r -p 'Existing Caddyfile path: ' file
        read -r -p 'Existing Caddy container [caddy]: ' container; container=${container:-caddy}
        read -r -p 'Existing site HTTPS health URL: ' health
        read -r -p 'Resource profile standard / compact-test [compact-test]: ' profile; profile=${profile:-compact-test}
        purpose='test'
    else
        rw_info 'Purpose: production uses normal resource requirements; test permits a compact validation stack.'
        read -r -p 'Purpose test / production [production]: ' purpose; purpose=${purpose:-production}
        if [[ $purpose == test ]]; then read -r -p 'Resource profile standard / compact-test [standard]: ' profile; profile=${profile:-standard}; fi
    fi
    RW_ROOT_PUBLIC_KEY=
    rw_security_key_input
    jq -n --arg role "$role" --arg env "$env" --arg mode "$mode" --arg panel "$panel" --arg sub "$sub" --arg node "$node" --argjson ips "$ips" --argjson sources "$sources" --arg user "$user" --arg email "$email" \
      --arg file "$file" --arg container "$container" --arg health "$health" --arg profile "$profile" --arg purpose "$purpose" --arg rootkey "$RW_ROOT_PUBLIC_KEY" \
      '{schema_version:1,environment_id:$env,role:$role,network_mode:$mode,domains:({panel:$panel,subscription:$sub,node:$node}|with_entries(select(.value!=""))),public_addresses:$ips,panel_addresses:$sources,admin:{username:$user,email:$email},resources:{profile:$profile,purpose:$purpose},security:{enabled:true}} | if $rootkey!="" then .security.root_public_key=$rootkey else . end | if $mode=="fi-parallel" then .existing_caddy={config_file:$file,container:$container,health_url:$health} else . end' > "$RW_TMP/interactive.json"
    RW_CONFIG=$RW_TMP/interactive.json
}
rw_help() {
    cat <<'RW_HELP'
Remnawave - Linux/Bash/Docker Compose. UFW is installed from Debian APT.
Installation:
  rw-setup.sh [--role panel|node|panel-node] [--config FILE] [--output DIR] [--versions FILE]
  rw-setup.sh --config FILE --dry-run
Maintenance:
  rwctl info [--show-secrets]
  rwctl security apply|confirm|revert|status
  rwctl plan|preflight|apply|doctor|backup --config FILE --output DIR
  rwctl restore --archive FILE [--config FILE] [--output DIR] [--dry-run]
  rwctl upgrade [--component all|panel|node|caddy|subscription] [--versions FILE] [--archive BACKUP_FILE] [--dry-run]
  rwctl rollback --archive FILE [--dry-run]
  rwctl ssh prepare --admin-user USER --public-key FILE --output DIR
  rwctl ssh harden --config FILE --output SERVER_DIR --ssh USER@HOST
  rwctl tls-test [--test-http-port 18082] [--test-https-port 19447] [--dry-run]
  rwctl stats install [--stats-port 13100] [--archive BACKUP_FILE] [--dry-run]
  rwctl stats status
  rwctl tokens status
  rwctl tokens rotate [--token all|subscription|installer] [--dry-run]
  rwctl mfa status|guide
  rwctl site set [--template confluence|simple | --site-file HTML_FILE]
  rwctl node attach --config PANEL_FILE --output PANEL_DIR --ssh USER@HOST --node-config NODE_FILE
Removal:
  uninstall.sh --output DIR [--dry-run] [--purge] [--yes]
  uninstall.sh --output DIR --prepared-only [--yes]
--connection-file FILE attaches a standalone node using the native panel SECRET_KEY.
--archive FILE selects the private backup archive; keep a copy off the VPS.
Supported server: Debian 13 amd64. Installation requires root.
RW_HELP
}
rw_plan() {
    jq '{environment_id,role,network_mode,ports,docker_subnet,operations:["install required APT packages and Docker","docker compose pull/up","create administrator via API","issue scoped subscription token","register Xray profile/node/hosts/squads","source-restricted persistent firewall","start Caddy and transports"]}' "$RW_CFG"
}
rw_main() {
    local entry=$1 command
    shift; rw_linux
    RW_CONFIG=; RW_OUT=; RW_CONNECTION=; RW_DRY_RUN=0; RW_YES=0; RW_PURGE=0; RW_PREPARED_ONLY=0; RW_ROLE_ARG=; RW_ARCHIVE=; RW_SSH=; RW_NODE_CONFIG=; RW_VERSION_FILE=; RW_SSH_ADMIN=; RW_SSH_PUBLIC_KEY=; RW_SSH_NONCE=; RW_TLS_HTTP=; RW_TLS_HTTPS=; RW_STATS_PORT=; RW_STATS_SOURCE_MANIFEST=; RW_TOKEN_PURPOSE=all; RW_COMPONENT=all; RW_SITE_TEMPLATE=; RW_SITE_FILE=; RW_SHOW_SECRETS=0
    if [[ $entry == ctl ]]; then
        command=${1:-help}; (( $#==0 )) || shift
        [[ $command != --help && $command != -h ]] || command=help
        local beside; beside=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        [[ ! -f $beside/config.json || ! -f $beside/manifest.json ]] || RW_OUT=$beside
    else command=$entry; fi
    if [[ $command == node ]]; then
        case ${1:-} in attach) command='node-attach';; receive) command='node-receive';; *) rw_die 'Use node attach or node receive.';; esac
        shift
    fi
    if [[ $command == ssh ]]; then
        case ${1:-} in prepare|harden|status|commit|confirm|revert) command=ssh-$1;; *) rw_die 'ssh: prepare or harden.';; esac
        shift
    fi
    if [[ $command == stats ]]; then
        case ${1:-} in install|status) command=stats-$1;; *) rw_die 'stats: install or status.';; esac
        shift
    fi
    if [[ $command == tokens ]]; then
        case ${1:-} in status|rotate) command=tokens-$1;; *) rw_die 'tokens: status or rotate.';; esac
        shift
    fi
    if [[ $command == mfa ]]; then
        case ${1:-} in status|guide) command=mfa-$1;; *) rw_die 'mfa: status or guide.';; esac
        shift
    fi
    if [[ $command == site ]]; then
        [[ ${1:-} == set ]] || rw_die 'site: use set.'
        command='site-set'; shift
    fi
    if [[ $command == security ]]; then
        case ${1:-} in apply|confirm|revert|status) command=security-$1;; *) rw_die 'security: apply, confirm, revert or status.';; esac
        shift
    fi
    while (( $# )); do
        case $1 in
          --help|-h) rw_help; return;;
          --config) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_CONFIG=$2; shift;;
          --output) [[ $# -ge 2 ]] || rw_die 'DIR is required.'; RW_OUT=$2; shift;;
          --role) [[ $# -ge 2 ]] || rw_die 'A role is required.'; RW_ROLE_ARG=$2; shift;;
          --connection-file) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_CONNECTION=$2; shift;;
          --archive) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_ARCHIVE=$2; shift;;
          --versions) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_VERSION_FILE=$2; shift;;
          --component) [[ $# -ge 2 ]] || rw_die 'A component is required.'; RW_COMPONENT=$2; shift;;
          --template) [[ $# -ge 2 ]] || rw_die 'A template is required.'; RW_SITE_TEMPLATE=$2; shift;;
          --site-file) [[ $# -ge 2 ]] || rw_die 'HTML_FILE is required.'; RW_SITE_FILE=$2; shift;;
          --admin-user) [[ $# -ge 2 ]] || rw_die 'USER is required.'; RW_SSH_ADMIN=$2; shift;;
          --public-key) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_SSH_PUBLIC_KEY=$2; shift;;
          --nonce) [[ $# -ge 2 ]] || rw_die 'A nonce is required.'; RW_SSH_NONCE=$2; shift;;
          --test-http-port) [[ $# -ge 2 ]] || rw_die 'PORT is required.'; RW_TLS_HTTP=$2; shift;;
          --test-https-port) [[ $# -ge 2 ]] || rw_die 'PORT is required.'; RW_TLS_HTTPS=$2; shift;;
          --stats-port) [[ $# -ge 2 ]] || rw_die 'PORT is required.'; RW_STATS_PORT=$2; shift;;
          --token) [[ $# -ge 2 ]] || rw_die 'A token purpose is required.'; RW_TOKEN_PURPOSE=$2; shift;;
          --ssh) [[ $# -ge 2 ]] || rw_die 'HOST is required.'; RW_SSH=$2; shift;;
          --node-config) [[ $# -ge 2 ]] || rw_die 'FILE is required.'; RW_NODE_CONFIG=$2; shift;;
          --dry-run) RW_DRY_RUN=1;; --yes) RW_YES=1;; --purge) RW_PURGE=1;; --prepared-only) RW_PREPARED_ONLY=1;;
          --show-secrets) RW_SHOW_SECRETS=1;;
          *) rw_die "Unknown option: $1.";;
        esac; shift
    done
    [[ $command != help ]] || { rw_help; return; }
    [[ $RW_SHOW_SECRETS == 0 || $command == info ]] || rw_die '--show-secrets is supported by info only.'
    [[ $RW_DRY_RUN == 0 || ( $command != security-confirm && $command != security-revert ) ]] || rw_die 'Use security apply --dry-run to preview host security changes.'
    rw_init_tmp
    if [[ ( $command == setup || $command == restore ) && $RW_DRY_RUN == 0 ]]; then rw_root; rw_os; rw_deps; else rw_need jq; fi
    if [[ $command == restore ]]; then rw_restore; return; fi
    if [[ -z $RW_CONFIG && -n $RW_OUT && -f $RW_OUT/config.json ]]; then RW_CONFIG=$RW_OUT/config.json; fi
    if [[ -z $RW_CONFIG ]]; then
        if [[ $command == setup ]]; then rw_interactive
        elif [[ $command == uninstall ]]; then
            local -a roots=(); local choice path
            while IFS= read -r path; do roots+=("$path"); done < <(find /opt/pdm-remnawave -mindepth 2 -maxdepth 2 -name manifest.json -printf '%h\n' 2>/dev/null)
            (( ${#roots[@]} > 0 )) || rw_die 'No installations found. Specify --output DIR.'
            printf '%s\n' "${roots[@]}" >&2; read -r -p 'Installation number [1]: ' choice; choice=${choice:-1}
            [[ $choice =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#roots[@]} )) || rw_die 'Invalid selection.'
            RW_OUT=${roots[choice-1]}; RW_CONFIG=$RW_OUT/config.json
        else rw_die 'Specify --config FILE or --output DIR for an existing installation.'; fi
    fi
    rw_config_load "$RW_CONFIG"
    [[ -z $RW_ROLE_ARG || $RW_ROLE_ARG == "$RW_ROLE" ]] || rw_die 'The role does not match the configuration.'
    case $command in
      plan) rw_plan;;
      setup|apply) if (( RW_DRY_RUN )); then rw_plan; else [[ $command == setup ]] || rw_deps; rw_apply; rw_track_files; fi;;
      preflight) rw_preflight;;
      doctor) rw_doctor;;
      info) rw_show_summary;;
      security-apply) rw_security_configure;;
      security-confirm) rw_security_confirm; rw_install_summary; rw_track_files;;
      security-revert) rw_security_revert;;
      security-status) rw_security_status;;
      backup) rw_backup;;
      upgrade) rw_upgrade;;
      rollback) rw_rollback;;
      node-attach) rw_node_attach; rw_track_files;;
      node-receive) rw_node_receive;;
      ssh-prepare) rw_ssh_prepare;;
      ssh-harden) rw_ssh_harden;;
      ssh-status) rw_ssh_status;;
      ssh-commit) rw_ssh_commit;;
      ssh-confirm) rw_ssh_confirm;;
      ssh-revert) rw_ssh_revert;;
      tls-test) rw_tls_test;;
      stats-install) rw_stats_install;;
      stats-status) rw_stats_status;;
      tokens-status) rw_owned; rw_tokens_status;;
      tokens-rotate) rw_tokens_rotate;;
      mfa-status) rw_mfa_status;;
      mfa-guide) rw_mfa_guide;;
      site-set) rw_site_set;;
      uninstall) rw_uninstall;;
      *) rw_die "Unknown command: $command.";;
    esac
}

rw_main uninstall "$@"
