#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
RW_OUT=$RW_TMP/installation
rw_config_load "$ROOT/installer/examples/node.json"
rw_lock; rw_manifest preparing; rw_render; rw_track_files
exec 9>&-; RW_LOCK_DIR=
cat > "$RW_TMP/child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
source <(sed '$d' "$1")
rw_init_tmp
RW_OUT=$2; stage=$3
rw_config_load "$RW_OUT/config.json"; rw_owned; rw_lock; RW_MUTATING=1
atomic_pid=$BASHPID
printf '%s\n' "$RW_TMP" > "$RW_OUT/child-temp-path"
definition=$(declare -f rw_write_begin)
eval "${definition/rw_write_begin ()/rw_original_write_begin ()}"
definition=$(declare -f rw_plain_atomic)
eval "${definition/rw_plain_atomic ()/rw_original_plain_atomic ()}"
rw_write_begin() {
    rw_original_write_begin "$@"
    if [[ $stage == before-rename ]]; then kill -KILL "$atomic_pid"
    elif [[ $stage == term-before-rename ]]; then kill -TERM "$atomic_pid"; fi
}
rw_plain_atomic() {
    if [[ $stage == after-rename && $1 == "$RW_OUT/manifest.json" && -f $RW_OUT/.rw-write.json ]]; then kill -KILL "$atomic_pid"; exit 99; fi
    rw_original_plain_atomic "$@"
}
rm() {
    if [[ $stage == after-manifest && ${*: -1} == "$RW_OUT/.rw-write.json" ]]; then kill -KILL "$atomic_pid"; exit 99; fi
    command rm "$@"
}
printf '%s\n' "$stage" > "$RW_TMP/payload"
rw_atomic "$RW_OUT/site/index.html" < "$RW_TMP/payload"
CHILD
for stage in before-rename after-rename after-manifest term-before-rename; do
    if bash "$RW_TMP/child.sh" "$ROOT/rwctl" "$RW_OUT" "$stage" > "$RW_TMP/$stage.log" 2>&1; then printf 'Signal injection did not interrupt\n' >&2; exit 1; fi
    exec 9>"$RW_OUT/.rw.lock"; flock -w 5 9; RW_LOCK_DIR=$RW_OUT
    rw_resume_writes; rw_verify_files
    [[ $(cat "$RW_OUT/site/index.html") == "$stage" && ! -f $RW_OUT/.rw-write.json ]]
    child_tmp=$(cat "$RW_OUT/child-temp-path")
    [[ $child_tmp == /tmp/pdm-rw.* && ! -L $child_tmp ]] && rm -rf -- "$child_tmp"
    exec 9>&-; RW_LOCK_DIR=
    printf 'Real signal recovery passed: %s.\n' "$stage"
done