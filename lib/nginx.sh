#!/bin/bash
#############################################
# Cipi — Nginx helpers (mainline repo + HTTP/2 bomb mitigation)
#############################################

# Minimum nginx version that ships max_headers (HTTP/2 bomb fix).
[[ -z "${_NGINX_MIN_VERSION:-}" ]] && readonly _NGINX_MIN_VERSION="1.29.8"

nginx_installed_version() {
    nginx -v 2>&1 | sed -n 's/.*nginx\///p' | awk '{print $1}'
}

nginx_version_at_least() {
    local ver="${1:-}" min="${2:-$_NGINX_MIN_VERSION}"
    [[ -z "$ver" ]] && return 1
    [[ "$(printf '%s\n' "$min" "$ver" | sort -V | head -1)" == "$min" ]]
}

# ── Security state ───────────────────────────────────────────
# nginx_security_floor (lib/common.sh) is the oldest release with every fix
# Cipi knows about. nginx.org packages carry the upstream version
# ("1.31.9-1~noble"), so the version says whether the fixes are in. The
# Ubuntu archive's ("1.24.0-2ubuntu7.20") get them backported under an old
# version: there the number says nothing, and Cipi's nightly update — which
# follows nginx.org — does not reach them.

[[ -z "${_NGINX_PROC:-}" ]] && readonly _NGINX_PROC="/proc"

nginx_package_version() { dpkg-query -W -f='${Version}' nginx 2>/dev/null || true; }

nginx_is_distro_build() {
    local pkg="${1:-$(nginx_package_version)}"
    # "-2ubuntu7.20" is the archive's; a PPA build says "+ubuntu24.04".
    [[ "$pkg" =~ -[0-9]+ubuntu[0-9] ]]
}

# "<state> <version>": patched | vulnerable | distro | none.
nginx_security_state() {
    local ver
    command -v nginx >/dev/null 2>&1 || { echo "none -"; return 0; }
    ver=$(nginx_installed_version 2>/dev/null || true)
    [[ -n "$ver" ]] || { echo "none -"; return 0; }
    if nginx_is_distro_build; then
        echo "distro ${ver}"
    elif nginx_version_at_least "$ver" "$(nginx_security_floor)"; then
        echo "patched ${ver}"
    else
        echo "vulnerable ${ver}"
    fi
}

# True while an nginx process still runs a binary that is no longer the one
# on disk. A package upgrade replaces /usr/sbin/nginx and asks the running
# master to start the new one (USR2); when that fails the package only
# prints a line, and when it works the old workers stay for as long as a
# connection of theirs is open — a WebSocket, for hours. Either way the
# fixes just installed are not what answers requests.
nginx_running_binary_stale() {
    local pid exe
    for pid in $(pgrep -x nginx 2>/dev/null || true); do
        exe=$(readlink "${_NGINX_PROC}/${pid}/exe" 2>/dev/null || true)
        [[ "$exe" == *"(deleted)" ]] && return 0
    done
    return 1
}

# After an upgrade or a config change: test, then make sure what runs is the
# binary on disk. A reload where that is already so; a restart (every
# connection dropped, well under a second) where an old binary is still in
# memory after a short wait for its workers to finish.
#   0 = running the current binary   1 = config refused, nothing touched
#   2 = nginx did not come back
nginx_activate() {
    local i wait="${_NGINX_STALE_WAIT:-10}"
    nginx -t >/dev/null 2>&1 || return 1
    if systemctl is-active --quiet nginx 2>/dev/null; then
        for (( i = 0; i < wait; i++ )); do
            nginx_running_binary_stale || break
            sleep 1
        done
        if nginx_running_binary_stale; then
            echo "  The nginx binary from before the upgrade is still running — restarting nginx"
            systemctl restart nginx 2>/dev/null || return 2
        else
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || return 2
        fi
    else
        systemctl restart nginx 2>/dev/null || return 2
    fi
    systemctl is-active --quiet nginx 2>/dev/null || return 2
    return 0
}

# Config files (as nginx loads them) that turn HTTP/2 on. Cipi 4 and 5 never
# do: their vhosts are `listen 443 ssl;` and nginx has it off by default
# since 1.25.1. What this finds was written by hand, or by Cipi 3.
nginx_http2_listeners() {
    nginx -T 2>/dev/null | awk '
        /^# configuration file / { f = $4; sub(/:$/, "", f); next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*http2[[:space:]]+on[[:space:]]*;/ { print f; next }
        /^[[:space:]]*listen[[:space:]][^;#]*[[:space:]]http2([[:space:]]|;)/ { print f }' | sort -u
}

# Fails without touching the keyring already there: a download that breaks
# half way used to leave an empty one, and apt then refused the repository.
nginx_setup_mainline_repo() {
    apt-get install -y -qq curl gnupg2 ca-certificates lsb-release ubuntu-keyring 2>/dev/null || true

    local keyring=/usr/share/keyrings/nginx-archive-keyring.gpg tmp
    tmp=$(mktemp "${keyring}.XXXXXX") || return 1
    if curl -fsSL --max-time 60 https://nginx.org/keys/nginx_signing.key 2>/dev/null \
            | gpg --dearmor > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        chmod 644 "$tmp"
        mv -f "$tmp" "$keyring"
    else
        rm -f "$tmp"
        if [[ ! -s "$keyring" ]]; then
            echo "  ERROR: could not download the nginx.org signing key (https://nginx.org/keys/nginx_signing.key)" >&2
            return 1
        fi
    fi

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
https://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" \
        > /etc/apt/sources.list.d/nginx.list

    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        > /etc/apt/preferences.d/99nginx

    apt-get update -qq 2>/dev/null || true
}

nginx_ensure_sites_layout() {
    # nginx.org packages ship conf.d/ only; Cipi uses Debian-style sites-* dirs.
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
    rm -f /etc/nginx/conf.d/default.conf
}

nginx_write_global_conf() {
    local worker_processes="${1:-$(nproc)}"

    cat > /etc/nginx/nginx.conf <<NGINXEOF
user www-data;
worker_processes ${worker_processes};
# Headroom for long-lived connections — see the same pair in setup.sh and in
# _ensure_nginx_ws_limits (lib/common.sh). A WebSocket holds two nginx
# connections and a descriptor each for as long as it stays open.
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 64;
    server_tokens off;
    max_headers 1000;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml font/truetype font/opentype
               application/vnd.ms-fontobject image/svg+xml;

    client_max_body_size 256M;
    fastcgi_read_timeout 300;

    limit_req_zone \$binary_remote_addr zone=global:10m rate=30r/s;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF
}

# Makes an nginx.conf written for the Ubuntu archive's nginx load on
# nginx.org's, in place, keeping everything else in it: without the
# modules-enabled include and the headers-more directives (that module is
# Ubuntu's), with max_headers. Prints the result; the caller decides.
nginx_conf_for_mainline() {
    local conf="${1:-/etc/nginx/nginx.conf}" has_max=0 after_tokens=0
    [[ -f "$conf" ]] || return 1
    grep -qE '^[[:space:]]*max_headers[[:space:]]' "$conf" && has_max=1
    # max_headers goes after server_tokens, where Cipi's template has it; in
    # a file without that line, first thing in the http block.
    grep -qE '^[[:space:]]*server_tokens[[:space:]]' "$conf" && after_tokens=1
    awk -v has_max="$has_max" -v after_tokens="$after_tokens" '
        /^[[:space:]]*include[[:space:]]+\/etc\/nginx\/modules-enabled\// { next }
        /^[[:space:]]*more_(clear|set)_(input_)?headers[[:space:]]/ { next }
        { print }
        !has_max && !added && after_tokens && /^[[:space:]]*server_tokens[[:space:]]/ {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "max_headers 1000;"
            added = 1
        }
        !has_max && !added && !after_tokens && /^[[:space:]]*http[[:space:]]*\{[[:space:]]*$/ {
            print "    max_headers 1000;"
            added = 1
        }' "$conf"
}

# What would stop nginx.org's nginx from loading this server's configuration
# and that the move does not fix by itself: headers-more directives (the
# module is Ubuntu's, and Cipi installed it) in a file other than nginx.conf
# — a vhost or a snippet somebody wrote. One "<file>: <directive>" per line.
nginx_mainline_blockers() {
    nginx -T 2>/dev/null | awk -v main="/etc/nginx/nginx.conf" '
        /^# configuration file / { f = $4; sub(/:$/, "", f); next }
        /^[[:space:]]*#/ { next }
        f != main && /^[[:space:]]*more_(clear|set)_(input_)?headers[[:space:]]/ { print f ": " $1 }' | sort -u
}

# Move to nginx.org mainline and make nginx.conf load on it (max_headers,
# no headers-more). Named after the reason it was written (4.5.9); since
# 5.9.1 also the way a server on the Ubuntu archive's nginx gets to
# nginx_security_floor. Idempotent — safe to re-run.
nginx_upgrade_mainline_for_http2_bomb() {
    local cur_ver workers candidate conf=/etc/nginx/nginx.conf backup tmp rc

    cur_ver=$(nginx_installed_version 2>/dev/null || echo "")
    if [[ -n "$cur_ver" ]] \
       && nginx_version_at_least "$cur_ver" \
       && ! nginx_is_distro_build \
       && grep -qE '^\s*max_headers\s' "$conf" 2>/dev/null \
       && ! grep -q 'more_clear_headers' "$conf" 2>/dev/null; then
        echo "  Nginx ${cur_ver} with max_headers already configured — nothing to do"
        return 0
    fi

    workers=$(grep -E '^worker_processes' "$conf" 2>/dev/null \
        | awk '{print $2}' | tr -d ';')
    [[ -z "$workers" || "$workers" == "auto" ]] && workers=$(nproc)

    # Two things are looked at while the archive's nginx is still the one
    # installed, because after the swap there is no going back to ask it. A
    # configuration it already refuses: nothing here could tell its own
    # damage from what was there. And directives only its modules know, in
    # files this does not rewrite: nginx.org's binary would refuse them, and
    # if removing the archive's packages stopped nginx it would stay down.
    if nginx_is_distro_build; then
        local blockers
        if ! nginx -t >/dev/null 2>&1; then
            echo "  ERROR: nginx -t already fails on this server — fix the configuration first (nginx -t), then: cipi nginx upgrade"
            return 1
        fi
        blockers=$(nginx_mainline_blockers || true)
        if [[ -n "$blockers" ]]; then
            echo "  ERROR: these files use the headers-more module, which nginx.org's nginx does not have — nginx left as it is:"
            while IFS= read -r candidate; do echo "    ${candidate}"; done <<< "$blockers"
            echo "  Remove those directives (or the files), then: cipi nginx upgrade"
            return 1
        fi
    fi

    echo "  Configuring nginx.org mainline repository..."
    nginx_setup_mainline_repo || return 1

    candidate=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -z "$candidate" || "$candidate" == "(none)" ]] || nginx_is_distro_build "$candidate"; then
        echo "  ERROR: nginx mainline package not available from APT (candidate: ${candidate:-none})."
        echo "  nginx left as it is — check the nginx.org repository / network."
        return 1
    fi
    echo "  nginx candidate: ${candidate}"

    # One apt transaction: nginx.org's nginx in, Ubuntu's headers-more module
    # out (it is built for the distro nginx). Simulated first — if apt cannot
    # do all of it, nothing is removed and nginx stays as it is.
    local -a want=(nginx)
    if dpkg-query -W -f='${db:Status-Status}' libnginx-mod-http-headers-more-filter 2>/dev/null | grep -q '^installed$'; then
        want+=(libnginx-mod-http-headers-more-filter-)
    fi
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -s -qq "${want[@]}" >/dev/null 2>&1; then
        echo "  ERROR: apt cannot resolve the move to nginx.org mainline — nginx left as it is."
        echo "  See why: apt-get install -s ${want[*]}"
        return 1
    fi

    backup="${conf}.cipi-$(date +%Y%m%d%H%M%S).bak"
    cp -p "$conf" "$backup" 2>/dev/null || backup=""

    # --force-confold: nginx.conf and the other files in /etc/nginx are in
    # both packages; without it dpkg stops to ask which one to keep.
    if ! apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
            -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            "${want[@]}" 2>/dev/null; then
        echo "  ERROR: failed to install nginx from the nginx.org mainline repository."
        return 1
    fi
    nginx_ensure_sites_layout

    cur_ver=$(nginx_installed_version 2>/dev/null || echo "")
    if [[ -n "$cur_ver" ]] && ! nginx_version_at_least "$cur_ver"; then
        echo "  WARNING: installed nginx ${cur_ver} is below ${_NGINX_MIN_VERSION} (max_headers may be missing)."
    fi

    # The running nginx is still the old binary here (the new one cannot
    # start on a config with headers-more in it), or stopped by the removal
    # of Ubuntu's packages: nginx_activate below settles both.
    # The config already there, adapted; Cipi's own template only where the
    # adapted one does not load.
    if ! { grep -qE '^\s*max_headers\s' "$conf" 2>/dev/null && nginx -t >/dev/null 2>&1; }; then
        echo "  Adapting ${conf} (max_headers, no headers-more module)..."
        tmp=$(mktemp) || return 1
        if nginx_conf_for_mainline "$conf" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
            cat "$tmp" > "$conf"
        fi
        rm -f "$tmp"
        declare -f _ensure_nginx_octane_map >/dev/null && { _ensure_nginx_octane_map >/dev/null 2>&1 || true; }
        if ! nginx -t >/dev/null 2>&1; then
            echo "  The adapted config does not load — writing Cipi's nginx.conf${backup:+ (the previous one: ${backup})}"
            nginx_write_global_conf "$workers"
            # The template has the WebSocket map: the snippet would define it twice.
            declare -f _ensure_nginx_octane_map >/dev/null && { _ensure_nginx_octane_map >/dev/null 2>&1 || true; }
        fi
    fi

    systemctl enable nginx 2>/dev/null || true
    rc=0
    nginx_activate || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        nginx -t 2>&1 | sed 's/^/    /' || true
        echo "  ERROR: nginx -t failed after the upgrade — review ${conf}${backup:+ (before the upgrade: ${backup})}"
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        echo "  ERROR: nginx did not come back after the upgrade — systemctl status nginx"
        return 1
    fi
    echo "  Nginx upgraded to $(nginx_installed_version 2>/dev/null || echo unknown)"
    return 0
}

# Everything a security release of nginx asks of a Cipi server, in one call:
# nginx.org mainline at nginx_security_floor or newer, and that binary — not
# the one from before — answering requests. For the 5.9.1 migration and for
# whoever wants to run it by hand; `cipi nginx upgrade` does the same with a
# preview and a question.
#   0 = at or above the floor and running it   1 = not there
nginx_security_upgrade() {
    local floor ver rc=0
    floor=$(nginx_security_floor)
    command -v nginx >/dev/null 2>&1 || { echo "  nginx is not installed — nothing to do"; return 0; }
    ver=$(nginx_installed_version 2>/dev/null || true)

    if nginx_is_distro_build; then
        echo "  nginx ${ver:-?} is the Ubuntu archive build ($(nginx_package_version)) — moving to nginx.org mainline..."
        nginx_upgrade_mainline_for_http2_bomb || return 1
    else
        if [[ -n "$ver" ]] && nginx_version_at_least "$ver" "$floor"; then
            echo "  nginx ${ver} is at or above ${floor}"
        else
            echo "  nginx ${ver:-?} is below ${floor} — upgrading from nginx.org mainline..."
            nginx_setup_mainline_repo || return 1
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
                -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
                --only-upgrade nginx 2>/dev/null \
                || { echo "  ERROR: apt could not upgrade nginx"; return 1; }
        fi
        nginx_activate || rc=$?
        case "$rc" in
            0) : ;;
            1) echo "  ERROR: nginx -t fails — the package is installed, the running nginx was not touched. Fix the config, then: systemctl restart nginx"
               return 1 ;;
            *) echo "  ERROR: nginx did not come back — systemctl status nginx"
               return 1 ;;
        esac
    fi

    ver=$(nginx_installed_version 2>/dev/null || true)
    if [[ -z "$ver" ]] || ! nginx_version_at_least "$ver" "$floor"; then
        echo "  ERROR: nginx is ${ver:-unknown}, still below ${floor} — the repository may not have it yet for this Ubuntu release; later: cipi nginx upgrade"
        return 1
    fi
    echo "  nginx ${ver} running (floor ${floor})"
    return 0
}

# ── Catch-all default server ─────────────────────────────────
#
# Without an explicit default_server for a port, nginx answers any request
# matching no server_name with the *first* vhost it loaded for that port. On
# :80 the installer already claims the default with the "Server Up" page, but
# :443 has never had one — so an HTTPS request carrying an unknown Host (a
# direct hit on the IP, a scanner, a stray Cloudflare origin request) lands on
# whichever app happens to sort first. For a wildcard multi-tenant app that
# means the tenant resolver receives a hostname it cannot parse and the
# request errors out inside someone else's application.
#
# Cipi's block claims the default only for ports that do not already have one,
# and closes the connection without a response (444).

[[ -z "${_NGINX_DEFAULT_SITE:-}" ]] && readonly _NGINX_DEFAULT_SITE="/etc/nginx/sites-available/000-cipi-default"
[[ -z "${_NGINX_DEFAULT_LINK:-}" ]] && readonly _NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/000-cipi-default"

nginx_default_server_enabled() { [[ -L "$_NGINX_DEFAULT_LINK" || -f "$_NGINX_DEFAULT_LINK" ]]; }

# Name of the vhost claiming default_server on <port>, ignoring Cipi's own
# block. nginx allows exactly one per port — a second is a hard config error.
nginx_default_server_owner() {
    local port="$1" f
    for f in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" || -L "$f" ]] || continue
        [[ "$(basename "$f")" == "000-cipi-default" ]] && continue
        if grep -qE "^[[:space:]]*listen[[:space:]]+(\[::\]:)?${port}\b[^;#]*\bdefault_server\b" "$f" 2>/dev/null; then
            basename "$f"
            return 0
        fi
    done
    return 1
}

# Write the catch-all for whichever of :80 / :443 is still unclaimed.
#   0 = written
#   2 = nothing to claim (both ports already have a default server)
#   1 = could not write the file
nginx_write_default_server() {
    local ver with_ssl=true wrote=false
    ver=$(nginx_installed_version 2>/dev/null || echo "")
    # ssl_reject_handshake needs nginx >= 1.19.4; without it a certificate-less
    # TLS server block would refuse to load at all.
    if [[ -n "$ver" ]] && ! nginx_version_at_least "$ver" "1.19.4"; then
        with_ssl=false
    fi

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled 2>/dev/null || true
    if ! : > "$_NGINX_DEFAULT_SITE" 2>/dev/null; then
        # Say what actually happened. Reporting "already claimed" here would be
        # a plain lie, and the kind that sends someone hunting the wrong vhost.
        error "Cannot write ${_NGINX_DEFAULT_SITE}"
        return 1
    fi
    {
        echo "# Managed by Cipi — catch-all for requests matching no app."
        echo "# Disable with: cipi nginx default-server off"
        if ! nginx_default_server_owner 80 >/dev/null; then
            cat <<'EOF'

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    access_log off;
    return 444;
}
EOF
            wrote=true
        fi
        if [[ "$with_ssl" == true ]] && ! nginx_default_server_owner 443 >/dev/null; then
            cat <<'EOF'

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    access_log off;
    return 444;
}
EOF
            wrote=true
        fi
    } > "$_NGINX_DEFAULT_SITE"
    chmod 644 "$_NGINX_DEFAULT_SITE"

    if [[ "$wrote" != true ]]; then
        rm -f "$_NGINX_DEFAULT_SITE"
        return 2
    fi
    return 0
}

nginx_enable_default_server() {
    local wrc=0
    nginx_write_default_server || wrc=$?
    if [[ $wrc -eq 2 ]]; then
        info "Both :80 and :443 already have a default server — nothing to claim."
        return 2
    fi
    if [[ $wrc -ne 0 ]]; then
        return 1
    fi
    ln -sf "$_NGINX_DEFAULT_SITE" "$_NGINX_DEFAULT_LINK"
    if ! nginx -t &>/dev/null; then
        rm -f "$_NGINX_DEFAULT_LINK" "$_NGINX_DEFAULT_SITE"
        error "nginx config test failed with the catch-all enabled — reverted, nothing changed."
        nginx -t 2>&1 | sed 's/^/  /'
        return 1
    fi
    systemctl reload nginx 2>/dev/null || true
    return 0
}

nginx_disable_default_server() {
    rm -f "$_NGINX_DEFAULT_LINK" "$_NGINX_DEFAULT_SITE"
    nginx -t &>/dev/null && systemctl reload nginx 2>/dev/null || true
    return 0
}

_nginx_default_server_report() {
    echo -e "\n${BOLD}Nginx default server${NC} ${DIM}(who answers a request matching no app)${NC}\n"
    local port owner
    for port in 80 443; do
        if owner=$(nginx_default_server_owner "$port"); then
            printf "  :%-4s ${CYAN}%s${NC}\n" "$port" "$owner"
        elif nginx_default_server_enabled && grep -qE "listen (\[::\]:)?${port}\b" "$_NGINX_DEFAULT_SITE" 2>/dev/null; then
            printf "  :%-4s ${GREEN}%s${NC} ${DIM}(empty reply, 444)${NC}\n" "$port" "cipi catch-all"
        else
            printf "  :%-4s ${YELLOW}%s${NC}\n" "$port" "none — the first vhost loaded answers"
        fi
    done
    echo ""
    if nginx_default_server_enabled; then
        echo -e "  ${DIM}Disable: ${CYAN}cipi nginx default-server off${NC}"
    else
        echo -e "  ${DIM}Enable:  ${CYAN}cipi nginx default-server on${NC}"
        echo -e "  ${DIM}Recommended with wildcard/multi-tenant apps, so unmatched hostnames${NC}"
        echo -e "  ${DIM}never reach a tenant resolver that cannot parse them.${NC}"
    fi
    echo ""
}

# cipi nginx security — where this server stands, without changing anything.
_nginx_security_report() {
    local state ver floor f h2
    read -r state ver <<< "$(nginx_security_state)"
    floor=$(nginx_security_floor)
    echo -e "\n${BOLD}Nginx security${NC}\n"
    case "$state" in
        patched)    echo -e "  nginx ${GREEN}${ver}${NC}  patched ${DIM}(nginx.org mainline, ${floor} or newer)${NC}" ;;
        vulnerable) echo -e "  nginx ${RED}${ver}${NC}  ${RED}VULNERABLE${NC} — ${floor} has the fixes: ${CYAN}cipi nginx upgrade${NC}" ;;
        distro)     echo -e "  nginx ${YELLOW}${ver}${NC}  Ubuntu archive build ($(nginx_package_version)) — not what Cipi's nightly update follows: ${CYAN}cipi nginx upgrade${NC} moves it to nginx.org mainline" ;;
        *)          echo -e "  ${DIM}nginx is not installed${NC}\n"; return 0 ;;
    esac
    if nginx_running_binary_stale; then
        echo -e "  ${RED}●${NC} the binary from before the last upgrade is still running: ${CYAN}systemctl restart nginx${NC}"
    else
        echo -e "  ${GREEN}●${NC} the running nginx is the installed binary"
    fi
    h2=$(nginx_http2_listeners || true)
    if [[ -n "$h2" ]]; then
        echo -e "  ${YELLOW}●${NC} HTTP/2 is on in config Cipi did not write (the HTTP/2 fixes of a release matter here):"
        while IFS= read -r f; do [[ -n "$f" ]] && echo -e "      ${f}"; done <<< "$h2"
    else
        echo -e "  ${GREEN}●${NC} HTTP/2 is off ${DIM}(Cipi's vhosts never enable it)${NC}"
    fi
    echo ""
}

nginx_command() {
    local sub="${1:-status}"; shift||true
    case "$sub" in
        upgrade)
            # shellcheck source=/dev/null
            source "${CIPI_LIB}/stack-upgrade.sh"
            _stack_upgrade nginx "$@"
            ;;
        default-server)
            local action="${1:-status}"
            case "$action" in
                on|enable)
                    if nginx_default_server_enabled; then
                        info "Catch-all default server already enabled"
                        _nginx_default_server_report
                        return 0
                    fi
                    local erc=0
                    nginx_enable_default_server || erc=$?
                    case $erc in
                        0) success "Catch-all default server enabled"
                           log_action "NGINX DEFAULT SERVER: on" ;;
                        2) : ;;   # nothing to claim, already reported
                        *) exit 1 ;;
                    esac
                    _nginx_default_server_report
                    ;;
                off|disable)
                    nginx_default_server_enabled || { info "Catch-all default server already disabled"; return 0; }
                    nginx_disable_default_server
                    success "Catch-all default server disabled"
                    log_action "NGINX DEFAULT SERVER: off"
                    _nginx_default_server_report
                    ;;
                status) _nginx_default_server_report ;;
                *) error "Use: cipi nginx default-server on|off|status"; exit 1 ;;
            esac
            ;;
        status) _nginx_default_server_report ;;
        security) _nginx_security_report ;;
        real-ip|realip) nginx_realip_command "$@" ;;
        show)  nginx_custom_show "$@" ;;
        edit)  nginx_custom_edit "$@" ;;
        set)   nginx_custom_set "$@" ;;
        reset|unset|clear) nginx_custom_reset "$@" ;;
        *) error "Use: cipi nginx show|edit|set|reset <app> | real-ip cloudflare|off|status | default-server on|off|status | security | upgrade [--yes]"; exit 1 ;;
    esac
}

# ── The visitor's address behind Cloudflare ───────────────────
#   cipi nginx real-ip cloudflare     trust Cloudflare's edge for the visitor's address
#   cipi nginx real-ip status [--json]
#   cipi nginx real-ip refresh        fetch Cloudflare's ranges again (also every night)
#   cipi nginx real-ip off [--yes]
#
# A domain proxied by Cloudflare (the orange cloud) reaches nginx from
# Cloudflare's addresses: the access log, fail2ban, CrowdSec and the app all
# see Cloudflare, not the visitor. With this on, a request that comes from one
# of Cloudflare's ranges is given the address in its CF-Connecting-IP header
# (nginx's real_ip module); a request from anywhere else keeps the address of
# its connection, so the header cannot be forged by connecting to the server
# directly. It is one setting for the whole server, right for the domains
# behind Cloudflare and without effect on the others.
#
# The work is Zero Trust's (lib/zt.sh), without the tunnel: the same file in
# conf.d, the same fail2ban ignore list and CrowdSec whitelist for Cloudflare's
# ranges — a ban on Cloudflare takes every proxied site down — and a refresh
# of the ranges every night. No Cloudflare token is needed: the list is public.

_nginx_realip_load() {
    declare -f _zt_apply_realip >/dev/null 2>&1 || source "${CIPI_LIB}/zt.sh"
}

# on | off, and who keeps it on: real-ip (this command), zero-trust, both, other
# (a real_ip configuration Cipi did not write).
_nginx_realip_state() {
    local on="off" by=""
    if [[ -s "$ZT_REALIP" ]]; then
        on="on"
        local a=false b=false
        [[ -f "$NGINX_REALIP_CRON" ]] && a=true
        _zt_enabled 2>/dev/null && b=true
        if   $a && $b; then by="both"
        elif $a; then by="real-ip"
        elif $b; then by="zero-trust"
        else by="real-ip"; fi
    elif grep -rqsE '^[[:space:]]*set_real_ip_from[[:space:]]' "$(dirname "$(dirname "$ZT_REALIP")")/nginx.conf" "$(dirname "$ZT_REALIP")" 2>/dev/null; then
        on="on"; by="other"
    fi
    echo "${on} ${by}"
}

nginx_realip_command() {
    local action="${1:-status}"; shift || true
    _nginx_realip_load
    case "$action" in
        cloudflare|on|enable) _nginx_realip_enable "$@" ;;
        off|disable)          _nginx_realip_disable "$@" ;;
        refresh)              _nginx_realip_refresh "$@" ;;
        status)               _nginx_realip_status "$@" ;;
        *) error "Use: cipi nginx real-ip cloudflare|off|status|refresh"; exit 1 ;;
    esac
}

_nginx_realip_enable() {
    local state by had="" out
    read -r state by <<< "$(_nginx_realip_state)"
    if [[ "$by" == "other" ]]; then
        error "nginx already has a real_ip configuration that Cipi did not write (set_real_ip_from in /etc/nginx)"
        echo "  Remove it first, or keep it: two of them would trust two lists." >&2
        exit 1
    fi
    if ! nginx -t >/dev/null 2>&1; then
        error "nginx configuration is already invalid — fix it first (nginx -t)"; exit 1
    fi
    step "Fetching Cloudflare's address ranges..."
    _zt_fetch_ips || { error "Could not fetch Cloudflare's ranges (api.cloudflare.com/client/v4/ips) and none are saved"; exit 1; }
    [[ -f "$ZT_REALIP" ]] && had=$(cat "$ZT_REALIP")
    _zt_write_realip || { error "Could not write ${ZT_REALIP}"; exit 1; }
    if ! out=$(nginx -t 2>&1); then
        # Put back what was there: nginx must never be left unable to reload.
        if [[ -n "$had" ]]; then printf '%s\n' "$had" > "$ZT_REALIP"; else rm -f "$ZT_REALIP"; fi
        error "nginx refused the configuration — nothing changed"
        printf '%s\n' "$out" | grep -v 'test is successful\|syntax is ok' | head -3 | sed 's/^/  /' >&2
        exit 1
    fi
    systemctl reload nginx || { error "systemctl reload nginx failed"; exit 1; }
    _zt_write_fail2ban_ignore
    _zt_write_crowdsec_allowlist || true
    cat > "$NGINX_REALIP_CRON" <<'CRONEOF'
# Cipi — Cloudflare's address ranges for nginx real_ip, fail2ban and CrowdSec (cipi nginx real-ip).
23 3 * * * root /usr/local/bin/cipi nginx real-ip refresh >/dev/null 2>&1
CRONEOF
    chmod 644 "$NGINX_REALIP_CRON"
    log_action "NGINX REAL-IP: cloudflare"
    if [[ "$state" == "on" ]]; then
        success "Already on — Cloudflare's ranges refreshed ($(_zt_each_cf_cidr | wc -l) ranges)"
    else
        success "nginx now takes the visitor's address from Cloudflare ($(_zt_each_cf_cidr | wc -l) ranges, refreshed every night)"
    fi
    echo -e "  ${DIM}Logs, fail2ban, CrowdSec and the apps see the visitor for domains proxied by Cloudflare; a direct${NC}"
    echo -e "  ${DIM}connection keeps its own address. PHP-FPM apps read it as REMOTE_ADDR (\$request->ip(), no${NC}"
    echo -e "  ${DIM}TrustProxies change); Octane and Node apps in X-Forwarded-For, as before. A firewall ban stops${NC}"
    echo -e "  ${DIM}direct connections only: a visitor who comes through Cloudflare is blocked at Cloudflare (WAF).${NC}"
}

_nginx_realip_refresh() {
    if [[ ! -f "$NGINX_REALIP_CRON" && ! -f "$ZT_REALIP" ]]; then
        info "real-ip is off — nothing to refresh"
        return 0
    fi
    _zt_refresh
}

_nginx_realip_disable() {
    parse_args "$@"
    local state by
    read -r state by <<< "$(_nginx_realip_state)"
    if [[ "$state" == "off" ]]; then
        rm -f "$NGINX_REALIP_CRON"
        info "real-ip is already off"
        return 0
    fi
    if [[ "$by" == "other" ]]; then
        error "The real_ip configuration in /etc/nginx was not written by Cipi — remove it by hand"; exit 1
    fi
    if [[ "$by" == "zero-trust" || "$by" == "both" ]]; then
        # The tunnel delivers every request from Cloudflare: without real_ip all of them are one address.
        rm -f "$NGINX_REALIP_CRON"
        warn "Zero Trust is enabled and needs Cloudflare's real_ip: it stays on until 'cipi zt disable'"
        return 0
    fi
    if systemctl is-active --quiet crowdsec 2>/dev/null || systemctl is-active --quiet fail2ban 2>/dev/null; then
        warn "With a domain still proxied by Cloudflare, every visitor becomes one of Cloudflare's addresses again:"
        warn "CrowdSec or fail2ban could ban Cloudflare itself and take those sites down."
        warn "Turn the proxy off in Cloudflare (DNS only) first."
        if [[ "${ARG_yes:-}" != "true" ]]; then
            [[ -t 0 ]] || { error "Pass --yes to turn it off without a terminal"; exit 1; }
            confirm "Turn real-ip off?" || { info "Nothing changed"; return 0; }
        fi
    fi
    local had=""
    [[ -f "$ZT_REALIP" ]] && had=$(cat "$ZT_REALIP")
    rm -f "$ZT_REALIP"
    if ! nginx -t >/dev/null 2>&1; then
        # A vhost may use what the file defined: nginx stays as it was.
        [[ -n "$had" ]] && printf '%s\n' "$had" > "$ZT_REALIP"
        error "nginx refuses its configuration without the file — nothing changed (nginx -t)"; exit 1
    fi
    systemctl reload nginx || { error "systemctl reload nginx failed"; exit 1; }
    rm -f "$ZT_F2B" "$ZT_CS_WL" "$NGINX_REALIP_CRON"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        systemctl reload crowdsec 2>/dev/null || true
    fi
    log_action "NGINX REAL-IP: off"
    success "real-ip is off — nginx sees the address of each connection"
}

# The state as JSON: `cipi nginx real-ip status --json`, and `real_ip` in
# `cipi firewall status --json` (the panel's Firewall tab).
#   can_disable — `off` would turn it off: on, and kept by this command alone
#                 (Zero Trust needs it; a configuration Cipi did not write is
#                 not Cipi's to remove);
#   bans_active — CrowdSec or fail2ban runs: with a domain still proxied,
#                 turning it off lets them ban Cloudflare (what `off` warns of).
_nginx_realip_json() {
    local state by ranges=0 refreshed="" bans=false
    read -r state by <<< "$(_nginx_realip_state)"
    [[ -s "$ZT_REALIP" ]] && ranges=$(grep -c '^set_real_ip_from ' "$ZT_REALIP" 2>/dev/null || true)
    [[ -s "${ZT_IPS_DIR}/v4" ]] && refreshed=$(date -u -r "${ZT_IPS_DIR}/v4" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    if systemctl is-active --quiet crowdsec 2>/dev/null || systemctl is-active --quiet fail2ban 2>/dev/null; then
        bans=true
    fi
    jq -n -c --arg state "$state" --arg by "$by" --argjson ranges "${ranges:-0}" --arg refreshed "$refreshed" \
          --argjson nightly "$([[ -f "$NGINX_REALIP_CRON" || -f "$ZT_CRON" ]] && echo true || echo false)" \
          --argjson bans "$bans" \
          '{enabled: ($state == "on"), provider: (if $state == "on" and $by != "other" then "cloudflare" else null end),
            header: (if $state == "on" and $by != "other" then "CF-Connecting-IP" else null end),
            kept_by: (if $by == "" then null else $by end), ranges: $ranges,
            refreshed_at: (if $refreshed == "" then null else $refreshed end), nightly_refresh: $nightly,
            can_disable: ($state == "on" and $by == "real-ip"), bans_active: $bans}'
}

_nginx_realip_status() {
    parse_args "$@"
    local state by ranges=0 refreshed=""
    if [[ "${ARG_json:-}" == "true" ]]; then
        _nginx_realip_json | jq .
        return 0
    fi
    read -r state by <<< "$(_nginx_realip_state)"
    [[ -s "$ZT_REALIP" ]] && ranges=$(grep -c '^set_real_ip_from ' "$ZT_REALIP" 2>/dev/null || true)
    [[ -s "${ZT_IPS_DIR}/v4" ]] && refreshed=$(date -u -r "${ZT_IPS_DIR}/v4" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    echo -e "\n${BOLD}nginx — the visitor's address${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    case "$state $by" in
        "off "*)
            printf "  %-14s %b\n" "real-ip" "${DIM}off${NC} — the address of each connection"
            echo -e "\n  ${DIM}Domains behind Cloudflare's proxy show Cloudflare's addresses in the logs and in the app.${NC}"
            echo -e "  ${DIM}Turn it on with:${NC} ${CYAN}cipi nginx real-ip cloudflare${NC}" ;;
        "on other")
            printf "  %-14s %b\n" "real-ip" "${YELLOW}on${NC} — a configuration in /etc/nginx that Cipi did not write" ;;
        *)
            printf "  %-14s %b\n" "real-ip" "${GREEN}on${NC} — Cloudflare (CF-Connecting-IP)"
            printf "  %-14s %s\n" "Ranges" "${ranges} trusted${refreshed:+, fetched ${refreshed/T/ }}"
            printf "  %-14s %s\n" "Kept by" "$(case "$by" in zero-trust) echo "Zero Trust (cipi zt)";; both) echo "cipi nginx real-ip and Zero Trust";; *) echo "cipi nginx real-ip";; esac)"
            printf "  %-14s %s\n" "File" "$ZT_REALIP" ;;
    esac
    echo ""
}

# ── An app's own nginx directives ─────────────────────────────
#   cipi nginx show <app> [--json]
#   cipi nginx edit <app>                      in $EDITOR, at a terminal
#   cipi nginx set <app> --file=<path>         (- for stdin)
#   cipi nginx set <app> --content-b64=<…>     what the API sends
#   cipi nginx reset <app>
#
# The vhost of an app is Cipi's: it is written again at every alias, SSL,
# PHP, basic auth or routing change, so an edit of /etc/nginx/sites-available
# does not last. What lasts is this: directives kept in apps.json and included
# in the app's server block (lib/app.sh, nginx_custom_render) — headers,
# caching, limits, rewrites, locations of your own. A location Cipi already
# defines cannot be defined twice: nginx says so, and nothing changes.
#
# Every change is tested with `nginx -t` before nginx reloads; refused, the
# app's settings and its vhost go back to what they were and nginx's reason
# is shown. From the API (SUDO_USER=www-data) only the directives in
# lib/nginx-lint.sh are taken: the whole language would make a token root.

[[ -z "${_NGINX_CUSTOM_MAX:-}" ]] && readonly _NGINX_CUSTOM_MAX=32768

_nginx_custom_from_api() { [[ "${SUDO_USER:-}" == "www-data" ]]; }

_nginx_custom_require() {
    local app="${1:-}" what="$2"
    [[ -n "$app" && "$app" != --* ]] || { error "Usage: cipi nginx ${what}"; exit 1; }
    declare -f _create_nginx_vhost >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
}

# _nginx_custom_lint <app> < text — the API's subset (lib/nginx-lint.sh).
declare -f _nginx_custom_lint >/dev/null 2>&1 || source "${CIPI_LIB}/nginx-lint.sh"

# nginx's own words about the app's file, without the path: "line 3: unknown directive "foo"".
_nginx_custom_reason() {
    local file="$1" out="$2"
    printf '%s\n' "$out" | grep -F "$file" | head -5 \
        | sed -e 's/^nginx: \[[a-z]*\] //' -e "s#^\\(.*\\) in ${file}:\\([0-9][0-9]*\\)\$#line \\2: \\1#" -e "s#${file}#the app's directives#g" \
        | tr -d '\000-\010\013-\037\177' | cut -c1-300
}

# Save the text (empty: none) as the app's directives and reload nginx with
# them. Refused by nginx: everything back as it was, 1.
_nginx_custom_apply() {
    local app="$1" text="$2" before out file reason
    declare -f _routes_app_json >/dev/null 2>&1 || source "${CIPI_LIB}/routes.sh"
    _routes_preflight || return 1
    before=$(_routes_app_json "$app")
    file=$(_nginx_custom_file "$app")
    if [[ -z "${text//[[:space:]]/}" ]]; then
        app_unset "$app" nginx_custom
    else
        app_set "$app" nginx_custom "$(printf '%s' "$text" | base64 -w0)"
    fi
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    if out=$(nginx -t 2>&1); then
        systemctl reload nginx || { error "systemctl reload nginx failed"; return 1; }
        [[ "$(app_get "$app" suspended)" == "true" ]] && \
            warn "'${app}' is suspended — the directives are saved and take effect on: cipi app unsuspend ${app}"
        return 0
    fi
    error "nginx refused the directives — nothing changed"
    reason=$(_nginx_custom_reason "$file" "$out")
    [[ -n "$reason" ]] && printf '%s\n' "$reason" | sed 's/^/  /' >&2
    app_save "$app" "$before" || true
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    nginx -t >/dev/null 2>&1 || warn "nginx -t still fails after putting the vhost back — run: nginx -t"
    return 1
}

# Checks that do not need nginx: size, control characters, and from the API
# (or with --strict) the allowed subset. Problems on stderr, 1.
_nginx_custom_check() {
    local app="$1" text="$2" problems
    if (( $(printf '%s' "$text" | wc -c) > _NGINX_CUSTOM_MAX )); then
        error "The directives are too long ($(( _NGINX_CUSTOM_MAX / 1024 )) KB at most)"; return 1
    fi
    if printf '%s' "$text" | LC_ALL=C grep -q $'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]'; then
        error "The directives hold a control character"; return 1
    fi
    if _nginx_custom_from_api || [[ "${ARG_strict:-}" == "true" ]]; then
        if ! problems=$(printf '%s' "$text" | _nginx_custom_lint "$app"); then
            error "Not accepted from the API — the whole nginx language is for 'cipi nginx edit ${app}' at the server"
            printf '%s\n' "$problems" | sed 's/^/  /' >&2
            return 1
        fi
    fi
}

nginx_custom_show() {
    local app="${1:-}"; _nginx_custom_require "$app" "show <app> [--json]"; shift
    parse_args "$@"
    local text file active=false
    text=$(nginx_custom_get "$app"; printf x); text="${text%x}"
    file=$(_nginx_custom_file "$app")
    [[ -s "$file" ]] && grep -qF "include ${file};" "/etc/nginx/sites-available/${app}" 2>/dev/null && active=true
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg app "$app" --arg config "$text" --arg file "$file" --argjson active "$active" \
              --argjson max "$_NGINX_CUSTOM_MAX" \
              --argjson suspended "$([[ "$(app_get "$app" suspended)" == "true" ]] && echo true || echo false)" \
              '{app: $app, config: $config, bytes: ($config | utf8bytelength), max_bytes: $max, file: $file, active: $active, suspended: $suspended}'
        return 0
    fi
    echo -e "\n${BOLD}nginx — ${app}${NC} ${DIM}(${file})${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -z "${text//[[:space:]]/}" ]]; then
        echo -e "  ${DIM}No directives of its own — add them with: cipi nginx edit ${app}${NC}\n"
        return 0
    fi
    printf '%s\n' "${text%$'\n'}"
    [[ "$active" == "true" ]] || echo -e "\n  ${YELLOW}Saved, not in the vhost right now${NC} ${DIM}(suspended app?)${NC}"
    echo ""
}

nginx_custom_set() {
    local app="${1:-}"; _nginx_custom_require "$app" "set <app> --file=<path|-> | --content-b64=<base64>"; shift
    unset ARG_file ARG_content_b64 ARG_strict
    parse_args "$@"
    local text
    if [[ -n "${ARG_content_b64+x}" ]]; then
        [[ "${ARG_content_b64}" =~ ^[A-Za-z0-9+/=]*$ ]] || { error "--content-b64 is not base64"; exit 1; }
        text=$(printf '%s' "${ARG_content_b64}" | base64 -d 2>/dev/null; printf x) || { error "--content-b64 is not base64"; exit 1; }
        text="${text%x}"
    elif [[ -n "${ARG_file:-}" ]]; then
        _nginx_custom_from_api && { error "--file is for the terminal — the API sends --content-b64"; exit 1; }
        if [[ "${ARG_file}" == "-" ]]; then
            text=$(head -c $(( _NGINX_CUSTOM_MAX + 1 )); printf x)
        else
            [[ -f "${ARG_file}" && -r "${ARG_file}" ]] || { error "Cannot read ${ARG_file}"; exit 1; }
            text=$(head -c $(( _NGINX_CUSTOM_MAX + 1 )) -- "${ARG_file}"; printf x)
        fi
        text="${text%x}"
    else
        error "Usage: cipi nginx set <app> --file=<path|-> | --content-b64=<base64>"; exit 1
    fi
    text="${text//$'\r'/}"
    _nginx_custom_check "$app" "$text" || exit 1
    local current
    current=$(nginx_custom_get "$app"; printf x); current="${current%x}"
    if [[ "$text" == "$current" ]]; then
        info "No change: these are already the directives of '${app}'"
        return 0
    fi
    _nginx_custom_apply "$app" "$text" || exit 1
    if [[ -z "${text//[[:space:]]/}" ]]; then
        success "Directives of '${app}' removed"
        log_action "NGINX CUSTOM RESET: ${app}"
    else
        success "Directives of '${app}' saved and live ($(printf '%s' "$text" | wc -c) bytes)"
        log_action "NGINX CUSTOM SET: ${app}"
    fi
}

nginx_custom_reset() {
    local app="${1:-}"; _nginx_custom_require "$app" "reset <app>"; shift
    if [[ -z "$(app_get "$app" nginx_custom)" ]]; then
        info "'${app}' has no directives of its own"
        return 0
    fi
    _nginx_custom_apply "$app" "" || exit 1
    success "Directives of '${app}' removed"
    log_action "NGINX CUSTOM RESET: ${app}"
}

nginx_custom_edit() {
    local app="${1:-}"; _nginx_custom_require "$app" "edit <app>"
    _nginx_custom_from_api && { error "cipi nginx edit is for a terminal — the API uses: cipi nginx set"; exit 1; }
    [[ -t 0 && -t 1 ]] || { error "cipi nginx edit needs a terminal — in a script: cipi nginx set ${app} --file=<path>"; exit 1; }
    local tmp text current
    current=$(nginx_custom_get "$app"; printf x); current="${current%x}"
    tmp=$(mktemp /tmp/cipi-nginx-XXXXXX.conf) || { error "mktemp failed"; exit 1; }
    chmod 600 "$tmp"
    if [[ -n "${current//[[:space:]]/}" ]]; then
        printf '%s\n' "${current%$'\n'}" > "$tmp"
    else
        cat > "$tmp" <<'TEMPLATE'
# nginx directives of this app — included in its server block.
# Lines starting with # are comments. Save an empty file to have none.
#
# client_max_body_size 512M;
# location ^~ /downloads/ {
#     add_header Cache-Control "public, max-age=31536000, immutable";
# }
TEMPLATE
    fi
    while true; do
        ${EDITOR:-nano} "$tmp" || { rm -f "$tmp"; error "The editor exited with an error — nothing changed"; exit 1; }
        text=$(cat "$tmp"; printf x); text="${text%x}"; text="${text//$'\r'/}"
        # Only comments and blank lines: nothing to include.
        grep -qvE '^[[:space:]]*(#.*)?$' "$tmp" || text=""
        if [[ "${text%$'\n'}" == "${current%$'\n'}" ]]; then
            rm -f "$tmp"; info "No change"; return 0
        fi
        if _nginx_custom_check "$app" "$text" && _nginx_custom_apply "$app" "$text"; then
            rm -f "$tmp"
            if [[ -z "$text" ]]; then success "Directives of '${app}' removed"; log_action "NGINX CUSTOM RESET: ${app}"
            else success "Directives of '${app}' saved and live"; log_action "NGINX CUSTOM SET: ${app}"; fi
            return 0
        fi
        confirm_yes "Open the editor again?" || { rm -f "$tmp"; warn "Nothing changed"; exit 1; }
    done
}
