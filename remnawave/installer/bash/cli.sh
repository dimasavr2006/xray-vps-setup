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
      setup|apply) if (( RW_DRY_RUN )); then rw_plan; else rw_deps; rw_apply; rw_track_files; fi;;
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
