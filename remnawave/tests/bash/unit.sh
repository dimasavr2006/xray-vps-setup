#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
TEST_ROOT=$(mktemp -d /tmp/pdm-rw-unit.XXXXXX)
trap '[[ $TEST_ROOT == /tmp/pdm-rw-unit.* ]] && rm -rf -- "$TEST_ROOT"' EXIT
RW_TMP=$TEST_ROOT/tmp; mkdir "$RW_TMP"
RW_MUTATING=0
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
fail_expected() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }
for mode in panel node panel-node fi-parallel; do
    RW_OUT=$TEST_ROOT/$mode; rw_config_load "$ROOT/installer/examples/$mode.json"
    cp "$RW_CFG" "$TEST_ROOT/normalized.json"
    rw_config_load "$TEST_ROOT/normalized.json"
    case $mode in panel) [[ $(rw_port https) == 443 && -z $(rw_port node_api) ]];; node) [[ -z $(rw_port https) && $(rw_port reality) == 443 ]];; panel-node) [[ $(rw_port https) == 9443 && $(rw_port reality) == 443 ]];; fi-parallel) [[ $(rw_port reality) == 24443 && $(rw_port xhttp) == 28443 ]];; esac
    passed "ports for $mode"
done
for domain in 'https://bad.example' 'bad.example:443' 'bad.example/abc' 'a.example"}' '127.0.0.1'; do
    jq --arg domain "$domain" '.domains.panel=$domain' "$ROOT/installer/examples/panel.json" > "$TEST_ROOT/bad.json"
    fail_expected rw_config_load "$TEST_ROOT/bad.json"
done
passed 'reject URL/path/JSON injection in domains'
jq '.api_token="DO_NOT_ACCEPT"' "$ROOT/installer/examples/panel.json" > "$TEST_ROOT/bad.json"
fail_expected rw_config_load "$TEST_ROOT/bad.json"; passed 'reject unknown/plaintext-secret config fields'
for port in 80 443 8443 37241 4123 53042; do
    jq --argjson port "$port" '.ports.reality=$port' "$ROOT/installer/examples/fi-parallel.json" > "$TEST_ROOT/bad.json"
    fail_expected rw_config_load "$TEST_ROOT/bad.json"
done
passed 'FI existing ports reserved'
jq '.ports.reality=9443' "$ROOT/installer/examples/panel-node.json" > "$TEST_ROOT/bad.json"
fail_expected rw_config_load "$TEST_ROOT/bad.json"; passed 'duplicate ports block configuration'
jq 'del(.panel_addresses)' "$ROOT/installer/examples/node.json" > "$TEST_ROOT/bad.json"
fail_expected rw_config_load "$TEST_ROOT/bad.json"; passed 'standalone node requires panel source allowlist'
RW_OUT=$TEST_ROOT/compact; rw_config_load "$ROOT/installer/examples/fi-compact-single-domain.json"
[[ $(rw_port https) == 9443 && $(rw_subscription_port) == 9444 ]]; passed 'shared hostname separates admin and public subscription ports'
jq '.resources.purpose="production" | .network_mode="clean"' "$ROOT/installer/examples/fi-compact-single-domain.json" > "$TEST_ROOT/bad.json"
fail_expected rw_config_load "$TEST_ROOT/bad.json"; passed 'compact limits cannot be used as a production profile'
rw_config_load "$ROOT/installer/examples/fi-compact-single-domain.json"
rw_manifest preparing; rw_render
jq -e '([.services[].mem_limit]|add)==1207959552 and all(.services[]; .memswap_limit==.mem_limit)' "$RW_OUT/compose.json" >/dev/null
passed 'compact hard limits total 1152 MiB and forbid container swap growth'
grep -q '^SUB_PUBLIC_DOMAIN=fi.example.com:9444$' "$RW_OUT/private/panel.env"
[[ $(grep -Fc 'http://fi.example.com:18080 {' "$RW_OUT/Caddyfile") == 1 ]]
passed 'shared hostname has one challenge listener and correct public subscription URL'
printf 'http://fi.example.com {\n\tbind 0.0.0.0\n\tredir https://fi.example.com{uri} permanent\n}\n' > "$TEST_ROOT/old.Caddyfile"
old_hash=$(sha256sum "$TEST_ROOT/old.Caddyfile")
rw_existing_caddy_candidate "$TEST_ROOT/old.Caddyfile" "$TEST_ROOT/new.Caddyfile"
[[ $old_hash == "$(sha256sum "$TEST_ROOT/old.Caddyfile")" && $(grep -Fc 'http://fi.example.com {' "$TEST_ROOT/new.Caddyfile") == 1 ]]
grep -q 'redir @pdm_rw_fi_test_redirect https://fi.example.com{uri} permanent' "$TEST_ROOT/new.Caddyfile"
passed 'ACME shares existing HTTP site while preserving its old redirect and source file'
printf 'http://fi.example.com {\n\treverse_proxy 127.0.0.1:9999\n}\n' > "$TEST_ROOT/old.Caddyfile"
fail_expected rw_existing_caddy_candidate "$TEST_ROOT/old.Caddyfile" "$TEST_ROOT/new.Caddyfile"
passed 'unrecognised existing HTTP layout blocks modification'
RW_OUT=$TEST_ROOT/fixture; rw_config_load "$ROOT/installer/examples/panel-node.json"
rw_lock; rw_manifest preparing; rw_render; rw_manifest_set '.status="prepared"'; rw_track_files
before=$(sha256sum "$RW_OUT/private/secrets.json" | cut -d' ' -f1)
rw_render; rw_track_files
[[ $before == $(sha256sum "$RW_OUT/private/secrets.json" | cut -d' ' -f1) ]]; passed 'repeat preserves all secrets'
jq -e '.admin_password|length>=24 and test("[A-Z]") and test("[a-z]") and test("[0-9]")' "$RW_OUT/private/secrets.json" >/dev/null
passed 'administrator password meets actual panel requirements'
! grep -q '^SECRET_KEY=' "$RW_OUT/private/node.env"; passed 'management SECRET_KEY is never fabricated'
jq -e '.services.rw_db.ports==null and .services.rw_valkey.ports==null and ([.services[]|.ports[]?]|all(startswith("127.0.0.1:")))' "$RW_OUT/compose.json" >/dev/null
passed 'database/cache private and all mapped APIs loopback-only'
jq -e '.services.rw_node.volumes==null and (.services.rw_node|has("privileged")|not) and .services.rw_panel.cap_add==null' "$RW_OUT/compose.json" >/dev/null
passed 'profile belongs to panel API; no privileged panel/node mounts'
jq -e '.inbounds|length==2 and (.[0].streamSettings.network=="tcp") and (.[1].streamSettings.network=="xhttp")' "$RW_OUT/private/xray-profile.json" >/dev/null
passed 'both Reality transports generated structurally with jq'
grep -q 'require mfa' "$RW_OUT/Caddyfile"; passed 'Caddy admin routes require MFA'
[[ $(stat -c %a "$RW_OUT/private") == 700 && $(stat -c %a "$RW_OUT/private/secrets.json") == 600 ]]; passed 'secret directory/file permissions'
rw_verify_files; passed 'manifest integrity verification'
printf 'operator backup\n' > "$RW_OUT/operator-backup.txt"
rw_track_files
! jq -e '.managed_files|any(.path=="operator-backup.txt")' "$RW_OUT/manifest.json" >/dev/null
passed 'operator files are never adopted into deletion manifest'
dig() { printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR\n'; if [[ $* == *' AAAA'* ]]; then printf 'name. 300 IN AAAA 2001:db8::99\n'; else printf 'name. 300 IN A 192.0.2.10\n'; fi; }
fail_expected rw_dns_checks; unset -f dig; passed 'unexpected AAAA blocks deployment'
dig() { printf ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL\n'; }
fail_expected rw_dns_checks; unset -f dig; passed 'DNS failure does not become an empty confirmed AAAA answer'
df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfixture 10737418240 5368709120 5368709120 50%% /\n'; }
docker() { [[ $1 == image && $2 == inspect ]]; }
rw_resource_checks; passed 'cached pinned images are not charged twice against free disk'
docker() { return 1; }
fail_expected rw_resource_checks; unset -f docker df; passed 'missing images retain the full download disk budget'
awk() {
    case "$*" in
      *MemTotal*) printf '8192\n';;
      *MemAvailable*) printf '128\n';;
      *) command awk "$@";;
    esac
}
df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfixture 21474836480 1073741824 20401094656 5%% /\n'; }
docker() { [[ $1 == image && $2 == inspect ]]; }
fail_expected rw_resource_checks
passed 'prepared manifest does not bypass available RAM admission'
docker() {
    if [[ $1 == ps ]]; then rw_memory_limits | jq -r 'keys[]'
    elif [[ $1 == inspect ]]; then
        jq -n --arg s "$2" --arg owner "$RW_OWNER" --arg cfg "$RW_OUT/compose.json" --argjson limits "$(rw_memory_limits)" '[{State:{Running:true},Config:{Labels:{"io.pdm.remnawave.installation":$owner,"com.docker.compose.project.config_files":$cfg,"com.docker.compose.service":$s}},HostConfig:{Memory:($limits[$s]*1048576)}}]'
    elif [[ $1 == image ]]; then return 0
    else return 1; fi
}
rw_resource_checks
unset -f awk docker df
passed 'running owned containers are credited against their existing RAM reservation'
(
    RW_TMP=$TEST_ROOT/production-node-tmp; mkdir "$RW_TMP"
    jq '.resources.purpose="production"' "$ROOT/installer/examples/node.json" > "$TEST_ROOT/production-node.json"
    RW_OUT=$TEST_ROOT/production-node; rw_config_load "$TEST_ROOT/production-node.json"
    awk() {
        case "$*" in *MemTotal*|*MemAvailable*) printf '1024\n';; *) command awk "$@";; esac
    }
    getconf() { printf '1\n'; }
    df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfixture 10000000000 2000000000 8000000000 20%% /\n'; }
    docker() { [[ $1 == image && $2 == inspect ]]; }
    rw_resource_checks
)
passed 'standalone production node uses node requirements, not combined panel RAM/disk minimum'
df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfixture 1000 999 1 99%% /\n'; }
fail_expected rw_resource_checks; unset -f df; passed 'low disk budget blocks before container launch'
ss() { printf 'LISTEN 0 128 [::]:9443 [::]:* users:(("foreign",pid=999999,fd=1))\n'; }
docker() { :; }
fail_expected rw_port_checks; unset -f ss docker; passed 'foreign IPv6 listener blocks deployment'
ss() { printf 'LISTEN 0 128 127.0.0.1:13000 0.0.0.0:* users:(("docker-proxy",pid=999999,fd=1))\n'; }
docker() {
    case $1 in
      ps) printf 'own-container\n';;
      top) printf 'PID\n12345\n';;
      inspect) if [[ $* == *'.NetworkSettings.Ports'* ]]; then printf '{"3000/tcp":[{"HostIp":"127.0.0.1","HostPort":"13000"}]}\n'; else printf '%s\n' "$RW_OWNER"; fi;;
    esac
}
rw_port_checks; passed 'own loopback docker-proxy publication permits repeated apply'
docker() {
    case $1 in
      ps) printf 'own-container\n';;
      top) printf 'PID\n12345\n';;
      inspect) printf '{"3000/tcp":[{"HostIp":"0.0.0.0","HostPort":"13000"}]}\n';;
    esac
}
fail_expected rw_port_checks; unset -f ss docker; passed 'own container cannot excuse a non-loopback publication'
docker() {
    if [[ $* == 'network ls -q' ]]; then printf 'deadbeef0000abcdef\n';
    elif [[ $* == *'--format'* ]]; then printf '%s\n' "$RW_OWNER";
    else printf '[{"Id":"deadbeef0000abcdef","Driver":"bridge","Options":{}}]\n'; fi
}
ip() { printf '[{"dst":"%s","dev":"br-deadbeef0000"}]\n' "$RW_SUBNET"; }
rw_network_check; passed 'own connected bridge route permits repeated apply'
ip() { printf '[{"dst":"%s","dev":"foreign-bridge"}]\n' "$RW_SUBNET"; }
fail_expected rw_network_check; unset -f ip docker; passed 'matching subnet on a foreign interface still blocks apply'
RW_PREPARED_ONLY=1; RW_PURGE=0; RW_DRY_RUN=1
rw_uninstall > "$TEST_ROOT/removal.json"
jq -e '.read_only==true' "$TEST_ROOT/removal.json" >/dev/null
[[ -f $RW_OUT/private/secrets.json ]]; passed 'uninstall preview makes no changes'
printf 'operator change\n' >> "$RW_OUT/Caddyfile"
fail_expected rw_verify_files; passed 'modified managed files are a conflict'
rw_render_caddy; rw_track_files
RW_DRY_RUN=0; RW_YES=1
rw_uninstall
[[ -f $RW_OUT/operator-backup.txt && ! -f $RW_OUT/private/secrets.json ]]; passed 'prepared uninstall deletes only owned files'
mkdir "$TEST_ROOT/fake-bin"
printf '#!/usr/bin/env bash\nprintf Darwin\\n\n' > "$TEST_ROOT/fake-bin/uname"; chmod 700 "$TEST_ROOT/fake-bin/uname"
fail_expected env "PATH=$TEST_ROOT/fake-bin:$PATH" bash "$ROOT/rw-setup.sh" --help
passed 'non-Linux rejected before installation'
! grep -qE 'python3?|base64 -d|payload\.zip' "$ROOT/rw-setup.sh"; passed 'entrypoint contains no Python invocation or embedded Python payload'
bash "$ROOT/installer/build-entrypoints.sh" --check; passed 'assembled Bash entrypoints are current'
printf '%s Bash checks passed.\n' "$count"
