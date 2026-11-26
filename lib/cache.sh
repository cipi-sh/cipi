#!/bin/bash
#############################################
# Cipi — nginx page cache per app (cipi cache)
#
# OPcache, which every PHP on a Cipi server has on, keeps the compiled code
# of an app in memory: PHP no longer parses its files at every request, but
# it still runs — WordPress boots, loads its plugins, asks the database, and
# builds the same page again for every visitor. That is what takes the time.
#
# This is the other cache: nginx keeps the page PHP made and answers the
# next visitors with it, without starting PHP at all. For a WordPress site, a
# blog, a brochure site or any app whose pages are the same for everyone who
# is not signed in, a page comes back in a millisecond instead of a few
# hundred, and a small server holds a traffic peak that would have filled its
# PHP pool. It does nothing for pages that are different for each visitor,
# and it is not asked to: those are never cached.
#
#   cipi cache <app> on [--ttl=10m] [--size=256m]
#   cipi cache <app> off
#   cipi cache <app> ttl 10m
#   cipi cache <app> size 512m
#   cipi cache <app> clear
#   cipi cache <app> [status] [--json]
#   cipi cache [list] [--json]
#
# One zone per app (fastcgi_cache for PHP-FPM, proxy_cache for Octane), its
# files in /var/cache/nginx/cipi/<app>. Off unless turned on.
#
# What is never cached — every rule fails towards "not cached", a page that
# is slower, never towards a private page shown to someone else:
#   - anything but GET and HEAD (nginx's own rule);
#   - a request with a session or login cookie: WordPress and WooCommerce
#     (wordpress_logged_in_, wp-postpass_, comment_author_, the cart), PHP's
#     PHPSESSID, Laravel's <app>_session and remember_web_;
#   - a request with an Authorization header (API tokens, basic auth);
#   - /wp-admin, wp-login.php, xmlrpc.php, wp-cron.php, /wp-json and the
#     routes of cipi/agent;
#   - a URL with a query string, unless it only carries tracking parameters
#     (utm_*, fbclid, gclid…): searches, filters and previews stay live, the
#     link a newsletter sends to everybody is cached;
#   - a response that sets a cookie, or says Cache-Control: private, no-cache
#     or no-store. The app's headers are respected — nothing here ignores
#     them — so what WordPress and WooCommerce mark as private stays private,
#     and a Laravel app, which marks every response "no-cache, private" by
#     default, caches only the responses it marks public itself.
#
# The time to live is for pages that say nothing: a response with its own
# Cache-Control max-age (or X-Accel-Expires) is kept that long instead. A
# page that expired is served once more while nginx fetches the new one, and
# when PHP is down the cached copy keeps answering.
#
# Emptied by `cipi cache <app> clear`, by the panel, after every successful
# deploy and rollback, and — as the app's own user, for a recipe, a script or
# a plugin — by `sudo /usr/local/bin/cipi-cache-clear <app>`.
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${CACHE_CONF_DIR:-}" ]] && CACHE_CONF_DIR="/etc/nginx/conf.d"
[[ -z "${CACHE_ROOT:-}" ]] && CACHE_ROOT="/var/cache/nginx/cipi"
[[ -z "${CACHE_NGINX_CONF:-}" ]] && CACHE_NGINX_CONF="/etc/nginx/nginx.conf"
[[ -z "${CACHE_SITES_DIR:-}" ]] && CACHE_SITES_DIR="/etc/nginx/sites-available"
CACHE_MAPS_FILE="${CACHE_CONF_DIR}/cipi-cache-maps.conf"
CACHE_DEFAULT_TTL="10m"
CACHE_DEFAULT_SIZE="256m"
# Set by cache_render for the vhost being written.
CACHE_FPM_BLOCK=""
CACHE_PROXY_BLOCK=""
CACHE_HEADER_LINE=""

_cache_app_ok() { [[ "${1:-}" =~ ^[a-z][a-z0-9]{2,31}$ ]]; }
_cache_zone_file() { echo "${CACHE_CONF_DIR}/cipi-cache-${1}.conf"; }
_cache_dir() { echo "${CACHE_ROOT}/${1}"; }

# The user nginx's workers run as: the owner of what is in the cache.
_cache_nginx_user() {
    local u
    u=$(awk '$1 == "user" { gsub(/;/, "", $2); print $2; exit }' "$CACHE_NGINX_CONF" 2>/dev/null || true)
    [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || u="www-data"
    echo "$u"
}

# "10m" → 600. Seconds, minutes, hours, days; one second to thirty days.
cache_ttl_seconds() {
    local t="${1:-}" n
    [[ "$t" =~ ^([1-9][0-9]{0,6})(s|m|h|d)$ ]] || return 1
    n="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        m) n=$((n * 60)) ;;
        h) n=$((n * 3600)) ;;
        d) n=$((n * 86400)) ;;
    esac
    (( n >= 1 && n <= 2592000 )) || return 1
    echo "$n"
}

# "256m", "2g": 16 MB to 100 GB.
cache_size_valid() {
    local s="${1:-}" mb
    [[ "$s" =~ ^([1-9][0-9]{0,5})(m|g)$ ]] || return 1
    mb="${BASH_REMATCH[1]}"
    [[ "${BASH_REMATCH[2]}" == g ]] && mb=$((mb * 1024))
    (( mb >= 16 && mb <= 102400 ))
}

# What serves the app's pages: fastcgi (PHP-FPM: Laravel, WordPress, any PHP
# app), proxy (Octane), or nothing a page cache is written for (Node).
cache_app_kind() {   # <app>
    local app="$1"
    if [[ "$(app_get "$app" runtime)" == "node" ]]; then
        return 0
    elif [[ -n "$(app_get "$app" octane)" && -n "$(app_get "$app" octane_port)" && "$(app_get "$app" custom)" != "true" ]]; then
        echo proxy
    else
        echo fastcgi
    fi
}

# Not `// empty`: jq reads false as nothing there, and "off" is a setting.
_cache_setting() {   # <app> <key>
    vault_read apps.json 2>/dev/null | jq -r --arg a "$1" --arg k "$2" \
        '(.[$a].page_cache // {})[$k] | if . == null then empty else tostring end' 2>/dev/null || true
}

cache_enabled() { [[ "$(_cache_setting "$1" enabled)" == "true" ]]; }

cache_ttl() {
    local t; t=$(_cache_setting "$1" ttl)
    cache_ttl_seconds "$t" >/dev/null 2>&1 || t="$CACHE_DEFAULT_TTL"
    echo "$t"
}

cache_size() {
    local s; s=$(_cache_setting "$1" size)
    cache_size_valid "$s" || s="$CACHE_DEFAULT_SIZE"
    echo "$s"
}

# Emptied after a successful deploy unless the app said no.
cache_clear_on_deploy() { [[ "$(_cache_setting "$1" clear_on_deploy)" != "false" ]]; }

# ── what nginx reads ─────────────────────────────────────────

# The rules that keep a request out of the cache, once for the server: a map
# is global in nginx, so it cannot be written in each vhost.
_cache_maps_text() {
    cat <<'EOF'
# Managed by Cipi (cipi cache) — rewritten on update, do not edit.
# A request any of these maps answers 1 for is neither served from an app's
# page cache nor stored in it.

# A session or a login: WordPress, WooCommerce, PHP's own session, Laravel.
map $http_cookie $cipi_cache_skip_cookie {
    default 0;
    "~*(^|;\s*)(wordpress_logged_in_|wordpress_sec_|wp-postpass_|comment_author_|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session_|edd_items_in_cart)" 1;
    "~*(^|;\s*)(PHPSESSID|remember_web_[a-z0-9]*|[a-z0-9_-]*_session)=" 1;
}

# Back offices, and what must reach PHP every time.
map $request_uri $cipi_cache_skip_uri {
    default 0;
    "~*^/(wp-admin(/|$)|wp-login\.php|wp-cron\.php|xmlrpc\.php|wp-comments-post\.php|wp-json(/|$)|cipi/)" 1;
}

# A query string — unless it is made of tracking parameters only.
map $args $cipi_cache_skip_args {
    default 1;
    "" 0;
    "~*^((utm_[a-z0-9_]+|fbclid|gclid|gbraid|wbraid|msclkid|mc_cid|mc_eid|_ga|_gl)=[^&]*(&|$))+$" 0;
}

# An API token, basic auth.
map $http_authorization $cipi_cache_skip_auth {
    default 1;
    "" 0;
}
EOF
}

_cache_maps_ensure() {
    local tmp
    install -d -m 755 "$CACHE_CONF_DIR" 2>/dev/null || return 1
    tmp=$(mktemp) || return 1
    _cache_maps_text > "$tmp"
    if [[ -f "$CACHE_MAPS_FILE" && ! -L "$CACHE_MAPS_FILE" ]] && cmp -s "$tmp" "$CACHE_MAPS_FILE"; then
        rm -f "$tmp"; return 0
    fi
    [[ -L "$CACHE_MAPS_FILE" ]] && rm -f "$CACHE_MAPS_FILE"
    install -m 644 "$tmp" "$CACHE_MAPS_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# The app's zone: where its pages are kept and how much of the disk they may
# take. `inactive` is how long a page nobody asks for stays: an hour, or the
# time to live when that is longer.
_cache_zone_ensure() {   # <app> <fastcgi|proxy>
    local app="$1" kind="$2" file dir size ttl_s inactive nuser tmp
    file=$(_cache_zone_file "$app"); dir=$(_cache_dir "$app")
    size=$(cache_size "$app")
    ttl_s=$(cache_ttl_seconds "$(cache_ttl "$app")")
    inactive=3600; (( ttl_s > inactive )) && inactive="$ttl_s"
    nuser=$(_cache_nginx_user)
    # nginx makes the last directory itself, not its parents.
    install -d -m 755 "$CACHE_ROOT" 2>/dev/null || return 1
    if [[ ! -d "$dir" ]]; then
        install -d -m 700 -o "$nuser" -g "$nuser" "$dir" 2>/dev/null || install -d -m 700 "$dir" 2>/dev/null || return 1
    fi
    tmp=$(mktemp) || return 1
    {
        echo "# Managed by Cipi (cipi cache ${app}) — rewritten with the app's vhost."
        echo "${kind}_cache_path ${dir} levels=1:2 keys_zone=cipi_${app}:10m max_size=${size} inactive=${inactive}s use_temp_path=off;"
    } > "$tmp"
    if [[ -f "$file" && ! -L "$file" ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"; return 0
    fi
    [[ -L "$file" ]] && rm -f "$file"
    install -m 644 "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# For _create_nginx_vhost_http: writes the server's maps and the app's zone,
# and sets what goes in the vhost —
#   CACHE_HEADER_LINE   in the server block (X-Cache-Status: HIT, MISS, BYPASS…);
#   CACHE_FPM_BLOCK     in `location ~ \.php$`;
#   CACHE_PROXY_BLOCK   in `location @octane`.
# All empty, and the zone removed, when the app's cache is off. The header
# is at server level on purpose: an add_header inside a location would drop
# every header the server block sets there (nginx does not merge them).
cache_render() {   # <app>
    local app="$1" kind ttl_s nf skip file
    CACHE_FPM_BLOCK=""; CACHE_PROXY_BLOCK=""; CACHE_HEADER_LINE=""
    _cache_app_ok "$app" || return 0
    file=$(_cache_zone_file "$app")
    # Off for almost every app: one read of the settings, and done.
    if ! cache_enabled "$app"; then
        rm -f "$file" 2>/dev/null || true
        return 0
    fi
    kind=$(cache_app_kind "$app")
    if [[ -z "$kind" ]]; then
        rm -f "$file" 2>/dev/null || true
        return 0
    fi
    _cache_maps_ensure || return 1
    _cache_zone_ensure "$app" "$kind" || return 1
    ttl_s=$(cache_ttl_seconds "$(cache_ttl "$app")")
    # A page that is not there is cached for a minute at most: bots ask for
    # thousands of them, and a page created meanwhile must show up soon.
    nf=60; (( ttl_s < nf )) && nf="$ttl_s"
    skip='$cipi_cache_skip_cookie $cipi_cache_skip_uri $cipi_cache_skip_args $cipi_cache_skip_auth'
    CACHE_HEADER_LINE='    add_header X-Cache-Status $upstream_cache_status always;'$'\n'
    if [[ "$kind" == fastcgi ]]; then
        CACHE_FPM_BLOCK="        fastcgi_cache cipi_${app};
        fastcgi_cache_key \"\$scheme\$request_method\$host\$request_uri\";
        fastcgi_cache_valid 200 301 ${ttl_s}s;
        fastcgi_cache_valid 404 ${nf}s;
        fastcgi_cache_bypass ${skip};
        fastcgi_no_cache ${skip};
        fastcgi_cache_lock on;
        fastcgi_cache_lock_timeout 10s;
        fastcgi_cache_use_stale updating error timeout http_500 http_503;
        fastcgi_cache_background_update on;
"
    else
        # \$http_upgrade: a WebSocket handshake is not a page.
        CACHE_PROXY_BLOCK="        proxy_cache cipi_${app};
        proxy_cache_key \"\$scheme\$request_method\$host\$request_uri\";
        proxy_cache_valid 200 301 ${ttl_s}s;
        proxy_cache_valid 404 ${nf}s;
        proxy_cache_bypass ${skip} \$http_upgrade;
        proxy_no_cache ${skip} \$http_upgrade;
        proxy_cache_lock on;
        proxy_cache_lock_timeout 10s;
        proxy_cache_use_stale updating error timeout http_500 http_503;
        proxy_cache_background_update on;
"
    fi
    return 0
}

# ── the files ────────────────────────────────────────────────

# As nginx's user: what is in the directory is that user's, and root does
# not walk a tree another user controls. Nothing follows a symlink.
_cache_as_nginx() {
    local nuser; nuser=$(_cache_nginx_user)
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v runuser >/dev/null 2>&1 && id "$nuser" &>/dev/null; then
        ( cd / && runuser -u "$nuser" -- "$@" )
    else
        ( cd / && "$@" )
    fi
}

# "<files> <bytes>" of what nginx holds for the app.
cache_usage() {   # <app>
    local dir files=0 bytes=0
    _cache_app_ok "${1:-}" || { echo "0 0"; return 0; }
    dir=$(_cache_dir "$1")
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        files=$(_cache_as_nginx find "$dir" -xdev -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        bytes=$(_cache_as_nginx du -sb "$dir" 2>/dev/null | awk '{ print $1 }' || echo 0)
    fi
    [[ "$files" =~ ^[0-9]+$ ]] || files=0
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    echo "${files} ${bytes}"
}

# Deletes every page nginx holds for the app and prints how many there were.
# nginx finds a page gone the next time it is asked for and fetches it again:
# nothing to reload. Safe to call for an app without a cache.
cache_clear() {   # <app>
    local app="${1:-}" dir files=0
    _cache_app_ok "$app" || return 1
    dir=$(_cache_dir "$app")
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        files=$(_cache_as_nginx find "$dir" -xdev -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        _cache_as_nginx find "$dir" -xdev -mindepth 1 -type f -delete 2>/dev/null || true
    fi
    [[ "$files" =~ ^[0-9]+$ ]] || files=0
    echo "$files"
}

# After a successful deploy or rollback: the pages of the release before
# name its assets. One line to show when something was emptied, nothing
# otherwise. Never fails the deploy.
cache_after_deploy() {   # <app>
    local app="${1:-}" n
    _cache_app_ok "$app" || return 0
    cache_enabled "$app" || return 0
    cache_clear_on_deploy "$app" || return 0
    n=$(cache_clear "$app" 2>/dev/null) || return 0
    echo "Page cache: emptied (${n} page(s))"
}

# With the app: its zone and its pages.
cache_remove_app() {   # <app>
    _cache_app_ok "${1:-}" || return 0
    rm -f "$(_cache_zone_file "$1")" 2>/dev/null || true
    rm -rf "${CACHE_ROOT:?}/${1}" 2>/dev/null || true
}

# The per-app sudoers rule that lets the app's own user empty its cache —
# from a deploy recipe, a script, a WordPress plugin. Added when the cache is
# turned on; checked by visudo before it replaces the file.
_cache_sudoers_ensure() {   # <app>
    local app="$1" f tmp line
    f="${CACHE_SUDOERS_DIR:-/etc/sudoers.d}/cipi-${app}"
    line="${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-cache-clear ${app}"
    [[ -f "$f" && ! -L "$f" ]] || return 0
    grep -qxF "$line" "$f" 2>/dev/null && return 0
    tmp=$(mktemp) || return 1
    { cat "$f"; echo "$line"; } > "$tmp"
    chmod 440 "$tmp"
    if command -v visudo >/dev/null 2>&1 && ! visudo -c -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; return 1
    fi
    install -m 440 "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# ── commands ─────────────────────────────────────────────────

_cache_status_json() {   # <app>
    local app="$1" kind files bytes active=false
    kind=$(cache_app_kind "$app")
    read -r files bytes <<< "$(cache_usage "$app")"
    cache_enabled "$app" && grep -qE "(fastcgi|proxy)_cache cipi_${app};" "${CACHE_SITES_DIR}/${app}" 2>/dev/null && active=true
    jq -n --arg app "$app" --arg kind "$kind" --arg ttl "$(cache_ttl "$app")" --arg size "$(cache_size "$app")" \
        --argjson enabled "$(cache_enabled "$app" && echo true || echo false)" \
        --argjson cod "$(cache_clear_on_deploy "$app" && echo true || echo false)" \
        --argjson active "$active" --argjson files "$files" --argjson bytes "$bytes" \
        --argjson ttl_s "$(cache_ttl_seconds "$(cache_ttl "$app")")" \
        --argjson suspended "$([[ "$(app_get "$app" suspended)" == "true" ]] && echo true || echo false)" \
        --arg dir "$(_cache_dir "$app")" \
        '{app: $app, supported: ($kind != ""), kind: (if $kind == "" then null else $kind end),
          enabled: $enabled, active: $active, ttl: $ttl, ttl_seconds: $ttl_s, size: $size,
          clear_on_deploy: $cod, files: $files, bytes: $bytes, path: $dir, suspended: $suspended,
          clear_command: ("sudo /usr/local/bin/cipi-cache-clear " + $app)}'
}

_cache_human() {   # <bytes>
    awk -v b="${1:-0}" 'BEGIN { if (b >= 1073741824) printf "%.1f GB", b / 1073741824; else if (b >= 1048576) printf "%.1f MB", b / 1048576; else if (b >= 1024) printf "%.0f KB", b / 1024; else printf "%d B", b }'
}

_cache_status() {   # <app> [--json]
    local app="$1"; shift
    parse_args "$@"
    if [[ "${ARG_json:-}" == "true" ]]; then _cache_status_json "$app"; return 0; fi
    local kind files bytes
    kind=$(cache_app_kind "$app")
    echo -e "\n${BOLD}Page cache — ${app}${NC}"
    if [[ -z "$kind" ]]; then
        echo -e "  ${DIM}Not available for a Node app: its pages come from its own server.${NC}\n"
        return 0
    fi
    if ! cache_enabled "$app"; then
        echo -e "  ${YELLOW}off${NC}  ${DIM}— every request runs PHP. Turn it on: ${CYAN}cipi cache ${app} on${NC}"
        echo -e "  ${DIM}OPcache is on already, and it is another cache: it keeps the compiled code, PHP still builds each page.${NC}\n"
        return 0
    fi
    read -r files bytes <<< "$(cache_usage "$app")"
    echo -e "  ${GREEN}on${NC}   pages kept ${BOLD}$(cache_ttl "$app")${NC}, up to $(cache_size "$app") on disk  ${DIM}(${kind}_cache, $(_cache_dir "$app"))${NC}"
    echo -e "  Now: ${files} page(s), $(_cache_human "$bytes")"
    if cache_clear_on_deploy "$app"; then
        echo -e "  Emptied after every successful deploy and rollback"
    else
        echo -e "  ${YELLOW}Not emptied after a deploy${NC} ${DIM}(cipi cache ${app} on --deploy-clear)${NC}"
    fi
    [[ "$(app_get "$app" suspended)" == "true" ]] && echo -e "  ${YELLOW}The app is suspended${NC} ${DIM}— the cache is back with: cipi app unsuspend ${app}${NC}"
    echo -e "  ${DIM}Look at a response: curl -sI https://$(app_get "$app" domain)/ | grep -i x-cache-status   (HIT, MISS, BYPASS, EXPIRED, STALE)${NC}"
    echo -e "  ${DIM}Empty it: ${CYAN}cipi cache ${app} clear${NC}${DIM} — as the app's user, in a recipe or a script: ${CYAN}sudo /usr/local/bin/cipi-cache-clear ${app}${NC}\n"
}

_cache_list() {
    parse_args "$@"
    local app rows="[]"
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        rows=$(jq -c --argjson r "$(_cache_status_json "$app")" '. + [$r]' <<< "$rows")
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq '{apps: .}' <<< "$rows"
        return 0
    fi
    echo -e "\n${BOLD}Page cache${NC} ${DIM}— nginx answers with the page PHP made, without running PHP again${NC}"
    if [[ "$(jq 'length' <<< "$rows")" -eq 0 ]]; then
        echo -e "  ${DIM}No apps.${NC}\n"; return 0
    fi
    tbl_start
    tbl_head "APP" "CACHE" "KEPT" "PAGES" "ON DISK"
    local en ttl files bytes sup
    while IFS=$'\t' read -r app en ttl files bytes sup; do
        if [[ "$sup" != "true" ]]; then
            tbl_row "$app" "${DIM}n/a (Node)${NC}" "—" "—" "—"
        elif [[ "$en" == "true" ]]; then
            tbl_row "$app" "${GREEN}on${NC}" "$ttl" "$files" "$(_cache_human "$bytes")"
        else
            tbl_row "$app" "${DIM}off${NC}" "—" "—" "—"
        fi
    done < <(jq -r '.[] | [.app, (.enabled | tostring), .ttl, (.files | tostring), (.bytes | tostring), (.supported | tostring)] | @tsv' <<< "$rows")
    tbl_print
    echo -e "  ${DIM}cipi cache <app> on [--ttl=10m] · off · ttl <time> · clear${NC}\n"
}

# Saves the settings ($2: a jq filter on the app's page_cache), writes the
# vhost again and reloads nginx. nginx refuses: everything back as it was.
_cache_apply() {   # <app> <jq filter> [--arg …]
    local app="$1" filter="$2" before out; shift 2
    declare -f _routes_app_json >/dev/null 2>&1 || source "${CIPI_LIB}/routes.sh"
    _routes_preflight || return 1
    before=$(_routes_app_json "$app")
    vault_read apps.json | jq --arg a "$app" "$@" ".[\$a].page_cache = ((.[\$a].page_cache // {}) | ${filter})" | vault_write apps.json
    ensure_apps_json_api_access
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    if out=$(nginx -t 2>&1); then
        systemctl reload nginx || { error "systemctl reload nginx failed"; return 1; }
        return 0
    fi
    error "nginx refused the configuration — nothing changed"
    printf '%s\n' "$out" | grep -E 'emerg|error' | head -5 | sed -e 's/^nginx: //' -e 's/^/  /' >&2
    app_save "$app" "$before" || true
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    nginx -t >/dev/null 2>&1 || warn "nginx -t still fails after putting the vhost back — run: nginx -t"
    return 1
}

_cache_need_supported() {
    local app="$1"
    if [[ -z "$(cache_app_kind "$app")" ]]; then
        error "'${app}' is a Node app: its pages come from its own server, and the page cache is written for PHP apps (PHP-FPM and Octane)"
        exit 1
    fi
}

_cache_on() {
    local app="$1"; shift
    unset ARG_ttl ARG_size ARG_deploy_clear ARG_no_deploy_clear 2>/dev/null || true
    parse_args "$@"
    _cache_need_supported "$app"
    local ttl size cod was=false
    ttl="${ARG_ttl:-$(cache_ttl "$app")}"; size="${ARG_size:-$(cache_size "$app")}"
    cache_ttl_seconds "$ttl" >/dev/null || { error "Invalid --ttl '${ttl}' — a number and s, m, h or d (30s, 10m, 1h, 7d), thirty days at most"; exit 1; }
    cache_size_valid "$size" || { error "Invalid --size '${size}' — megabytes or gigabytes, 16m to 100g (256m, 2g)"; exit 1; }
    cod=$(cache_clear_on_deploy "$app" && echo true || echo false)
    [[ "${ARG_deploy_clear:-}" == "true" ]] && cod=true
    [[ "${ARG_no_deploy_clear:-}" == "true" ]] && cod=false
    cache_enabled "$app" && was=true
    if [[ "$was" == true && "$ttl" == "$(cache_ttl "$app")" && "$size" == "$(cache_size "$app")" \
          && "$cod" == "$(cache_clear_on_deploy "$app" && echo true || echo false)" ]]; then
        info "The page cache of '${app}' is on already (pages kept ${ttl})"
        return 0
    fi
    _cache_apply "$app" '.enabled = true | .ttl = $ttl | .size = $size | .clear_on_deploy = $cod' \
        --arg ttl "$ttl" --arg size "$size" --argjson cod "$cod" || exit 1
    _cache_sudoers_ensure "$app" || warn "Could not add cipi-cache-clear to /etc/sudoers.d/cipi-${app} — the app's user cannot empty the cache itself (cipi cache ${app} clear still does)"
    log_action "PAGE CACHE ON: ${app} ttl=${ttl} size=${size}"
    if [[ "$was" == true ]]; then
        success "Page cache of '${app}': pages kept ${ttl}, up to ${size} on disk"
        return 0
    fi
    cipi_notify \
        "Cipi page cache on: ${app} on $(hostname)" \
        "The nginx page cache was turned on for an app.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nPages kept: ${ttl}\nTime: $(notify_now)" \
        app_cache
    success "Page cache on for '${app}' — pages kept ${ttl}, up to ${size} on disk"
    echo -e "  ${DIM}Not cached: signed-in visitors, carts, admin pages, query strings, anything the app marks private.${NC}"
    echo -e "  ${DIM}Check: curl -sI https://$(app_get "$app" domain)/ | grep -i x-cache-status   (MISS first, HIT after)${NC}"
    if [[ "$(app_get "$app" custom)" != "true" ]]; then
        echo -e "  ${DIM}A Laravel app marks its responses \"no-cache, private\": only those it marks public are cached (the cache.headers middleware).${NC}"
    fi
    if [[ "$(app_get "$app" suspended)" == "true" ]]; then warn "'${app}' is suspended — the cache starts with: cipi app unsuspend ${app}"; fi
}

_cache_off() {
    local app="$1" n
    if ! cache_enabled "$app"; then
        info "The page cache of '${app}' is off already"
        return 0
    fi
    _cache_apply "$app" '.enabled = false' || exit 1
    n=$(cache_clear "$app" 2>/dev/null || echo 0)
    rm -rf "${CACHE_ROOT:?}/${app}" 2>/dev/null || true
    log_action "PAGE CACHE OFF: ${app}"
    cipi_notify \
        "Cipi page cache off: ${app} on $(hostname)" \
        "The nginx page cache was turned off for an app.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nTime: $(notify_now)" \
        app_cache
    success "Page cache off for '${app}' — ${n} cached page(s) deleted, every request runs PHP again"
}

_cache_ttl_cmd() {
    local app="$1" ttl="${2:-}"
    if [[ -z "$ttl" || "$ttl" == --* ]]; then
        echo -e "  Pages of '${app}' are kept ${BOLD}$(cache_ttl "$app")${NC}$(cache_enabled "$app" || echo " ${DIM}(the cache is off)${NC}")"
        return 0
    fi
    cache_ttl_seconds "$ttl" >/dev/null || { error "Invalid time '${ttl}' — a number and s, m, h or d (30s, 10m, 1h, 7d), thirty days at most"; exit 1; }
    if [[ "$ttl" == "$(cache_ttl "$app")" ]]; then
        info "Pages of '${app}' are kept ${ttl} already"
        return 0
    fi
    if cache_enabled "$app"; then
        _cache_apply "$app" '.ttl = $ttl' --arg ttl "$ttl" || exit 1
    else
        vault_read apps.json | jq --arg a "$app" --arg ttl "$ttl" '.[$a].page_cache = ((.[$a].page_cache // {}) | .ttl = $ttl)' | vault_write apps.json
        ensure_apps_json_api_access
    fi
    log_action "PAGE CACHE TTL: ${app} ${ttl}"
    success "Pages of '${app}' are kept ${ttl}$(cache_enabled "$app" || echo " — when the cache is turned on (cipi cache ${app} on)")"
}

_cache_size_cmd() {
    local app="$1" size="${2:-}"
    if [[ -z "$size" || "$size" == --* ]]; then
        echo -e "  The cache of '${app}' may take ${BOLD}$(cache_size "$app")${NC} on disk"
        return 0
    fi
    cache_size_valid "$size" || { error "Invalid size '${size}' — megabytes or gigabytes, 16m to 100g (256m, 2g)"; exit 1; }
    [[ "$size" == "$(cache_size "$app")" ]] && { info "The cache of '${app}' may take ${size} already"; return 0; }
    if cache_enabled "$app"; then
        _cache_apply "$app" '.size = $size' --arg size "$size" || exit 1
    else
        vault_read apps.json | jq --arg a "$app" --arg size "$size" '.[$a].page_cache = ((.[$a].page_cache // {}) | .size = $size)' | vault_write apps.json
        ensure_apps_json_api_access
    fi
    log_action "PAGE CACHE SIZE: ${app} ${size}"
    success "The cache of '${app}' may take ${size} on disk"
}

_cache_clear_cmd() {
    local app="$1" n
    if ! cache_enabled "$app"; then
        info "The page cache of '${app}' is off — nothing to empty"
        return 0
    fi
    n=$(cache_clear "$app") || { error "Could not empty the cache of '${app}'"; exit 1; }
    log_action "PAGE CACHE CLEARED: ${app} (${n})"
    success "Page cache of '${app}' emptied — ${n} page(s); the next visit to each page runs PHP and caches it again"
}

cache_command() {
    declare -f _create_nginx_vhost >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
    local app="${1:-}"
    # `cipi cache`, `cipi cache list` — unless an app is called that.
    if [[ -z "$app" || "$app" == --* ]] || { [[ "$app" == list || "$app" == ls || "$app" == status ]] && ! app_exists "$app"; }; then
        [[ "$app" == --* || -z "$app" ]] || shift
        _cache_list "$@"
        return 0
    fi
    shift
    _cache_app_ok "$app" && app_exists "$app" || { error "App '${app}' not found (cipi cache — the list)"; exit 1; }
    local sub="${1:-status}"
    [[ "$sub" == --* ]] && sub=status || { shift || true; }
    case "$sub" in
        status|show)          _cache_status "$app" "$@" ;;
        on|enable)            _cache_on "$app" "$@" ;;
        off|disable)          _cache_off "$app" ;;
        ttl)                  _cache_ttl_cmd "$app" "$@" ;;
        size)                 _cache_size_cmd "$app" "$@" ;;
        clear|purge|flush)    _cache_clear_cmd "$app" ;;
        *) error "Use: cipi cache <app> on [--ttl=10m] [--size=256m] | off | ttl <time> | size <size> | clear | status [--json]"; exit 1 ;;
    esac
}
