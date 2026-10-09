#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build() {
    local command=$1
    printf '%s\n' '#!/usr/bin/env bash' '# Generated from installer/bash by installer/build-entrypoints.sh.' 'set +x' 'set -euo pipefail' 'umask 077'
    printf '%s\n' 'rw_versions() {' "cat <<'RW_VERSIONS'"
    cat "$ROOT/installer/versions.candidate.json"
    printf '%s\n' 'RW_VERSIONS' '}' 'rw_auth_global() {' "cat <<'RW_AUTH_GLOBAL'"
    cat "$ROOT/installer/templates/auth-global.caddy"
    printf '%s\n' 'RW_AUTH_GLOBAL' '}' 'rw_config_filter() {' "cat <<'RW_CONFIG_JQ'"
    cat "$ROOT/installer/bash/config.jq"
    printf '%s\n' 'RW_CONFIG_JQ' '}'
    for spec in 'schema.sql:schema' 'panel-hook.cjs:hook' 'server.cjs:server' 'patch-panel.cjs:patcher'; do
        file=${spec%:*}; fn=${spec#*:}
        printf 'rw_stats_%s() {\n' "$fn"
        printf "cat <<'RW_STATS_PAYLOAD'\n"
        cat "$ROOT/stats/$file"
        printf '\nRW_STATS_PAYLOAD\n}\n'
    done
    for file in common render preflight deploy maintenance recovery upgrade stats ssh tls cli; do cat "$ROOT/installer/bash/$file.sh"; done
    printf '\nrw_main %s "$@"\n' "$command"
}
for spec in 'rw-setup.sh:setup' 'uninstall.sh:uninstall' 'rwctl:ctl'; do
    name=${spec%:*}; command=${spec#*:}
    if [[ ${1:-} == --check ]]; then
        build "$command" | cmp -s "$ROOT/$name" - || { printf 'Rebuild needed: %s\n' "$name" >&2; exit 1; }
    else
        build "$command" > "$ROOT/$name"; chmod 755 "$ROOT/$name"
        printf 'Built %s\n' "$name"
    fi
done
