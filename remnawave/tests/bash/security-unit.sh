#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034
set -euo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source <(sed '$d' "$ROOT/rwctl")
rw_init_tmp
count=0
passed() { count=$((count+1)); printf 'ok %s - %s\n' "$count" "$1"; }
RW_OUT=$RW_TMP/install
rw_config_load "$ROOT/installer/examples/fi-compact-single-domain.json"
! jq -e 'has("security")' "$RW_CFG" >/dev/null
passed 'legacy configuration normalization keeps the existing fingerprint contract'
rw_manifest preparing; rw_render; rw_track_files
ssh-keygen -q -t ed25519 -N '' -f "$RW_TMP/owner-key"
ssh-keygen -q -t ed25519 -N '' -f "$RW_TMP/other-key"
public=$(cat "$RW_TMP/owner-key.pub")
rw_public_key_check "$public"
if rw_public_key_check 'ssh-ed25519 AAAA invalid'; then exit 1; fi
if rw_public_key_check "$(cat "$RW_TMP/owner-key")"; then exit 1; fi
passed 'public key validation rejects malformed and private key input'
key_path=$RW_TMP/root-ssh/authorized_keys
rw_root_key_paths() { printf '%s\n' "$key_path"; }
if rw_root_key_present; then exit 1; fi
mkdir -m 700 "$RW_TMP/root-ssh"
printf '# existing comment\n' > "$key_path"
jq --arg key "$public" '.security={enabled:true,root_public_key:$key}' "$RW_CFG" > "$RW_TMP/config-key.json"
rw_config_load "$RW_TMP/config-key.json"
rw_security_key_prepare
grep -q '# existing comment' "$key_path"
ssh-keygen -lf "$key_path" >/dev/null
[[ $(stat -c %a "$key_path") == 600 ]]
passed 'missing root key is appended without deleting existing lines and with mode 0600'
cat "$RW_TMP/other-key.pub" > "$key_path"
before=$(sha256sum "$key_path")
rw_security_key_prepare; rw_security_key_prepare
[[ $before == "$(sha256sum "$key_path")" ]]
passed 'any existing valid root key prevents replacement or an additional key'
for field in '"yes"' '{"enabled":"yes"}' '{"root_private_key":"hidden"}' '{"root_public_key":"private-key-data"}'; do
    jq --argjson field "$field" '.security=$field' "$RW_CFG" > "$RW_TMP/invalid-security.json"
    if (rw_config_load "$RW_TMP/invalid-security.json") >/dev/null 2>&1; then exit 1; fi
done
passed 'security contract rejects invalid types and private/unknown fields'
rw_config_load "$RW_TMP/config-key.json"
ss() { cat <<'RW_LISTENERS'
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
tcp LISTEN 0 128 [::]:53042 [::]:*
tcp LISTEN 0 128 *:2222 *:*
tcp LISTEN 0 128 127.0.0.1:13000 0.0.0.0:*
tcp LISTEN 0 128 [::1]:12019 [::]:*
udp UNCONN 0 0 *:4123 *:*
RW_LISTENERS
}
docker() {
    case $1 in ps) printf 'foreign-container\n';; inspect) printf '[{"NetworkSettings":{"Ports":{"443/tcp":[{"HostIp":"0.0.0.0","HostPort":"8443"}],"99/tcp":[{"HostIp":"127.0.0.2","HostPort":"9999"}]}}}]\n';; *) return 1;; esac
}
rw_security_ports > "$RW_TMP/preserved.json"
jq -e 'any(.[];.port==4123 and .proto=="udp") and any(.[];.port==8443) and any(.[];.port==53042) and all(.[];.port!=2222 and .port!=13000 and .port!=12019 and .port!=9999)' "$RW_TMP/preserved.json" >/dev/null
passed 'inventory preserves real TCP/UDP and Docker ports but excludes loopback and owned management API'
ufw() { printf 'Status: inactive\n'; }
rw_ufw_input_policy() { printf 'DROP\n'; }
SSH_CONNECTION='203.0.113.8 50111 192.0.2.10 52222'
rw_security_plan "$RW_TMP/preserved.json"
jq -e '.active_before==false and (.ssh_ports|index(52222)!=null) and (.preserved_ports|length==4) and any(.public_ports[];.port==9444 and .proto=="udp") and all(.public_ports[];.port!=2222 and .port!=13000 and .port!=18080)' "$RW_TMP/security-plan.json" >/dev/null
passed 'inactive UFW plan keeps legacy ports, actual SSH port and HTTP3 without exposing local APIs'
ufw() { printf 'Status: active\n'; }
rw_security_plan "$RW_TMP/preserved.json"
jq -e '.preserved_ports==[] and .ssh_source=="203.0.113.8" and .active_before==true' "$RW_TMP/security-plan.json" >/dev/null
passed 'existing active deny policy is not widened to every listening foreign port'
rw_track_files
RW_DRY_RUN=1
before=$(sha256sum "$RW_OUT/manifest.json")
rw_security_configure > "$RW_TMP/preview.json"
jq -e '.read_only==true and .root_key_present==true' "$RW_TMP/preview.json" >/dev/null
[[ $before == "$(sha256sum "$RW_OUT/manifest.json")" && ! -e $RW_OUT/private/security-state.json ]]
passed 'security apply preview changes no keys, manifest, UFW or timers'
printf '{"status":"armed"}' | rw_atomic "$RW_OUT/private/security-state.json"
if (rw_security_idle) >/dev/null 2>&1; then exit 1; fi
printf '{"status":"confirmed"}' | rw_atomic "$RW_OUT/private/security-state.json"
rw_security_idle
passed 'pending access verification blocks overlapping installation changes'
printf '%s host-security checks passed.\n' "$count"
