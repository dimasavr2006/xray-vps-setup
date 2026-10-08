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
