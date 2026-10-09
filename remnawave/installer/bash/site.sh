# shellcheck shell=bash
rw_site_default() {
    # Rendering or recovery must preserve an existing customized cover.
    [[ ! -f $RW_OUT/site/index.html ]] || return 0
    rw_confluence | rw_atomic "$RW_OUT/site/index.html"
    rw_manifest_set '.cover={template:"confluence"}'
}
rw_site_set() {
    rw_root; rw_owned; rw_lock; rw_resume_writes; rw_verify_files
    [[ $RW_ROLE != panel ]] || rw_die 'This installation has no node cover site.'
    [[ -z ${RW_SITE_FILE:-} || -z ${RW_SITE_TEMPLATE:-} ]] || rw_die 'Choose --template or --site-file, not both.'
    if (( ${RW_DRY_RUN:-0} )); then
        jq -n --arg template "${RW_SITE_TEMPLATE:-confluence}" --arg file "${RW_SITE_FILE:-}" '{template:$template,source_file:$file,read_only:true}'
        return
    fi
    if [[ -n ${RW_SITE_FILE:-} ]]; then
        [[ -f $RW_SITE_FILE && ! -L $RW_SITE_FILE && $(stat -c %s "$RW_SITE_FILE") -le 2097152 ]] || rw_die 'Provide a regular HTML file of at most 2 MiB.'
        cat "$RW_SITE_FILE" | rw_atomic "$RW_OUT/site/index.html"
        rw_manifest_set '.cover={template:"custom"}'
    else
        case ${RW_SITE_TEMPLATE:-confluence} in
            confluence) rw_confluence | rw_atomic "$RW_OUT/site/index.html";;
            simple) printf '<!doctype html><html lang="en"><meta charset="utf-8"><title>Service</title><h1>Service online</h1></html>\n' | rw_atomic "$RW_OUT/site/index.html";;
            *) rw_die 'Cover template must be confluence or simple.';;
        esac
        rw_manifest_set '.cover={template:$template}' --arg template "${RW_SITE_TEMPLATE:-confluence}"
    fi
    rw_track_files
    rw_info 'Cover page updated. Domains, Reality keys and transports were preserved.'
}
