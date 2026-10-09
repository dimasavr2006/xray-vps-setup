# shellcheck shell=bash
rw_interactive() {
    local role=${RW_ROLE_ARG:-} env mode panel='' sub='' node='' ips sources='' user='' email=''
    if [[ -z $role ]]; then
        printf '\nRemnawave: 1) панель  2) отдельная нода  3) панель и нода\n' >&2
        read -r -p 'Режим [3]: ' role; case ${role:-3} in 1) role=panel;; 2) role=node;; 3) role='panel-node';; *) rw_die 'Неверный режим.';; esac
    fi
    read -r -p 'ID окружения (например fi-test): ' env
    read -r -p 'Режим сети clean / fi-parallel [clean]: ' mode; mode=${mode:-clean}
    if [[ $role != node ]]; then
        read -r -p 'Домен панели: ' panel
        read -r -p "Домен подписок [$panel]: " sub; sub=${sub:-$panel}
        read -r -p 'Логин администратора: ' user; read -r -p 'Email администратора: ' email
    fi
    if [[ $role != panel ]]; then
        read -r -p "Домен ноды${panel:+ [$panel]}: " node; node=${node:-$panel}
    fi
    read -r -p 'Публичные IPv4/IPv6 через запятую: ' ips
    [[ $role != node ]] || read -r -p 'IP панели для управления через запятую: ' sources
    jq -n --arg role "$role" --arg env "$env" --arg mode "$mode" --arg panel "$panel" --arg sub "$sub" --arg node "$node" --arg ips "$ips" --arg sources "$sources" --arg user "$user" --arg email "$email" \
      '{schema_version:1,environment_id:$env,role:$role,network_mode:$mode,domains:({panel:$panel,subscription:$sub,node:$node}|with_entries(select(.value!=""))),public_addresses:($ips|split(",")|map(gsub("^ +| +$";""))),panel_addresses:($sources|split(",")|map(select(length>0)|gsub("^ +| +$";""))),admin:{username:$user,email:$email}}' > "$RW_TMP/interactive.json"
    RW_CONFIG=$RW_TMP/interactive.json
    if [[ $mode == fi-parallel ]]; then rw_die 'Для параллельного FI нужен config файл с existing_caddy; используйте пример installer/examples/fi-parallel.json.'; fi
}
rw_help() {
    cat <<'RW_HELP'
Remnawave — Linux/Bash/Docker Compose. На VPS Python не нужен.
Установка:
  rw-setup.sh [--role panel|node|panel-node] [--config FILE] [--output DIR] [--versions FILE]
  rw-setup.sh --config FILE --dry-run
Обслуживание:
  rwctl plan|preflight|apply|doctor|backup --config FILE --output DIR
  rwctl restore --archive FILE [--config FILE] [--output DIR] [--dry-run]
  rwctl upgrade [--versions FILE] [--archive BACKUP_FILE] [--dry-run]
  rwctl rollback --archive FILE [--dry-run]
  rwctl ssh prepare --admin-user USER --public-key FILE --output DIR
  rwctl ssh harden --config FILE --output SERVER_DIR --ssh USER@HOST
  rwctl tls-test [--test-http-port 18082] [--test-https-port 19447] [--dry-run]
  rwctl stats install [--stats-port 13100] [--archive BACKUP_FILE] [--dry-run]
  rwctl stats status
  rwctl node attach --config PANEL_FILE --output PANEL_DIR --ssh USER@HOST --node-config NODE_FILE
Удаление:
  uninstall.sh --output DIR [--dry-run] [--purge] [--yes]
  uninstall.sh --output DIR --prepared-only [--yes]
--connection-file FILE подключает отдельную ноду штатным SECRET_KEY панели.
--archive FILE задаёт выходной архив backup (данные закрыты; хранить вне VPS).
Первый поддерживаемый сервер: Debian 13 amd64. Установка требует root.
RW_HELP
}
rw_plan() {
    jq '{environment_id,role,network_mode,ports,docker_subnet,operations:["install required APT packages and Docker","docker compose pull/up","create administrator via API","issue scoped subscription token","register Xray profile/node/hosts/squads","source-restricted persistent firewall","start Caddy and transports"]}' "$RW_CFG"
}
rw_main() {
    local entry=$1 command
    shift; rw_linux
    RW_CONFIG=; RW_OUT=; RW_CONNECTION=; RW_DRY_RUN=0; RW_YES=0; RW_PURGE=0; RW_PREPARED_ONLY=0; RW_ROLE_ARG=; RW_ARCHIVE=; RW_SSH=; RW_NODE_CONFIG=; RW_VERSION_FILE=; RW_SSH_ADMIN=; RW_SSH_PUBLIC_KEY=; RW_SSH_NONCE=; RW_TLS_HTTP=; RW_TLS_HTTPS=; RW_STATS_PORT=; RW_STATS_SOURCE_MANIFEST=
    if [[ $entry == ctl ]]; then
        command=${1:-help}; (( $#==0 )) || shift
        [[ $command != --help && $command != -h ]] || command=help
        local beside; beside=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        [[ ! -f $beside/config.json || ! -f $beside/manifest.json ]] || RW_OUT=$beside
    else command=$entry; fi
    if [[ $command == node ]]; then
        case ${1:-} in attach) command='node-attach';; receive) command='node-receive';; *) rw_die 'Поддерживается node attach.';; esac
        shift
    fi
    if [[ $command == ssh ]]; then
        case ${1:-} in prepare|harden|status|commit|confirm|revert) command=ssh-$1;; *) rw_die 'ssh: prepare или harden.';; esac
        shift
    fi
    if [[ $command == stats ]]; then
        case ${1:-} in install|status) command=stats-$1;; *) rw_die 'stats: install или status.';; esac
        shift
    fi
    while (( $# )); do
        case $1 in
          --help|-h) rw_help; return;;
          --config) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_CONFIG=$2; shift;;
          --output) [[ $# -ge 2 ]] || rw_die 'Нужен DIR.'; RW_OUT=$2; shift;;
          --role) [[ $# -ge 2 ]] || rw_die 'Нужна роль.'; RW_ROLE_ARG=$2; shift;;
          --connection-file) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_CONNECTION=$2; shift;;
          --archive) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_ARCHIVE=$2; shift;;
          --versions) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_VERSION_FILE=$2; shift;;
          --admin-user) [[ $# -ge 2 ]] || rw_die 'Нужен USER.'; RW_SSH_ADMIN=$2; shift;;
          --public-key) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_SSH_PUBLIC_KEY=$2; shift;;
          --nonce) [[ $# -ge 2 ]] || rw_die 'Нужен nonce.'; RW_SSH_NONCE=$2; shift;;
          --test-http-port) [[ $# -ge 2 ]] || rw_die 'Нужен PORT.'; RW_TLS_HTTP=$2; shift;;
          --test-https-port) [[ $# -ge 2 ]] || rw_die 'Нужен PORT.'; RW_TLS_HTTPS=$2; shift;;
          --stats-port) [[ $# -ge 2 ]] || rw_die 'Нужен PORT.'; RW_STATS_PORT=$2; shift;;
          --ssh) [[ $# -ge 2 ]] || rw_die 'Нужен HOST.'; RW_SSH=$2; shift;;
          --node-config) [[ $# -ge 2 ]] || rw_die 'Нужен FILE.'; RW_NODE_CONFIG=$2; shift;;
          --dry-run) RW_DRY_RUN=1;; --yes) RW_YES=1;; --purge) RW_PURGE=1;; --prepared-only) RW_PREPARED_ONLY=1;;
          *) rw_die "Неизвестный параметр $1.";;
        esac; shift
    done
    [[ $command != help ]] || { rw_help; return; }
    rw_init_tmp
    if [[ ( $command == setup || $command == restore ) && $RW_DRY_RUN == 0 ]]; then rw_root; rw_os; rw_deps; else rw_need jq; fi
    if [[ $command == restore ]]; then rw_restore; return; fi
    if [[ -z $RW_CONFIG && -n $RW_OUT && -f $RW_OUT/config.json ]]; then RW_CONFIG=$RW_OUT/config.json; fi
    if [[ -z $RW_CONFIG ]]; then
        if [[ $command == setup ]]; then rw_interactive
        elif [[ $command == uninstall ]]; then
            local -a roots=(); local choice path
            while IFS= read -r path; do roots+=("$path"); done < <(find /opt/pdm-remnawave -mindepth 2 -maxdepth 2 -name manifest.json -printf '%h\n' 2>/dev/null)
            (( ${#roots[@]} > 0 )) || rw_die 'Нет установок. Укажите --output DIR.'
            printf '%s\n' "${roots[@]}" >&2; read -r -p 'Номер установки [1]: ' choice; choice=${choice:-1}
            [[ $choice =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#roots[@]} )) || rw_die 'Неверный выбор.'
            RW_OUT=${roots[choice-1]}; RW_CONFIG=$RW_OUT/config.json
        else rw_die 'Укажите --config FILE или --output DIR установленной системы.'; fi
    fi
    rw_config_load "$RW_CONFIG"
    [[ -z $RW_ROLE_ARG || $RW_ROLE_ARG == "$RW_ROLE" ]] || rw_die 'Роль не совпадает с config.'
    case $command in
      plan) rw_plan;;
      setup|apply) if (( RW_DRY_RUN )); then rw_plan; else rw_deps; rw_apply; rw_track_files; fi;;
      preflight) rw_preflight;;
      doctor) rw_doctor;;
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
      uninstall) rw_uninstall;;
      *) rw_die "Неизвестная команда $command.";;
    esac
}
