# shellcheck shell=bash
rw_address_jq() { rw_config_filter | sed '/^\.$/,$d'; }
rw_address_list() {
    { rw_address_jq; printf '\n[inputs|split(",")[]|gsub("^ +| +$";"")]|require(length>0 and all(ip);"Enter valid IPv4/IPv6 addresses")|map(ipnorm)|unique\n'; } > "$RW_TMP/addresses.jq"
    jq -Ren -f "$RW_TMP/addresses.jq"
}
rw_domain_check() {
    { rw_address_jq; printf '\n$domain|domain\n'; } > "$RW_TMP/domain.jq"
    jq -ne --arg domain "$1" -f "$RW_TMP/domain.jq" >/dev/null
}
rw_dns_addresses() {
    local domain=$1 family
    rw_domain_check "$domain" || return 1
    : > "$RW_TMP/address-dns.txt"
    for family in A AAAA; do
        dig +time=2 +tries=1 +noall +answer +comments "$domain" "$family" > "$RW_TMP/address-answer.txt" || return 1
        grep -q 'status: NOERROR' "$RW_TMP/address-answer.txt" || return 1
        awk '$4=="A" || $4=="AAAA" {print $5}' "$RW_TMP/address-answer.txt" >> "$RW_TMP/address-dns.txt"
    done
    { rw_address_jq; printf '\n[inputs|select(length>0)]|require(all(ip);"Invalid DNS address")|map(ipnorm)|unique\n'; } > "$RW_TMP/address-dns.jq"
    jq -Rn -f "$RW_TMP/address-dns.jq" < "$RW_TMP/address-dns.txt"
}
rw_detect_addresses() {
    local family url pid
    local -a pids=()
    : > "$RW_TMP/detected-addresses.txt"
    ip -j address show scope global > "$RW_TMP/interfaces.json" 2>/dev/null || printf '[]\n' > "$RW_TMP/interfaces.json"
    jq -r '.[]|select(.ifname|test("^(lo|docker|br-|veth|virbr|pdm-)" )|not)|.addr_info[]?|select(.scope=="global" and .preferred_life_time!=0)|.local' "$RW_TMP/interfaces.json" >> "$RW_TMP/detected-addresses.txt"
    for family in 4 6; do
        if [[ $family == 4 ]]; then url=https://api.ipify.org; else url=https://api6.ipify.org; fi
        # Independent family probes share a four-second deadline, not two serial waits.
        (curl -"$family" -fsS --proto '=https' --connect-timeout 2 --max-time 4 --max-filesize 128 "$url" > "$RW_TMP/echo-ip$family" 2>/dev/null || : > "$RW_TMP/echo-ip$family") &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    for family in 4 6; do cat "$RW_TMP/echo-ip$family" >> "$RW_TMP/detected-addresses.txt"; printf '\n' >> "$RW_TMP/detected-addresses.txt"; done
    { rw_address_jq; cat <<'RW_PUBLIC_JQ'
[inputs|select(ip)|ipnorm|select(
 if contains(":") then test("^[23]")
 else split(".")|map(tonumber)|
   .[0]>0 and .[0]<224 and .[0]!=10 and .[0]!=127 and
   (.[0]!=172 or .[1]<16 or .[1]>31) and
   (.[0]!=192 or .[1]!=168) and (.[0]!=169 or .[1]!=254) and
   (.[0]!=100 or .[1]<64 or .[1]>127)
 end)]|unique
RW_PUBLIC_JQ
    } > "$RW_TMP/public-addresses.jq"
    jq -Rn -f "$RW_TMP/public-addresses.jq" < "$RW_TMP/detected-addresses.txt"
}
rw_confirm_addresses() {
    local label=$1 candidate=$2 answer input
    if jq -e 'length>0' "$candidate" >/dev/null; then
        printf '%s: %s\n' "$label" "$(jq -r 'join(", ")' "$candidate")" >&2
        read -r -p 'Use these addresses? [Y/n]: ' answer || rw_die 'Address confirmation was interrupted.'
        case ${answer:-y} in y|Y|yes|YES) cat "$candidate"; return;; n|N|no|NO) :;; *) rw_info 'Enter y or n. Switching to manual address entry.';; esac
    fi
    while :; do
        read -r -p "$label (comma-separated IPv4/IPv6): " input || rw_die 'Address input was interrupted.'
        if printf '%s\n' "$input" | rw_address_list > "$RW_TMP/manual-addresses.json" 2>/dev/null; then cat "$RW_TMP/manual-addresses.json"; return; fi
        rw_info 'Invalid address list. IPv6 is optional; enter IPv4 only if needed.'
    done
}
rw_choose_public_addresses() {
    local domain common='' same=1 detected=$RW_TMP/public-detected.json dns=$RW_TMP/public-dns.json
    rw_detect_addresses > "$detected"
    rw_info "Detected public server addresses: $(jq -r 'if length>0 then join(", ") else "unavailable" end' "$detected")"
    for domain in "$@"; do
        if rw_dns_addresses "$domain" > "$dns"; then
            printf 'DNS %s: %s\n' "$domain" "$(jq -r 'if length>0 then join(", ") else "no A/AAAA records" end' "$dns")" >&2
            if [[ -z $common ]]; then common=$(jq -c . "$dns"); elif [[ $common != "$(jq -c . "$dns")" ]]; then same=0; fi
        else rw_info "DNS $domain: lookup failed."; same=0; fi
    done
    if [[ $same == 1 && -n $common ]] && jq -e --argjson dns "$common" '$dns|length>0' "$detected" >/dev/null && jq -e --argjson dns "$common" '. as $server|all($dns[]; . as $ip|$server|index($ip)!=null)' "$detected" >/dev/null; then
        printf '%s\n' "$common" > "$RW_TMP/public-proposed.json"
    else
        cp "$detected" "$RW_TMP/public-proposed.json"
        rw_info 'DNS and detected addresses differ or are unverified. DNS must match the confirmed list before installation.'
    fi
    rw_confirm_addresses 'Public server addresses' "$RW_TMP/public-proposed.json"
}
rw_choose_panel_addresses() {
    local input
    rw_info 'Node management must allow the panel server source IPs. A proxied/CDN domain does not identify those IPs.'
    while :; do
        read -r -p 'Panel server domain or comma-separated source IPs: ' input || rw_die 'Panel address input was interrupted.'
        if printf '%s\n' "$input" | rw_address_list > "$RW_TMP/panel-proposed.json" 2>/dev/null; then :
        elif rw_dns_addresses "$input" > "$RW_TMP/panel-proposed.json" && jq -e 'length>0' "$RW_TMP/panel-proposed.json" >/dev/null; then :
        else rw_info 'No valid panel addresses found. Enter the actual panel server source IPs.'; continue; fi
        rw_confirm_addresses 'Allowed panel source addresses' "$RW_TMP/panel-proposed.json"
        return
    done
}
