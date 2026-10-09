#!/usr/bin/env bash
# FI acceptance collector. No user accounts, credentials or container environments are recorded.
set +x
set -euo pipefail
umask 077
installation=/opt/pdm-remnawave/fi-test
state=/var/lib/pdm-remnawave-observation/fi-test
unit=pdm-rw-fi-test-observation
marker=pdm-remnawave-fi-acceptance-v1
expected_xray=37383f1a7d573ff4d49e2db3a99cf368dd99dcf9a0fe74aae01dca6f21062e3a
[[ $EUID == 0 && -f $installation/manifest.json ]]
owner=$(jq -er '.ownership_label' "$installation/manifest.json")
expected_count=$(jq '.services|length' "$installation/compose.json")
[[ $owner == "$(printf '%s' "fi-test:$installation" | sha256sum | cut -d' ' -f1)" ]]
for path in "$state" /usr/local/lib/pdm-remnawave-observation; do
    [[ ! -L $path ]]; install -d -m 700 "$path"
done
[[ ! -e $state/owner || $(cat "$state/owner") == "$owner" ]]
printf '%s\n' "$owner" > "$state/owner"
if [[ ${1:-} == --install ]]; then
    for path in /etc/systemd/system/$unit.{service,timer}; do
        [[ ! -e $path ]] || grep -qxF "# $marker $owner" "$path"
    done
    target=/usr/local/lib/pdm-remnawave-observation/fi-test.sh
    [[ ! -L $target ]]; install -m 700 "${BASH_SOURCE[0]}" "$target"
    printf '# %s %s\n[Unit]\nDescription=FI Remnawave 48h acceptance observations\nAfter=docker.service network-online.target\n[Service]\nType=oneshot\nExecStart=%s\nTimeoutStartSec=90\n' "$marker" "$owner" "$target" > /etc/systemd/system/$unit.service
    printf '# %s %s\n[Unit]\nDescription=FI Remnawave acceptance every five minutes\n[Timer]\nOnBootSec=30s\nOnUnitActiveSec=5min\nAccuracySec=1s\nUnit=%s.service\n[Install]\nWantedBy=timers.target\n' "$marker" "$owner" "$unit" > /etc/systemd/system/$unit.timer
    systemctl daemon-reload; systemctl enable --now "$unit.timer"
    systemctl start "$unit.service"
    exit
fi
exec 9> "$state/.lock"; flock -n 9 || exit 0
now=$(date -u +%s)
[[ -e $state/started ]] || printf '%s\n' "$now" > "$state/started"
started=$(cat "$state/started"); deadline=$((started+172800))
tmp=$(mktemp -d "$state/.sample.XXXXXX"); trap 'rm -rf -- "$tmp"' EXIT
docker ps -aq --filter "label=io.pdm.remnawave.installation=$owner" > "$tmp/ids"
mapfile -t ids < "$tmp/ids"
if (( ${#ids[@]} )); then docker inspect "${ids[@]}" | jq '[.[]|{name:.Name,running:.State.Running,health:(.State.Health.Status//"none"),oom:.State.OOMKilled,restarts:.RestartCount,started_at:.State.StartedAt}]' > "$tmp/new.json"; else printf '[]\n' > "$tmp/new.json"; fi
docker inspect marznode caddy pdm-fi-quota-quota-agent-1 discord-music-bot | jq '[.[]|{name:.Name,running:.State.Running,health:(.State.Health.Status//"none"),oom:.State.OOMKilled,restarts:.RestartCount,started_at:.State.StartedAt}]' > "$tmp/legacy.json"
[[ -e $state/legacy-baseline.json ]] || cp "$tmp/legacy.json" "$state/legacy-baseline.json"
xray=$(sha256sum /opt/marznode/marznode_data/xray_config.json | cut -d' ' -f1)
old_http=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' https://fl.wf.md || true)
panel_http=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' https://fl.wf.md:9443 || true)
available=$(awk '/MemAvailable:/ {print $2*1024}' /proc/meminfo)
disk=$(df -PB1 / | awk 'NR==2 {print $4}')
docker stats --no-stream --format '{{json .}}' "${ids[@]}" | jq -s 'map({name:.Name,memory:.MemUsage,cpu:.CPUPerc})' > "$tmp/resources.json"
jq -nc --argjson now "$now" --argjson expected_count "$expected_count" --argjson available "$available" --argjson disk "$disk" --arg xray "$xray" --arg expected "$expected_xray" --arg old "$old_http" --arg panel "$panel_http" --slurpfile containers "$tmp/new.json" --slurpfile legacy "$tmp/legacy.json" --slurpfile baseline "$state/legacy-baseline.json" --slurpfile resources "$tmp/resources.json" '
  {epoch:$now,checked_at_utc:($now|todate),expected_containers:$expected_count,available_memory_bytes:$available,free_disk_bytes:$disk,containers:$containers[0],legacy:$legacy[0],resources:$resources[0],legacy_http:$old,panel_http:$panel,
   passed:(($containers[0]|length)==$expected_count and ($containers[0]|all(.running and (.health=="healthy" or .health=="none") and (.oom|not) and .restarts==0)) and
     ($legacy[0]==$baseline[0]) and ($legacy[0]|all(.running and (.health=="healthy" or .health=="none") and (.oom|not))) and
     $xray==$expected and $old=="200" and ($panel=="302" or $panel=="303") and $available>=134217728 and $disk>=1073741824)}' >> "$state/samples.jsonl"
jq -s --argjson started "$started" --argjson deadline "$deadline" --argjson now "$now" '
  sort_by(.epoch) as $s | ([range(1;($s|length))|$s[.].epoch-$s[.-1].epoch]|max//0) as $gap |
  {schema_version:1,started_at_utc:($started|todate),deadline_utc:($deadline|todate),checked_at_utc:($now|todate),elapsed_seconds:($now-$started),required_seconds:172800,samples:($s|length),failed_samples:([$s[]|select(.passed|not)]|length),max_sample_gap_seconds:$gap,minimum_available_memory_bytes:([$s[].available_memory_bytes]|min),minimum_free_disk_bytes:([$s[].free_disk_bytes]|min),completed:($now>=$deadline),
   passed:($now>=$deadline and ($s|length)>=570 and $gap<=600 and ($s|all(.passed))),
   scope:"Parallel FI health, resource headroom, unchanged legacy config and container state; this is not a load test"}' "$state/samples.jsonl" > "$tmp/summary.json"
mv "$tmp/summary.json" "$state/summary.json"
if (( now>=deadline )); then systemctl disable --now "$unit.timer"; fi
cat "$state/summary.json"
