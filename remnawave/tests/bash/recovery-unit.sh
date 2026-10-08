#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
testdir=$RW_TMP/fixtures
mkdir -p "$testdir/valid"
printf 'safe\n' > "$testdir/valid/file"
tar -czf "$testdir/valid.tgz" -C "$testdir/valid" .
rw_archive_check "$testdir/valid.tgz"
fail_expected() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; }
ln -s /etc/passwd "$testdir/valid/escape"
tar -czf "$testdir/symlink.tgz" -C "$testdir/valid" .
fail_expected rw_archive_check "$testdir/symlink.tgz"
tar -czf "$testdir/traversal.tgz" --transform='s|file|../outside|' -C "$testdir/valid" file
fail_expected rw_archive_check "$testdir/traversal.tgz"
tar -czf "$testdir/duplicate.tgz" -C "$testdir/valid" file file
fail_expected rw_archive_check "$testdir/duplicate.tgz"
rw_versions > "$testdir/versions.json"
rw_versions_check "$testdir/versions.json"
jq '.components.panel.image="attacker/repo@sha256:"+("a"*64)' "$testdir/versions.json" > "$testdir/bad-versions.json"
fail_expected rw_versions_check "$testdir/bad-versions.json"
RW_OUT=$testdir/installation
rw_config_load "$ROOT/installer/examples/node.json"
rw_manifest preparing; rw_render; rw_track_files
jq '.components.postgres.source_tag="19.0"' "$testdir/versions.json" > "$testdir/major.json"
RW_VERSION_FILE=$testdir/major.json
fail_expected rw_upgrade_candidate
jq '.components.postgres.source_tag="18.3"' "$testdir/versions.json" > "$testdir/lower.json"
RW_VERSION_FILE=$testdir/lower.json
fail_expected rw_upgrade_candidate
printf '%064d  archive.tgz\n' 0 > "$testdir/valid.tgz.sha256"
fail_expected rw_backup_open "$testdir/valid.tgz"
printf '9 archive/upgrade safety checks passed.\n'
