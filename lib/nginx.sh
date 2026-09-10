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

nginx_setup_mainline_repo() {
    apt-get install -y -qq curl gnupg2 ca-certificates lsb-release ubuntu-keyring 2>/dev/null || true

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg

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

# Upgrade to nginx.org mainline (>= 1.29.8) and apply max_headers.
# Idempotent — safe to re-run.
nginx_upgrade_mainline_for_http2_bomb() {
    local cur_ver workers candidate

    cur_ver=$(nginx_installed_version 2>/dev/null || echo "")
    if [[ -n "$cur_ver" ]] \
       && nginx_version_at_least "$cur_ver" \
       && grep -qE '^\s*max_headers\s' /etc/nginx/nginx.conf 2>/dev/null \
       && ! grep -q 'more_clear_headers' /etc/nginx/nginx.conf 2>/dev/null; then
        echo "  Nginx ${cur_ver} with max_headers already configured — nothing to do"
        return 0
    fi

    workers=$(grep -E '^worker_processes' /etc/nginx/nginx.conf 2>/dev/null \
        | awk '{print $2}' | tr -d ';')
    [[ -z "$workers" || "$workers" == "auto" ]] && workers=$(nproc)

    echo "  Configuring nginx.org mainline repository..."
    nginx_setup_mainline_repo

    candidate=$(apt-cache policy nginx 2>/dev/null | awk '/Candidate:/{print $2}')
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        echo "  ERROR: nginx mainline package not available from APT."
        echo "  HTTP/2 bomb mitigation not applied — check nginx.org repo / network."
        return 1
    fi
    echo "  nginx candidate: ${candidate}"

    # Ubuntu's headers-more module is tied to distro nginx; drop before switching packages.
    apt-get purge -y -qq libnginx-mod-http-headers-more-filter 2>/dev/null || true

    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -qq nginx 2>/dev/null; then
        echo "  ERROR: failed to install nginx from nginx.org mainline repository."
        return 1
    fi

    cur_ver=$(nginx_installed_version 2>/dev/null || echo "")
    if [[ -n "$cur_ver" ]] && ! nginx_version_at_least "$cur_ver"; then
        echo "  WARNING: installed nginx ${cur_ver} is below ${_NGINX_MIN_VERSION} (max_headers may be missing)."
    fi

    echo "  Rewriting /etc/nginx/nginx.conf (max_headers, drop headers-more module)..."
    nginx_ensure_sites_layout
    nginx_write_global_conf "$workers"

    if ! nginx -t 2>&1; then
        echo "  ERROR: nginx -t failed after upgrade — please review /etc/nginx/nginx.conf"
        return 1
    fi

    systemctl enable nginx 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    echo "  Nginx upgraded to $(nginx_installed_version 2>/dev/null || echo unknown)"
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
        *) error "Use: cipi nginx default-server on|off|status | upgrade [--yes]"; exit 1 ;;
    esac
}
