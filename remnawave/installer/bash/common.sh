# shellcheck shell=bash
rw_die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
rw_info() { printf '%s\n' "$*" >&2; }
rw_linux() { [[ $(uname -s) == Linux ]] || rw_die 'Установщик предназначен только для Linux.'; }
rw_root() { (( EUID == 0 )) || rw_die 'Для установки/удаления запустите скрипт от root.'; }
rw_need() { command -v "$1" >/dev/null 2>&1 || rw_die "Нужна команда $1."; }
rw_safe_parents() {
    local parent
    parent=$(dirname -- "$1")
    while [[ $parent != / && $parent != . ]]; do
        [[ ! -L $parent ]] || rw_die 'Символьная ссылка в родительском каталоге.'
        parent=$(dirname -- "$parent")
    done
}
rw_atomic() {
    local target=$1 temp
    rw_safe_parents "$target"
    [[ ! -L $target ]] || rw_die 'Символьная ссылка вместо управляемого файла.'
    mkdir -p -- "$(dirname -- "$target")"
    temp=$(mktemp "${target}.tmp.XXXXXX")
    cat > "$temp"; chmod 600 "$temp"; mv -f -- "$temp" "$target"
    if [[ -n ${RW_OUT:-} && $target == "$RW_OUT/"* && $target != "$RW_OUT/manifest.json" ]]; then
        mkdir -p "$RW_OUT/private"
        printf '%s\n' "${target#"$RW_OUT/"}" >> "$RW_OUT/private/.managed-paths"
        chmod 600 "$RW_OUT/private/.managed-paths"
    fi
}
rw_jwrite() { local target=$1; shift; jq "$@" | rw_atomic "$target"; }
rw_lock() {
    [[ ${RW_LOCK_DIR:-} != "$RW_OUT" ]] || return 0
    rw_safe_parents "$RW_OUT/private/.lock-check"
    mkdir -p -- "$RW_OUT/private"
    chmod 700 "$RW_OUT" "$RW_OUT/private"
    exec 9>"$RW_OUT/.rw.lock"
    flock -n 9 || rw_die 'Другая операция с этой установкой уже выполняется.'
    RW_LOCK_DIR=$RW_OUT
}
rw_cleanup() {
    if [[ ${RW_TLS_PROXY_PENDING:-0} == 1 ]]; then rw_tls_restore_proxy || true; fi
    if [[ -n ${RW_TLS_CONTAINER:-} ]]; then rw_tls_cleanup || true; fi
    if [[ ${RW_UPGRADE_PENDING:-0} == 1 ]]; then rw_upgrade_abort || true; fi
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
    RW_TMP=$(mktemp -d /tmp/pdm-rw.XXXXXX)
    trap rw_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
}
rw_deps() {
    local missing=0 cmd
    for cmd in curl jq openssl dig ss nft flock; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
    if (( missing )); then
        rw_root
        rw_info 'Установка зависимостей: curl jq openssl dnsutils iproute2 nftables util-linux ca-certificates.'
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl jq openssl dnsutils iproute2 nftables util-linux ca-certificates
    fi
}
rw_os() {
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 && $(uname -m) == x86_64 ]] || rw_die 'Первый поддерживаемый VPS: Debian 13 amd64.'
}
rw_docker_install() {
    if ! command -v docker >/dev/null 2>&1; then
        rw_info 'Установка Docker Engine и Compose из официального APT-репозитория Docker.'
        apt-get install -y --no-install-recommends ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsS --proto '=https' --tlsv1.2 https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' 'Components: stable' 'Architectures: amd64' 'Signed-By: /etc/apt/keyrings/docker.asc' > /etc/apt/sources.list.d/docker.sources
        apt-get update -q
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker.service
    fi
    docker info >/dev/null 2>&1 || rw_die 'Docker недоступен; существующий daemon не переустанавливается.'
    local version major minor
    version=$(docker compose version --short); version=${version#v}; IFS=. read -r major minor _ <<< "$version"
    (( major > 2 || (major == 2 && minor >= 30) )) || rw_die 'Нужен Docker Compose 2.30+.'
}
rw_config_load() {
    local file=$1
    rw_config_filter > "$RW_TMP/config.jq"
    jq -ef "$RW_TMP/config.jq" "$file" > "$RW_TMP/config.json" 2>"$RW_TMP/config-error" || rw_die 'Некорректный config JSON. Проверьте поля и примеры в installer/examples.'
    RW_CFG=$RW_TMP/config.json
    RW_ENV=$(jq -r '.environment_id' "$RW_CFG"); RW_ROLE=$(jq -r '.role' "$RW_CFG"); RW_MODE=$(jq -r '.network_mode' "$RW_CFG")
    RW_OUT=$(realpath -m -- "${RW_OUT:-/opt/pdm-remnawave/$RW_ENV}")
    [[ $RW_OUT =~ ^/[A-Za-z0-9_./-]+$ ]] || rw_die 'Каталог установки: абсолютный путь без пробелов и управляющих символов.'
    [[ $RW_OUT != / && $RW_OUT != /opt && $RW_OUT != /etc && $RW_OUT != /tmp && $RW_OUT != /root && $RW_OUT != /home ]] || rw_die 'Укажите отдельный каталог установки.'
    local parent=$RW_OUT
    while [[ $parent != / ]]; do [[ ! -L $parent ]] || rw_die 'Каталог установки содержит symlink.'; parent=$(dirname -- "$parent"); done
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
rw_manifest_set() { local filter=$1; shift; jq "$@" "$filter" "$RW_OUT/manifest.json" | rw_atomic "$RW_OUT/manifest.json"; }
rw_manifest() {
    local status=$1
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" --arg project "$RW_PROJECT" --arg owner "$RW_OWNER" --arg fp "$RW_FINGERPRINT" --arg status "$status" \
      '{schema_version:2,implementation:"bash-docker",environment_id:$e,role:$role,compose_project:$project,ownership_label:$owner,config_fingerprint:$fp,status:$status,api:{},managed_files:[]}' | rw_atomic "$RW_OUT/manifest.json"
}
rw_owned() {
    [[ -f $RW_OUT/manifest.json && ! -L $RW_OUT/manifest.json ]] || rw_die 'Нет manifest собственной установки.'
    jq -e --arg owner "$RW_OWNER" --arg e "$RW_ENV" --arg p "$RW_PROJECT" \
      '.schema_version==2 and .implementation=="bash-docker" and .environment_id==$e and .ownership_label==$owner and .compose_project==$p' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Конфликт владения установкой.'
}
rw_install_ctl() {
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set +x' 'set -euo pipefail' 'umask 077'
        local fn
        while IFS= read -r fn; do declare -f "$fn"; done < <(compgen -A function | LC_ALL=C sort | awk '/^rw_/')
        printf '%s\n' 'rw_main ctl "$@"'
    } | rw_atomic "$RW_OUT/rwctl"
    chmod 700 "$RW_OUT/rwctl"
}
