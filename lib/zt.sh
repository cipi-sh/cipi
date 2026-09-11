#!/bin/bash
#############################################
# Cipi — Cloudflare Zero Trust (opt-in)
#
# Off by default. enable installs cloudflared, writes nginx real_ip from
# Cloudflare's published ranges, and creates a locally-managed tunnel.
# It does not close 22/80/443. lock http / lock ssh are explicit later
# steps, and lock ssh refuses unless the tunnel is healthy.
# disable restores UFW and removes cloudflared; Fail2ban stays.
# setup.sh / self-update never call enable.
#############################################

[[ -z "${ZT_TOKEN_FILE:-}" ]] && readonly ZT_TOKEN_FILE="${CIPI_CONFIG}/zt.token"
[[ -z "${ZT_STATE:-}" ]]      && readonly ZT_STATE="zt.json"
[[ -z "${ZT_TOKEN_META:-}" ]] && readonly ZT_TOKEN_META="zt-token.json"
[[ -z "${ZT_CRON:-}" ]]       && readonly ZT_CRON="/etc/cron.d/cipi-zt"
[[ -z "${ZT_REALIP:-}" ]]     && readonly ZT_REALIP="/etc/nginx/conf.d/cipi-cloudflare-realip.conf"
[[ -z "${ZT_F2B:-}" ]]        && readonly ZT_F2B="/etc/fail2ban/jail.d/cipi-zt.conf"
[[ -z "${ZT_CF_DIR:-}" ]]     && readonly ZT_CF_DIR="/etc/cloudflared"
[[ -z "${ZT_CF_CONF:-}" ]]    && readonly ZT_CF_CONF="${ZT_CF_DIR}/config.yml"
[[ -z "${ZT_IPS_DIR:-}" ]]    && readonly ZT_IPS_DIR="/var/lib/cipi/cloudflare-ips"
[[ -z "${ZT_ORIGIN:-}" ]]     && readonly ZT_ORIGIN="/etc/ssl/cipi-origin"
[[ -z "${ZT_UNIT:-}" ]]       && readonly ZT_UNIT="cloudflared"
[[ -z "${ZT_API:-}" ]]        && readonly ZT_API="https://api.cloudflare.com/client/v4"
[[ -z "${ZT_CS_WL:-}" ]]      && readonly ZT_CS_WL="/etc/crowdsec/parsers/s02-enrich/cipi-cloudflare-whitelists.yaml"

zt_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        token)        _zt_token "$@" ;;
        enable)       _zt_enable "$@" ;;
        disable)      _zt_disable "$@" ;;
        status)       _zt_status "$@" ;;
        refresh)      _zt_refresh "$@" ;;
        hostname)     _zt_hostname "$@" ;;
        access)       _zt_access "$@" ;;
        ssh)          _zt_ssh "$@" ;;
        lock)         _zt_lock "$@" ;;
        unlock)       _zt_unlock "$@" ;;
        origin-cert|origincert|origin_cert) _zt_origin_cert "$@" ;;
        *) error "Usage: cipi zt token|enable|disable|status|refresh|hostname|access|ssh|lock|unlock|origin-cert [args]"; exit 1 ;;
    esac
}

# ── state ────────────────────────────────────────────────────

_zt_state() {
    vault_read "$ZT_STATE" 2>/dev/null || echo '{}'
}

_zt_state_write() {
    echo "$1" | vault_write "$ZT_STATE"
}

_zt_enabled() {
    [[ "$(_zt_state | jq -r '.enabled // false')" == "true" ]]
}

_zt_account() {
    _zt_state | jq -r '.account_id // empty'
}

_zt_tunnel_id() {
    _zt_state | jq -r '.tunnel_id // empty'
}

_zt_read_token() {
    [[ -s "$ZT_TOKEN_FILE" ]] || return 1
    tr -d '[:space:]' < "$ZT_TOKEN_FILE"
}

_zt_require_token() {
    _zt_read_token >/dev/null || {
        error "No Cloudflare API token. Run: cipi zt token set --token=TOKEN --account=ACCOUNT_ID"
        return 1
    }
}

_zt_require_enabled() {
    _zt_enabled || {
        error "Cloudflare Zero Trust is not enabled. Run: cipi zt enable"
        return 1
    }
}

# ── Cloudflare API ───────────────────────────────────────────

_zt_api() {
    local method="$1" path="$2" body="${3:-}"
    local token resp tmp
    token=$(_zt_read_token) || return 1
    tmp=$(mktemp)
    # No curl -f: Cloudflare 4xx still carries a JSON error we must surface.
    if [[ -n "$body" ]]; then
        _cipi_run_timed 45 curl -sS -X "$method" "${ZT_API}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$body" >"$tmp" 2>/dev/null || {
            rm -f "$tmp"
            return 1
        }
    else
        _cipi_run_timed 45 curl -sS -X "$method" "${ZT_API}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" >"$tmp" 2>/dev/null || {
            rm -f "$tmp"
            return 1
        }
    fi
    resp=$(cat "$tmp")
    rm -f "$tmp"
    printf '%s' "$resp"
}

_zt_api_ok() {
    echo "$1" | jq -e '.success == true' >/dev/null 2>&1
}

_zt_api_err() {
    echo "$1" | jq -r '[.errors[]? | .message] | join("; ")' 2>/dev/null
}

# ── token ────────────────────────────────────────────────────

_zt_token_usage() {
    error "Usage: cipi zt token set --token=TOKEN [--account=ACCOUNT_ID]"
    echo "  Token needs: Account.Cloudflare Tunnel (Edit), Account.Access: Apps and Policies (Edit),"
    echo "  Zone.DNS (Edit). Origin CA also needs Zone.SSL and Certificates (Edit)."
    echo "  This is NOT the DNS-01 file at /etc/cipi/cloudflare.ini (Zone.DNS only)."
}

_zt_token_cli() {
    local action="${1:-}"; shift || true
    case "$action" in
        set|configure) _zt_token_set "$@" ;;
        show)          _zt_token_show ;;
        *) _zt_token_usage; exit 1 ;;
    esac
}

# Keep the public name `token` as the subcommand dispatcher.
_zt_token() { _zt_token_cli "$@"; }

_zt_token_set() {
    parse_args "$@"
    local token="${ARG_token:-}" account="${ARG_account:-}"
    [[ -z "$token" ]] && read_input "Cloudflare API token" "" token
    [[ -z "$token" ]] && { _zt_token_usage; exit 1; }

    mkdir -p "$CIPI_CONFIG"
    printf '%s\n' "$token" > "$ZT_TOKEN_FILE"
    chmod 600 "$ZT_TOKEN_FILE"
    chown root:root "$ZT_TOKEN_FILE"

    if [[ -z "$account" ]]; then
        local list
        list=$(_zt_api GET "/accounts?per_page=50") || list=""
        if _zt_api_ok "$list"; then
            local n
            n=$(echo "$list" | jq '.result | length')
            if [[ "$n" == "1" ]]; then
                account=$(echo "$list" | jq -r '.result[0].id')
                info "Using Cloudflare account $(echo "$list" | jq -r '.result[0].name')"
            elif [[ "${n:-0}" -gt 1 ]]; then
                error "This token sees multiple accounts. Pass --account=ACCOUNT_ID"
                echo "$list" | jq -r '.result[] | "  " + .id + "  " + .name'
                exit 1
            fi
        fi
    fi
    [[ -z "$account" ]] && read_input "Cloudflare account ID" "" account
    [[ -z "$account" ]] && { error "Account ID required"; exit 1; }

    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg a "$account" '.account_id = $a')
    _zt_state_write "$st"
    echo "{\"configured_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"account_id\":\"${account}\"}" \
        | vault_write "$ZT_TOKEN_META"
    log_action "ZT TOKEN SET account=${account}"
    success "Cloudflare Zero Trust token saved (root-only ${ZT_TOKEN_FILE})"
    echo -e "  ${DIM}Does not replace /etc/cipi/cloudflare.ini (certbot DNS-01).${NC}"
}

_zt_token_show() {
    if [[ -f "${CIPI_CONFIG}/${ZT_TOKEN_META}" ]]; then
        vault_read "$ZT_TOKEN_META" | jq .
    else
        info "No token. Run: cipi zt token set --token=TOKEN --account=ACCOUNT_ID"
    fi
    if [[ -s "$ZT_TOKEN_FILE" ]]; then
        echo -e "  Token file: ${CYAN}${ZT_TOKEN_FILE}${NC} (present)"
    fi
    local acc; acc=$(_zt_account)
    [[ -n "$acc" ]] && echo -e "  Account:    ${CYAN}${acc}${NC}"
    # Must not end on a conditional: `cipi` runs under set -e, so returning
    # non-zero here aborts `cipi zt token show` whenever no account is saved.
    return 0
}

# ── Cloudflare IP ranges ─────────────────────────────────────

_zt_fetch_ips() {
    mkdir -p "$ZT_IPS_DIR"
    local raw
    raw=$(_cipi_run_timed 20 curl -fsSL "${ZT_API}/ips" 2>/dev/null) || raw=""
    local v4 v6
    v4=$(echo "$raw" | jq -r '.result.ipv4_cidrs[]?' 2>/dev/null || true)
    v6=$(echo "$raw" | jq -r '.result.ipv6_cidrs[]?' 2>/dev/null || true)
    if [[ -z "$v4" ]]; then
        [[ -s "${ZT_IPS_DIR}/v4" ]] && return 0
        return 1
    fi
    printf '%s\n' "$v4" > "${ZT_IPS_DIR}/v4"
    printf '%s\n' "$v6" > "${ZT_IPS_DIR}/v6"
    return 0
}

_zt_each_cf_cidr() {
    local f
    for f in "${ZT_IPS_DIR}/v4" "${ZT_IPS_DIR}/v6"; do
        [[ -s "$f" ]] || continue
        grep -v '^#' "$f" | grep -v '^$'
    done
}

_zt_write_realip() {
    mkdir -p /etc/nginx/conf.d
    local tmp cidr
    tmp=$(mktemp)
    {
        echo "# Written by cipi zt. Cloudflare edge ranges; refresh: cipi zt refresh"
        echo "real_ip_header CF-Connecting-IP;"
        echo "real_ip_recursive on;"
        echo "map \$http_x_forwarded_proto \$cipi_forwarded_proto {"
        echo "    default \$http_x_forwarded_proto;"
        echo "    ''      \$scheme;"
        echo "}"
        while IFS= read -r cidr; do
            [[ -n "$cidr" ]] && echo "set_real_ip_from ${cidr};"
        done < <(_zt_each_cf_cidr)
    } > "$tmp"
    if ! grep -q 'set_real_ip_from' "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$ZT_REALIP"
    chmod 644 "$ZT_REALIP"
    return 0
}

_zt_write_fail2ban_ignore() {
    mkdir -p /etc/fail2ban/jail.d
    local cidrs="" c
    while IFS= read -r c; do
        [[ -n "$c" ]] && cidrs+=" ${c}"
    done < <(_zt_each_cf_cidr)
    cat > "$ZT_F2B" <<EOF
# Written by cipi zt. ignoreip replaces jail.local's list, so localhost stays.
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1${cidrs}
EOF
    chmod 644 "$ZT_F2B"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null 2>&1 || systemctl reload fail2ban >/dev/null 2>&1 || true
    fi
}

# CrowdSec: dedicated parser so we do not flood cipi crowdsec allow.
_zt_write_crowdsec_allowlist() {
    [[ -d /etc/crowdsec/parsers/s02-enrich ]] || return 0
    local tmp c
    tmp=$(mktemp)
    {
        echo "name: crowdsecurity/cipi-cloudflare-whitelists"
        echo "description: \"Cloudflare edge CIDRs (cipi zt) — defence if real_ip is missing\""
        echo "filter: \"1 == 1\""
        echo "whitelist:"
        echo "  reason: \"cloudflare edge\""
        echo "  cidr:"
        while IFS= read -r c; do
            [[ -n "$c" ]] && echo "    - \"${c}\""
        done < <(_zt_each_cf_cidr)
    } > "$tmp"
    if grep -q '    - "' "$tmp"; then
        mv "$tmp" "$ZT_CS_WL"
        systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    else
        rm -f "$tmp"
        return 1
    fi
}

_zt_apply_realip() {
    _zt_fetch_ips || { error "Could not fetch Cloudflare IP ranges"; return 1; }
    _zt_write_realip || { error "Could not write ${ZT_REALIP}"; return 1; }
    _zt_write_fail2ban_ignore
    _zt_write_crowdsec_allowlist || true
    if command -v nginx >/dev/null 2>&1; then
        reload_nginx || return 1
    fi
    return 0
}

_zt_write_cron() {
    cat > "$ZT_CRON" <<'EOF'
# Cipi Cloudflare Zero Trust — refresh edge IP ranges (nginx real_ip, fail2ban, UFW, CrowdSec).
# Does not install or enable anything; enable is operator-only.
17 3 * * * root /usr/local/bin/cipi zt refresh >/dev/null 2>&1
EOF
    chmod 644 "$ZT_CRON"
}

# ── cloudflared ──────────────────────────────────────────────

_zt_install_cloudflared() {
    if command -v cloudflared >/dev/null 2>&1; then
        return 0
    fi
    step "Installing cloudflared..."
    mkdir -p /usr/share/keyrings /etc/apt/keyrings
    local key="/usr/share/keyrings/cloudflare-main.gpg"
    local list="/etc/apt/sources.list.d/cloudflared.list"
    if [[ ! -s "$key" ]]; then
        if ! _cipi_run_timed 30 curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            -o "$key" 2>/dev/null; then
            rm -f "$key"
            error "Could not fetch the Cloudflare package signing key"
            return 1
        fi
        chmod 644 "$key"
    fi
    echo "deb [signed-by=${key}] https://pkg.cloudflare.com/cloudflared any main" > "$list"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -qq; then
        rm -f "$list"
        apt-get update -qq >/dev/null 2>&1 || true
        error "Cloudflare cloudflared apt repo failed"
        return 1
    fi
    apt-get install -y -qq cloudflared >/dev/null || {
        error "apt-get install cloudflared failed"
        return 1
    }
    command -v cloudflared >/dev/null 2>&1
}

_zt_write_unit() {
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/${ZT_UNIT}.service <<EOF
[Unit]
Description=Cipi Cloudflare Tunnel (cloudflared)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v cloudflared) --no-autoupdate tunnel --config ${ZT_CF_CONF} run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

_zt_tunnel_healthy() {
    systemctl is-active --quiet "$ZT_UNIT" 2>/dev/null || return 1
    [[ -f "$ZT_CF_CONF" ]] || return 1
    grep -qE 'tunnel:' "$ZT_CF_CONF" 2>/dev/null
}

_zt_ssh_ingress_present() {
    [[ -f "$ZT_CF_CONF" ]] && grep -q 'ssh://127.0.0.1:22' "$ZT_CF_CONF" 2>/dev/null
}

# Rebuild config.yml from zt.json. Catch-all 404 must be last.
_zt_write_config() {
    local st id cred
    st=$(_zt_state)
    id=$(echo "$st" | jq -r '.tunnel_id // empty')
    [[ -n "$id" ]] || { error "No tunnel id in state"; return 1; }
    cred="${ZT_CF_DIR}/${id}.json"
    [[ -f "$cred" ]] || { error "Missing tunnel credentials ${cred}"; return 1; }
    mkdir -p "$ZT_CF_DIR"
    local tmp guih sshh h
    tmp=$(mktemp)
    {
        echo "tunnel: ${id}"
        echo "credentials-file: ${cred}"
        echo "ingress:"
        while IFS= read -r h; do
            [[ -z "$h" ]] && continue
            printf '  - hostname: "%s"\n    service: http://127.0.0.1:80\n' "$h"
        done < <(echo "$st" | jq -r '(.hostnames // {}) | to_entries[] | .value.domains[]? | .name' 2>/dev/null)
        guih=$(echo "$st" | jq -r '.gui.domain // empty')
        if [[ -n "$guih" ]]; then
            printf '  - hostname: "%s"\n    service: http://127.0.0.1:80\n' "$guih"
        fi
        sshh=$(echo "$st" | jq -r '.ssh.hostname // empty')
        if [[ -n "$sshh" ]]; then
            printf '  - hostname: "%s"\n    service: ssh://127.0.0.1:22\n' "$sshh"
        fi
        echo "  - service: http_status:404"
    } > "$tmp"
    mv "$tmp" "$ZT_CF_CONF"
    chmod 600 "$ZT_CF_CONF"
}

_zt_reload_tunnel() {
    _zt_write_config || return 1
    systemctl enable "$ZT_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$ZT_UNIT" || {
        error "cloudflared failed to start. Check: journalctl -u ${ZT_UNIT} -n 30 --no-pager"
        return 1
    }
    local i
    for i in $(seq 1 15); do
        systemctl is-active --quiet "$ZT_UNIT" && return 0
        sleep 1
    done
    error "${ZT_UNIT} is not running"
    return 1
}

_zt_create_tunnel() {
    local account name secret body resp id
    account=$(_zt_account)
    [[ -n "$account" ]] || { error "No account id. Run: cipi zt token set"; return 1; }
    name="cipi-$(hostname -s | tr -cd 'a-zA-Z0-9-' | cut -c1-40)"
    [[ -z "$name" ]] && name="cipi-server"
    secret=$(openssl rand -base64 32 | tr -d '\n')
    body=$(jq -n --arg n "$name" --arg s "$secret" \
        '{name:$n, config_src:"local", tunnel_secret:$s}')
    step "Creating Cloudflare Tunnel ${name}..."
    resp=$(_zt_api POST "/accounts/${account}/cfd_tunnel" "$body") || resp=""
    if ! _zt_api_ok "$resp"; then
        error "Could not create the tunnel: $(_zt_api_err "$resp")"
        echo "  Token needs Account.Cloudflare Tunnel: Edit"
        return 1
    fi
    id=$(echo "$resp" | jq -r '.result.id // empty')
    [[ -n "$id" ]] || { error "Tunnel API returned no id"; return 1; }
    mkdir -p "$ZT_CF_DIR"
    chmod 700 "$ZT_CF_DIR"
    jq -n --arg a "$account" --arg s "$secret" --arg i "$id" \
        '{AccountTag:$a, TunnelSecret:$s, TunnelID:$i}' \
        > "${ZT_CF_DIR}/${id}.json"
    chmod 600 "${ZT_CF_DIR}/${id}.json"
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg i "$id" --arg n "$name" \
        '.tunnel_id = $i | .tunnel_name = $n | .enabled = true')
    _zt_state_write "$st"
}

_zt_delete_tunnel() {
    local account id
    account=$(_zt_account)
    id=$(_zt_tunnel_id)
    [[ -n "$account" && -n "$id" ]] || return 0
    _zt_api DELETE "/accounts/${account}/cfd_tunnel/${id}?cascade=true" >/dev/null 2>&1 || true
}

# ── DNS ──────────────────────────────────────────────────────

_zt_bare_host() {
    local h="$1"
    [[ "$h" == \*.* ]] && h="${h#*.}"
    printf '%s' "$h"
}

_zt_zone_id() {
    local host="$1" try id resp
    host=$(_zt_bare_host "$host")
    try="$host"
    while [[ "$try" == *.* ]]; do
        resp=$(_zt_api GET "/zones?name=${try}") || resp=""
        id=$(echo "$resp" | jq -r '.result[0].id // empty')
        if [[ -n "$id" ]]; then
            printf '%s' "$id"
            return 0
        fi
        try="${try#*.}"
    done
    return 1
}

_zt_dns_upsert() {
    local hostname="$1"
    local tunnel; tunnel=$(_zt_tunnel_id)
    [[ -n "$tunnel" ]] || return 1
    local zone rec_id body resp content
    zone=$(_zt_zone_id "$hostname") || {
        error "No Cloudflare zone for ${hostname}. The zone must live on this account."
        return 1
    }
    content="${tunnel}.cfargotunnel.com"
    local qname="$hostname"
    [[ "$hostname" == \*.* ]] && qname="$hostname"
    resp=$(_zt_api GET "/zones/${zone}/dns_records?type=CNAME&name=${hostname}") || resp=""
    rec_id=$(echo "$resp" | jq -r '.result[0].id // empty')
    body=$(jq -n --arg n "$hostname" --arg c "$content" \
        '{type:"CNAME", name:$n, content:$c, proxied:true, comment:"cipi-zt"}')
    if [[ -n "$rec_id" ]]; then
        resp=$(_zt_api PUT "/zones/${zone}/dns_records/${rec_id}" "$body") || resp=""
    else
        resp=$(_zt_api POST "/zones/${zone}/dns_records" "$body") || resp=""
        rec_id=$(echo "$resp" | jq -r '.result.id // empty')
    fi
    if ! _zt_api_ok "$resp"; then
        error "DNS CNAME for ${hostname} failed: $(_zt_api_err "$resp")"
        echo "  Token needs Zone.DNS: Edit on this zone"
        return 1
    fi
    [[ -z "$rec_id" ]] && rec_id=$(echo "$resp" | jq -r '.result.id // empty')
    printf '%s %s' "$zone" "$rec_id"
}

_zt_dns_delete() {
    local zone="$1" rec="$2"
    [[ -n "$zone" && -n "$rec" ]] || return 0
    _zt_api DELETE "/zones/${zone}/dns_records/${rec}" >/dev/null 2>&1 || true
}

# ── Access ───────────────────────────────────────────────────

_zt_access_create() {
    local name="$1" domain="$2" type="${3:-self_hosted}"
    local account body resp id
    account=$(_zt_account)
    body=$(jq -n --arg n "$name" --arg d "$domain" --arg t "$type" \
        '{name:$n, domain:$d, type:$t, session_duration:"24h",
          destinations:[{type:"public", uri:$d}]}')
    resp=$(_zt_api POST "/accounts/${account}/access/apps" "$body") || resp=""
    if ! _zt_api_ok "$resp"; then
        echo ""
        return 1
    fi
    id=$(echo "$resp" | jq -r '.result.id // empty')
    printf '%s' "$id"
}

_zt_access_policy() {
    local app_id="$1" decision="$2"
    local account body resp
    account=$(_zt_account)
    body=$(jq -n --arg n "cipi-${decision}" --arg d "$decision" \
        '{name:$n, decision:$d, include:[{everyone:{}}]}')
    resp=$(_zt_api POST "/accounts/${account}/access/apps/${app_id}/policies" "$body") || resp=""
    _zt_api_ok "$resp"
}

_zt_access_delete() {
    local app_id="$1"
    [[ -n "$app_id" ]] || return 0
    local account; account=$(_zt_account)
    _zt_api DELETE "/accounts/${account}/access/apps/${app_id}" >/dev/null 2>&1 || true
}

# ── app domain list ──────────────────────────────────────────

_zt_app_domains() {
    local app="$1" d aliases
    d=$(app_get "$app" domain)
    [[ -n "$d" ]] && printf '%s\n' "$d"
    aliases=$(vault_read apps.json | jq -r --arg a "$app" --arg d "$d" \
        '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
    while IFS= read -r a; do
        [[ -n "$a" ]] && printf '%s\n' "$a"
    done <<< "${aliases:-}"
}

_zt_gui_domain() {
    [[ -f "${CIPI_CONFIG}/gui.json" ]] || return 1
    local d
    d=$(vault_read gui.json | jq -r '.domain // empty')
    [[ -n "$d" && "$d" != "null" ]] || return 1
    printf '%s' "$d"
}

# ── enable / disable / refresh / status ──────────────────────

_zt_enable() {
    parse_args "$@"
    _zt_require_token || exit 1
    [[ -n "$(_zt_account)" ]] || {
        error "No account id. Run: cipi zt token set --token=TOKEN --account=ACCOUNT_ID"
        exit 1
    }

    if _zt_enabled && _zt_tunnel_healthy; then
        info "Zero Trust already enabled — refreshing real_ip and tunnel config"
        _zt_apply_realip || exit 1
        _zt_reload_tunnel || true
        _zt_status
        return 0
    fi

    _zt_install_cloudflared || exit 1
    step "Writing nginx real_ip from Cloudflare IP ranges..."
    _zt_apply_realip || exit 1
    _zt_write_cron

    if [[ -z "$(_zt_tunnel_id)" ]]; then
        _zt_create_tunnel || exit 1
    fi
    _zt_write_unit
    _zt_reload_tunnel || exit 1

    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.enabled = true | .enabled_at = $t | .lock_http = false | .lock_ssh = false')
    _zt_state_write "$st"

    log_action "ZT ENABLE tunnel=$(_zt_tunnel_id)"
    log_event "Cloudflare Zero Trust enabled on $(hostname)"
    cipi_notify \
        "Cipi Zero Trust enabled on $(hostname)" \
        "cloudflared is running. Nginx real_ip uses CF-Connecting-IP. Ports 22/80/443 are still open.\n\nNext:\n  cipi zt hostname add <app>     # public site through the tunnel\n  cipi zt access enable <app>    # IdP in front (staging / GUI)\n  cipi zt ssh enable --hostname=ssh.example.com\n  cipi zt lock http --yes\n  cipi zt lock ssh --yes\n\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        zt_enable
    success "Cloudflare Zero Trust enabled (tunnel + real_ip). Ports are still open."
    echo ""
    echo -e "  ${DIM}Public app:${NC}     ${CYAN}cipi zt hostname add <app>${NC}"
    echo -e "  ${DIM}Protect app:${NC}    ${CYAN}cipi zt access enable <app>${NC}"
    echo -e "  ${DIM}SSH over tunnel:${NC} ${CYAN}cipi zt ssh enable --hostname=ssh.example.com${NC}"
    echo -e "  ${DIM}Then, later:${NC}    ${CYAN}cipi zt lock http${NC} / ${CYAN}cipi zt lock ssh${NC}"
    echo ""
}

_zt_disable() {
    parse_args "$@"
    if ! _zt_enabled && [[ ! -f "$ZT_CRON" ]] && ! command -v cloudflared >/dev/null 2>&1; then
        info "Cloudflare Zero Trust is not installed"
        return 0
    fi
    if [[ "${ARG_force:-}" != "true" ]]; then
        confirm "Disable Zero Trust, remove the tunnel and cloudflared, restore UFW 22/80/443? Fail2ban stays." \
            || { info "Aborted"; return 0; }
    fi

    step "Reopening firewall ports..."
    _zt_unlock_http_apply
    _zt_unlock_ssh_apply

    step "Removing Access applications..."
    local st ids
    st=$(_zt_state)
    ids=$(echo "$st" | jq -r '
        [.hostnames[]? | .access_id, .webhook_access_id]
        + [.gui.access_id, .ssh.access_id]
        | .[] | select(. != null and . != "")
    ' 2>/dev/null || true)
    while IFS= read -r id; do
        [[ -n "$id" ]] && _zt_access_delete "$id"
    done <<< "${ids:-}"

    step "Removing DNS records Cipi created..."
    echo "$st" | jq -r '
        (.hostnames // {}) | to_entries[] | .value.domains[]? | select(.zone_id != null and .dns_id != null) | "\(.zone_id) \(.dns_id)"
    ' 2>/dev/null | while read -r z r; do
        [[ -n "$z" && -n "$r" ]] && _zt_dns_delete "$z" "$r"
    done
    local gz gr sz sr
    gz=$(echo "$st" | jq -r '.gui.zone_id // empty')
    gr=$(echo "$st" | jq -r '.gui.dns_id // empty')
    _zt_dns_delete "$gz" "$gr"
    sz=$(echo "$st" | jq -r '.ssh.zone_id // empty')
    sr=$(echo "$st" | jq -r '.ssh.dns_id // empty')
    _zt_dns_delete "$sz" "$sr"

    step "Stopping cloudflared..."
    systemctl disable --now "$ZT_UNIT" 2>/dev/null || true
    _zt_delete_tunnel
    rm -f /etc/systemd/system/${ZT_UNIT}.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$ZT_CF_DIR"
    rm -f "$ZT_REALIP" "$ZT_F2B" "$ZT_CRON" "$ZT_CS_WL"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    fi
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet crowdsec 2>/dev/null; then
        systemctl reload crowdsec 2>/dev/null || true
    fi

    step "Removing cloudflared package..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y -qq cloudflared >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq >/dev/null 2>&1 || true

    st=$(echo "$st" | jq '.enabled = false | .lock_http = false | .lock_ssh = false
        | .lock_http_mode = "" | .hostnames = {} | .gui = {} | .ssh = {}
        | .tunnel_id = "" | .tunnel_name = ""')
    _zt_state_write "$st"

    log_action "ZT DISABLE"
    log_event "Cloudflare Zero Trust disabled on $(hostname)"
    cipi_notify \
        "Cipi Zero Trust disabled on $(hostname)" \
        "cloudflared and the tunnel were removed. UFW 22/80/443 restored. Fail2ban is unchanged. Let's Encrypt certificates were left in place.\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        zt_disable
    success "Cloudflare Zero Trust removed — firewall is back to 22/80/443"
}

_zt_refresh() {
    _zt_fetch_ips || { warn "Cloudflare IP fetch failed — kept the previous list"; return 0; }
    if [[ -f "$ZT_REALIP" ]] || _zt_enabled; then
        _zt_write_realip || true
        _zt_write_fail2ban_ignore
        _zt_write_crowdsec_allowlist || true
        if command -v nginx >/dev/null 2>&1; then
            nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
        fi
    fi
    local st mode
    st=$(_zt_state)
    mode=$(echo "$st" | jq -r '.lock_http_mode // empty')
    if [[ "$(echo "$st" | jq -r '.lock_http // false')" == "true" && "$mode" == "cf-ips" ]]; then
        _zt_lock_http_cf_ips
    fi
    log_action "ZT REFRESH"
}

_zt_status() {
    parse_args "$@"
    echo ""
    echo -e "  ${BOLD}Cloudflare Zero Trust${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ! _zt_enabled; then
        echo -e "  ${DIM}not enabled${NC}  —  ${CYAN}cipi zt enable${NC}"
        echo ""
        return 0
    fi
    local tun st sshh lockh locks mode
    st=$(_zt_state)
    tun="stopped"
    systemctl is-active --quiet "$ZT_UNIT" 2>/dev/null && tun="running"
    printf "  %-16s ${CYAN}%s${NC}\n" "cloudflared" "$tun"
    printf "  %-16s ${CYAN}%s${NC}\n" "Tunnel" "$(echo "$st" | jq -r '.tunnel_name // .tunnel_id // "?"')"
    printf "  %-16s ${CYAN}%s${NC}\n" "real_ip" "$([[ -f "$ZT_REALIP" ]] && echo "CF-Connecting-IP" || echo "off")"
    lockh=$(echo "$st" | jq -r '.lock_http // false')
    mode=$(echo "$st" | jq -r '.lock_http_mode // empty')
    locks=$(echo "$st" | jq -r '.lock_ssh // false')
    printf "  %-16s ${CYAN}%s${NC}\n" "lock http" "${lockh}${mode:+ (${mode})}"
    printf "  %-16s ${CYAN}%s${NC}\n" "lock ssh" "$locks"
    sshh=$(echo "$st" | jq -r '.ssh.hostname // empty')
    if [[ -n "$sshh" ]]; then
        printf "  %-16s ${CYAN}%s${NC}\n" "SSH hostname" "$sshh"
    else
        printf "  %-16s ${DIM}%s${NC}\n" "SSH hostname" "not configured"
    fi
    echo ""
    echo -e "  ${BOLD}Hostnames${NC}"
    local apps_json names app
    names=$(echo "$st" | jq -r '.hostnames | keys[]?' 2>/dev/null || true)
    if [[ -z "$names" ]]; then
        echo -e "    ${DIM}none — cipi zt hostname add <app>${NC}"
    else
        while IFS= read -r app; do
            [[ -z "$app" ]] && continue
            local acc ds
            acc=$(echo "$st" | jq -r --arg a "$app" '.hostnames[$a].access_id // empty')
            ds=$(echo "$st" | jq -r --arg a "$app" '[.hostnames[$a].domains[]?.name] | join(", ")')
            if [[ -n "$acc" ]]; then
                echo -e "    ${CYAN}${app}${NC}  ${ds}  ${GREEN}Access${NC}"
            else
                echo -e "    ${CYAN}${app}${NC}  ${ds}  ${DIM}public${NC}"
            fi
        done <<< "$names"
    fi
    local guid
    guid=$(echo "$st" | jq -r '.gui.domain // empty')
    if [[ -n "$guid" ]]; then
        local gacc
        gacc=$(echo "$st" | jq -r '.gui.access_id // empty')
        echo -e "    ${CYAN}gui${NC}  ${guid}  $([[ -n "$gacc" ]] && echo -e "${GREEN}Access${NC}" || echo -e "${DIM}public${NC}")"
    fi
    echo ""
    echo -e "  ${BOLD}Apps not on the tunnel${NC}"
    local missing="" a
    apps_json=$(vault_read apps.json 2>/dev/null || echo '{}')
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        echo "$st" | jq -e --arg a "$a" '.hostnames[$a] != null' >/dev/null 2>&1 && continue
        missing+=" ${a}"
    done < <(echo "$apps_json" | jq -r 'keys[]?' 2>/dev/null)
    if _zt_gui_domain >/dev/null 2>&1; then
        [[ -z "$guid" ]] && missing+=" gui"
    fi
    if [[ -z "$missing" ]]; then
        echo -e "    ${DIM}none${NC}"
    else
        echo -e "    ${YELLOW}${missing}${NC}"
        echo -e "    ${DIM}cipi zt hostname add <app>${NC}"
    fi
    echo ""
}

# ── hostname ─────────────────────────────────────────────────

_zt_hostname() {
    local action="${1:-}"; shift || true
    case "$action" in
        add)    _zt_hostname_add "$@" ;;
        remove) _zt_hostname_remove "$@" ;;
        list)   _zt_status "$@" ;;
        *) error "Usage: cipi zt hostname add|remove <app|--gui>"; exit 1 ;;
    esac
}

_zt_hostname_add() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local app="${1:-}" gui="${ARG_gui:-}"
    if [[ "$gui" == "true" || "$app" == "--gui" ]]; then
        _zt_hostname_add_gui
        return $?
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt hostname add <app>  or  cipi zt hostname add --gui"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    step "Routing ${app} through the tunnel..."
    local st domain_json="[]" d pair zone rec
    st=$(_zt_state)
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        pair=$(_zt_dns_upsert "$d") || exit 1
        zone="${pair%% *}"
        rec="${pair#* }"
        domain_json=$(echo "$domain_json" | jq --arg n "$d" --arg z "$zone" --arg r "$rec" \
            '. + [{name:$n, zone_id:$z, dns_id:$r}]')
        success "CNAME ${d} → $(_zt_tunnel_id).cfargotunnel.com"
    done < <(_zt_app_domains "$app")
    st=$(echo "$st" | jq --arg a "$app" --argjson d "$domain_json" \
        '.hostnames[$a] = ((.hostnames[$a] // {}) + {domains:$d})')
    _zt_state_write "$st"
    _zt_reload_tunnel || exit 1
    log_action "ZT HOSTNAME ADD ${app}"
    success "${app} is public on the tunnel (CDN/WAF, no Access)"
    echo -e "  ${DIM}Protect it: cipi zt access enable ${app}${NC}"
}

_zt_hostname_add_gui() {
    local domain
    domain=$(_zt_gui_domain) || { error "GUI not configured. Run: cipi gui <domain>"; exit 1; }
    step "Routing GUI ${domain} through the tunnel..."
    local pair zone rec st
    pair=$(_zt_dns_upsert "$domain") || exit 1
    zone="${pair%% *}"
    rec="${pair#* }"
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg d "$domain" --arg z "$zone" --arg r "$rec" \
        '.gui.domain = $d | .gui.zone_id = $z | .gui.dns_id = $r')
    _zt_state_write "$st"
    _zt_reload_tunnel || exit 1
    log_action "ZT HOSTNAME ADD gui ${domain}"
    success "GUI ${domain} is on the tunnel"
    echo -e "  ${DIM}Protect it: cipi zt access enable --gui${NC}"
}

_zt_hostname_remove() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local app="${1:-}" gui="${ARG_gui:-}"
    local st
    st=$(_zt_state)
    if [[ "$gui" == "true" || "$app" == "--gui" ]]; then
        _zt_access_delete "$(echo "$st" | jq -r '.gui.access_id // empty')"
        _zt_dns_delete "$(echo "$st" | jq -r '.gui.zone_id // empty')" "$(echo "$st" | jq -r '.gui.dns_id // empty')"
        st=$(echo "$st" | jq '.gui = {}')
        _zt_state_write "$st"
        _zt_reload_tunnel || true
        success "GUI removed from the tunnel"
        return 0
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt hostname remove <app|--gui>"; exit 1; }
    echo "$st" | jq -e --arg a "$app" '.hostnames[$a] != null' >/dev/null 2>&1 || {
        error "App '${app}' is not on the tunnel"
        exit 1
    }
    _zt_access_delete "$(echo "$st" | jq -r --arg a "$app" '.hostnames[$a].access_id // empty')"
    _zt_access_delete "$(echo "$st" | jq -r --arg a "$app" '.hostnames[$a].webhook_access_id // empty')"
    echo "$st" | jq -r --arg a "$app" \
        '.hostnames[$a].domains[]? | select(.zone_id != null) | "\(.zone_id) \(.dns_id)"' \
        | while read -r z r; do _zt_dns_delete "$z" "$r"; done
    st=$(echo "$st" | jq --arg a "$app" 'del(.hostnames[$a])')
    _zt_state_write "$st"
    _zt_reload_tunnel || true
    log_action "ZT HOSTNAME REMOVE ${app}"
    success "${app} removed from the tunnel"
}

# ── access ───────────────────────────────────────────────────

_zt_access() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable)  _zt_access_enable "$@" ;;
        disable) _zt_access_disable "$@" ;;
        *) error "Usage: cipi zt access enable|disable <app|--gui>"; exit 1 ;;
    esac
}

_zt_access_enable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local app="${1:-}" gui="${ARG_gui:-}"
    if [[ "$gui" == "true" || "$app" == "--gui" ]]; then
        _zt_access_enable_gui
        return $?
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt access enable <app>  or  --gui"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local st d
    st=$(_zt_state)
    echo "$st" | jq -e --arg a "$app" '.hostnames[$a] != null' >/dev/null 2>&1 || {
        error "${app} is not on the tunnel. Run: cipi zt hostname add ${app}"
        exit 1
    }
    d=$(app_get "$app" domain)
    [[ "$d" == \*.* ]] && d="${d#*.}"
    step "Creating Access application for ${d}..."
    local aid
    aid=$(_zt_access_create "cipi:${app}" "$d" "self_hosted") || {
        error "Access API failed. Token needs Account.Access: Apps and Policies: Edit"
        echo "  Connect an IdP (Google, GitHub, One-time PIN) in the Zero Trust dashboard first."
        exit 1
    }
    _zt_access_policy "$aid" "allow" || warn "Allow policy was not created — set it in the dashboard"
    st=$(echo "$st" | jq --arg a "$app" --arg id "$aid" '.hostnames[$a].access_id = $id')

    local wt
    wt=$(app_get "$app" webhook_token)
    if [[ -n "$wt" ]]; then
        step "Bypassing Access on /cipi/webhook (Git forge deploy hook)..."
        local wid path
        path="${d}/cipi/webhook"
        wid=$(_zt_access_create "cipi:${app}:webhook" "$path" "self_hosted") || wid=""
        if [[ -n "$wid" ]]; then
            _zt_access_policy "$wid" "bypass" \
                || warn "Webhook bypass policy failed — Git webhooks will 403 until you add a Bypass path in Access"
            st=$(echo "$st" | jq --arg a "$app" --arg id "$wid" '.hostnames[$a].webhook_access_id = $id')
            success "Webhook bypass: https://${path}"
        else
            warn "Could not create the /cipi/webhook bypass. Git webhooks will hit Access."
            echo "  Add a Bypass policy for ${d}/cipi/webhook in the Zero Trust dashboard."
        fi
    fi
    _zt_state_write "$st"
    log_action "ZT ACCESS ENABLE ${app}"
    success "Access in front of ${d} (authenticate before Nginx)"
    echo -e "  ${DIM}Tighten the IdP in the Cloudflare Zero Trust dashboard if you need more than 'any logged-in user'.${NC}"
}

_zt_access_enable_gui() {
    local domain st
    domain=$(_zt_gui_domain) || { error "GUI not configured"; exit 1; }
    st=$(_zt_state)
    [[ "$(echo "$st" | jq -r '.gui.domain // empty')" == "$domain" ]] || {
        error "GUI is not on the tunnel. Run: cipi zt hostname add --gui"
        exit 1
    }
    step "Creating Access application for GUI ${domain}..."
    local aid
    aid=$(_zt_access_create "cipi:gui" "$domain" "self_hosted") || {
        error "Access API failed. Token needs Account.Access: Apps and Policies: Edit"
        exit 1
    }
    _zt_access_policy "$aid" "allow" || warn "Allow policy was not created"
    st=$(echo "$st" | jq --arg id "$aid" '.gui.access_id = $id')
    _zt_state_write "$st"
    log_action "ZT ACCESS ENABLE gui"
    success "Access in front of the GUI (${domain})"
}

_zt_access_disable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local app="${1:-}" gui="${ARG_gui:-}" st
    st=$(_zt_state)
    if [[ "$gui" == "true" || "$app" == "--gui" ]]; then
        _zt_access_delete "$(echo "$st" | jq -r '.gui.access_id // empty')"
        st=$(echo "$st" | jq '.gui.access_id = ""')
        _zt_state_write "$st"
        success "Access removed from the GUI (hostname stays on the tunnel)"
        return 0
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt access disable <app|--gui>"; exit 1; }
    _zt_access_delete "$(echo "$st" | jq -r --arg a "$app" '.hostnames[$a].access_id // empty')"
    _zt_access_delete "$(echo "$st" | jq -r --arg a "$app" '.hostnames[$a].webhook_access_id // empty')"
    st=$(echo "$st" | jq --arg a "$app" \
        '.hostnames[$a].access_id = "" | .hostnames[$a].webhook_access_id = ""')
    _zt_state_write "$st"
    log_action "ZT ACCESS DISABLE ${app}"
    success "Access removed from ${app} (hostname stays public on the tunnel)"
}

# ── SSH ──────────────────────────────────────────────────────

_zt_ssh() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable)  _zt_ssh_enable "$@" ;;
        disable) _zt_ssh_disable "$@" ;;
        unlock)  _zt_unlock ssh "$@" ;;
        *) error "Usage: cipi zt ssh enable --hostname=HOST | disable | unlock"; exit 1 ;;
    esac
}

_zt_ssh_enable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local host="${ARG_hostname:-}"
    [[ -z "$host" ]] && read_input "Public hostname for SSH (e.g. ssh.example.com)" "" host
    [[ -z "$host" ]] && { error "Usage: cipi zt ssh enable --hostname=ssh.example.com"; exit 1; }
    validate_domain "$host" || { error "Invalid hostname '${host}'"; exit 1; }

    step "Publishing SSH on ${host} through the tunnel..."
    local pair zone rec st
    pair=$(_zt_dns_upsert "$host") || exit 1
    zone="${pair%% *}"
    rec="${pair#* }"
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg h "$host" --arg z "$zone" --arg r "$rec" \
        '.ssh.hostname = $h | .ssh.zone_id = $z | .ssh.dns_id = $r')
    _zt_state_write "$st"
    _zt_reload_tunnel || exit 1

    step "Creating Access SSH application..."
    local aid
    aid=$(_zt_access_create "cipi:ssh" "$host" "ssh") || aid=""
    if [[ -n "$aid" ]]; then
        _zt_access_policy "$aid" "allow" || warn "SSH Access allow policy failed — add it in the dashboard"
        st=$(_zt_state)
        st=$(echo "$st" | jq --arg id "$aid" '.ssh.access_id = $id')
        _zt_state_write "$st"
        success "Access SSH on ${host}"
    else
        warn "Access SSH application was not created. Tunnel SSH still works; add an SSH app in the dashboard."
    fi

    log_action "ZT SSH ENABLE ${host}"
    success "SSH via tunnel on ${host} — port 22 is still open"
    echo ""
    echo -e "  ${BOLD}On your laptop${NC} (~/.ssh/config):"
    echo ""
    echo "    Host ${host}"
    echo "      ProxyCommand cloudflared access ssh --hostname %h"
    echo "      User cipi"
    echo "      IdentityFile ~/.ssh/id_ed25519"
    echo ""
    echo -e "  Then: ${CYAN}ssh ${host}${NC}"
    echo -e "  When that works: ${CYAN}cipi zt lock ssh --yes${NC}"
    echo -e "  ${DIM}Deployer uses localhost SSH and is not affected.${NC}"
    echo ""
}

_zt_ssh_disable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local st
    st=$(_zt_state)
    if [[ "$(echo "$st" | jq -r '.lock_ssh // false')" == "true" ]]; then
        warn "SSH is locked — reopening port 22 before dropping the tunnel ingress"
        _zt_unlock_ssh_apply
        st=$(echo "$st" | jq '.lock_ssh = false')
    fi
    _zt_access_delete "$(echo "$st" | jq -r '.ssh.access_id // empty')"
    _zt_dns_delete "$(echo "$st" | jq -r '.ssh.zone_id // empty')" "$(echo "$st" | jq -r '.ssh.dns_id // empty')"
    st=$(echo "$st" | jq '.ssh = {}')
    _zt_state_write "$st"
    _zt_reload_tunnel || true
    log_action "ZT SSH DISABLE"
    success "SSH hostname removed from the tunnel"
}

# ── lock / unlock ────────────────────────────────────────────

_zt_lock() {
    local what="${1:-}"; shift || true
    case "$what" in
        http) _zt_lock_http "$@" ;;
        ssh)  _zt_lock_ssh "$@" ;;
        *) error "Usage: cipi zt lock http|ssh [--yes]"; exit 1 ;;
    esac
}

_zt_unlock() {
    local what="${1:-}"; shift || true
    case "$what" in
        http) _zt_unlock_http "$@" ;;
        ssh)  _zt_unlock_ssh "$@" ;;
        *) error "Usage: cipi zt unlock http|ssh  (ssh: also cipi zt ssh unlock)"; exit 1 ;;
    esac
}

_zt_app_http01_blocked() {
    local app="$1"
    [[ "$(app_get "$app" ssl_origin_ca)" == "true" ]] && return 1
    [[ -n "$(app_get "$app" ssl_dns_provider)" ]] && return 1
    local d cert
    d=$(app_get "$app" domain)
    [[ -z "$d" ]] && return 1
    cert=$(domain_cert_name "$d")
    [[ -d "/etc/letsencrypt/live/${cert}" ]]
}

_zt_lock_http_refuse_http01() {
    local bad="" a
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        if _zt_app_http01_blocked "$a"; then
            bad+=" ${a}"
        fi
    done < <(vault_read apps.json | jq -r 'keys[]?' 2>/dev/null)
    if [[ -n "$bad" ]]; then
        error "These apps still renew SSL over HTTP-01, which dies once port 80 is not world-open:${bad}"
        echo "  Switch each one first:"
        echo "    cipi ssl install <app> --dns=cloudflare"
        echo "    cipi zt origin-cert <app>"
        echo "  Or pass --force if you accept that those certificates will not renew."
        return 1
    fi
    return 0
}

_zt_all_http_on_tunnel() {
    local st a
    st=$(_zt_state)
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        echo "$st" | jq -e --arg a "$a" '.hostnames[$a] != null' >/dev/null 2>&1 || return 1
    done < <(vault_read apps.json | jq -r 'keys[]?' 2>/dev/null)
    if _zt_gui_domain >/dev/null 2>&1; then
        [[ -n "$(echo "$st" | jq -r '.gui.domain // empty')" ]] || return 1
    fi
    return 0
}

_zt_ufw_delete_comment() {
    local comment="$1" nums n
    command -v ufw >/dev/null 2>&1 || return 0
    nums=$(ufw status numbered 2>/dev/null | awk -v c="$comment" '
        index($0, c) {
            gsub(/^\[/, "", $1); gsub(/\]/, "", $1); print $1
        }' | sort -nr)
    for n in $nums; do
        yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
}

_zt_ufw_drop_world_http() {
    command -v ufw >/dev/null 2>&1 || return 0
    yes | ufw delete allow 80/tcp >/dev/null 2>&1 || true
    yes | ufw delete allow 443/tcp >/dev/null 2>&1 || true
    yes | ufw delete allow 80 >/dev/null 2>&1 || true
    yes | ufw delete allow 443 >/dev/null 2>&1 || true
}

_zt_lock_http_cf_ips() {
    _zt_ufw_delete_comment "cipi-zt-http"
    _zt_ufw_drop_world_http
    local c
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        ufw allow from "$c" to any port 80 proto tcp comment 'cipi-zt-http' >/dev/null 2>&1 || true
        ufw allow from "$c" to any port 443 proto tcp comment 'cipi-zt-http' >/dev/null 2>&1 || true
    done < <(_zt_each_cf_cidr)
}

_zt_lock_http_dark() {
    _zt_ufw_delete_comment "cipi-zt-http"
    _zt_ufw_drop_world_http
}

_zt_lock_http() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    if [[ "${ARG_force:-}" != "true" ]]; then
        _zt_lock_http_refuse_http01 || exit 1
    else
        warn "HTTP-01 apps will not renew — --force noted"
    fi
    if [[ "${ARG_yes:-}" != "true" ]]; then
        confirm "Restrict ports 80/443 (Cloudflare IPs only, or closed if every hostname is on the tunnel)?" \
            || { info "Aborted"; return 0; }
    fi
    _zt_fetch_ips || true
    local mode="cf-ips"
    if _zt_all_http_on_tunnel; then
        mode="dark"
        step "Every HTTP hostname is on the tunnel — closing 80/443 entirely"
        _zt_lock_http_dark
    else
        step "Some apps are not on the tunnel — 80/443 only from Cloudflare IPs"
        _zt_lock_http_cf_ips
    fi
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg m "$mode" '.lock_http = true | .lock_http_mode = $m')
    _zt_state_write "$st"
    log_action "ZT LOCK HTTP mode=${mode}"
    cipi_notify \
        "Cipi locked HTTP on $(hostname) (${mode})" \
        "Ports 80/443 are no longer world-open (${mode}). Let's Encrypt HTTP-01 cannot renew. Use DNS-01 or cipi zt origin-cert.\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        zt_lock_http
    success "HTTP locked (${mode})"
}

_zt_lock_ssh() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    if ! _zt_tunnel_healthy; then
        error "cloudflared is not healthy — refusing to close port 22 (you would lock yourself out)."
        echo "  Fix: systemctl status ${ZT_UNIT}   journalctl -u ${ZT_UNIT} -n 30"
        echo "  Port 22 stays open until the tunnel is running."
        exit 1
    fi
    if ! _zt_ssh_ingress_present; then
        error "No SSH ingress on the tunnel. Run: cipi zt ssh enable --hostname=ssh.example.com"
        echo "  Then ssh through cloudflared from your laptop, and only then lock."
        exit 1
    fi
    local host
    host=$(_zt_state | jq -r '.ssh.hostname // empty')
    if [[ "${ARG_yes:-}" != "true" ]]; then
        echo ""
        echo -e "  This closes ${BOLD}port 22${NC} on UFW. SSH will only work through:"
        echo -e "    ${CYAN}ssh ${host}${NC}  (ProxyCommand cloudflared access ssh --hostname ${host})"
        echo -e "  CrowdSec rescue (if enabled) stays reachable. Deployer uses localhost and is fine."
        echo ""
        confirm "Close port 22? You must already be able to SSH via the tunnel." \
            || { info "Aborted"; return 0; }
    fi
    command -v ufw >/dev/null 2>&1 && yes | ufw delete allow 22/tcp >/dev/null 2>&1 || true
    command -v ufw >/dev/null 2>&1 && yes | ufw delete allow 22 >/dev/null 2>&1 || true
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq '.lock_ssh = true')
    _zt_state_write "$st"
    log_action "ZT LOCK SSH"
    log_event "SSH port 22 closed (Cloudflare Tunnel) on $(hostname)"
    cipi_notify \
        "Cipi locked SSH on $(hostname)" \
        "Port 22 is closed. SSH is only via cloudflared access on ${host}. Unlock with: cipi zt ssh unlock\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        zt_lock_ssh
    success "Port 22 closed. SSH is tunnel-only (${host}). Unlock: cipi zt ssh unlock"
}

_zt_unlock_http_apply() {
    _zt_ufw_delete_comment "cipi-zt-http"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
}

_zt_unlock_ssh_apply() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 22/tcp >/dev/null 2>&1 || true
}

_zt_unlock_http() {
    parse_args "$@"
    _zt_unlock_http_apply
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq '.lock_http = false | .lock_http_mode = ""')
    _zt_state_write "$st"
    log_action "ZT UNLOCK HTTP"
    success "Ports 80/443 world-open again"
}

_zt_unlock_ssh() {
    parse_args "$@"
    _zt_unlock_ssh_apply
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq '.lock_ssh = false')
    _zt_state_write "$st"
    log_action "ZT UNLOCK SSH"
    success "Port 22 reopened"
}

# ── Origin CA ────────────────────────────────────────────────

_zt_vhost_install_origin() {
    local app="$1" cert="$2" key="$3"
    local vhost="/etc/nginx/sites-available/${app}"
    [[ -f "$vhost" ]] || { error "Nginx vhost for '${app}' not found"; return 1; }
    if grep -qE '^\s*ssl_certificate\s' "$vhost"; then
        sed -i -E "s|^(\s*)ssl_certificate\s+.*|\1ssl_certificate ${cert};|" "$vhost"
        sed -i -E "s|^(\s*)ssl_certificate_key\s+.*|\1ssl_certificate_key ${key};|" "$vhost"
        return 0
    fi
    # Tunnel ingress is http://127.0.0.1:80 — Origin CA is for Full Strict
    # orange-cloud (:443). Do not clone the vhost; custom/Octane layouts differ.
    warn "No ssl_certificate in the vhost yet — Origin CA saved at ${cert}"
    echo "  The tunnel talks HTTP to :80 and does not need it. After a :443 block exists"
    echo "  (cipi ssl install, or Cloudflare connecting to origin 443), re-run:"
    echo "    cipi zt origin-cert ${app}"
    return 0
}

_zt_origin_cert() {
    parse_args "$@"
    _zt_require_token || exit 1
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi zt origin-cert <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local d hosts_json h
    d=$(app_get "$app" domain)
    [[ -z "$d" ]] && { error "No domain for app '$app'"; exit 1; }
    hosts_json="[]"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        hosts_json=$(echo "$hosts_json" | jq --arg n "$h" '. + [$n]')
    done < <(_zt_app_domains "$app")
    if domain_is_wildcard "$d"; then
        local apex; apex=$(domain_cert_name "$d")
        hosts_json=$(echo "$hosts_json" | jq --arg a "$apex" --arg w "*.${apex}" \
            '. + [$a, $w] | unique')
    fi

    mkdir -p "${ZT_ORIGIN}/${app}"
    chmod 700 "$ZT_ORIGIN" "${ZT_ORIGIN}/${app}"
    local key="${ZT_ORIGIN}/${app}/key.pem"
    local csr="${ZT_ORIGIN}/${app}/csr.pem"
    local cert="${ZT_ORIGIN}/${app}/cert.pem"
    step "Generating CSR for Origin CA..."
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$csr" \
        -subj "/CN=$(domain_cert_name "$d")" >/dev/null 2>&1 || {
        error "openssl could not create the CSR"
        exit 1
    }
    chmod 600 "$key" "$csr"
    local csr_body body resp
    csr_body=$(cat "$csr")
    body=$(jq -n --arg csr "$csr_body" --argjson hosts "$hosts_json" \
        '{csr:$csr, hostnames:$hosts, requested_validity:5475, request_type:"origin-rsa"}')
    step "Requesting Cloudflare Origin CA certificate..."
    resp=$(_zt_api POST "/certificates" "$body") || resp=""
    if ! _zt_api_ok "$resp"; then
        error "Origin CA failed: $(_zt_api_err "$resp")"
        echo "  Token needs Zone.SSL and Certificates: Edit. HTTP-01 Let's Encrypt is left alone."
        exit 1
    fi
    echo "$resp" | jq -r '.result.certificate' > "$cert"
    [[ -s "$cert" ]] || { error "Origin CA returned an empty certificate"; exit 1; }
    chmod 644 "$cert"
    _zt_vhost_install_origin "$app" "$cert" "$key" || exit 1
    reload_nginx || exit 1
    app_set "$app" ssl_origin_ca "true"
    app_set "$app" force_https "true"
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg a "$app" '
        if .hostnames[$a] then .hostnames[$a].origin_cert = true else . end')
    _zt_state_write "$st"
    log_action "ZT ORIGIN CERT ${app}"
    success "Cloudflare Origin CA installed for ${d}"
    echo -e "  ${DIM}cipi ssl install HTTP-01 will refuse this app. Tunnel can keep talking HTTP to :80.${NC}"
}
