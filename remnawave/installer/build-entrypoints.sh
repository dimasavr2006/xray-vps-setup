#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build() {
    local command=$1
    local -a modules=(common addresses site summary security render preflight deploy tokens maintenance recovery upgrade stats ssh tls mfa cli)
    printf '%s\n' '#!/usr/bin/env bash' '# Generated from installer/bash by installer/build-entrypoints.sh.'
    if [[ $command == uninstall ]]; then
        printf '%s\n' '# Shared modules also define setup-only variables/helpers; full entrypoints lint them.' '# shellcheck disable=SC2034,SC2120'
    fi
    printf '%s\n' 'set +x' 'set -euo pipefail' 'export LC_ALL=C' 'umask 077'
    printf '%s\n' 'rw_config_filter() {' "cat <<'RW_CONFIG_JQ'"
    cat "$ROOT/installer/bash/config.jq"
    printf '%s\n' 'RW_CONFIG_JQ' '}'
    if [[ $command == uninstall ]]; then
        # Removal never installs a CLI or renders services. Keep ownership checks,
        # pending SSH/UFW guards and scoped cleanup, without installation assets.
        modules=(common security preflight maintenance ssh cli)
    else
        printf '%s\n' 'rw_versions() {' "cat <<'RW_VERSIONS'"
        cat "$ROOT/installer/versions.lock.json"
        printf '%s\n' 'RW_VERSIONS' '}' 'rw_auth_global() {' "cat <<'RW_AUTH_GLOBAL'"
        cat "$ROOT/installer/templates/auth-global.caddy"
        printf '%s\n' 'RW_AUTH_GLOBAL' '}'
        for spec in 'schema.sql:schema' 'panel-hook.cjs:hook' 'server.cjs:server' 'patch-panel.cjs:patcher'; do
            file=${spec%:*}; fn=${spec#*:}
            printf 'rw_stats_%s() {\n' "$fn"
            printf "cat <<'RW_STATS_PAYLOAD'\n"
            cat "$ROOT/stats/$file"
            printf '\nRW_STATS_PAYLOAD\n}\n'
        done
        printf '%s\n' 'rw_confluence() {' "cat <<'RW_CONFLUENCE'"
        cat "$ROOT/installer/templates/confluence.html"
        printf '\nRW_CONFLUENCE\n}\n'
    fi
    for file in "${modules[@]}"; do cat "$ROOT/installer/bash/$file.sh"; done
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
