#!/bin/bash
#############################################
# Cipi — SSL (Let's Encrypt)
#############################################

ssl_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install) _ssl_install "$@" ;;
        renew)   _ssl_renew ;;
        status)  _ssl_status ;;
        *) error "Use: install renew status"; exit 1 ;;
    esac
}

_ssl_install() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi ssl install <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
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

    local domains="-d ${d}"
    local aliases
    aliases=$(jq -r --arg a "$app" '.[$a].aliases // [] | .[]' "${CIPI_CONFIG}/apps.json" 2>/dev/null || true)
    while read -r a; do
        [[ -n "$a" ]] && domains+=" -d ${a}"
    done <<< "${aliases:-}"

    echo ""
    step "Installing SSL for ${d}$([ -n "${aliases}" ] && echo " + aliases")..."
    echo ""

    if certbot --nginx $domains \
        --cert-name "${d}" \
        --expand \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect 2>&1; then

        # Force nginx test + reload after certbot modifies the vhost
        if nginx -t 2>&1; then
            systemctl reload nginx 2>/dev/null || true
        else
            error "Nginx config test failed after certbot modification. Check: nginx -t"
            exit 1
        fi

        sed -i "s|^APP_URL=http://|APP_URL=https://|" "/home/${app}/shared/.env" 2>/dev/null || true
        log_action "SSL INSTALLED: $app"
        echo ""
        success "SSL installed for ${d}"
    else
        echo ""
        error "SSL failed. Check: DNS points to this server, port 80 is open, domain is correct."
        exit 1
    fi
}

_ssl_renew() {
    step "Renewing certificates..."
    certbot renew --nginx --non-interactive 2>&1
    systemctl reload nginx 2>/dev/null
    success "Renewal complete"
}

_ssl_status() {
    echo -e "\n${BOLD}SSL Certificates${NC}"
    certbot certificates 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *"Certificate Name:"*) echo -e "\n  ${BOLD}${line##*: }${NC}" ;;
            *"Domains:"*)          echo -e "    Domains: ${CYAN}${line##*: }${NC}" ;;
            *"Expiry Date:"*)
                local exp; exp=$(echo "${line##*: }"|awk '{print $1}')
                local days; days=$(( ($(date -d "$exp" +%s) - $(date +%s)) / 86400 ))
                local c="${GREEN}"; [[ $days -lt 14 ]] && c="${RED}"; [[ $days -lt 30 && $days -ge 14 ]] && c="${YELLOW}"
                echo -e "    Expiry:  ${c}${exp} (${days}d)${NC}" ;;
        esac
    done; echo ""
}
