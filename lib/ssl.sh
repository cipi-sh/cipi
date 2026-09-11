#!/bin/bash
#############################################
# Cipi — SSL (Let's Encrypt)
#############################################

_ssl_zt_lock_http() {
    vault_read zt.json 2>/dev/null | jq -e '.lock_http == true' >/dev/null 2>&1
}

_ssl_app_on_tunnel() {
    vault_read zt.json 2>/dev/null | jq -e --arg a "$1" '.hostnames[$a] != null' >/dev/null 2>&1
}

_ssl_certbot_redirect_flag() {
    if _ssl_app_on_tunnel "$1"; then
        echo "--no-redirect"
    else
        echo "--redirect"
    fi
}

ssl_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install) _ssl_install "$@" ;;
        force)   _ssl_force "$@" ;;
        renew)   _ssl_renew ;;
        status)  _ssl_status ;;
        dns)     _ssl_dns "$@" ;;
        *) error "Use: install force renew status dns"; exit 1 ;;
    esac
}

_ssl_dns() {
    local action="${1:-}"; shift || true
    case "$action" in
        set|configure) _ssl_dns_set "$@" ;;
        show)          _ssl_dns_show ;;
        *) error "Usage: cipi ssl dns set --provider=cloudflare --token=TOKEN"; exit 1 ;;
    esac
}

_ssl_dns_set() {
    parse_args "$@"
    local provider="${ARG_provider:-cloudflare}"
    local token="${ARG_token:-}"
    [[ "$provider" == "cloudflare" ]] || { error "Supported DNS providers: cloudflare"; exit 1; }
    [[ -z "$token" ]] && read_input "Cloudflare API token" "" token
    [[ -z "$token" ]] && { error "Token required"; exit 1; }

    # Install certbot DNS plugin if missing
    if ! dpkg -l python3-certbot-dns-cloudflare 2>/dev/null | grep -q '^ii'; then
        step "Installing certbot-dns-cloudflare..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-certbot-dns-cloudflare >/dev/null
    fi

    local creds="/etc/cipi/cloudflare.ini"
    cat > "$creds" <<EOF
# Cloudflare API token for certbot DNS-01 (Cipi)
dns_cloudflare_api_token = ${token}
EOF
    chmod 600 "$creds"
    chown root:root "$creds"

    echo "{\"provider\":\"cloudflare\",\"configured_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}" \
        | vault_write ssl-dns.json
    log_action "SSL DNS CONFIGURED: cloudflare"
    success "Cloudflare DNS-01 credentials saved (root-only ${creds})"
}

_ssl_dns_show() {
    if [[ -f "${CIPI_CONFIG}/ssl-dns.json" ]]; then
        vault_read ssl-dns.json | jq .
    else
        info "DNS-01 not configured. Run: cipi ssl dns set --provider=cloudflare --token=TOKEN"
    fi
    if [[ -f /etc/cipi/cloudflare.ini ]]; then
        echo -e "  Credentials file: ${CYAN}/etc/cipi/cloudflare.ini${NC} (present)"
    fi
}

_ssl_install() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi ssl install <app> [--dns=cloudflare] [--wildcard]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local d; d=$(app_get "$app" domain)
    [[ -z "$d" ]] && { error "No domain for app '$app'"; exit 1; }

    # Pre-flight: nginx vhost must exist
    if [[ ! -f "/etc/nginx/sites-available/${app}" ]]; then
        error "Nginx vhost for '${app}' not found. Create the app first."
        exit 1
    fi

    # Pre-flight: nginx must be serving the domain on port 80
    if ! nginx -t 2>/dev/null; then
        error "Nginx config test failed. Fix nginx errors before installing SSL."
        exit 1
    fi

    local dns_provider="${ARG_dns:-}"
    local wildcard="${ARG_wildcard:-}"

    if [[ -z "$dns_provider" ]]; then
        if [[ "$(app_get "$app" ssl_origin_ca)" == "true" ]]; then
            error "App '${app}' uses a Cloudflare Origin CA certificate (cipi zt origin-cert)."
            echo -e "  ${DIM}HTTP-01 would overwrite it. Keep Origin CA, or: cipi ssl install ${app} --dns=cloudflare${NC}"
            exit 1
        fi
        if _ssl_zt_lock_http; then
            error "HTTP-01 cannot work while cipi zt lock http is on (Let's Encrypt does not come from Cloudflare IPs)."
            echo -e "  ${DIM}cipi ssl install ${app} --dns=cloudflare${NC}"
            echo -e "  ${DIM}cipi zt origin-cert ${app}${NC}"
            echo -e "  ${DIM}cipi zt unlock http${NC}  (only if you really want HTTP-01 again)"
            exit 1
        fi
    fi

    if [[ -n "$dns_provider" ]]; then
        _ssl_install_dns01 "$app" "$d" "$dns_provider" "$wildcard"
        return $?
    fi

    # Let's Encrypt issues a wildcard certificate over DNS-01 only. Sending
    # "*.example.com" to the HTTP-01 challenge fails the *whole* order, so the
    # primary is refused up front and a wildcard alias is left out of this
    # certificate instead of taking the other domains down with it.
    if domain_is_wildcard "$d"; then
        error "'${d}' is a wildcard domain — HTTP-01 cannot validate it."
        echo -e "  ${DIM}cipi ssl dns set --provider=cloudflare --token=<TOKEN>${NC}"
        echo -e "  ${DIM}cipi ssl install ${app} --dns=cloudflare${NC}"
        exit 1
    fi

    local domains="-d ${d}"
    local aliases skipped=""
    # Exclude primary domain from aliases to avoid duplicates
    aliases=$(vault_read apps.json | jq -r --arg a "$app" --arg d "$d" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
    while read -r a; do
        [[ -n "$a" ]] || continue
        if domain_is_wildcard "$a"; then
            skipped="${skipped} ${a}"
            continue
        fi
        domains+=" -d ${a}"
    done <<< "${aliases:-}"
    if [[ -n "$skipped" ]]; then
        warn "Skipping wildcard alias(es):${skipped} — they need DNS-01 (cipi ssl install ${app} --dns=cloudflare)"
    fi

    echo ""
    step "Installing SSL for ${d}$([ -n "${aliases}" ] && echo " + aliases")..."
    echo ""

    if certbot --nginx $domains \
        --cert-name "$(domain_cert_name "$d")" \
        --expand \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        $(_ssl_certbot_redirect_flag "$app") 2>&1; then

        # Force nginx test + reload after certbot modifies the vhost
        if nginx -t 2>&1; then
            systemctl reload nginx 2>/dev/null || true
        else
            error "Nginx config test failed after certbot modification. Check: nginx -t"
            exit 1
        fi

        sed -i "s|^APP_URL=http://|APP_URL=https://|" "/home/${app}/shared/.env" 2>/dev/null || true
        app_set "$app" force_https "true"
        app_unset "$app" ssl_dns_provider 2>/dev/null || true
        # A certificate turns ws:// into wss:// for a Reverb app: without this
        # the browser blocks the socket as mixed content while nginx is already
        # serving it over TLS, and nothing shows up in the Reverb log.
        if [[ -n "$(app_get "$app" reverb)" ]]; then
            declare -f _reverb_sync_env >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
            _reverb_sync_env "$app"
        fi

        log_action "SSL INSTALLED: $app"
        cipi_notify \
            "Cipi SSL installed: ${d} (${app}) on $(hostname)" \
            "An SSL certificate was installed.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            ssl_install
        echo ""
        success "SSL installed for ${d}"
    else
        echo ""
        error "SSL failed. Check: DNS points to this server, port 80 is open, domain is correct."
        exit 1
    fi
}

_ssl_install_dns01() {
    local app="$1" d="$2" provider="$3" wildcard="${4:-}"
    [[ "$provider" == "cloudflare" ]] || { error "Supported --dns providers: cloudflare"; exit 1; }
    [[ -f /etc/cipi/cloudflare.ini ]] || {
        error "DNS credentials missing. Run: cipi ssl dns set --provider=cloudflare --token=TOKEN"
        exit 1
    }
    if ! command -v certbot &>/dev/null; then
        error "certbot not found"; exit 1
    fi

    # Apex for wildcard: drop the wildcard label and a leading www. so
    # "*.apex" is built once, whether or not the primary is already a wildcard.
    local apex; apex=$(domain_cert_name "$d")
    [[ "$apex" == www.* ]] && apex="${apex#www.}"
    # certbot rejects "*" in a lineage name and stores a wildcard cert under the
    # bare domain, so the whole app must address it by that name.
    local cert; cert=$(domain_cert_name "$d")

    local domains="-d ${d}"
    if [[ "$wildcard" == "true" ]]; then
        domains="-d ${apex} -d *.${apex}"
        # Cert name stays on primary app domain for certbot install compatibility
    else
        local aliases
        aliases=$(vault_read apps.json | jq -r --arg a "$app" --arg d "$d" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
        while read -r a; do
            [[ -n "$a" ]] && domains+=" -d ${a}"
        done <<< "${aliases:-}"
    fi

    echo ""
    step "Installing SSL via DNS-01 (${provider}) for ${d}${wildcard:+ (wildcard)}..."
    echo ""

    if ! certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /etc/cipi/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 \
        $domains \
        --cert-name "${cert}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --expand 2>&1; then
        echo ""
        error "DNS-01 certificate issuance failed. Check Cloudflare token permissions (Zone:DNS:Edit)."
        exit 1
    fi

    if ! certbot install --nginx --cert-name "${cert}" --non-interactive $(_ssl_certbot_redirect_flag "$app") 2>&1; then
        error "Certificate issued but nginx install failed. Check: nginx -t"
        error "The certificate is saved under /etc/letsencrypt/live/${cert} — reapply with: cipi ssl force ${app}"
        exit 1
    fi

    if nginx -t 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    else
        error "Nginx config test failed after certbot install. Check: nginx -t"
        exit 1
    fi

    sed -i "s|^APP_URL=http://|APP_URL=https://|" "/home/${app}/shared/.env" 2>/dev/null || true
    app_set "$app" force_https "true"
    app_set "$app" ssl_dns_provider "$provider"
    # Same as HTTP-01 above: move a Reverb app's clients onto wss://.
    if [[ -n "$(app_get "$app" reverb)" ]]; then
        declare -f _reverb_sync_env >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        _reverb_sync_env "$app"
    fi

    log_action "SSL INSTALLED DNS-01: $app provider=$provider wildcard=${wildcard:-false}"
    cipi_notify \
        "Cipi SSL installed (DNS-01): ${d} (${app}) on $(hostname)" \
        "An SSL certificate was installed via DNS-01.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\nProvider: ${provider}\nWildcard: ${wildcard:-false}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ssl_install
    echo ""
    success "SSL installed for ${d} via DNS-01 (${provider})"
}

# Re-apply HTTP → HTTPS redirect for an app that already has a certificate.
# Useful after vhost regeneration (alias/www/basicauth) when the Certbot
# redirect block was overwritten. No new ACME issuance — no rate-limit risk.
_ssl_force() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi ssl force <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local d; d=$(app_get "$app" domain)
    [[ -z "$d" ]] && { error "No domain for app '$app'"; exit 1; }

    local cert; cert=$(domain_cert_name "$d")
    if [[ ! -d "/etc/letsencrypt/live/${cert}" ]]; then
        error "No SSL certificate for '${d}'. Run: cipi ssl install ${app}"
        exit 1
    fi
    if [[ ! -f "/etc/nginx/sites-available/${app}" ]]; then
        error "Nginx vhost for '${app}' not found."
        exit 1
    fi
    if ! command -v certbot &>/dev/null; then
        error "certbot not found"; exit 1
    fi

    if _ssl_app_on_tunnel "$app"; then
        error "App '${app}' is on the Cloudflare tunnel — origin HTTP→HTTPS redirect would break it."
        echo "  Cloudflare already terminates HTTPS at the edge. The tunnel talks HTTP to :80."
        exit 1
    fi

    step "Forcing HTTP → HTTPS redirect for ${d}..."
    if ! certbot install --nginx --cert-name "${cert}" --non-interactive --redirect 2>&1; then
        error "Failed to apply HTTPS redirect. Check: nginx -t"
        exit 1
    fi
    if nginx -t 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    else
        error "Nginx config test failed after redirect. Check: nginx -t"
        exit 1
    fi

    app_set "$app" force_https "true"
    log_action "SSL FORCE HTTPS: $app"
    cipi_notify \
        "Cipi SSL force HTTPS: ${d} (${app}) on $(hostname)" \
        "HTTP → HTTPS redirect was forced.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ssl_force
    success "HTTP → HTTPS redirect enabled for ${d}"
}

_ssl_renew() {
    step "Renewing certificates..."
    if certbot renew --quiet 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        log_action "SSL RENEWED"
        cipi_notify \
            "Cipi SSL renewed on $(hostname)" \
            "SSL certificates were renewed.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            ssl_renew
        success "Renewal complete"
    else
        error "Renewal failed"
        exit 1
    fi
}

_ssl_status() {
    echo -e "\n${BOLD}SSL certificates${NC}"
    if [[ ! -d /etc/letsencrypt/live ]]; then
        info "No certificates"
        return
    fi
    local name
    for name in /etc/letsencrypt/live/*/; do
        [[ -d "$name" ]] || continue
        local cn; cn=$(basename "$name")
        [[ "$cn" == "README" ]] && continue
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "${name}cert.pem" 2>/dev/null | cut -d= -f2 || echo "?")
        printf "  %-40s %s\n" "$cn" "$expiry"
    done
    echo ""
}
