#!/usr/bin/env bash
# Generated from installer/bash by installer/build-entrypoints.sh.
set +x
set -euo pipefail
umask 077
rw_versions() {
cat <<'RW_VERSIONS'
{
  "schema_version": 1,
  "environment_id": null,
  "status": "runtime-verified-fi-parallel-test",
  "resolved_at": "2026-10-08T16:25:08.239404+03:00",
  "components": {
    "panel": {
      "image": "remnawave/backend@sha256:b16d724b90fd7c9fec2df04bd28938a671cafc62894105068e11550ee3449c56",
      "source_tag": "3.4.5",
      "platforms": [
        {
          "architecture": "arm64",
          "os": "linux"
        },
        {
          "architecture": "amd64",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    },
    "node": {
      "image": "remnawave/node@sha256:1f97485b4bc7e4944f1ae95cc57d176376813b0022e9567b705f384f1a2e909d",
      "source_tag": "3.4.2",
      "platforms": [
        {
          "architecture": "amd64",
          "os": "linux"
        },
        {
          "architecture": "arm64",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    },
    "postgres": {
      "image": "library/postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636",
      "source_tag": "18.4",
      "platforms": [
        {
          "architecture": "amd64",
          "os": "linux"
        },
        {
          "architecture": "arm",
          "os": "linux",
          "variant": "v5"
        },
        {
          "architecture": "arm",
          "os": "linux",
          "variant": "v7"
        },
        {
          "architecture": "arm64",
          "os": "linux",
          "variant": "v8"
        },
        {
          "architecture": "386",
          "os": "linux"
        },
        {
          "architecture": "ppc64le",
          "os": "linux"
        },
        {
          "architecture": "riscv64",
          "os": "linux"
        },
        {
          "architecture": "s390x",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    },
    "valkey": {
      "image": "valkey/valkey@sha256:48332870af354a799964c0012ae1194a0bf2bf894eb508f945810596dc2d8d11",
      "source_tag": "9-alpine",
      "platforms": [
        {
          "architecture": "amd64",
          "os": "linux"
        },
        {
          "architecture": "arm64",
          "os": "linux"
        },
        {
          "architecture": "arm",
          "os": "linux",
          "variant": "v7"
        },
        {
          "architecture": "ppc64le",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    },
    "caddy_auth": {
      "image": "remnawave/caddy-with-auth@sha256:2098e1331c3499781791582076491b38545e27140c5a28b5c476a08b9b5c5f6f",
      "source_tag": "latest",
      "platforms": [
        {
          "architecture": "amd64",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    },
    "subscription": {
      "image": "remnawave/subscription-page@sha256:04e8d479afb3598024e4018e9e15cd7fe879938250090a690ba39f1ee91b79ac",
      "source_tag": "latest",
      "platforms": [
        {
          "architecture": "amd64",
          "os": "linux"
        },
        {
          "architecture": "arm64",
          "os": "linux"
        }
      ],
      "runtime_verified": true
    }
  },
  "verified_scope": "Debian 13 amd64; FI compact parallel panel-node; 2026-10-09"
}
RW_VERSIONS
}
rw_auth_global() {
cat <<'RW_AUTH_GLOBAL'
	order authenticate before respond
	order authorize before respond
	security {
		local identity store localdb {
			realm local
			path /data/.local/caddy/users.json
		}
		authentication portal remnawaveportal {
			crypto default token lifetime {$AUTH_TOKEN_LIFETIME}
			enable identity store localdb
			cookie domain {$REMNAWAVE_PANEL_DOMAIN}
			ui {
				links {
					"Remnawave" "/dashboard/home" icon "las la-tachometer-alt"
					"My Identity" "/r/whoami" icon "las la-user"
					"API Keys" "/r/settings/apikeys" icon "las la-key"
					"MFA" "/r/settings/mfa" icon "lab la-keycdn"
				}
			}
			transform user {
				match origin local
				action add role authp/admin
				require mfa
			}
		}
		authorization policy panelpolicy {
			set auth url /r
			allow roles authp/admin
			with api key auth portal remnawaveportal realm local
			acl rule {
				comment "Accept"
				match role authp/admin
				allow stop log info
			}
			acl rule {
				comment "Deny"
				match any
				deny log warn
			}
		}
	}
RW_AUTH_GLOBAL
}
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
| require((keys - ["schema_version","environment_id","role","network_mode","domains","public_addresses","panel_addresses","management_address","ports","admin","resources","docker_subnet","acme","node_country","existing_caddy"]) == []; "unknown config field")
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
# shellcheck shell=bash
rw_secrets() {
    local file=$RW_OUT/private/secrets.json key
    if [[ -f $file ]]; then jq -e '.app_secret and .admin_password and .reality_private' "$file" >/dev/null || rw_die 'Файл секретов повреждён; новые ключи не создаются.'; return; fi
    if [[ -f $RW_OUT/manifest.json ]]; then
        [[ $(jq -r '.secrets_ready // false' "$RW_OUT/manifest.json") == false ]] || rw_die 'Секреты потеряны; остановка без генерации новых ключей.'
    fi
    for key in app_secret postgres_password metrics_password webhook_secret auth_password; do openssl rand -hex 32 > "$RW_TMP/$key"; done
    printf 'Aa1%s\n' "$(openssl rand -hex 32)" > "$RW_TMP/admin_password"
    openssl genpkey -algorithm X25519 -outform DER -out "$RW_TMP/key.der"
    openssl pkey -inform DER -in "$RW_TMP/key.der" -pubout -outform DER -out "$RW_TMP/pub.der"
    [[ $(wc -c < "$RW_TMP/key.der") == 48 && $(wc -c < "$RW_TMP/pub.der") == 44 ]] || rw_die 'Некорректный формат X25519 DER.'
    tail -c 32 "$RW_TMP/key.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=' > "$RW_TMP/reality_private"
    tail -c 32 "$RW_TMP/pub.der" | openssl base64 -A | tr '+/' '-_' | tr -d '=' > "$RW_TMP/reality_public"
    openssl rand -hex 8 > "$RW_TMP/short_id"; printf '/%s\n' "$(openssl rand -hex 16)" > "$RW_TMP/xhttp_path"
    jq -n --rawfile app "$RW_TMP/app_secret" --rawfile pg "$RW_TMP/postgres_password" --rawfile met "$RW_TMP/metrics_password" \
      --rawfile wh "$RW_TMP/webhook_secret" --rawfile auth "$RW_TMP/auth_password" --rawfile admin "$RW_TMP/admin_password" \
      --rawfile priv "$RW_TMP/reality_private" --rawfile pub "$RW_TMP/reality_public" --rawfile sid "$RW_TMP/short_id" --rawfile path "$RW_TMP/xhttp_path" \
      '{app_secret:$app,postgres_password:$pg,metrics_password:$met,webhook_secret:$wh,auth_password:$auth,admin_password:$admin,reality_private:$priv,reality_public:$pub,short_id:$sid,xhttp_path:$path}|map_values(rtrimstr("\n"))' | rw_atomic "$file"
    if [[ -f $RW_OUT/manifest.json ]]; then rw_manifest_set '.secrets_ready=true'; fi
}
rw_render_compose() {
    local target=${1:-$RW_OUT/compose.json} versions=${2:-$RW_OUT/versions.lock.json}
    rw_memory_limits > "$RW_TMP/limits.json"
    jq -n --slurpfile c "$RW_CFG" --slurpfile v "$versions" --slurpfile limits "$RW_TMP/limits.json" --arg owner "$RW_OWNER" --arg project "$RW_PROJECT" --arg prefix "$RW_NET_PREFIX" '
      $c[0] as $c | $v[0].components as $v | $c.ports as $p |
      def service($image;$name): ($limits[0][$name]*1048576) as $memory |
        {image:$image,restart:"unless-stopped",mem_limit:$memory,cpus:(if $c.resources.profile=="compact-test" then 0.5 else 0.75 end),labels:{"io.pdm.remnawave.installation":$owner},logging:{driver:"json-file",options:{"max-size":"10m","max-file":"3"}}} |
        if $c.resources.profile=="compact-test" then .memswap_limit=$memory else . end;
      def env($path): [{path:$path,format:"raw"}];
      def health($test): {test:$test,interval:"5s",timeout:"3s",retries:20,start_period:"60s"};
      {name:$project,services:{},volumes:{caddy_data:{},caddy_config:{}},networks:{default:{labels:{"io.pdm.remnawave.installation":$owner},ipam:{config:[{subnet:$c.docker_subnet,gateway:($prefix+".1")}]}}}} |
      if $c.role != "node" then
        .services.rw_db=(service($v.postgres.image;"rw_db")+{shm_size:"128m",env_file:env("private/postgres.env"),volumes:["database:/var/lib/postgresql"],healthcheck:health(["CMD-SHELL","pg_isready -U postgres -d remnawave"])}) |
        (if $c.resources.profile=="compact-test" then .services.rw_db.command=["postgres","-c","shared_buffers=32MB","-c","max_connections=20","-c","work_mem=2MB","-c","maintenance_work_mem=16MB"] else . end) |
        .services.rw_valkey=(service($v.valkey.image;"rw_valkey")+{volumes:["valkey_socket:/var/run/valkey"],command:["valkey-server","--save","","--appendonly","no","--maxmemory",(if $c.resources.profile=="compact-test" then "16mb" else "96mb" end),"--maxmemory-policy","noeviction","--loglevel","warning","--unixsocket","/var/run/valkey/valkey.sock","--unixsocketperm","777","--port","0"],healthcheck:health(["CMD","valkey-cli","-s","/var/run/valkey/valkey.sock","ping"])}) |
        .services.rw_panel=(service($v.panel.image;"rw_panel")+{env_file:env("private/panel.env"),ports:[("127.0.0.1:"+($p.panel_api|tostring)+":3000"),("127.0.0.1:"+($p.metrics|tostring)+":3001")],networks:{default:{ipv4_address:($prefix+".10")}},volumes:["valkey_socket:/var/run/valkey"],depends_on:{rw_db:{condition:"service_healthy"},rw_valkey:{condition:"service_healthy"}},healthcheck:health(["CMD","curl","-f","http://127.0.0.1:3001/health"])}) |
        (if $c.resources.profile=="compact-test" then .services.rw_panel.environment={NODE_OPTIONS:"--max-old-space-size=256"} else . end) |
        .services.rw_subscription=(service($v.subscription.image;"rw_subscription")+{profiles:["public"],env_file:env("private/subscription.env"),ports:[("127.0.0.1:"+($p.subscription_api|tostring)+":3010")]}) |
        .volumes.database={} | .volumes.valkey_socket={}
      else . end |
      .services.rw_caddy=(service($v.caddy_auth.image;"rw_caddy")+{profiles:["public"],network_mode:"host",env_file:env("private/caddy.env"),volumes:["./Caddyfile:/etc/caddy/Caddyfile:ro","caddy_data:/data","caddy_config:/config","./site:/srv:ro"]}) |
      if $c.role != "panel" then .services.rw_node=(service($v.node.image;"rw_node")+{profiles:["node"],network_mode:"host",env_file:env("private/node.env")}) else . end |
      .volumes |= with_entries(.value.labels={"io.pdm.remnawave.installation":$owner})' | rw_atomic "$target"
}
rw_render_env() {
    local panel_port sub_port authority sub_authority
    panel_port=$(rw_port https)
    sub_port=$(rw_subscription_port)
    authority=$(rw_cfg '.domains.panel // empty'); sub_authority=$(rw_cfg '.domains.subscription // empty')
    if [[ -n $panel_port && $panel_port != 443 ]]; then authority+=:$panel_port; fi
    if [[ -n $sub_port && $sub_port != 443 ]]; then sub_authority+=:$sub_port; fi
    if [[ $RW_ROLE != node ]]; then
        jq -r --slurpfile c "$RW_CFG" --arg front "https://$authority" --arg sub "$sub_authority" '
          "APP_PORT=3000\nMETRICS_PORT=3001\nAPI_INSTANCES=1\nDATABASE_URL=postgresql://postgres:"+.postgres_password+"@rw_db:5432/remnawave\nREDIS_SOCKET=/var/run/valkey/valkey.sock\nAPP_SECRET="+.app_secret+
          "\nPANEL_DOMAIN="+$c[0].domains.panel+"\nFRONT_END_DOMAIN="+$front+"\nSUB_PUBLIC_DOMAIN="+$sub+"\nMETRICS_USER=metrics\nMETRICS_PASS="+.metrics_password+
          "\nWEBHOOK_SECRET_HEADER="+.webhook_secret+"\nWEBHOOK_ENABLED=false\nIS_TELEGRAM_NOTIFICATIONS_ENABLED=false"' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/panel.env"
        jq -r '"POSTGRES_USER=postgres\nPOSTGRES_DB=remnawave\nTZ=UTC\nPOSTGRES_PASSWORD="+.postgres_password' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/postgres.env"
        jq --slurpfile c "$RW_CFG" '{username:$c[0].admin.username,password:.admin_password}' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/admin.json"
        jq -r --slurpfile c "$RW_CFG" '"AUTH_TOKEN_LIFETIME=3600\nREMNAWAVE_PANEL_DOMAIN="+$c[0].domains.panel+"\nAUTHP_ADMIN_USER="+$c[0].admin.username+"\nAUTHP_ADMIN_EMAIL="+$c[0].admin.email+"\nAUTHP_ADMIN_SECRET="+.auth_password' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/caddy.env"
    else printf '# Separate node, no admin identity store.\n' | rw_atomic "$RW_OUT/private/caddy.env"; fi
    if [[ ! -f $RW_OUT/private/subscription.env ]]; then printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nREMNAWAVE_API_TOKEN=\nTRUST_PROXY=1\n' | rw_atomic "$RW_OUT/private/subscription.env"; fi
    if [[ ! -f $RW_OUT/private/node.env ]]; then printf 'NODE_PORT=%s\n' "$(rw_port node_api)" | rw_atomic "$RW_OUT/private/node.env"; fi
}
rw_render_profile() {
    [[ $RW_ROLE != panel ]] || return 0
    jq --slurpfile c "$RW_CFG" '
      $c[0] as $c | . as $s |
      {log:{loglevel:"warning"},inbounds:(["tcp","xhttp"]|map(. as $transport |
        {tag:("PDM-"+$c.environment_id+"-"+ascii_upcase),listen:"::",port:(if .=="tcp" then $c.ports.reality else $c.ports.xhttp end),protocol:"vless",settings:{clients:[],decryption:"none"},
         streamSettings:{network:$transport,security:"reality",realitySettings:{dest:("127.0.0.1:"+($c.ports.reality_target|tostring)),xver:0,serverNames:[$c.domains.node],privateKey:$s.reality_private,shortIds:[$s.short_id]}}} |
        if $transport=="xhttp" then .streamSettings.xhttpSettings={mode:"auto",path:$s.xhttp_path} else . end)),
       outbounds:[{tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}},{tag:"block",protocol:"blackhole"}]}' "$RW_OUT/private/secrets.json" | rw_atomic "$RW_OUT/private/xray-profile.json"
}
rw_render_caddy() {
    local http name kind port target ca
    http=$(rw_port http); ca=$(rw_cfg '.acme')
    {
        printf '{\n\tadmin 127.0.0.1:%s\n\tauto_https disable_redirects\n\thttp_port %s\n' "$(rw_port caddy_admin)" "$http"
        printf '\tcert_issuer acme {\n\t\tdisable_tlsalpn_challenge\n'
        [[ $ca != staging ]] || printf '\t\tdir https://acme-staging-v02.api.letsencrypt.org/directory\n'
        printf '\t}\n'
        [[ $RW_ROLE == node ]] || rw_auth_global
        printf '}\n'
        while IFS=$'\t' read -r kind name; do
            case $kind in node) port=$(rw_port reality_target);; subscription) port=$(rw_subscription_port);; *) port=$(rw_port https);; esac
            printf '\nhttps://%s:%s {\n' "$name" "$port"
            [[ $kind != node ]] || printf '\tbind 127.0.0.1\n'
            case $kind in
              panel)
                printf '\troute /api/* {\n\t\tauthorize with panelpolicy\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$(rw_port panel_api)"
                printf '\thandle /r {\n\t\trewrite * /auth\n\t\trequest_header +X-Forwarded-Prefix /r\n\t\tauthenticate with remnawaveportal\n\t}\n\troute /r* {\n\t\tauthenticate with remnawaveportal\n\t}\n'
                printf '\troute /* {\n\t\tauthorize with panelpolicy\n\t\treverse_proxy 127.0.0.1:%s\n\t}\n' "$(rw_port panel_api)";;
              subscription) printf '\treverse_proxy 127.0.0.1:%s\n' "$(rw_port subscription_api)";;
              node) printf '\troot * /srv\n\tfile_server\n';;
            esac
            printf '}\n'
        done < <(jq -r '.domains|to_entries[]|[.key,.value]|@tsv' "$RW_CFG")
        # A shared hostname has one HTTP listener, with the panel as its default redirect.
        while IFS=$'\t' read -r kind name; do
            printf 'http://%s:%s {\n' "$name" "$http"
            [[ $RW_MODE != fi-parallel ]] || printf '\tbind 127.0.0.1\n'
            case $kind in node) target=$(rw_port reality);; subscription) target=$(rw_subscription_port);; *) target=$(rw_port https);; esac
            printf '\tredir https://%s:%s{uri} 308\n}\n' "$name" "$target"
        done < <(rw_http_sites)
    } | rw_atomic "$RW_OUT/Caddyfile"
}
rw_render() {
    mkdir -p "$RW_OUT/site" "$RW_OUT/private"; chmod 700 "$RW_OUT" "$RW_OUT/site" "$RW_OUT/private"
    cat "$RW_CFG" | rw_atomic "$RW_OUT/config.json"
    if [[ -n ${RW_VERSION_FILE:-} ]]; then
        rw_versions_check "$RW_VERSION_FILE"
        jq --arg env "$RW_ENV" '.environment_id=$env' "$RW_VERSION_FILE" | rw_atomic "$RW_OUT/versions.lock.json"
    else rw_versions | jq --arg env "$RW_ENV" '.environment_id=$env' | rw_atomic "$RW_OUT/versions.lock.json"; fi
    rw_secrets; rw_render_compose; rw_render_env; rw_render_profile; rw_render_caddy
    printf '<!doctype html><html><title>Service</title><h1>Service online</h1></html>\n' | rw_atomic "$RW_OUT/site/index.html"
    rw_install_ctl
    jq -n --slurpfile c "$RW_CFG" --arg owner "$RW_OWNER" '{schema_version:1,environment_id:$c[0].environment_id,role:$c[0].role,domains:$c[0].domains,ports:$c[0].ports,ownership_label:$owner,nodes:[],access_groups:[],secret_files:["private/secrets.json","private/node.env"],grants_existing_users_access:false}' | rw_atomic "$RW_OUT/inventory.json"
}
# shellcheck shell=bash
rw_resource_checks() {
    local total available free required minram mincpu cpus image cached=0 path=$RW_OUT
    total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    available=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    cpus=$(getconf _NPROCESSORS_ONLN)
    minram=1536; mincpu=1
    if [[ $(rw_cfg '.resources.purpose') == production ]]; then minram=4096; mincpu=2; fi
    (( total >= minram && cpus >= mincpu )) || rw_die 'Недостаточно RAM/CPU для выбранного назначения.'
    if ! [[ -f $RW_OUT/manifest.json ]]; then
        required=$(rw_memory_limits | jq --arg role "$RW_ROLE" 'if $role=="node" then .rw_caddy+.rw_node
          elif $role=="panel" then del(.rw_node)|[.[]]|add else [.[]]|add end')
        # Compact tests reserve host headroom as well as every container's hard limit.
        if [[ $(rw_cfg '.resources.profile') == compact-test ]]; then required=$((required+128));
        elif [[ $RW_ROLE == node ]]; then required=$((required+128)); fi
        (( available >= required )) || rw_die "Для новых контейнеров требуется $required MiB свободной RAM сверх действующих служб."
    fi
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
    if [[ $(rw_cfg '.resources.purpose') == production ]]; then (( required >= 21474836480 )) || required=21474836480; fi
    (( free >= required )) || rw_die 'Недостаточно места для образов, данных, восстановления и резерва; чужие данные не очищаются.'
}
rw_dns_checks() {
    local domain family
    while IFS= read -r domain; do
        : > "$RW_TMP/dns.txt"
        for family in A AAAA; do
            dig +time=3 +tries=1 +noall +answer +comments "$domain" "$family" > "$RW_TMP/dig-answer.txt" || rw_die "DNS недоступен: $domain"
            grep -q 'status: NOERROR' "$RW_TMP/dig-answer.txt" || rw_die "Ответ DNS для $domain/$family не подтверждён."
            awk '$4=="A" || $4=="AAAA" {print $5}' "$RW_TMP/dig-answer.txt" >> "$RW_TMP/dns.txt"
        done
        # CNAMEs are excluded, but every A/AAAA address must match the declared set.
        { rw_config_filter | sed '/^\.$/,$d'; printf '\n[inputs|select(ip)|ipnorm]|unique\n'; } > "$RW_TMP/dns.jq"
        jq -Rn -f "$RW_TMP/dns.jq" < "$RW_TMP/dns.txt" > "$RW_TMP/dns.json"
        jq -e --slurpfile actual "$RW_TMP/dns.json" '.public_addresses == $actual[0]' "$RW_CFG" >/dev/null || rw_die "A/AAAA домена $domain не совпадают с public_addresses."
    done < <(jq -r '.domains[]' "$RW_CFG")
}
rw_docker_ownership() {
    local id owner project configs
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        owner=$(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id")
        project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$id")
        configs=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$id")
        [[ $owner == "$RW_OWNER" && $project == "$RW_PROJECT" && $configs == "$RW_OUT/compose.json" ]] || rw_die 'Одноимённый Compose-проект принадлежит другой установке.'
    done < <(docker ps -aq --filter "label=com.docker.compose.project=$RW_PROJECT")
}
rw_port_checks() {
    local name port id pids row socket_pids owned_ids publication
    owned_ids=$(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    : > "$RW_TMP/owned-pids"
    for id in $owned_ids; do docker top "$id" -eo pid | awk 'NR>1 && $1~/^[0-9]+$/ {print $1}' >> "$RW_TMP/owned-pids"; done
    while IFS=$'\t' read -r name port; do
        while IFS= read -r row; do
            [[ -n $row ]] || continue
            socket_pids=$(grep -oE 'pid=[0-9]+' <<< "$row" | cut -d= -f2 || true)
            [[ -n $socket_pids ]] || rw_die "Неизвестный владелец TCP $port ($name)."
            for pids in $socket_pids; do
                if ! grep -qx "$pids" "$RW_TMP/owned-pids"; then
                    publication=0
                    if [[ $name == panel_api || $name == metrics || $name == subscription_api ]]; then
                        for id in $owned_ids; do
                            docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" | jq -e --arg port "$port" 'to_entries | any(.[]|.value[]?; .HostIp=="127.0.0.1" and .HostPort==$port)' >/dev/null && publication=1
                        done
                    fi
                    (( publication )) || rw_die "TCP $port ($name) занят другим сервисом."
                fi
            done
        done < <(ss -H -lntp | awk -v p="$port" '$4 ~ (":" p "$") {print}')
    done < <(jq -r '.ports|to_entries[]|[.key,.value]|@tsv' "$RW_CFG")
    # Docker NAT publications can exist without a listening docker-proxy process.
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.installation"}}' "$id") == "$RW_OWNER" ]] && continue
        docker inspect --format '{{json .NetworkSettings.Ports}}' "$id" > "$RW_TMP/docker-ports.json"
        jq -e --slurpfile c "$RW_CFG" '[to_entries[]|select(.key|endswith("/tcp"))|.value[]?.HostPort|tonumber] as $used | ($c[0].ports|[.[]]) as $wanted | all($used[]; . as $port | ($wanted|index($port))==null)' "$RW_TMP/docker-ports.json" >/dev/null || rw_die 'Порт нового окружения уже опубликован другим Docker-контейнером.'
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
      ($subnet|bounds) as $wanted | [inputs|select(test("^[0-9.]+/[0-9]+$"))|bounds] | all(.[]; .[1]<$wanted[0] or .[0]>$wanted[1])' < "$RW_TMP/networks" | grep -qx true || rw_die 'docker_subnet пересекается с действующей сетью; задайте другой subnet явно.'
}
rw_preflight() {
    rw_os; rw_resource_checks; rw_dns_checks
    /usr/sbin/sshd -t || rw_die 'sshd -t не прошёл; SSH не изменялся.'
    [[ $(timedatectl show -p NTPSynchronized --value) == yes ]] || rw_die 'Не подтверждена синхронизация времени.'
    nft -j list ruleset >/dev/null || rw_die 'Невозможно прочитать текущий firewall.'
    rw_docker_ownership; rw_port_checks; rw_network_check
    if [[ $RW_MODE == fi-parallel ]]; then rw_existing_caddy_check; fi
    rw_info 'Preflight пройден: ОС, DNS A/AAAA, RAM/диск, порты, Docker и сети.'
}
# shellcheck shell=bash
rw_api() {
    local method=$1 path=$2 body=${3:-} target=$4 code
    local -a args=(--silent --show-error --connect-timeout 5 --max-time 30 --request "$method" --header 'Content-Type: application/json' --header 'X-Forwarded-Proto: https' --header 'X-Forwarded-For: 127.0.0.1')
    [[ -z ${RW_AUTH_CONF:-} ]] || args+=(--config "$RW_AUTH_CONF")
    [[ ${RW_AUTH_KIND:-} != admin ]] || args+=(--header 'X-Remnawave-Client-Type: browser')
    [[ -z $body ]] || args+=(--data-binary "@$body")
    code=$(curl "${args[@]}" --output "$target" --write-out '%{http_code}' "$RW_API_ROOT$path") || return 1
    [[ $code =~ ^2[0-9][0-9]$ ]] || return 1
    jq -e 'type=="object" and has("response")' "$target" >/dev/null
}
rw_auth_header() {
    local file=$1
    [[ -f $file && ! -L $file && $(stat -c %a "$file") == 600 ]] || rw_die 'Токен должен находиться в отдельном файле с правами 0600.'
    grep -qxE '[A-Za-z0-9._=+/-]+' "$file" || rw_die 'Неподдерживаемый формат токена.'
    { printf 'header = "Authorization: Bearer '; tr -d '\n' < "$file"; printf '"\n'; } | rw_atomic "$RW_TMP/auth.curl"
    RW_AUTH_CONF=$RW_TMP/auth.curl
    RW_AUTH_KIND=${2:-api}
}
rw_wait_panel() {
    local attempt
    RW_API_ROOT=http://127.0.0.1:$(rw_port panel_api); RW_AUTH_CONF=
    for ((attempt=0; attempt<60; attempt++)); do rw_api GET /api/auth/status '' "$RW_TMP/status.json" 2>/dev/null && return 0; sleep 2; done
    rw_die 'Панель не вышла в готовность; новые контейнеры сохранены для диагностики.'
}
rw_panel_login() {
    RW_API_ROOT=http://127.0.0.1:$(rw_port panel_api); RW_AUTH_CONF=
    rw_api GET /api/auth/status '' "$RW_TMP/status.json" || rw_die 'API панели недоступен.'
    if jq -e '.response.isRegisterAllowed == true' "$RW_TMP/status.json" >/dev/null; then
        rw_info 'Создание первого администратора через закрытый API панели.'
        rw_api POST /api/auth/register "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || {
            # Registration may have succeeded before a lost response. Reconcile by login, not another register.
            rw_api POST /api/auth/login "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || rw_die 'Не удалось подтвердить создание администратора.'
        }
    else rw_api POST /api/auth/login "$RW_OUT/private/admin.json" "$RW_TMP/login.json" || rw_die 'Существующий администратор не соответствует сохранённым данным; перезапись запрещена.'; fi
    jq -er '.response.accessToken' "$RW_TMP/login.json" | rw_atomic "$RW_TMP/admin.jwt"
    rw_auth_header "$RW_TMP/admin.jwt" admin
    if [[ ${RW_MUTATING:-0} == 1 ]]; then rw_manifest_set '.admin_bootstrapped=true'; fi
}
rw_token() {
    local key=$1 scopes=$2 body=$RW_TMP/token-request.json response=$RW_TMP/token-response.json uuid
    if [[ -s $RW_OUT/private/$key.token ]]; then return; fi
    # A lost create-token response cannot recover the token value. Stop for explicit revocation/rotation.
    [[ $(jq -r --arg key "$key" '.token_intents[$key] // false' "$RW_OUT/manifest.json") == false ]] || rw_die 'Ранее начат выпуск API-токена без сохранённого ответа; нужна проверка/ротация этого токена.'
    jq -n --arg name "${key}-${RW_OWNER:0:8}" --slurpfile scopes "$scopes" '{name:$name,expiresInDays:90,scopes:$scopes[0]}' | rw_atomic "$body"
    rw_manifest_set '.token_intents[$key]=true' --arg key "$key"
    rw_api POST /api/tokens "$body" "$response" || rw_die 'Выпуск токена не подтверждён; публикация не выполнялась.'
    jq -er '.response.token' "$response" | rw_atomic "$RW_OUT/private/$key.token"
    uuid=$(jq -er '.response.uuid' "$response")
    jq --arg uuid "$uuid" --arg key "$key" '.tokens[$key]={uuid:$uuid,expires_at:(now+90*86400)}' "$RW_OUT/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
}
rw_panel_tokens() {
    rw_api GET /api/tokens/scopes '' "$RW_TMP/scopes.json" || rw_die 'Не удалось проверить каталог прав API.'
    jq '[.response.resources[].endpoints[]|select(.kind=="read" and (.path|test("/api/system/metadata$|/api/sub(/|$)|/api/subscriptions?(/|$)|/api/(subscription-page-configs?|subpage-configs?)(/|$)")))|.key]|unique' "$RW_TMP/scopes.json" > "$RW_TMP/subscription-scopes.json"
    jq -e 'length>0 and all(.!="*")' "$RW_TMP/subscription-scopes.json" >/dev/null || rw_die 'Не найдены минимальные права subscription-page; общий токен не выдаётся.'
    rw_token subscription "$RW_TMP/subscription-scopes.json"
    jq '[.response.resources[].endpoints[]|select((.method|ascii_upcase)=="GET" or (.method|ascii_upcase)=="POST")|select(.path|test("^/api/(nodes|config-profiles|hosts|internal-squads)(/\\{[^/]+\\})?$|^/api/keygen$"))|.key]|unique' "$RW_TMP/scopes.json" > "$RW_TMP/installer-scopes.json"
    jq -e 'length>0 and all(.!="*")' "$RW_TMP/installer-scopes.json" >/dev/null || rw_die 'Не получены права управления нодой.'
    rw_token installer "$RW_TMP/installer-scopes.json"
    {
        printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nTRUST_PROXY=1\nREMNAWAVE_API_TOKEN='
        tr -d '\n' < "$RW_OUT/private/subscription.token"; printf '\n'
    } | rw_atomic "$RW_OUT/private/subscription.env"
    rw_auth_header "$RW_OUT/private/installer.token"
}
rw_api_object() {
    local key=$1 endpoint=$2 collection=$3 name=$4 request=$5 uuid intent count
    uuid=$(jq -r --arg key "$key" '.api[$key].uuid // empty' "$RW_OUT/manifest.json")
    if [[ -n $uuid ]]; then
        rw_api GET "$endpoint/$uuid" '' "$RW_TMP/object.json" || rw_die 'Ранее зарегистрированный API-объект недоступен.'
        jq -e --arg name "$name" '.response.name==$name or .response.remark==$name' "$RW_TMP/object.json" >/dev/null || rw_die 'API UUID больше не соответствует собственной установке.'
        return
    fi
    rw_api GET "$endpoint" '' "$RW_TMP/objects.json" || rw_die 'Не удалось прочитать каталог API.'
    jq --arg name "$name" "$collection | map(select(.name==\$name or .remark==\$name))" "$RW_TMP/objects.json" > "$RW_TMP/matches.json"
    count=$(jq 'length' "$RW_TMP/matches.json")
    intent=$(jq -r --arg key "$key" '.api[$key].intent // empty' "$RW_OUT/manifest.json")
    if (( count > 0 )); then
        [[ -n $intent && $count == 1 && $intent == $(sha256sum "$request" | cut -d' ' -f1) ]] || rw_die 'Одноимённый чужой API-объект: установка остановлена.'
        jq -e --slurpfile request "$request" '.[0] as $actual | $request[0] | to_entries | all(.[]; . as $entry | $actual[$entry.key]==$entry.value)' "$RW_TMP/matches.json" >/dev/null || rw_die 'Ответ после потери соединения не совпадает с фиксированной целью.'
        jq '{response:.[0]}' "$RW_TMP/matches.json" > "$RW_TMP/object.json"
    else
        intent=$(sha256sum "$request" | cut -d' ' -f1)
        rw_manifest_set '.api[$key].intent=$intent' --arg key "$key" --arg intent "$intent"
        rw_api POST "$endpoint" "$request" "$RW_TMP/object.json" || rw_die 'Создание API-объекта не подтверждено; повтор сверит результат по журналу.'
    fi
    uuid=$(jq -er '.response.uuid' "$RW_TMP/object.json")
    [[ $uuid =~ ^[a-f0-9-]{36}$ ]] || rw_die 'Некорректный UUID API.'
    rw_manifest_set '.api[$key].uuid=$uuid' --arg key "$key" --arg uuid "$uuid"
}
rw_register_node() {
    local config=$1 package=$2 address=$3 profile_file=${4:-$RW_OUT/private/xray-profile.json} prefix profile_uuid node_uuid transport inbound
    local env owner
    local api_owner
    api_owner=$(jq -r '.api_namespace_owner // .ownership_label' "$RW_OUT/manifest.json")
    env=$(jq -r '.environment_id' "$config"); owner=$(printf '%s' "$env:$api_owner" | sha256sum | cut -c1-8)
    prefix=PDM-${env:0:10}-$owner
    jq --arg name "$prefix" '{name:$name,config:.}' "$profile_file" > "$RW_TMP/profile-request.json"
    rw_api_object "profile-$env" /api/config-profiles '.response.configProfiles' "$prefix" "$RW_TMP/profile-request.json"
    profile_uuid=$(jq -r --arg key "profile-$env" '.api[$key].uuid' "$RW_OUT/manifest.json")
    rw_api GET "/api/config-profiles/$profile_uuid" '' "$RW_TMP/profile.json" || rw_die 'Не удалось получить inbounds профиля.'
    jq -e '.response.inbounds|length==2' "$RW_TMP/profile.json" >/dev/null || rw_die 'Не получены оба TCP/XHTTP inbound.'
    jq -n --arg name "$prefix" --arg address "$address" --arg profile "$profile_uuid" --arg owner "$api_owner" \
      --slurpfile c "$config" --slurpfile p "$RW_TMP/profile.json" '{name:$name,address:$address,port:$c[0].ports.node_api,countryCode:$c[0].node_country,note:("pdm-install:"+$owner),configProfile:{activeConfigProfileUuid:$profile,activeInbounds:[$p[0].response.inbounds[].uuid]}}' > "$RW_TMP/node-request.json"
    rw_api_object "node-$env" /api/nodes '.response' "$prefix" "$RW_TMP/node-request.json"
    node_uuid=$(jq -r --arg key "node-$env" '.api[$key].uuid' "$RW_OUT/manifest.json")
    for transport in tcp xhttp; do
        inbound=$(jq -er --arg tag "PDM-$env-${transport^^}" '.response.inbounds[]|select(.tag==$tag)|.uuid' "$RW_TMP/profile.json")
        jq -n --arg remark "$prefix-$transport" --arg profile "$profile_uuid" --arg inbound "$inbound" --arg node "$node_uuid" --arg transport "$transport" --slurpfile c "$config" --slurpfile xray "$profile_file" \
          '{remark:$remark,inbound:{configProfileUuid:$profile,configProfileInboundUuid:$inbound},address:$c[0].domains.node,port:(if $transport=="tcp" then $c[0].ports.reality else $c[0].ports.xhttp end),sni:$c[0].domains.node,fingerprint:"chrome",nodes:[$node]} | if $transport=="xhttp" then .path=($xray[0].inbounds[]|select(.streamSettings.network=="xhttp")|.streamSettings.xhttpSettings.path) else . end' > "$RW_TMP/host-request.json"
        rw_api_object "host-$env-$transport" /api/hosts '.response' "$prefix-$transport" "$RW_TMP/host-request.json"
        jq -n --arg name "$prefix-$transport" --arg inbound "$inbound" '{name:$name,inbounds:[$inbound]}' > "$RW_TMP/squad-request.json"
        rw_api_object "squad-$env-$transport" /api/internal-squads '.response.internalSquads' "$prefix-$transport" "$RW_TMP/squad-request.json"
        local squad_uuid
        squad_uuid=$(jq -r --arg key "squad-$env-$transport" '.api[$key].uuid' "$RW_OUT/manifest.json")
        jq --arg env "$env" --arg transport "$transport" --arg node "$node_uuid" --arg uuid "$squad_uuid" \
          '.access_groups=([.access_groups[]?|select(.environment_id!=$env or .transport!=$transport)]+[{environment_id:$env,transport:$transport,node_uuid:$node,uuid:$uuid}])' "$RW_OUT/inventory.json" | rw_atomic "$RW_OUT/inventory.json"
    done
    rw_api GET /api/keygen '' "$RW_TMP/node-secret.json" || rw_die 'Штатный SECRET_KEY панели не получен.'
    jq -e '.response.secretKey|type=="string" and test("^[A-Za-z0-9+/=_-]+$")' "$RW_TMP/node-secret.json" >/dev/null || rw_die 'Некорректный SECRET_KEY панели.'
    local node_fp
    node_fp=$(jq -Sc . "$config" | sha256sum | cut -d' ' -f1)
    jq -n --slurpfile c "$config" --slurpfile k "$RW_TMP/node-secret.json" --arg node "$node_uuid" --arg profile "$profile_uuid" --arg fp "$node_fp" \
      '{schema_version:1,environment_id:$c[0].environment_id,config_fingerprint:$fp,expires_at:(now+3600),node_uuid:$node,config_profile_uuid:$profile,secret_key:$k[0].response.secretKey}' | rw_atomic "$package"
    jq --arg node "$node_uuid" --arg profile "$profile_uuid" --slurpfile p "$RW_TMP/profile.json" '.nodes=([.nodes[]?|select(.node_uuid!=$node)]+[{node_uuid:$node,config_profile_uuid:$profile,inbound_uuids:[$p[0].response.inbounds[].uuid]}])' "$RW_OUT/inventory.json" | rw_atomic "$RW_OUT/inventory.json"
}
rw_node_connection() {
    local package=$1
    [[ -f $package && ! -L $package && $(stat -c %a "$package") == 600 ]] || rw_die 'Файл подключения ноды должен иметь права 0600.'
    jq -e --arg env "$RW_ENV" --arg fp "$RW_FINGERPRINT" '.schema_version==1 and .environment_id==$env and .config_fingerprint==$fp and .expires_at>now and (.secret_key|test("^[A-Za-z0-9+/=_-]+$"))' "$package" >/dev/null || rw_die 'Файл подключения просрочен или относится к другим параметрам ноды.'
    if [[ $package == "$RW_OUT/private/connection.json" ]]; then cat "$package" | rw_atomic "$package"; fi
    if grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then
        jq -e --slurpfile package "$package" '.node_uuid==$package[0].node_uuid and .config_profile_uuid==$package[0].config_profile_uuid' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Существующий ключ относится к другой записи ноды.'
        return
    fi
    jq -r --arg port "$(rw_port node_api)" '"NODE_PORT="+$port+"\nSECRET_KEY="+.secret_key' "$package" | rw_atomic "$RW_OUT/private/node.env"
    rw_manifest_set '.node_uuid=$node|.config_profile_uuid=$profile' --arg node "$(jq -r '.node_uuid' "$package")" --arg profile "$(jq -r '.config_profile_uuid' "$package")"
}
rw_firewall() {
    local port sources4 sources6 id rules=$RW_OUT/private/firewall.nft
    port=$(rw_port node_api)
    if [[ $RW_ROLE == node ]]; then
        sources4=$(jq -r '[.panel_addresses[]|select(contains(":")|not)]|join(", ")' "$RW_CFG")
        sources6=$(jq -r '[.panel_addresses[]|select(contains(":"))]|join(", ")' "$RW_CFG")
    else sources4=$RW_NET_PREFIX.10; sources6=; fi
    {
        if nft -j list table inet "$RW_TABLE" > "$RW_TMP/existing-table.json" 2>/dev/null; then
            jq -e --arg owner "$RW_OWNER" '.nftables | any(.table.comment==$owner)' "$RW_TMP/existing-table.json" >/dev/null || rw_die 'Одноимённая nftables table принадлежит другой установке.'
            printf 'delete table inet %s\n' "$RW_TABLE"
        fi
        printf 'table inet %s {\n comment "%s"\n chain input { type filter hook input priority -5; policy accept;\n' "$RW_TABLE" "$RW_OWNER"
        if [[ -n $port ]]; then
            printf ' iifname "lo" tcp dport %s accept\n' "$port"
            [[ -z $sources4 ]] || printf ' ip saddr { %s } tcp dport %s accept\n' "$sources4" "$port"
            [[ -z $sources6 ]] || printf ' ip6 saddr { %s } tcp dport %s accept\n' "$sources6" "$port"
            printf ' tcp dport %s drop\n' "$port"
        fi
        printf '}\n'
        if [[ $RW_ROLE != node ]]; then
            printf ' chain forward { type filter hook forward priority -5; policy accept;\n ip daddr %s ip saddr != %s tcp dport { 3000, 3001, 3010, 5432, 6379 } drop\n }\n' "$RW_SUBNET" "$RW_SUBNET"
        fi
        printf '}\n'
    } | rw_atomic "$rules"
    nft --check -f "$rules" || rw_die 'Проверка собственной nftables-конфигурации не прошла.'
    nft -f "$rules"
    # On reboot the table is absent; load only the table declaration, not its previous deletion.
    sed '/^delete table /d' "$rules" | rw_atomic "$RW_OUT/private/firewall-boot.nft"
    local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
    if [[ -f $unit ]] && ! grep -qF "$RW_OWNER" "$unit"; then rw_die 'Конфликт systemd unit firewall.'; fi
    {
        printf '# %s\n[Unit]\nDescription=Remnawave scoped firewall\nBefore=docker.service\nAfter=network-pre.target\n\n[Service]\nType=oneshot\nExecStart=/usr/sbin/nft -f %s/private/firewall-boot.nft\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' "$RW_OWNER" "$RW_OUT"
    } > "$unit"
    chmod 644 "$unit"; systemctl daemon-reload; systemctl enable "$RW_PROJECT-firewall.service" >/dev/null
    rw_manifest_set '.firewall_installed=true'
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        while IFS= read -r port; do ufw allow "$port/tcp" comment "$RW_PROJECT" >/dev/null; done < <(jq -r '.ports | [.http,.https,.subscription_https,.reality,.xhttp] | map(select(.!=null and .!=18080)) | unique[]' "$RW_CFG")
        port=$(rw_port node_api)
        if [[ -n $port ]]; then
            for id in $sources4 $sources6; do ufw allow from "${id%,}" to any port "$port" proto tcp comment "$RW_PROJECT" >/dev/null; done
        fi
        rw_manifest_set '.ufw_rules_added=true'
    fi
}
rw_existing_caddy_check() {
    local file container health
    file=$(rw_cfg '.existing_caddy.config_file // empty'); container=$(rw_cfg '.existing_caddy.container // empty'); health=$(rw_cfg '.existing_caddy.health_url // empty')
    [[ $file == /* && -f $file && ! -L $file && $container =~ ^[A-Za-z0-9_.-]+$ && $health =~ ^https://[A-Za-z0-9.:-]+/?$ ]] || rw_die 'Для FI задайте existing_caddy: config_file, container, health_url.'
    docker inspect --format '{{.State.Running}}' "$container" | grep -qx true || rw_die 'Существующий Caddy не работает.'
    curl -f --silent --show-error --connect-timeout 5 --max-time 10 "$health" >/dev/null || rw_die 'Исходный сайт FI недоступен до изменений.'
}
rw_existing_caddy_candidate() {
    local file=$1 candidate=$2 kind domain https matcher=pdm_rw_${RW_ENV//-/_}_redirect
    cat "$file" > "$candidate"
    while IFS=$'\t' read -r kind domain; do
        if grep -Fxq "http://$domain {" "$candidate"; then
            # The FI HTTP site already serves this hostname. Scope the existing
            # redirect away from ACME, preserving its target and other directives.
            # Unrecognised layouts stop here instead of guessing at Caddy syntax.
            awk -v site="http://$domain {" -v domain="$domain" -v project="$RW_PROJECT" -v matcher="$matcher" -v port="$(rw_port http)" '
              $0==site {active=1}
              active && $1=="redir" {
                if (NF!=3 || index($2,"https://" domain)!=1) exit 42;
                print "\t# BEGIN " project;
                print "\t@" matcher " not path /.well-known/acme-challenge/*";
                print "\thandle /.well-known/acme-challenge/* {";
                print "\t\treverse_proxy 127.0.0.1:" port;
                print "\t}";
                print "\tredir @" matcher " " $2 " " $3;
                print "\t# END " project;
                changed++; next
              }
              active && $0=="}" {active=0}
              {print}
              END {if (changed!=1) exit 42}' "$candidate" > "$RW_TMP/existing-caddy.site" || rw_die 'Существующий HTTP site требует явной сверки; его конфиг не изменён.'
            cat "$RW_TMP/existing-caddy.site" > "$candidate"
        else
            case $kind in node) https=$(rw_port reality);; subscription) https=$(rw_subscription_port);; *) https=$(rw_port https);; esac
            printf '\n# BEGIN %s\nhttp://%s {\n handle /.well-known/acme-challenge/* {\n  reverse_proxy 127.0.0.1:%s\n }\n handle {\n  redir https://%s:%s{uri} 308\n }\n}\n# END %s\n' "$RW_PROJECT" "$domain" "$(rw_port http)" "$domain" "$https" "$RW_PROJECT" >> "$candidate"
        fi
    done < <(rw_http_sites)
}
rw_existing_caddy_apply() {
    [[ $RW_MODE == fi-parallel ]] || return 0
    local file container kind domain https code candidate=$RW_TMP/existing-caddy.new
    file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
    if grep -qF "# BEGIN $RW_PROJECT" "$file"; then
        [[ -f $RW_OUT/private/existing-caddy.applied.sha256 ]] || rw_die 'Неизвестный маршрут существующего Caddy.'
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'Существующий Caddy изменён после установки; нужна сверка.'
        rw_manifest_set '.existing_caddy_updated=true'
        return
    fi
    cp -p -- "$file" "$RW_OUT/private/existing-caddy.before"; chmod 600 "$RW_OUT/private/existing-caddy.before"
    rw_existing_caddy_candidate "$file" "$candidate"
    docker cp "$candidate" "$container:/tmp/$RW_PROJECT.Caddyfile"
    docker exec --user 0 "$container" caddy validate --config "/tmp/$RW_PROJECT.Caddyfile" --adapter caddyfile >/dev/null || rw_die 'Полный конфиг старого Caddy не прошёл проверку.'
    RW_EXISTING_CADDY_FILE=$file; RW_EXISTING_CADDY_CONTAINER=$container; RW_CADDY_ROLLBACK_PENDING=1
    # Preserve the inode of a single-file Docker bind mount; atomic rename would leave the old file mounted.
    cat "$candidate" > "$file"
    if ! docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || ! curl -f --silent --max-time 10 "$(rw_cfg '.existing_caddy.health_url')" >/dev/null; then
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || true
        rw_die 'Проверка reload старого Caddy не прошла; исходный файл восстановлен.'
    fi
    sha256sum "$file" | cut -d' ' -f1 | rw_atomic "$RW_OUT/private/existing-caddy.applied.sha256"
    rw_manifest_set '.existing_caddy_updated=true'
    RW_CADDY_ROLLBACK_PENDING=0
}
rw_apply() {
    rw_root; rw_os; rw_resource_checks; rw_dns_checks; rw_docker_install; rw_preflight
    if [[ -f $RW_OUT/manifest.json ]]; then
        [[ -z ${RW_VERSION_FILE:-} ]] || rw_die 'Для смены версий существующей установки используйте upgrade.'
        rw_owned
        rw_verify_files; rw_ssh_idle
        [[ $(jq -r '.config_fingerprint' "$RW_OUT/manifest.json") == "$RW_FINGERPRINT" ]] || rw_die 'Параметры изменились; ключи и конфиги не перезаписываются.'
    else
        [[ ! -d $RW_OUT || -z $(find "$RW_OUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || rw_die 'Каталог не пуст и не принадлежит установщику.'
    fi
    rw_lock
    RW_MUTATING=1
    if [[ ! -f $RW_OUT/manifest.json ]]; then rw_manifest preparing; fi
    if [[ $(jq -r '.status' "$RW_OUT/manifest.json") == preparing ]]; then rw_render; rw_manifest_set '.status="prepared"'; fi
    if [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared && -z $(docker ps -q --filter "label=io.pdm.remnawave.installation=$RW_OWNER") ]]; then
        # A never-started package can receive template fixes without replacing secrets or pinned images.
        rw_render_compose; rw_render_caddy; rw_install_ctl; rw_track_files
    fi
    rw_owned; rw_compose config --quiet
    rw_info 'Загрузка закреплённых Docker-образов.'
    rw_compose --profile public --profile node pull
    if ! rw_compose --profile public run --rm --no-deps --entrypoint caddy rw_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$RW_TMP/caddy-check.log" 2>&1; then
        cat "$RW_TMP/caddy-check.log" | rw_atomic "$RW_OUT/private/caddy-validation.log"
        rw_die 'Конфигурация Caddy не прошла проверку; публикация не выполнена. Диагностика сохранена в private/caddy-validation.log.'
    fi
    rw_firewall
    if [[ $RW_ROLE != node ]]; then
        rw_info 'Запуск PostgreSQL, Valkey и Remnawave.'
        rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey rw_panel
        rw_wait_panel; rw_panel_login; rw_panel_tokens
    fi
    if [[ $RW_ROLE == panel-node ]]; then
        rw_register_node "$RW_CFG" "$RW_OUT/private/connection.json" "$RW_PANEL_ADDRESS"
        rw_node_connection "$RW_OUT/private/connection.json"
    elif [[ $RW_ROLE == node ]]; then
        if [[ -n ${RW_CONNECTION:-} ]]; then rw_node_connection "$RW_CONNECTION";
        elif ! grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then
            rw_manifest_set '.status="node-prepared-awaiting-attachment"'
            rw_info "Нода подготовлена в $RW_OUT. Подключите её командой rwctl node attach на панели; SECRET_KEY не генерируется локально."
            return
        fi
    fi
    rw_existing_caddy_apply
    rw_info 'Запуск Caddy/MFA и публичной страницы подписок.'
    rw_compose --profile public up -d rw_caddy
    [[ $RW_ROLE == node ]] || rw_compose --profile public up -d rw_subscription
    if [[ $RW_ROLE != panel ]]; then rw_compose --profile node up -d rw_node; fi
    rw_manifest_set '.status="running-awaiting-acceptance"'
    rw_doctor
    rw_info "Контейнеры запущены в $RW_OUT."
    if [[ $RW_ROLE != node ]]; then rw_info 'Админские данные: private/admin.json; пароль Caddy Auth: private/secrets.json. Завершите MFA при первом входе.'; fi
}
# shellcheck shell=bash
rw_track_files() {
    local file relative sum
    : > "$RW_TMP/managed.jsonl"
    while IFS= read -r relative; do
        [[ -n $relative && $relative != manifest.json && $relative != .rw.lock && $relative != /* && $relative != *'..'* ]] || continue
        file=$RW_OUT/$relative
        [[ -f $file && ! -L $file ]] || continue
        sum=$(sha256sum "$file" | cut -d' ' -f1)
        jq -n --arg path "$relative" --arg sum "$sum" '{path:$path,sha256:$sum}' >> "$RW_TMP/managed.jsonl"
    done < <({ [[ ! -f $RW_OUT/private/.managed-paths ]] || cat "$RW_OUT/private/.managed-paths"; jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf '%s\n' 'private/.managed-paths'; } | LC_ALL=C sort -u)
    jq -s '.' "$RW_TMP/managed.jsonl" > "$RW_TMP/managed.json"
    rw_manifest_set '.managed_files=$files[0]' --slurpfile files "$RW_TMP/managed.json"
}
rw_verify_files() {
    local path sum parent
    while IFS=$'\t' read -r path sum; do
        [[ $path != /* && $path != *'..'* && $path != *$'\n'* ]] || rw_die 'Небезопасный путь в manifest.'
        parent=$RW_OUT/$path
        while [[ $parent != "$RW_OUT" ]]; do [[ ! -L $parent ]] || rw_die 'Symlink в управляемом пути.'; parent=$(dirname -- "$parent"); done
        [[ -f $RW_OUT/$path && $(sha256sum "$RW_OUT/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Изменён управляемый файл $path; требуется сверка."
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$RW_OUT/manifest.json")
}
rw_doctor() {
    local id state service node_uuid attempts
    rw_owned; rw_docker_ownership
    [[ $(jq -r '.status' "$RW_OUT/manifest.json") != node-prepared-awaiting-attachment ]] || rw_die 'Нода подготовлена, но ещё не подключена к панели.'
    while IFS= read -r service; do
        [[ -n $(rw_compose --profile public --profile node ps -q "$service") ]] || rw_die "Отсутствует работающий сервис $service."
    done < <(jq -r '.services|keys[]' "$RW_OUT/compose.json")
    [[ $(stat -c %a "$RW_OUT/private") == 700 ]] || rw_die 'private/ должен иметь права 0700.'
    while IFS= read -r -d '' id; do [[ $(stat -c %a "$id") == 600 ]] || rw_die 'Секретный файл имеет слишком широкие права.'; done < <(find "$RW_OUT/private" -type f -print0)
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        state=$(docker inspect --format '{{.State.Status}}' "$id"); service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
        [[ $state == running ]] || rw_die "Сервис $service находится в состоянии $state."
        for ((attempts=0; attempts<60; attempts++)); do
            state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id")
            [[ $state == starting ]] || break
            sleep 2
        done
        [[ $state == healthy || $state == none ]] || rw_die "Healthcheck $service: $state."
    done < <(docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER")
    if [[ $RW_ROLE != node ]]; then
        rw_wait_panel; rw_panel_login
        while IFS= read -r node_uuid; do
            for ((attempts=0; attempts<30; attempts++)); do
                rw_api GET "/api/nodes/$node_uuid" '' "$RW_TMP/node-health.json" && jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/node-health.json" >/dev/null && break
                sleep 2
            done
            jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/node-health.json" >/dev/null || rw_die 'Панель не подтвердила подключение ноды и работающий Xray.'
        done < <(jq -r '.nodes[].node_uuid' "$RW_OUT/inventory.json")
    fi
    jq -n --arg e "$RW_ENV" --arg role "$RW_ROLE" '{schema_version:1,environment_id:$e,role:$role,containers_running:true,client_acceptance_required:true}'
}
rw_resource_plan() {
    local kind=$1 command=$2 expression=$3 id owner
    while IFS= read -r id; do
        [[ -n $id ]] || continue
        owner=$(docker inspect --type "$kind" --format "$expression" "$id")
        [[ $owner == "$RW_OWNER" ]] || rw_die 'Docker-ресурс принадлежит другой установке.'
        printf '%s\n' "$id"
    done < <(docker "$command" ls -q --filter "label=com.docker.compose.project=$RW_PROJECT")
}
rw_uninstall() {
    rw_owned
    rw_ssh_idle
    if [[ ${RW_PREPARED_ONLY:-0} == 1 ]]; then
        [[ $(jq -r '.status' "$RW_OUT/manifest.json") == prepared ]] || rw_die 'prepared-only нельзя применять к запускавшейся системе.'
        [[ ${RW_PURGE:-0} == 0 ]] || rw_die 'prepared-only и purge несовместимы.'
        printf '[]\n' > "$RW_TMP/containers.json"
        : > "$RW_TMP/networks"; : > "$RW_TMP/volumes"
    else
        docker info >/dev/null 2>&1 || rw_die 'Docker недоступен; файлы установки сохранены.'
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]' > "$RW_TMP/containers.json"
        rw_resource_plan network network '{{index .Labels "io.pdm.remnawave.installation"}}' > "$RW_TMP/networks"
        rw_resource_plan volume volume '{{index .Labels "io.pdm.remnawave.installation"}}' > "$RW_TMP/volumes"
    fi
    rw_verify_files
    if [[ ${RW_DRY_RUN:-0} == 1 ]]; then
        jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --slurpfile containers "$RW_TMP/containers.json" --rawfile volumes "$RW_TMP/volumes" --argjson purge "${RW_PURGE:-0}" '{environment_id:$e,directory:$path,containers:$containers[0],volumes:($volumes|split("\n")|map(select(length>0))),purge:($purge==1),read_only:true}'; return
    fi
    rw_root
    if [[ ${RW_YES:-0} != 1 ]]; then
        rw_info "Удаление только $RW_PROJECT в $RW_OUT. Данные Docker: $([[ ${RW_PURGE:-0} == 1 ]] && printf удалить || printf сохранить)."
        local confirm; read -r -p "Введите $RW_ENV для подтверждения: " confirm
        [[ $confirm == "$RW_ENV" ]] || { rw_info 'Отмена.'; return; }
    fi
    rw_lock; rw_verify_files
    if [[ ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        rw_docker_ownership
        docker ps -aq --filter "label=io.pdm.remnawave.installation=$RW_OWNER" | jq -Rn '[inputs|select(length>0)]|sort' > "$RW_TMP/current-containers.json"
        jq 'sort' "$RW_TMP/containers.json" > "$RW_TMP/planned-containers.json"
        cmp -s "$RW_TMP/current-containers.json" "$RW_TMP/planned-containers.json" || rw_die 'Состав контейнеров изменился после подтверждения.'
    fi
    if [[ ${RW_PURGE:-0} != 1 && ${RW_PREPARED_ONLY:-0} != 1 ]]; then
        local recovery
        recovery=/var/backups/pdm-remnawave/$RW_ENV-config-$(date -u +%Y%m%dT%H%M%SZ).tgz
        mkdir -p /var/backups/pdm-remnawave; chmod 700 /var/backups/pdm-remnawave
        tar -C "$RW_OUT" -czf "$recovery" --files-from <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json"; printf 'manifest.json\n')
        chmod 600 "$recovery"
        rw_info "Закрытая копия конфигов/ключей для сохранённых томов: $recovery"
    fi
    if [[ $(jq -r '.existing_caddy_updated // false' "$RW_OUT/manifest.json") == true ]]; then
        local file container
        file=$(rw_cfg '.existing_caddy.config_file'); container=$(rw_cfg '.existing_caddy.container')
        [[ $(sha256sum "$file" | cut -d' ' -f1) == $(cat "$RW_OUT/private/existing-caddy.applied.sha256") ]] || rw_die 'Существующий Caddy был изменён; автоматический откат маршрута остановлен.'
        cat "$RW_OUT/private/existing-caddy.before" > "$file"
        docker exec "$container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
    fi
    local id
    while IFS= read -r id; do docker stop -t 30 "$id" >/dev/null; docker rm "$id" >/dev/null; done < <(jq -r '.[]' "$RW_TMP/containers.json")
    while IFS= read -r id; do [[ -z $id ]] || docker network rm "$id" >/dev/null; done < "$RW_TMP/networks"
    if [[ ${RW_PURGE:-0} == 1 ]]; then while IFS= read -r id; do [[ -z $id ]] || docker volume rm "$id" >/dev/null; done < "$RW_TMP/volumes"; fi
    if [[ $(jq -r '.ufw_rules_added // false' "$RW_OUT/manifest.json") == true ]]; then
        while IFS= read -r id; do ufw --force delete "$id" >/dev/null; done < <(ufw status numbered | awk -v tag="# $RW_PROJECT" 'index($0,tag) {gsub(/[][]/,"",$1);print $1}' | sort -rn)
    fi
    if [[ $(jq -r '.firewall_installed // false' "$RW_OUT/manifest.json") == true ]]; then
        local unit=/etc/systemd/system/$RW_PROJECT-firewall.service
        [[ -f $unit ]] && grep -qF "$RW_OWNER" "$unit" || rw_die 'Владение systemd firewall unit не подтверждено.'
        systemctl disable "$RW_PROJECT-firewall.service" >/dev/null; rm -f -- "$unit"; systemctl daemon-reload
        nft list table inet "$RW_TABLE" >/dev/null 2>&1 && nft delete table inet "$RW_TABLE"
    fi
    # Delete only recorded files. Unknown backups/operator files and nonempty directories remain.
    while IFS= read -r id; do rm -f -- "$RW_OUT/$id"; done < <(jq -r '.managed_files[].path' "$RW_OUT/manifest.json")
    rm -f -- "$RW_OUT/manifest.json" "$RW_OUT/.rw.lock"
    find "$RW_OUT" -depth -type d -empty -delete
    rw_info 'Удаление завершено. Чужие контейнеры, образы, Docker Engine, SSH и общий firewall сохранены.'
}
rw_backup() {
    local archive=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-$(date -u +%Y%m%dT%H%M%SZ).tgz} id name image build
    archive=$(realpath -m -- "$archive")
    [[ $archive != "$RW_OUT"/* && ! -e $archive ]] || rw_die 'Backup должен быть новым файлом вне каталога установки.'
    rw_owned; rw_root; rw_lock; rw_docker_ownership; rw_verify_files; rw_ssh_idle
    mkdir -p -- "$(dirname -- "$archive")"
    build=$(mktemp -d "$RW_TMP/backup.XXXXXX")
    [[ -z $(find "$RW_OUT" -type l -print -quit) ]] || rw_die 'Symlink в каталоге установки; backup остановлен.'
    cp -a -- "$RW_OUT" "$build/installation"
    jq -n --arg e "$RW_ENV" --arg path "$RW_OUT" --arg owner "$RW_OWNER" --arg time "$(date -u +%FT%TZ)" '{schema_version:1,environment_id:$e,installation_path:$path,ownership_label:$owner,created_at_utc:$time}' > "$build/metadata.json"
    if [[ $RW_ROLE != node ]]; then rw_compose exec -T rw_db pg_dump -U postgres -d remnawave -Fc > "$build/database.dump"; fi
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    id=$(rw_compose --profile public ps -q rw_caddy)
    if [[ -n $id ]]; then docker pause "$id" >/dev/null; RW_PAUSED_CADDY=$id; fi
    for name in caddy_data caddy_config; do
        docker volume inspect "${RW_PROJECT}_$name" --format '{{index .Labels "io.pdm.remnawave.installation"}}' | grep -qx "$RW_OWNER" || rw_die 'Владение Caddy volume не подтверждено.'
        docker run --rm --network none --read-only --cap-drop ALL --entrypoint tar --mount "type=volume,src=${RW_PROJECT}_$name,dst=/data,readonly" "$image" -C /data -czf - . > "$build/$name.tgz"
    done
    if [[ -n ${RW_PAUSED_CADDY:-} ]]; then docker unpause "$RW_PAUSED_CADDY" >/dev/null; RW_PAUSED_CADDY=; fi
    tar -C "$build" -czf "$archive" .; chmod 600 "$archive"; tar -tzf "$archive" >/dev/null
    sha256sum "$archive" > "$archive.sha256"; chmod 600 "$archive.sha256"
    rw_info "Backup проверен: $archive. До рабочего переключения скопируйте его вне VPS."
}
rw_node_attach() {
    local host=${RW_SSH:-} config=${RW_NODE_CONFIG:-} env remote
    [[ $RW_ROLE != node && $host =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*$ && -f $config ]] || rw_die 'node attach: нужны --ssh USER@HOST и --node-config FILE на стороне панели.'
    rw_owned; rw_verify_files; rw_ssh_idle; rw_lock
    rw_wait_panel; rw_panel_login
    jq -ef "$RW_TMP/config.jq" "$config" > "$RW_TMP/node-config.json"
    [[ $(jq -r '.role' "$RW_TMP/node-config.json") == node ]] || rw_die 'Ожидается config роли node.'
    env=$(jq -r '.environment_id' "$RW_TMP/node-config.json"); remote=/opt/pdm-remnawave/$env
    local -a ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
    local remote_uid prefix=
    remote_uid=$(ssh "${ssh_options[@]}" "$host" 'id -u')
    [[ $remote_uid =~ ^[0-9]+$ ]] || rw_die 'Не подтверждён UID SSH-пользователя.'
    if [[ $remote_uid != 0 ]]; then prefix='sudo -n '; ssh "${ssh_options[@]}" "$host" 'sudo -n true'; fi
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' preflight --config '$remote/config.json' --output '$remote'"
    local local_fp remote_fp
    local_fp=$(jq -Sc . "$RW_TMP/node-config.json" | sha256sum | cut -d' ' -f1)
    remote_fp=$(ssh "${ssh_options[@]}" "$host" "${prefix}jq -r .config_fingerprint '$remote/manifest.json'")
    [[ $local_fp == "$remote_fp" ]] || rw_die 'Локальные параметры ноды не совпадают с подготовленным SSH-хостом.'
    ssh "${ssh_options[@]}" "$host" "${prefix}cat '$remote/private/xray-profile.json'" > "$RW_TMP/remote-profile.json"
    RW_MUTATING=1
    rw_register_node "$RW_TMP/node-config.json" "$RW_TMP/connection.json" "$(jq -r '.management_address' "$RW_TMP/node-config.json")" "$RW_TMP/remote-profile.json"
    ssh "${ssh_options[@]}" "$host" "${prefix}bash '$remote/rwctl' node receive --output '$remote'" < "$RW_TMP/connection.json"
    local uuid attempt
    uuid=$(jq -er '.node_uuid' "$RW_TMP/connection.json")
    for ((attempt=0; attempt<30; attempt++)); do
        rw_api GET "/api/nodes/$uuid" '' "$RW_TMP/attached-node.json" && jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/attached-node.json" >/dev/null && break
        sleep 2
    done
    jq -e '.response.isConnected==true and .response.isDisabled==false and .response.xrayUptime>0' "$RW_TMP/attached-node.json" >/dev/null || rw_die 'Панель не подтвердила подключение ноды и работающий Xray.'
    rw_info 'Нода подключена; выдача доступа существующим пользователям не выполнялась.'
}
rw_node_receive() {
    rw_root; rw_owned
    [[ $RW_ROLE == node ]] || rw_die 'node receive предназначен для отдельной ноды.'
    rw_lock; RW_MUTATING=1
    cat > "$RW_TMP/received-connection.json"
    RW_CONNECTION=$RW_TMP/received-connection.json
    rw_apply; rw_track_files
}
# shellcheck shell=bash
rw_archive_check() {
    local archive=$1 names=$RW_TMP/tar-names types=$RW_TMP/tar-types path normalized size free
    [[ -f $archive && ! -L $archive ]] || rw_die 'Архив должен быть обычным файлом.'
    tar --absolute-names -tzf "$archive" > "$names" || rw_die 'Архив повреждён.'
    tar --absolute-names -tvzf "$archive" > "$types" || rw_die 'Не удалось проверить типы записей архива.'
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' "$types" || rw_die 'Ссылки и специальные файлы в архиве запрещены.'
    : > "$RW_TMP/tar-normalized"
    while IFS= read -r path; do
        [[ $path =~ ^[A-Za-z0-9_./@+:-]+$ && $path != /* && $path != *$'\r'* ]] || rw_die 'Небезопасное имя в архиве.'
        normalized=$path
        while [[ $normalized == ./* ]]; do normalized=${normalized#./}; done
        normalized=${normalized%/}
        [[ $normalized != .. && $normalized != ../* && $normalized != */../* && $normalized != */.. ]] || rw_die 'Выход из каталога в архиве.'
        [[ $normalized != *//* && $normalized != */./* && $normalized != */. ]] || rw_die 'Неоднозначный путь в архиве.'
        printf '%s\n' "$normalized" >> "$RW_TMP/tar-normalized"
    done < "$names"
    [[ -z $(LC_ALL=C sort "$RW_TMP/tar-normalized" | uniq -d) ]] || rw_die 'Повторяющиеся пути в архиве.'
    size=$(awk '{sum+=$3} END {printf "%.0f",sum}' "$types")
    free=$(df -PB1 "$RW_TMP" | awk 'NR==2 {print $4}')
    (( free > size + 134217728 )) || rw_die 'Недостаточно места для распаковки архива.'
}
rw_versions_check() {
    jq -e '
      .schema_version==1 and (.components|keys)==["caddy_auth","node","panel","postgres","subscription","valkey"] and
      ([.components|to_entries[]|(.key as $key|.value.image|type=="string" and test(
        (if $key=="panel" then "^remnawave/backend" elif $key=="node" then "^remnawave/node"
         elif $key=="postgres" then "^(library/)?postgres" elif $key=="valkey" then "^valkey/valkey"
         elif $key=="caddy_auth" then "^remnawave/caddy-with-auth" else "^remnawave/subscription-page" end)+"@sha256:[a-f0-9]{64}$"))]|all) and
      (.components.postgres.source_tag|type=="string" and test("^[0-9]+\\.[0-9]+$"))' "$1" >/dev/null || rw_die 'Нужны закреплённые digest официальных образов и версия PostgreSQL.'
}
rw_backup_open() {
    local archive=$1 expected path sum source
    [[ -f $archive && ! -L $archive ]] || rw_die 'Backup должен быть обычным файлом, не ссылкой.'
    archive=$(realpath -e -- "$archive")
    [[ -f $archive.sha256 && ! -L $archive.sha256 ]] || rw_die 'Рядом с backup нужен файл .sha256.'
    expected=$(awk 'NR==1 {print $1}' "$archive.sha256")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ && $(wc -l < "$archive.sha256") == 1 ]] || rw_die 'Некорректный checksum backup.'
    [[ $(sha256sum "$archive" | cut -d' ' -f1) == "${expected,,}" ]] || rw_die 'Checksum backup не совпадает.'
    rw_archive_check "$archive"
    RW_BACKUP=$(mktemp -d "$RW_TMP/recovery.XXXXXX")
    tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$RW_BACKUP"
    source=$RW_BACKUP/installation
    [[ -f $source/config.json && -f $source/manifest.json && -f $source/private/secrets.json ]] || rw_die 'Backup не содержит установку.'
    jq -e '.schema_version==2 and .implementation=="bash-docker" and (.managed_files|type=="array")' "$source/manifest.json" >/dev/null || rw_die 'Несовместимый manifest backup.'
    while IFS=$'\t' read -r path sum; do
        [[ $path =~ ^[A-Za-z0-9_./-]+$ && $path != /* && $path != *'..'* && $sum =~ ^[a-f0-9]{64}$ ]] || rw_die 'Небезопасный manifest backup.'
        [[ -f $source/$path && $(sha256sum "$source/$path" | cut -d' ' -f1) == "$sum" ]] || rw_die "Повреждён файл backup: $path"
    done < <(jq -r '.managed_files[]|[.path,.sha256]|@tsv' "$source/manifest.json")
    rw_versions_check "$source/versions.lock.json"
    jq -e '
      ([.app_secret,.postgres_password,.metrics_password,.webhook_secret,.auth_password]|all(type=="string" and test("^[a-f0-9]{64}$"))) and
      (.admin_password|type=="string" and test("^Aa1[a-f0-9]{64}$")) and
      ([.reality_private,.reality_public]|all(type=="string" and test("^[A-Za-z0-9_-]{43}$"))) and
      (.short_id|test("^[a-f0-9]{16}$")) and (.xhttp_path|test("^/[a-f0-9]{32}$"))' "$source/private/secrets.json" >/dev/null || rw_die 'Несовместимые секреты backup.'
    for path in caddy_data caddy_config; do rw_archive_check "$RW_BACKUP/$path.tgz"; done
    if [[ $(jq -r '.role' "$source/config.json") != panel ]]; then
        grep -vEx 'NODE_PORT=[0-9]+|SECRET_KEY=[A-Za-z0-9+/=_-]+' "$source/private/node.env" > "$RW_TMP/bad-node-env" || true
        [[ ! -s $RW_TMP/bad-node-env && $(grep -c '^NODE_PORT=' "$source/private/node.env") == 1 && $(grep -c '^SECRET_KEY=' "$source/private/node.env") -le 1 ]] || rw_die 'Некорректный node.env в backup.'
        [[ $(sed -n 's/^NODE_PORT=//p' "$source/private/node.env") == $(jq -r '.ports.node_api' "$source/config.json") ]] || rw_die 'Порт node.env не совпадает с config.'
    fi
    RW_BACKUP_SHA=${expected,,}
}
rw_restore_config() {
    local requested=${RW_CONFIG:-} source=$RW_BACKUP/installation normalized
    rw_config_filter > "$RW_TMP/config.jq"
    jq -ef "$RW_TMP/config.jq" "$source/config.json" > "$RW_TMP/source-config.json" || rw_die 'Некорректный config backup.'
    if [[ -n $requested ]]; then
        jq -ef "$RW_TMP/config.jq" "$requested" > "$RW_TMP/target-config.json" || rw_die 'Некорректный config восстановления.'
        # IP/DNS ownership and the existing proxy may differ on a replacement host.
        for normalized in source target; do jq 'del(.public_addresses,.panel_addresses,.existing_caddy)' "$RW_TMP/$normalized-config.json" > "$RW_TMP/$normalized-comparable.json"; done
        cmp -s "$RW_TMP/source-comparable.json" "$RW_TMP/target-comparable.json" || rw_die 'При restore сохраняйте ID, роль, домены, порты и subnet; можно изменить только адреса и existing_caddy.'
    else requested=$RW_TMP/source-config.json; fi
    rw_config_load "$requested"
    [[ $(jq -r '.environment_id' "$source/manifest.json") == "$RW_ENV" ]] || rw_die 'ID backup не совпадает с config.'
}
rw_restore_files() {
    local source=$RW_BACKUP/installation path
    if [[ -f $RW_OUT/manifest.json ]]; then
        rw_owned
        jq -e --arg sha "$RW_BACKUP_SHA" '.status=="restoring" and .restore_archive_sha256==$sha' "$RW_OUT/manifest.json" >/dev/null || rw_die 'Restore предназначен для пустой установки; существующую систему не перезаписываем.'
    else [[ ! -d $RW_OUT || -z $(find "$RW_OUT" -mindepth 1 -maxdepth 1 -print -quit) ]] || rw_die 'Каталог восстановления не пуст.'; fi
    rw_lock; RW_MUTATING=1
    while IFS= read -r path; do
        [[ $path != rwctl && $path != compose.json && $path != config.json && $path != private/.managed-paths && $path != private/ssh-* ]] || continue
        cat "$source/$path" | rw_atomic "$RW_OUT/$path"
    done < <(jq -r '.managed_files[].path' "$source/manifest.json")
    # Never execute archived shell code or trust an archived Compose with host mounts.
    jq --arg owner "$RW_OWNER" --arg fp "$RW_FINGERPRINT" --arg sha "$RW_BACKUP_SHA" \
      '.api_namespace_owner //= .ownership_label | .ownership_label=$owner | .config_fingerprint=$fp | .status="restoring" | .restore_archive_sha256=$sha | .firewall_installed=false | .ufw_rules_added=false | .existing_caddy_updated=false | .managed_files=[] | del(.ssh)' "$source/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
    cat "$RW_CFG" | rw_atomic "$RW_OUT/config.json"
    if [[ $RW_ROLE != node ]]; then
        local token=$source/private/subscription.token
        [[ -s $token ]] && grep -qxE '[A-Za-z0-9._=+/-]+' "$token" || rw_die 'Нет проверенного API-токена подписок в backup.'
        { printf 'APP_PORT=3010\nREMNAWAVE_PANEL_URL=http://rw_panel:3000\nREMNAWAVE_API_TOKEN='; cat "$token"; printf '\nTRUST_PROXY=1\n'; } | rw_atomic "$RW_OUT/private/subscription.env"
    fi
    rw_render_compose; rw_render_env; rw_render_caddy; rw_install_ctl
    rw_track_files
}
rw_stop_writers() {
    local -a services=()
    mapfile -t services < <(jq -r '.services|keys[]|select(.!="rw_db" and .!="rw_valkey")' "$RW_OUT/compose.json")
    rw_compose --profile public --profile node stop "${services[@]}" || rw_die 'Не удалось остановить пишущие сервисы.'
}
rw_restore_data() {
    local backup=$1 name image volume
    rw_docker_ownership
    rw_compose --profile public --profile node create || rw_die 'Не удалось создать контейнеры восстановления.'
    image=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    for name in caddy_data caddy_config; do
        volume=${RW_PROJECT}_$name
        [[ $(docker volume inspect "$volume" --format '{{index .Labels "io.pdm.remnawave.installation"}}') == "$RW_OWNER" ]] || rw_die 'Чужой volume восстановления.'
        rw_archive_check "$backup/$name.tgz"
        # Only this validated, stopped volume is replaced; no host paths are mounted.
        docker run --rm --network none --cap-drop ALL --entrypoint sh --mount "type=volume,src=$volume,dst=/data" "$image" -c 'find /data -mindepth 1 -delete' || rw_die 'Не удалось очистить собственный Caddy volume.'
        docker run --rm -i --network none --cap-drop ALL --entrypoint tar --mount "type=volume,src=$volume,dst=/data" "$image" -C /data --no-same-owner --no-same-permissions -xzf - < "$backup/$name.tgz" || rw_die 'Не удалось восстановить Caddy volume.'
    done
    if [[ $RW_ROLE != node ]]; then
        [[ -s $backup/database.dump ]] || rw_die 'Нет dump PostgreSQL.'
        rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey || rw_die 'База/кеш восстановления не запустились.'
        rw_compose exec -T rw_db pg_restore --list < "$backup/database.dump" >/dev/null || rw_die 'Невалидный PostgreSQL dump.'
        # pg_restore --clean alone leaves objects introduced by a failed migration.
        # Writers are stopped; replace only this installation's database completely.
        rw_compose exec -T rw_db dropdb --if-exists --force -U postgres remnawave || rw_die 'Не удалось пересоздать собственную БД.'
        rw_compose exec -T rw_db createdb -U postgres -T template0 remnawave || rw_die 'Не удалось создать БД восстановления.'
        rw_compose exec -T rw_db pg_restore --exit-on-error --single-transaction -U postgres -d remnawave < "$backup/database.dump" || rw_die 'Восстановление PostgreSQL не завершилось.'
    fi
}
rw_start_existing() {
    if [[ $RW_ROLE != node ]]; then rw_compose up -d --wait --wait-timeout 180 rw_db rw_valkey rw_panel || rw_die 'Панель не прошла запуск.'; rw_wait_panel; rw_panel_login; fi
    rw_compose --profile public up -d rw_caddy || rw_die 'Caddy не запустился.'
    if [[ $RW_ROLE != node ]]; then rw_compose --profile public up -d rw_subscription || rw_die 'Подписки не запустились.'; fi
    if [[ $RW_ROLE != panel ]] && grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; then rw_compose --profile node up -d rw_node || rw_die 'Нода не запустилась.'; fi
    rw_doctor
}
rw_restore() {
    [[ -n ${RW_ARCHIVE:-} ]] || rw_die 'restore требует --archive FILE.'
    rw_backup_open "$RW_ARCHIVE"; rw_restore_config
    if (( RW_DRY_RUN )); then
        jq -n --arg e "$RW_ENV" --arg dir "$RW_OUT" --arg sha "$RW_BACKUP_SHA" '{environment_id:$e,directory:$dir,archive_sha256:$sha,archive_verified:true,read_only:true}'; return
    fi
    rw_root; rw_os; rw_deps; rw_docker_install; rw_preflight
    rw_restore_files
    rw_compose --profile public --profile node pull
    rw_stop_writers; rw_restore_data "$RW_BACKUP"
    rw_firewall; rw_existing_caddy_apply
    rw_start_existing
    rw_manifest_set '.status="running-awaiting-acceptance"|.restored_at_utc=(now|strftime("%Y-%m-%dT%H:%M:%SZ"))'
    rw_track_files
    rw_info 'Restore завершён: ключи, API ID, база, MFA и сертификаты сохранены.'
}
# shellcheck shell=bash
rw_upgrade_candidate() {
    local file=${RW_VERSION_FILE:-} old_major new_major
    if [[ -n $file ]]; then cat "$file" > "$RW_TMP/upgrade-versions.json"; else rw_versions > "$RW_TMP/upgrade-versions.json"; fi
    rw_versions_check "$RW_TMP/upgrade-versions.json"
    old_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json")
    new_major=$(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_TMP/upgrade-versions.json")
    [[ $old_major == "$new_major" ]] || rw_die 'Смена major PostgreSQL требует отдельного переноса данных.'
    jq -e --slurpfile old "$RW_OUT/versions.lock.json" '(.components.postgres.source_tag|split(".")|map(tonumber)) >= ($old[0].components.postgres.source_tag|split(".")|map(tonumber))' "$RW_TMP/upgrade-versions.json" >/dev/null || rw_die 'Понижение PostgreSQL выполняется восстановлением backup, а не upgrade.'
    jq --arg e "$RW_ENV" '.environment_id=$e' "$RW_TMP/upgrade-versions.json" > "$RW_TMP/upgrade-lock.json"
    rw_render_compose "$RW_TMP/upgrade-compose.json" "$RW_TMP/upgrade-lock.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node config --quiet || rw_die 'Некорректный Compose обновления.'
}
rw_upgrade_activate() {
    cat "$RW_TMP/upgrade-lock.json" | rw_atomic "$RW_OUT/versions.lock.json" || rw_die 'Не удалось записать lock обновления.'
    cat "$RW_TMP/upgrade-compose.json" | rw_atomic "$RW_OUT/compose.json" || rw_die 'Не удалось записать Compose обновления.'
    rw_manifest_set '.status="upgrading"'
    rw_track_files
    rw_start_existing
}
rw_upgrade_rollback() {
    local source=$RW_UPGRADE_SOURCE path
    rw_stop_writers
    while IFS= read -r path; do
        [[ $path != rwctl && $path != private/.managed-paths ]] || continue
        cat "$source/$path" | rw_atomic "$RW_OUT/$path" || rw_die 'Не удалось вернуть файл отката.'
    done < <(jq -r '.managed_files[].path' "$source/manifest.json")
    cat "$source/manifest.json" | rw_atomic "$RW_OUT/manifest.json"
    rw_restore_data "${source%/installation}"
    rw_start_existing
    rw_install_ctl
    rw_manifest_set '.status="running-awaiting-acceptance"|.last_upgrade="rolled-back"'
    jq -n --arg archive "$RW_UPGRADE_ARCHIVE" '{status:"rolled-back",backup:$archive}' | rw_atomic "$RW_OUT/private/upgrade.json"
    rw_track_files
}
rw_upgrade_abort() {
    RW_UPGRADE_PENDING=0
    if (rw_upgrade_rollback > "$RW_TMP/rollback.log" 2>&1); then
        rw_info 'Обновление не прошло: прежние версии, БД и Caddy восстановлены из backup.'
    else
        cat "$RW_TMP/rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_info "Автоматический откат не завершён. Backup: $RW_UPGRADE_ARCHIVE; диагностика: private/rollback-error.log."
        return 1
    fi
}
rw_upgrade() {
    rw_owned; rw_verify_files; rw_ssh_idle; rw_versions_check "$RW_OUT/versions.lock.json"
    rw_upgrade_candidate
    if (( RW_DRY_RUN )); then
        jq -n --slurpfile old "$RW_OUT/versions.lock.json" --slurpfile new "$RW_TMP/upgrade-lock.json" '{before:($old[0].components|map_values(.image)),after:($new[0].components|map_values(.image)),backup_required:true,rollback_includes_database:true,read_only:true}'; return
    fi
    rw_root; rw_os; rw_docker_ownership; rw_resource_checks; rw_lock
    if [[ $RW_ROLE != node && $(jq -r '.components.panel.image' "$RW_OUT/versions.lock.json") != $(jq -r '.components.panel.image' "$RW_TMP/upgrade-lock.json") ]]; then
        [[ $(rw_compose exec -T rw_db psql -At -U postgres -d remnawave -c "SELECT EXISTS(SELECT FROM information_schema.schemata WHERE schema_name='pdm_stats')") == f ]] || rw_die 'Для обновления панели с pdm_stats нужна проверенная миграция статистики.'
    fi
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/upgrade-compose.json" --profile public --profile node pull || rw_die 'Образы обновления не загружены; текущие сервисы не остановлены.'
    # Validate against isolated Caddy stores; a candidate cannot migrate live MFA state before backup.
    local validation
    validation=$(mktemp -d "$RW_TMP/validation.XXXXXX")
    mkdir "$validation/data" "$validation/config" || rw_die 'Не удалось создать изолированное хранилище проверки.'
    jq --arg data "$validation/data" --arg config "$validation/config" '.services.rw_caddy.network_mode="none" | .services.rw_caddy.volumes|=map(if startswith("caddy_data:") then $data+":/data" elif startswith("caddy_config:") then $config+":/config" else . end)' "$RW_TMP/upgrade-compose.json" > "$RW_TMP/validate-compose.json"
    docker compose --project-directory "$RW_OUT" --project-name "$RW_PROJECT" -f "$RW_TMP/validate-compose.json" --profile public run --rm --no-deps --entrypoint caddy rw_caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$RW_TMP/candidate-validation.log" 2>&1 || rw_die 'Caddy-кандидат не прошёл проверку; текущий стек не остановлен.'
    RW_MUTATING=1
    # Freeze writers for a rollback point that does not discard concurrent user edits.
    rw_stop_writers
    RW_UPGRADE_ARCHIVE=${RW_ARCHIVE:-/var/backups/pdm-remnawave/$RW_ENV-pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).tgz}
    RW_ARCHIVE=$RW_UPGRADE_ARCHIVE
    if ! (rw_backup > "$RW_TMP/upgrade-backup.log" 2>&1); then
        (rw_start_existing) || true
        rw_die 'Backup обновления не создан; запуск прежнего стека выполнен повторно.'
    fi
    rw_backup_open "$RW_UPGRADE_ARCHIVE"
    RW_UPGRADE_SOURCE=$RW_BACKUP/installation
    RW_UPGRADE_PENDING=1
    if (rw_upgrade_activate > "$RW_TMP/upgrade-activate.log" 2>&1); then
        RW_UPGRADE_PENDING=0
        rw_manifest_set '.status="running-awaiting-acceptance"|.last_upgrade="verified"'
        rw_install_ctl
        jq -n --arg archive "$RW_UPGRADE_ARCHIVE" '{status:"verified",backup:$archive}' | rw_atomic "$RW_OUT/private/upgrade.json"
        rw_track_files
        rw_info "Обновление проверено. Backup для отката: $RW_UPGRADE_ARCHIVE"
    else
        cat "$RW_TMP/upgrade-activate.log" | rw_atomic "$RW_OUT/private/upgrade-error.log"
        rw_upgrade_abort
        rw_die 'Кандидат не прошёл приёмку; выполнен откат.'
    fi
}
rw_rollback() {
    [[ -n ${RW_ARCHIVE:-} ]] || rw_die 'rollback требует --archive FILE.'
    rw_owned; rw_verify_files
    rw_backup_open "$RW_ARCHIVE"
    local source=$RW_BACKUP/installation destination=$RW_OUT archive=$RW_ARCHIVE safety
    jq -e --arg owner "$RW_OWNER" --arg env "$RW_ENV" '.ownership_label==$owner and .environment_id==$env' "$source/manifest.json" >/dev/null || rw_die 'Backup отката принадлежит другой установке.'
    jq -Sc . "$RW_CFG" > "$RW_TMP/rollback-current-config.json"
    jq -Sc . "$source/config.json" > "$RW_TMP/rollback-source-config.json"
    cmp -s "$RW_TMP/rollback-current-config.json" "$RW_TMP/rollback-source-config.json" || rw_die 'Config backup отката не совпадает с установкой.'
    [[ $(jq -r '.components.postgres.source_tag|split(".")[0]' "$source/versions.lock.json") == $(jq -r '.components.postgres.source_tag|split(".")[0]' "$RW_OUT/versions.lock.json") ]] || rw_die 'Major PostgreSQL в backup отката не совпадает.'
    if (( RW_DRY_RUN )); then jq -n --arg archive "$archive" '{backup:$archive,database_replaced:true,safety_backup_required:true,read_only:true}'; return; fi
    rw_root; rw_os; rw_docker_ownership; rw_lock
    rw_stop_writers
    safety=/var/backups/pdm-remnawave/$RW_ENV-pre-rollback-$(date -u +%Y%m%dT%H%M%SZ).tgz
    RW_ARCHIVE=$safety
    if ! (rw_backup); then (rw_start_existing) || true; rw_die 'Снимок перед откатом не создан.'; fi
    RW_OUT=$destination; RW_UPGRADE_SOURCE=$source; RW_UPGRADE_ARCHIVE=$archive
    RW_MUTATING=1
    if (rw_upgrade_rollback > "$RW_TMP/manual-rollback.log" 2>&1); then
        rw_info "Откат проверен. Снимок состояния перед откатом: $safety"
    else
        cat "$RW_TMP/manual-rollback.log" | rw_atomic "$RW_OUT/private/rollback-error.log"
        rw_manifest_set '.status="rollback-needs-attention"'
        rw_die "Откат не завершён. Снимок до операции: $safety"
    fi
}
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
# shellcheck shell=bash
rw_tls_cleanup() {
    local id=${RW_TLS_CONTAINER:-}
    if [[ -n $id ]] && docker inspect "$id" >/dev/null 2>&1; then
        [[ $(docker inspect --format '{{index .Config.Labels "io.pdm.remnawave.tls-test"}}' "$id") == "$RW_OWNER" ]] || rw_die 'Чужой контейнер проверки TLS.'
        docker rm -f "$id" >/dev/null
    fi
    RW_TLS_CONTAINER=
}
rw_tls_restore_proxy() {
    [[ ${RW_TLS_PROXY_PENDING:-0} == 1 ]] || return 0
    cat "$RW_OUT/private/tls-caddy.before" > "$RW_OUT/Caddyfile"
    docker exec "$RW_TLS_MAIN_CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || rw_die 'Не удалось вернуть HTTP config после TLS test.'
    RW_TLS_PROXY_PENDING=0
}
rw_tls_forward_challenge() {
    local candidate=$RW_TMP/tls-caddy.proxy domain site
    cat "$RW_OUT/Caddyfile" | rw_atomic "$RW_OUT/private/tls-caddy.before"
    cat "$RW_OUT/Caddyfile" > "$candidate"
    while IFS= read -r domain; do
        site="http://$domain:$(rw_port http) {"
        awk -v site="$site" -v port="$RW_TLS_HTTP" '
          $0==site {active=1}
          active && $1=="redir" {
            if(NF!=3) exit 42;
            print "\t@pdm_tls_redirect not path /.well-known/acme-challenge/*";
            print "\thandle /.well-known/acme-challenge/* {";
            print "\t\treverse_proxy 127.0.0.1:" port;
            print "\t}";
            print "\tredir @pdm_tls_redirect " $2 " " $3;
            changed++; next
          }
          active && $0=="}" {active=0}
          {print}
          END {if(changed!=1) exit 42}' "$candidate" > "$RW_TMP/tls-caddy.site" || rw_die 'Не удалось подготовить HTTP challenge route.'
        cat "$RW_TMP/tls-caddy.site" > "$candidate"
    done < <(jq -r '.domains|[.[]]|unique[]' "$RW_CFG")
    RW_TLS_MAIN_CADDY=$(rw_compose --profile public ps -q rw_caddy)
    docker cp "$candidate" "$RW_TLS_MAIN_CADDY:/tmp/pdm-tls-test.Caddyfile"
    docker exec "$RW_TLS_MAIN_CADDY" caddy validate --config /tmp/pdm-tls-test.Caddyfile --adapter caddyfile > "$RW_TMP/tls-forward-check.log" 2>&1 || rw_die 'HTTP challenge route не прошёл проверку.'
    RW_TLS_PROXY_PENDING=1
    cat "$candidate" > "$RW_OUT/Caddyfile"
    docker exec "$RW_TLS_MAIN_CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || rw_die 'HTTP challenge route не применён.'
}
rw_tls_get_certificate() {
    local domain=$1 output=$2 attempt
    for attempt in {1..90}; do
        { openssl s_client -connect "127.0.0.1:$RW_TLS_HTTPS" -servername "$domain" </dev/null 2>/dev/null || true; } | openssl x509 -outform PEM > "$output" 2>/dev/null || true
        if [[ -s $output ]] && openssl x509 -in "$output" -noout -issuer | grep -qi staging; then
            openssl x509 -in "$output" -noout -checkhost "$domain" >/dev/null || rw_die 'SNI staging-сертификата не совпал.'
            return 0
        fi
        sleep 2
    done
    docker logs "$RW_TLS_CONTAINER" > "$RW_OUT/private/tls-test-error.log" 2>&1
    chmod 600 "$RW_OUT/private/tls-test-error.log"
    rw_die 'Staging-сертификат не получен; диагностика private/tls-test-error.log.'
}
rw_tls_launch() {
    RW_TLS_CONTAINER=$(docker run -d --rm --network host --memory 96m --memory-swap 96m --cpus 0.5 \
      --label "io.pdm.remnawave.tls-test=$RW_OWNER" --mount "type=volume,src=${RW_PROJECT}_caddy_data,dst=/data" \
      --mount "type=bind,src=$RW_TMP/tls-test.Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
      --mount "type=bind,src=$RW_TMP/tls-config,dst=/config" --entrypoint caddy "$RW_TLS_IMAGE" run --config /etc/caddy/Caddyfile --adapter caddyfile)
}
rw_tls_test() {
    rw_owned; rw_verify_files
    RW_TLS_HTTP=${RW_TLS_HTTP:-18082}; RW_TLS_HTTPS=${RW_TLS_HTTPS:-19447}
    [[ $RW_TLS_HTTP =~ ^[0-9]+$ && $RW_TLS_HTTPS =~ ^[0-9]+$ ]] && (( RW_TLS_HTTP>=1024 && RW_TLS_HTTP<=65535 && RW_TLS_HTTPS>=1024 && RW_TLS_HTTPS<=65535 && RW_TLS_HTTP!=RW_TLS_HTTPS )) || rw_die 'TLS test ports: разные числа 1024..65535.'
    if (( RW_DRY_RUN )); then jq '.domains|[.[]]|unique|{domains:.,staging_only:true,shared_http_challenge_storage:true,read_only:true}' "$RW_CFG"; return; fi
    rw_root; rw_os; rw_lock; rw_docker_ownership; rw_ssh_idle
    [[ -n $(rw_compose --profile public ps -q rw_caddy) ]] || rw_die 'Для TLS test нужен работающий основной Caddy.'
    [[ -z $(ss -H -lnt "sport = :$RW_TLS_HTTP") && -z $(ss -H -lnt "sport = :$RW_TLS_HTTPS") ]] || rw_die 'Порты TLS test заняты.'
    [[ $(docker volume inspect "${RW_PROJECT}_caddy_data" --format '{{index .Labels "io.pdm.remnawave.installation"}}') == "$RW_OWNER" ]] || rw_die 'Caddy storage принадлежит другой установке.'
    RW_TLS_IMAGE=$(jq -r '.components.caddy_auth.image' "$RW_OUT/versions.lock.json")
    mkdir "$RW_TMP/tls-config"
    {
        printf '{\n admin off\n http_port %s\n auto_https disable_redirects\n cert_issuer acme {\n  dir https://acme-staging-v02.api.letsencrypt.org/directory\n  disable_tlsalpn_challenge\n }\n}\n' "$RW_TLS_HTTP"
        while IFS= read -r domain; do printf 'https://%s:%s {\n bind 127.0.0.1\n respond 204\n}\n' "$domain" "$RW_TLS_HTTPS"; done < <(jq -r '.domains|[.[]]|unique[]' "$RW_CFG")
    } > "$RW_TMP/tls-test.Caddyfile"
    RW_MUTATING=1
    rw_tls_forward_challenge
    rw_tls_launch
    local domain first second root=/data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory
    : > "$RW_TMP/tls-results.jsonl"
    while IFS= read -r domain; do
        rw_tls_get_certificate "$domain" "$RW_TMP/$domain.first.pem"
        first=$(openssl x509 -in "$RW_TMP/$domain.first.pem" -noout -serial)
        rw_tls_cleanup
        # Replace only staging certificates. Production certs, MFA and config are not touched.
        docker run --rm --network none --cap-drop ALL --entrypoint sh --mount "type=volume,src=${RW_PROJECT}_caddy_data,dst=/data" "$RW_TLS_IMAGE" \
          -c 'test "$1" = /data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory && rm -f -- "$1/$2/$2.crt" "$1/$2/$2.key" "$1/$2/$2.json"' sh "$root" "$domain"
        rw_tls_launch
        rw_tls_get_certificate "$domain" "$RW_TMP/$domain.second.pem"
        second=$(openssl x509 -in "$RW_TMP/$domain.second.pem" -noout -serial)
        [[ $first != "$second" ]] || rw_die 'Staging-сертификат не перевыпущен.'
        jq -nc --arg domain "$domain" --arg before "$first" --arg after "$second" '{domain:$domain,staging_reissue:true,serial_before:$before,serial_after:$after}' >> "$RW_TMP/tls-results.jsonl"
    done < <(jq -r '.domains|[.[]]|unique[]' "$RW_CFG")
    rw_tls_cleanup
    rw_tls_restore_proxy
    jq -s '{checked_at_utc:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),staging_only:true,production_storage_kept:true,domains:.}' "$RW_TMP/tls-results.jsonl" | rw_atomic "$RW_OUT/private/tls-test.json"
    rw_track_files
    cat "$RW_OUT/private/tls-test.json"
}
# shellcheck shell=bash
rw_interactive() {
    local role=${RW_ROLE_ARG:-} env mode panel='' sub='' node='' ips sources='' user='' email=''
    if [[ -z $role ]]; then
        printf '\nRemnawave: 1) панель  2) отдельная нода  3) панель и нода\n' >&2
        read -r -p 'Режим [3]: ' role; case ${role:-3} in 1) role=panel;; 2) role=node;; 3) role='panel-node';; *) rw_die 'Неверный режим.';; esac
    fi
    read -r -p 'ID окружения (например fi-test): ' env
    read -r -p 'Режим сети clean / fi-parallel [clean]: ' mode; mode=${mode:-clean}
    if [[ $role != node ]]; then read -r -p 'Домен панели: ' panel; read -r -p 'Домен подписок: ' sub; read -r -p 'Логин администратора: ' user; read -r -p 'Email администратора: ' email; fi
    if [[ $role != panel ]]; then read -r -p 'Домен ноды: ' node; fi
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
    RW_CONFIG=; RW_OUT=; RW_CONNECTION=; RW_DRY_RUN=0; RW_YES=0; RW_PURGE=0; RW_PREPARED_ONLY=0; RW_ROLE_ARG=; RW_ARCHIVE=; RW_SSH=; RW_NODE_CONFIG=; RW_VERSION_FILE=; RW_SSH_ADMIN=; RW_SSH_PUBLIC_KEY=; RW_SSH_NONCE=; RW_TLS_HTTP=; RW_TLS_HTTPS=
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
      uninstall) rw_uninstall;;
      *) rw_die "Неизвестная команда $command.";;
    esac
}

rw_main uninstall "$@"
