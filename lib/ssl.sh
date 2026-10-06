#!/bin/bash
#############################################
# Cipi — SSL (Let's Encrypt)
#############################################

_ssl_zt_lock_http() {
    vault_read zt.json 2>/dev/null | jq -e '.lock_http == true' >/dev/null 2>&1
}

_ssl_app_on_tunnel() { app_on_cf_tunnel "$1"; }

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

# ── DNS-01 credentials: one or more Cloudflare accounts ──────
#
#   cipi ssl dns set [--name=NAME] --token=TOKEN    add an account, or replace its token
#   cipi ssl dns list                               accounts and the certificates on each
#   cipi ssl dns remove <NAME>                      refused while a certificate renews with it
#
# Without --name the account is "default", the single token Cipi always had
# (/etc/cipi/cloudflare.ini). Named accounts live next to it, one file each.
# certbot records the credentials file in every certificate's renewal config,
# so each certificate renews with the token of the account it was issued with.

[[ -z "${SSL_DNS_DEFAULT_CREDS:-}" ]] && readonly SSL_DNS_DEFAULT_CREDS="/etc/cipi/cloudflare.ini"
[[ -z "${SSL_DNS_DIR:-}" ]]           && readonly SSL_DNS_DIR="/etc/cipi/cloudflare"
[[ -z "${SSL_RENEWAL_DIR:-}" ]]       && readonly SSL_RENEWAL_DIR="/etc/letsencrypt/renewal"

_ssl_dns() {
    local action="${1:-}"; shift || true
    case "$action" in
        set|configure) _ssl_dns_set "$@" ;;
        list|ls|show)  _ssl_dns_list "$@" ;;
        remove|rm)     _ssl_dns_remove "$@" ;;
        *) error "Usage: cipi ssl dns set [--name=NAME] --token=TOKEN | list | remove <NAME>"; exit 1 ;;
    esac
}

# A name ends up in a path: lowercase letters, digits, - and _ only.
_ssl_dns_valid_name() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

# The credentials file of an account ("default" is the original single file).
_ssl_dns_creds_file() {
    local name="${1:-default}"
    if [[ "$name" == "default" ]]; then
        echo "$SSL_DNS_DEFAULT_CREDS"
    else
        _ssl_dns_valid_name "$name" || return 1
        echo "${SSL_DNS_DIR}/${name}.ini"
    fi
}

# Every configured account, "default" first.
_ssl_dns_accounts() {
    [[ -f "$SSL_DNS_DEFAULT_CREDS" ]] && echo "default"
    local f n
    shopt -s nullglob
    for f in "${SSL_DNS_DIR}"/*.ini; do
        n="${f##*/}"; n="${n%.ini}"
        _ssl_dns_valid_name "$n" && [[ "$n" != "default" ]] && echo "$n"
    done
    shopt -u nullglob
    return 0
}

# Certificates whose renewal uses this credentials file, one name per line.
_ssl_dns_certs_using() {
    local file="$1" conf val
    shopt -s nullglob
    for conf in "${SSL_RENEWAL_DIR}"/*.conf; do
        val=$(sed -n 's/^dns_cloudflare_credentials[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | head -1 || true)
        val="${val%"${val##*[![:space:]]}"}"
        if [[ "$val" == "$file" ]]; then
            conf="${conf##*/}"
            echo "${conf%.conf}"
        fi
    done
    shopt -u nullglob
    return 0
}

_ssl_dns_set() {
    parse_args "$@"
    local provider="${ARG_provider:-cloudflare}"
    local token="${ARG_token:-}"
    local name="${ARG_name:-default}"
    [[ "$provider" == "cloudflare" ]] || { error "Supported DNS providers: cloudflare"; exit 1; }
    local creds
    creds=$(_ssl_dns_creds_file "$name") || {
        error "Invalid account name '${name}' — lowercase letters, digits, - and _ (max 32)"
        exit 1
    }
    [[ -z "$token" ]] && read_input "Cloudflare API token" "" token
    [[ -z "$token" ]] && { error "Token required"; exit 1; }
    # One line of printable characters: it is written into an ini file.
    if [[ ! "$token" =~ ^[[:graph:]]{20,255}$ ]]; then
        error "That does not look like a Cloudflare API token (no spaces, at least 20 characters)"
        exit 1
    fi

    # Install certbot DNS plugin if missing
    if ! dpkg -l python3-certbot-dns-cloudflare 2>/dev/null | grep -q '^ii'; then
        step "Installing certbot-dns-cloudflare..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-certbot-dns-cloudflare >/dev/null
    fi

    local existed=false
    [[ -f "$creds" ]] && existed=true
    if [[ "$name" != "default" ]]; then
        mkdir -p "$SSL_DNS_DIR"
        chmod 700 "$SSL_DNS_DIR"
        chown root:root "$SSL_DNS_DIR" 2>/dev/null || true
    fi
    # umask: the token is never readable by anyone else, not even while it is written.
    ( umask 077; cat > "$creds" <<EOF
# Cloudflare API token for certbot DNS-01 (Cipi) — account: ${name}
dns_cloudflare_api_token = ${token}
EOF
    ) || { error "Could not write ${creds}"; exit 1; }
    chmod 600 "$creds"
    chown root:root "$creds" 2>/dev/null || true

    if [[ "$name" == "default" ]]; then
        echo "{\"provider\":\"cloudflare\",\"configured_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}" \
            | vault_write ssl-dns.json
    fi
    log_action "SSL DNS CONFIGURED: cloudflare account=${name}"
    if [[ "$existed" == true ]]; then
        success "Cloudflare account '${name}': token replaced (root-only ${creds})"
        echo -e "  ${DIM}Certificates issued with this account renew with the new token.${NC}"
    else
        success "Cloudflare account '${name}' saved (root-only ${creds})"
    fi
    if [[ "$name" == "default" ]]; then
        echo -e "  ${DIM}Use it: cipi ssl install <app> --dns=cloudflare [--wildcard]${NC}"
    else
        echo -e "  ${DIM}Use it: cipi ssl install <app> --dns=cloudflare --account=${name} [--wildcard]${NC}"
    fi
}

_ssl_dns_list() {
    parse_args "$@"
    local accounts name file certs
    accounts=$(_ssl_dns_accounts)

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            file=$(_ssl_dns_creds_file "$name")
            certs=$(_ssl_dns_certs_using "$file" | jq -R . | jq -sc .)
            items=$(jq -c --arg n "$name" --argjson c "$certs" '. + [{account: $n, provider: "cloudflare", certificates: $c}]' <<< "$items")
        done <<< "$accounts"
        jq -n --argjson a "$items" '{accounts: $a}'
        return 0
    fi

    echo -e "\n${BOLD}DNS-01 accounts (Cloudflare)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -z "$accounts" ]]; then
        echo -e "  ${DIM}none — add one with: cipi ssl dns set [--name=NAME] --token=TOKEN${NC}\n"
        return 0
    fi
    printf "  ${BOLD}%-20s %s${NC}\n" "ACCOUNT" "CERTIFICATES"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        file=$(_ssl_dns_creds_file "$name")
        certs=$(_ssl_dns_certs_using "$file" | tr '\n' ' ')
        printf "  %-20s %s\n" "$name" "${certs:-—}"
    done <<< "$accounts"
    echo ""
    echo -e "  ${DIM}Issue with an account: cipi ssl install <app> --dns=cloudflare --account=NAME [--wildcard]${NC}"
    echo -e "  ${DIM}Tokens are stored root-only and never shown.${NC}"
    echo ""
}

_ssl_dns_remove() {
    local name="${1:-}"
    [[ -z "$name" || "$name" == --* ]] && { error "Usage: cipi ssl dns remove <NAME>   (see: cipi ssl dns list)"; exit 1; }
    local creds
    creds=$(_ssl_dns_creds_file "$name") || { error "Invalid account name '${name}'"; exit 1; }
    [[ -f "$creds" ]] || { error "Cloudflare account '${name}' is not configured"; exit 1; }

    # Without its token a certificate stops renewing, silently, until it expires.
    local certs
    certs=$(_ssl_dns_certs_using "$creds" | tr '\n' ' ')
    if [[ -n "$certs" ]]; then
        error "Account '${name}' is still used to renew: ${certs}"
        echo -e "  ${DIM}Reissue those with another account first: cipi ssl install <app> --dns=cloudflare --account=OTHER${NC}"
        exit 1
    fi

    rm -f "$creds"
    if [[ "$name" == "default" ]]; then
        rm -f "${CIPI_CONFIG:?}/ssl-dns.json"
    fi
    log_action "SSL DNS REMOVED: cloudflare account=${name}"
    success "Cloudflare account '${name}' removed"
}

# ── Install ──────────────────────────────────────────────────
#
# certbot only issues the certificate (certonly): HTTP-01 through its nginx
# authenticator, DNS-01 through Cloudflare. The vhost is then rewritten by
# Cipi with that certificate (_create_nginx_vhost → nginx_vhost_apply_tls),
# so wildcard names, tenants and Origin CA certificates all take the same
# path. `certbot install` is never used on an app vhost.

# Names for the app's certificate: primary and aliases, plus "*.<apex>" when a
# wildcard certificate is asked for, minus what a wildcard of the list already
# covers (Let's Encrypt refuses such an order). One per line.
#   <wildcard>  true: add "*.<apex>"; "http": leave every wildcard out (HTTP-01
#               cannot validate one), and with it nothing counts as covered.
_ssl_app_cert_names() {
    local app="$1" wildcard="${2:-}" d apex a
    d=$(app_get "$app" domain)
    local -a all=()
    # --wildcard: the apex and "*.<apex>" first (the apex names the certificate),
    # as it always did — whether or not the app serves the apex itself.
    if [[ "$wildcard" == "true" ]]; then
        apex=$(domain_cert_name "$d")
        [[ "$apex" == www.* ]] && apex="${apex#www.}"
        all+=("$apex" "*.${apex}")
    fi
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        [[ "$wildcard" == "http" ]] && domain_is_wildcard "$a" && continue
        all+=("$a")
    done < <(echo "$d"; vault_read apps.json | jq -r --arg a "$app" --arg d "$d" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
    [[ ${#all[@]} -gt 0 ]] || return 0
    cert_names_for "${all[@]}"
}

# Rewrite the app vhost — with its certificate now — and reload nginx.
_ssl_apply_vhost() {
    local app="$1"
    declare -f _create_nginx_vhost >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    if ! grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "/etc/nginx/sites-available/${app}" 2>/dev/null; then
        error "The vhost of '${app}' could not be switched to HTTPS: /etc/nginx/sites-available/${app}"
        return 1
    fi
    reload_nginx
}

# What every successful install does after the vhost serves the certificate.
#   <how>      logged ("http-01", "dns-01 provider=… account=…")
#   <details>  extra notification lines, already "\n"-separated
_ssl_installed() {
    local app="$1" d="$2" how="$3" details="${4:-}" kind=""
    [[ "$how" == dns-01* ]] && kind=" (DNS-01)"
    sed -i "s|^APP_URL=http://|APP_URL=https://|" "/home/${app}/shared/.env" 2>/dev/null || true
    # A certificate turns ws:// into wss:// for a Reverb app: without this
    # the browser blocks the socket as mixed content while nginx is already
    # serving it over TLS, and nothing shows up in the Reverb log.
    if [[ -n "$(app_get "$app" reverb)" ]]; then
        declare -f _reverb_sync_env >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        _reverb_sync_env "$app"
    fi
    log_action "SSL INSTALLED: $app ${how}"
    cipi_notify \
        "Cipi SSL installed${kind}: ${d} (${app}) on $(hostname)" \
        "An SSL certificate was installed.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\n${details}Time: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ssl_install
}

# Names the app serves that its certificate does not cover, one per line.
_ssl_uncovered_names() {
    local app="$1" files cert d n
    files=$(app_tls_files "$app") || return 0
    cert="${files%%$'\t'*}"
    local names; names=$(cert_file_names "$cert")
    d=$(app_get "$app" domain)
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        cert_names_cover "$n" <<< "$names" || echo "$n"
    done < <(echo "$d"; vault_read apps.json | jq -r --arg a "$app" --arg d "$d" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
}

_ssl_install() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi ssl install <app> [--dns=cloudflare [--account=NAME] [--wildcard|--no-wildcard]] [--http]"; exit 1; }
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

    local dns_provider="${ARG_dns:-}" wildcard=""
    if [[ "${ARG_wildcard:-}" == "true" && "${ARG_no_wildcard:-}" == "true" ]]; then
        error "--wildcard and --no-wildcard exclude each other"; exit 1
    fi
    [[ "${ARG_wildcard:-}" == "true" ]] && wildcard="true"
    [[ "${ARG_no_wildcard:-}" == "true" ]] && wildcard="false"
    if [[ "${ARG_http:-}" == "true" && -n "$dns_provider" ]]; then
        error "--http and --dns exclude each other"; exit 1
    fi
    if [[ -n "${ARG_account:-}" && -z "$dns_provider" ]]; then
        error "--account selects a Cloudflare account for DNS-01: add --dns=cloudflare"
        exit 1
    fi

    # A certificate issued over DNS-01 is reissued over DNS-01. Over HTTP-01
    # certbot would replace its names — a wildcard is dropped — and its
    # renewals would leave the Cloudflare token for port 80.
    if [[ -z "$dns_provider" && "${ARG_http:-}" != "true" ]]; then
        local stored; stored=$(app_get "$app" ssl_dns_provider)
        if [[ -n "$stored" ]]; then
            dns_provider="$stored"
            info "'${app}' has a DNS-01 certificate (${stored}, account $(app_get "$app" ssl_dns_account | grep . || echo default)) — reissuing it over DNS-01. To go back to HTTP-01: --http"
        fi
    fi

    if [[ -n "$dns_provider" ]]; then
        _ssl_install_dns01 "$app" "$d" "$dns_provider" "$wildcard" "${ARG_account:-}"
        return $?
    fi

    if [[ "$wildcard" == "true" ]]; then
        error "--wildcard needs DNS-01: Let's Encrypt validates a wildcard name over DNS only."
        echo -e "  ${DIM}cipi ssl install ${app} --dns=cloudflare --wildcard   (see: cipi help ssl)${NC}"
        exit 1
    fi
    if [[ "$(app_get "$app" ssl_origin_ca)" == "true" ]]; then
        error "App '${app}' uses a Cloudflare Origin CA certificate (cipi zt origin-cert)."
        echo -e "  ${DIM}HTTP-01 would replace it. Keep Origin CA, or: cipi ssl install ${app} --dns=cloudflare${NC}"
        exit 1
    fi
    if _ssl_zt_lock_http; then
        error "HTTP-01 cannot work while cipi zt lock http is on (Let's Encrypt does not come from Cloudflare IPs)."
        echo -e "  ${DIM}cipi ssl install ${app} --dns=cloudflare${NC}"
        echo -e "  ${DIM}cipi zt origin-cert ${app}${NC}"
        echo -e "  ${DIM}cipi zt unlock http${NC}  (only if you really want HTTP-01 again)"
        exit 1
    fi

    # Let's Encrypt issues a wildcard certificate over DNS-01 only. Sending
    # "*.example.com" to the HTTP-01 challenge fails the *whole* order, so the
    # primary is refused up front and a wildcard alias is left out of this
    # certificate instead of taking the other domains down with it.
    if domain_is_wildcard "$d"; then
        error "'${d}' is a wildcard domain — HTTP-01 cannot validate it."
        echo -e "  ${DIM}cipi ssl dns set --token=<CLOUDFLARE_API_TOKEN>${NC}"
        echo -e "  ${DIM}cipi ssl install ${app} --dns=cloudflare${NC}"
        exit 1
    fi

    local -a dargs=() hnames=()
    local n skipped
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        hnames+=("$n")
        dargs+=(-d "$n")
    done < <(_ssl_app_cert_names "$app" http)
    skipped=$(vault_read apps.json | jq -r --arg a "$app" '.[$a].aliases // [] | map(select(startswith("*."))) | map(" " + .) | join("")' 2>/dev/null || true)
    if [[ -n "$skipped" ]]; then
        warn "Left out of this certificate:${skipped} — a wildcard name is validated over DNS-01 only."
        echo -e "  ${DIM}Its subdomains are served without a valid certificate until: cipi ssl install ${app} --dns=cloudflare${NC}"
    fi

    local cert; cert=$(domain_cert_name "$d")
    echo ""
    step "Requesting a Let's Encrypt certificate (HTTP-01) for ${d}$([[ ${#dargs[@]} -gt 2 ]] && echo " + $(( ${#dargs[@]} / 2 - 1 )) alias(es)")..."
    echo ""

    if ! certbot certonly --nginx "${dargs[@]}" \
        --cert-name "$cert" \
        --expand \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email 2>&1; then
        echo ""
        error "SSL failed. Check: DNS of every name points to this server, port 80 is open, domain is correct."
        echo -e "  ${DIM}Behind the Cloudflare proxy, DNS-01 avoids all of that: cipi ssl install ${app} --dns=cloudflare${NC}"
        exit 1
    fi

    app_set "$app" force_https "true"
    app_unset "$app" ssl_dns_provider 2>/dev/null || true
    app_unset "$app" ssl_dns_account 2>/dev/null || true
    app_unset "$app" ssl_wildcard 2>/dev/null || true
    certbot_ensure_reload_hook || true
    _ssl_apply_vhost "$app" || exit 1
    _ssl_installed "$app" "$d" "http-01 names=${hnames[*]}" "Names: ${hnames[*]}\n"
    echo ""
    success "SSL installed for ${d}"
}

_ssl_install_dns01() {
    local app="$1" d="$2" provider="$3" wildcard="${4:-}" account="${5:-}"
    [[ "$provider" == "cloudflare" ]] || { error "Supported --dns providers: cloudflare"; exit 1; }

    # Which Cloudflare account: the one asked for, else the one this app's
    # certificate was last issued with, else the default.
    [[ -z "$account" ]] && account=$(app_get "$app" ssl_dns_account)
    [[ -z "$account" ]] && account="default"
    local creds
    creds=$(_ssl_dns_creds_file "$account") || { error "Invalid account name '${account}'"; exit 1; }
    if [[ ! -f "$creds" ]]; then
        if [[ "$account" == "default" ]]; then
            error "DNS credentials missing. Run: cipi ssl dns set --token=TOKEN"
        else
            error "Cloudflare account '${account}' is not configured. Run: cipi ssl dns set --name=${account} --token=TOKEN"
        fi
        echo -e "  ${DIM}Configured accounts: $(_ssl_dns_accounts | tr '\n' ' ')${NC}"
        exit 1
    fi
    if ! command -v certbot &>/dev/null; then
        error "certbot not found"; exit 1
    fi

    # --wildcard / --no-wildcard, else what the certificate had last time.
    [[ -z "$wildcard" ]] && wildcard=$(app_get "$app" ssl_wildcard)
    [[ "$wildcard" == "true" ]] || wildcard="false"

    # certbot rejects "*" in a lineage name and stores a wildcard cert under the
    # bare domain, so the whole app must address it by that name.
    local cert; cert=$(domain_cert_name "$d")
    # An array: "*.example.com" must never meet pathname expansion.
    local -a dargs=() names=()
    local n
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        names+=("$n")
        dargs+=(-d "$n")
    done < <(_ssl_app_cert_names "$app" "$wildcard")
    if [[ ${#names[@]} -gt 100 ]]; then
        error "${#names[@]} names — a Let's Encrypt certificate holds 100 at most. A wildcard alias covers every subdomain in one name."
        exit 1
    fi

    echo ""
    step "Requesting a Let's Encrypt certificate (DNS-01, ${provider} account ${account}) for: ${names[*]}"
    echo ""

    if ! certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$creds" \
        --dns-cloudflare-propagation-seconds 30 \
        "${dargs[@]}" \
        --cert-name "${cert}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --expand 2>&1; then
        echo ""
        error "DNS-01 certificate issuance failed. Check that the Cloudflare account '${account}' holds the zone of ${d} and that its token has Zone:DNS:Edit."
        exit 1
    fi

    app_set "$app" force_https "true"
    app_set "$app" ssl_dns_provider "$provider"
    app_set "$app" ssl_dns_account "$account"
    if [[ "$wildcard" == "true" ]]; then app_set "$app" ssl_wildcard "true"; else app_unset "$app" ssl_wildcard 2>/dev/null || true; fi
    # Let's Encrypt takes over from a Cloudflare Origin CA certificate.
    app_unset "$app" ssl_origin_ca 2>/dev/null || true
    certbot_ensure_reload_hook || true
    _ssl_apply_vhost "$app" || exit 1
    _ssl_installed "$app" "$d" "dns-01 provider=${provider} account=${account} wildcard=${wildcard} names=${names[*]}" \
        "Provider: ${provider}\nAccount: ${account}\nWildcard: ${wildcard}\nNames: ${names[*]}\n"

    echo ""
    success "SSL installed for ${d} via DNS-01 (${provider}, account ${account})"
    echo -e "  ${DIM}Certificate names: ${names[*]}${NC}"
    # A wildcard certificate does not route anything by itself: nginx sends a
    # subdomain to this app only when "*.<apex>" is one of its names.
    local wname
    for wname in "${names[@]}"; do
        domain_is_wildcard "$wname" || continue
        if [[ "$wname" != "$d" ]] && ! vault_read apps.json | jq -e --arg a "$app" --arg w "$wname" '(.[$a].aliases // []) | index($w) != null' >/dev/null 2>&1; then
            info "The certificate covers ${wname}, but those subdomains are not routed to '${app}'."
            echo -e "  ${DIM}To serve them here (multi-tenant): cipi alias add ${app} '${wname}'${NC}"
        fi
    done
}

# Re-apply HTTP → HTTPS redirect for an app that already has a certificate.
# Rewrites the vhost with it; no ACME round-trip, so no rate-limit risk.
_ssl_force() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi ssl force <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local d; d=$(app_get "$app" domain)
    [[ -z "$d" ]] && { error "No domain for app '$app'"; exit 1; }

    if ! app_has_tls "$app"; then
        error "No SSL certificate for '${d}'. Run: cipi ssl install ${app}"
        exit 1
    fi
    if [[ ! -f "/etc/nginx/sites-available/${app}" ]]; then
        error "Nginx vhost for '${app}' not found."
        exit 1
    fi

    if _ssl_app_on_tunnel "$app"; then
        error "App '${app}' is on the Cloudflare tunnel — origin HTTP→HTTPS redirect would break it."
        echo "  Cloudflare already terminates HTTPS at the edge. The tunnel talks HTTP to :80."
        exit 1
    fi

    step "Forcing HTTP → HTTPS redirect for ${d}..."
    app_set "$app" force_https "true"
    if ! _ssl_apply_vhost "$app"; then
        error "Failed to apply HTTPS redirect. Check: nginx -t"
        exit 1
    fi

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
        info "No Let's Encrypt certificates"
        echo ""
        _ssl_status_apps
        return
    fi
    local name
    for name in /etc/letsencrypt/live/*/; do
        [[ -d "$name" ]] || continue
        local cn; cn=$(basename "$name")
        [[ "$cn" == "README" ]] && continue
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "${name}cert.pem" 2>/dev/null | cut -d= -f2 || echo "?")
        # DNS-01 certificates: the Cloudflare account they renew with.
        local via="" cf
        cf=$(sed -n 's/^dns_cloudflare_credentials[[:space:]]*=[[:space:]]*//p' "${SSL_RENEWAL_DIR}/${cn}.conf" 2>/dev/null | head -1 || true)
        if [[ -n "$cf" ]]; then
            if [[ "$cf" == "$SSL_DNS_DEFAULT_CREDS" ]]; then via="default"; else via="${cf##*/}"; via="${via%.ini}"; fi
            via="  ${DIM}dns-01 cloudflare:${via}${NC}"
        fi
        printf "  %-40s %s%b\n" "$cn" "$expiry" "$via"
    done
    echo ""
    _ssl_status_apps
}

# Per app: what its HTTPS is served with, and the names it serves that the
# certificate does not cover (a browser shows those as not secure, and behind
# the Cloudflare proxy "Full (strict)" answers 526 for them).
_ssl_status_apps() {
    local apps app files src uncovered
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    [[ -n "$apps" ]] || return 0
    echo -e "${BOLD}Apps${NC}"
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        if ! files=$(app_tls_files "$app"); then
            printf "  %-20s ${DIM}%s${NC}\n" "$app" "HTTP only — cipi ssl install ${app}"
            continue
        fi
        if [[ "$(app_get "$app" ssl_origin_ca)" == "true" && "$files" == "${CIPI_ORIGIN_CERT_DIR}/"* ]]; then
            src="Cloudflare Origin CA (proxied traffic only)"
        elif [[ -n "$(app_get "$app" ssl_dns_provider)" ]]; then
            src="Let's Encrypt, DNS-01 $(app_get "$app" ssl_dns_provider):$(app_get "$app" ssl_dns_account | grep . || echo default)"
        else
            src="Let's Encrypt, HTTP-01"
        fi
        uncovered=$(_ssl_uncovered_names "$app" | tr '\n' ' ')
        if [[ -n "$uncovered" ]]; then
            printf "  %-20s %s  ${YELLOW}not covered: %s${NC}\n" "$app" "$src" "${uncovered% }"
        else
            printf "  %-20s %s  ${GREEN}✓${NC}\n" "$app" "$src"
        fi
    done <<< "$apps"
    echo ""
}
