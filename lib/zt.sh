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
# `cipi nginx real-ip cloudflare` (lib/nginx.sh) keeps the same nginx file,
# fail2ban list and CrowdSec whitelist without a tunnel. Its nightly refresh
# is this cron file, and the file is the sign that it is on: disabling Zero
# Trust then leaves the three in place.
[[ -z "${NGINX_REALIP_CRON:-}" ]] && readonly NGINX_REALIP_CRON="/etc/cron.d/cipi-nginx-realip"
# Short-lived SSH certificates (cipi zt ssh cert): the CA of the SSH Access
# application, who may sign in with which certificate, and the sshd drop-in.
[[ -z "${ZT_SSH_CA:-}" ]]         && readonly ZT_SSH_CA="/etc/ssh/cipi-cloudflare-ca.pub"
[[ -z "${ZT_SSH_PRINCIPALS:-}" ]] && readonly ZT_SSH_PRINCIPALS="/etc/ssh/cipi-principals"
[[ -z "${ZT_SSHD_DROPIN:-}" ]]    && readonly ZT_SSHD_DROPIN="/etc/ssh/sshd_config.d/10-cipi-cloudflare-ca.conf"
# Calls a status or the monitor make: short, so a slow API never holds them up.
[[ -z "${ZT_API_TIMEOUT:-}" ]]    && ZT_API_TIMEOUT=45
[[ -z "${CIPI_BIN:-}" ]]          && CIPI_BIN="/usr/local/bin/cipi"

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
        service-token|service-tokens|servicetoken) _zt_service_token "$@" ;;
        tcp)          _zt_tcp "$@" ;;
        ssh)          _zt_ssh "$@" ;;
        lock)         _zt_lock "$@" ;;
        unlock)       _zt_unlock "$@" ;;
        lockdown)     _zt_lockdown "$@" ;;
        preview|previews) _zt_preview "$@" ;;
        replica|replicas) _zt_replica "$@" ;;
        purge)        _zt_purge "$@" ;;
        origin-cert|origincert|origin_cert) _zt_origin_cert "$@" ;;
        *) error "Usage: cipi zt token|enable|disable|status|refresh|hostname|access|service-token|tcp|ssh|lock|unlock|lockdown|preview|replica|purge|origin-cert [args]"; exit 1 ;;
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
        _cipi_run_timed "$ZT_API_TIMEOUT" curl -sS -X "$method" "${ZT_API}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$body" >"$tmp" 2>/dev/null || {
            rm -f "$tmp"
            return 1
        }
    else
        _cipi_run_timed "$ZT_API_TIMEOUT" curl -sS -X "$method" "${ZT_API}${path}" \
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
    mkdir -p "$(dirname "$ZT_REALIP")"
    local tmp cidr
    tmp=$(mktemp)
    {
        echo "# Written by Cipi (cipi nginx real-ip, cipi zt). Cloudflare's edge ranges, refreshed every night."
        echo "# A request is given the address in CF-Connecting-IP only when it comes from one of them."
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
    mkdir -p "$(dirname "$ZT_F2B")"
    local cidrs="" c
    while IFS= read -r c; do
        [[ -n "$c" ]] && cidrs+=" ${c}"
    done < <(_zt_each_cf_cidr)
    cat > "$ZT_F2B" <<EOF
# Written by Cipi (cipi nginx real-ip, cipi zt). ignoreip replaces jail.local's list, so localhost stays.
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
    [[ -d "$(dirname "$ZT_CS_WL")" ]] || return 0
    local tmp c
    tmp=$(mktemp)
    {
        echo "name: crowdsecurity/cipi-cloudflare-whitelists"
        echo "description: \"Cloudflare edge CIDRs (cipi nginx real-ip, cipi zt) — defence if real_ip is missing\""
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
        local apih
        apih=$(echo "$st" | jq -r '.api.domain // empty')
        if [[ -n "$apih" && "$apih" != "$guih" ]]; then
            printf '  - hostname: "%s"\n    service: http://127.0.0.1:80\n' "$apih"
        fi
        sshh=$(echo "$st" | jq -r '.ssh.hostname // empty')
        if [[ -n "$sshh" ]]; then
            printf '  - hostname: "%s"\n    service: ssh://127.0.0.1:22\n' "$sshh"
        fi
        # cipi zt tcp: a database or Valkey on 127.0.0.1, behind Access.
        local th tp
        while IFS=' ' read -r th tp; do
            [[ -n "$th" && "$tp" =~ ^[0-9]+$ ]] || continue
            printf '  - hostname: "%s"\n    service: tcp://127.0.0.1:%s\n' "$th" "$tp"
        done < <(echo "$st" | jq -r '(.tcp // {}) | to_entries[] | "\(.key) \(.value.port)"' 2>/dev/null)
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

# _zt_access_create <name> <domain> [type] [paths]
# paths: comma-separated, each from / (cipi zt access enable --path=/admin,/horizon):
# Access then covers those paths alone and the rest of the site stays public.
_zt_access_create() {
    local name="$1" domain="$2" type="${3:-self_hosted}" paths="${4:-}"
    local account body resp id dests p
    account=$(_zt_account)
    dests=$(jq -n --arg d "$domain" '[{type:"public", uri:$d}]')
    if [[ -n "$paths" ]]; then
        dests="[]"
        local -a list
        IFS=',' read -ra list <<< "$paths"
        for p in "${list[@]}"; do
            p="${p// /}"
            [[ -z "$p" ]] && continue
            p="${p%/}"
            dests=$(jq -c --arg u "${domain}${p}" '. + [{type:"public", uri:$u}]' <<< "$dests")
        done
        [[ "$(jq 'length' <<< "$dests")" -gt 0 ]] || dests=$(jq -n --arg d "$domain" '[{type:"public", uri:$d}]')
    fi
    body=$(jq -n --arg n "$name" --arg t "$type" --argjson ds "$dests" \
        '{name:$n, domain:$ds[0].uri, type:$t, session_duration:"24h", destinations:$ds}')
    resp=$(_zt_api POST "/accounts/${account}/access/apps" "$body") || resp=""
    if ! _zt_api_ok "$resp"; then
        echo ""
        return 1
    fi
    id=$(echo "$resp" | jq -r '.result.id // empty')
    printf '%s' "$id"
}

# The include rules of an allow policy (--allow=): emails and @domains,
# comma-separated; empty is anyone who signs in with the identity provider.
# Prints the JSON array; returns 1 on an item that is neither.
_zt_access_include() {
    local allow="${1:-}" out="[]" item
    if [[ -z "$allow" || "$allow" == "all" || "$allow" == "everyone" ]]; then
        echo '[{"everyone":{}}]'
        return 0
    fi
    local -a items
    IFS=',' read -ra items <<< "$allow"
    for item in "${items[@]}"; do
        item=$(printf '%s' "$item" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [[ -z "$item" ]] && continue
        if [[ "$item" =~ ^@?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && "$item" != *@*@* && ( "$item" == @* || "$item" != *@* ) ]]; then
            out=$(jq -c --arg d "${item#@}" '. + [{email_domain:{domain:$d}}]' <<< "$out")
        elif [[ "$item" =~ ^[a-z0-9._%+-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            out=$(jq -c --arg e "$item" '. + [{email:{email:$e}}]' <<< "$out")
        else
            error "Not an email or an @domain: ${item}"
            return 1
        fi
    done
    [[ "$(jq 'length' <<< "$out")" -gt 0 ]] || { echo '[{"everyone":{}}]'; return 0; }
    echo "$out"
}

# --allow as the state keeps it: normalised, comma-separated ("" = anyone signed in).
_zt_access_allow_norm() {
    local allow="${1:-}"
    [[ "$allow" == "all" || "$allow" == "everyone" ]] && allow=""
    printf '%s' "$allow" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | sed 's/,,*/,/g; s/^,//; s/,$//'
}

# _zt_access_policy <app_id> <decision> [include JSON] [name]
_zt_access_policy() {
    local app_id="$1" decision="$2" include="${3:-}" pname="${4:-}"
    local account body resp
    account=$(_zt_account)
    [[ -n "$include" ]] || include='[{"everyone":{}}]'
    [[ -n "$pname" ]] || pname="cipi-${decision}"
    body=$(jq -n --arg n "$pname" --arg d "$decision" --argjson i "$include" \
        '{name:$n, decision:$d, include:$i}')
    resp=$(_zt_api POST "/accounts/${account}/access/apps/${app_id}/policies" "$body") || resp=""
    _zt_api_ok "$resp" || return 1
    echo "$resp" | jq -r '.result.id // empty'
}

_zt_access_policy_delete() {
    local app_id="$1" policy_id="$2"
    [[ -n "$app_id" && -n "$policy_id" ]] || return 0
    local account; account=$(_zt_account)
    _zt_api DELETE "/accounts/${account}/access/apps/${app_id}/policies/${policy_id}" >/dev/null 2>&1 || true
}

# Validates --path=: comma-separated, each from /, no spaces or wildcards in
# the middle. Prints the normalised list.
_zt_access_paths_norm() {
    local paths="${1:-}" p out=""
    [[ -z "$paths" ]] && return 0
    local -a list
    IFS=',' read -ra list <<< "$paths"
    for p in "${list[@]}"; do
        p="${p// /}"
        [[ -z "$p" ]] && continue
        [[ "$p" =~ ^/[A-Za-z0-9._~/-]*$ ]] || { error "Not a path: ${p} (from /, e.g. /admin)"; return 1; }
        [[ "$p" != "/" ]] && p="${p%/}"
        out+="${out:+,}${p}"
    done
    printf '%s' "$out"
}

# Positional arguments only (flags may come first): the first one.
_zt_first_arg() {
    local a
    for a in "$@"; do
        [[ "$a" == --* ]] && continue
        printf '%s' "$a"
        return 0
    done
    return 0
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

_zt_api_domain() {
    [[ -f "${CIPI_CONFIG}/api.json" ]] || return 1
    local d
    d=$(vault_read api.json | jq -r '.domain // empty')
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
    # A replica (cipi zt replica join) shares the tunnel, its DNS and its
    # Access applications with other servers: deleting them would take those
    # servers offline too. It leaves; the server that created them disables.
    if [[ "$(_zt_state | jq -r '.replica // false')" == "true" && "${ARG_delete_tunnel:-}" != "true" ]]; then
        error "This server is a replica of tunnel $(_zt_state | jq -r '.tunnel_name // .tunnel_id'): disable would delete it for every server."
        echo "  Stop it here only:  cipi zt replica leave"
        echo "  Delete it anyway:   cipi zt disable --delete-tunnel"
        exit 1
    fi
    if [[ "${ARG_delete_tunnel:-}" != "true" ]]; then
        local others
        others=$(_zt_replica_connectors_elsewhere 2>/dev/null || echo 0)
        if [[ "${others:-0}" =~ ^[0-9]+$ && "${others:-0}" -gt 0 ]]; then
            error "${others} other server(s) run this tunnel (replicas): disable would take them offline."
            echo "  Move them first, or stop the tunnel here only: cipi zt replica leave"
            echo "  Delete it for everyone: cipi zt disable --delete-tunnel"
            exit 1
        fi
    fi
    if [[ "${ARG_force:-}" != "true" && "${ARG_yes:-}" != "true" ]]; then
        confirm "Disable Zero Trust, remove the tunnel and cloudflared, restore UFW 22/80/443? Fail2ban stays." \
            || { info "Aborted"; return 0; }
    fi

    step "Reopening firewall ports..."
    _zt_unlock_http_apply
    _zt_unlock_ssh_apply
    _zt_ssh_cert_remove_files

    step "Removing Access applications and service tokens..."
    local st ids
    st=$(_zt_state)
    ids=$(echo "$st" | jq -r '
        [.hostnames[]? | .access_id, .webhook_access_id]
        + [.gui.access_id, .api.access_id, .ssh.access_id]
        + [(.tcp // {})[] | .access_id]
        | .[] | select(. != null and . != "")
    ' 2>/dev/null || true)
    while IFS= read -r id; do
        [[ -n "$id" ]] && _zt_access_delete "$id"
    done <<< "${ids:-}"
    local acct; acct=$(_zt_account)
    echo "$st" | jq -r '(.service_tokens // {})[] | .id // empty' 2>/dev/null | while read -r tid; do
        [[ -n "$tid" ]] && _zt_api DELETE "/accounts/${acct}/access/service_tokens/${tid}" >/dev/null 2>&1 || true
    done

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
    _zt_dns_delete "$(echo "$st" | jq -r '.api.zone_id // empty')" "$(echo "$st" | jq -r '.api.dns_id // empty')"
    echo "$st" | jq -r '(.tcp // {})[] | select(.zone_id != null and .dns_id != null) | "\(.zone_id) \(.dns_id)"' 2>/dev/null \
        | while read -r z r; do _zt_dns_delete "$z" "$r"; done

    step "Stopping cloudflared..."
    systemctl disable --now "$ZT_UNIT" 2>/dev/null || true
    _zt_delete_tunnel
    rm -f /etc/systemd/system/${ZT_UNIT}.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$ZT_CF_DIR"
    if [[ -f "$NGINX_REALIP_CRON" ]]; then
        # cipi nginx real-ip cloudflare is on: the domains may still be behind
        # Cloudflare's proxy without the tunnel, and its ranges stay trusted.
        rm -f "$ZT_CRON"
        info "nginx keeps reading the visitor's address from Cloudflare (cipi nginx real-ip off to stop)"
    else
        rm -f "$ZT_REALIP" "$ZT_F2B" "$ZT_CRON" "$ZT_CS_WL"
    fi
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
        | .lock_http_mode = "" | .hostnames = {} | .gui = {} | .api = {} | .ssh = {}
        | .tcp = {} | .service_tokens = {} | .previews = (.previews // {}) | .replica = false
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
    if [[ "${ARG_json:-}" == "true" ]]; then
        _zt_status_json
        return 0
    fi
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
    local apid
    apid=$(echo "$st" | jq -r '.api.domain // empty')
    if [[ -n "$apid" ]]; then
        local aacc
        aacc=$(echo "$st" | jq -r '.api.access_id // empty')
        echo -e "    ${CYAN}api${NC}  ${apid}  $([[ -n "$aacc" ]] && echo -e "${GREEN}Access${NC}" || echo -e "${DIM}public${NC}")"
    fi
    local tcpl
    tcpl=$(echo "$st" | jq -r '(.tcp // {}) | to_entries[] | "    \(.key)  tcp → 127.0.0.1:\(.value.port) (\(.value.service))"')
    if [[ -n "$tcpl" ]]; then
        echo ""
        echo -e "  ${BOLD}TCP services${NC} (behind Access)"
        echo "$tcpl"
    fi
    local extra
    extra=$(echo "$st" | jq -r '[
        (if ((.service_tokens // {}) | length) > 0 then "service tokens: \((.service_tokens) | keys | join(", "))" else empty end),
        (if ((.previews // {}) | length) > 0 then "previews: \((.previews) | keys | join(", "))" else empty end),
        (if (.ssh.cert.enabled // false) then "SSH certificates: \((.ssh.cert.users // {}) | keys | join(", "))" else empty end),
        (if (.replica // false) then "replica of \(.replica_from // "another server")" else empty end)
    ] | .[]')
    if [[ -n "$extra" ]]; then
        echo ""
        while IFS= read -r line; do echo -e "  ${DIM}${line}${NC}"; done <<< "$extra"
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
    local app; app=$(_zt_first_arg "$@")
    if [[ "${ARG_gui:-}" == "true" ]]; then
        _zt_hostname_add_special gui
        return $?
    fi
    if [[ "${ARG_api:-}" == "true" ]]; then
        _zt_hostname_add_special api
        return $?
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt hostname add <app|--gui|--api>"; exit 1; }
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

# The panel (--gui) or the API (--api) on the tunnel: their own domain.
_zt_hostname_add_special() {
    local t="$1" domain
    if [[ "$t" == gui ]]; then
        domain=$(_zt_gui_domain) || { error "GUI not configured. Run: cipi gui <domain>"; exit 1; }
    else
        domain=$(_zt_api_domain) || { error "API not configured. Run: cipi api <domain>"; exit 1; }
    fi
    step "Routing $(_zt_target_label "$t") ${domain} through the tunnel..."
    local pair zone rec st
    pair=$(_zt_dns_upsert "$domain") || exit 1
    zone="${pair%% *}"
    rec="${pair#* }"
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg t "$t" --arg d "$domain" --arg z "$zone" --arg r "$rec" \
        '.[$t] = ((.[$t] // {}) + {domain:$d, zone_id:$z, dns_id:$r})')
    _zt_state_write "$st"
    _zt_reload_tunnel || exit 1
    log_action "ZT HOSTNAME ADD ${t} ${domain}"
    if [[ "$t" == gui ]]; then
        success "GUI ${domain} is on the tunnel"
        echo -e "  ${DIM}Protect it: cipi zt access enable --gui${NC}"
    else
        success "API ${domain} is on the tunnel"
        echo -e "  ${DIM}Only machines call it: cipi zt access enable --api --allow=none${NC}"
        echo -e "  ${DIM}then a token for the panel: cipi zt service-token create panel --for=api${NC}"
    fi
}

_zt_hostname_remove() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local app; app=$(_zt_first_arg "$@")
    local st t=""
    [[ "${ARG_gui:-}" == "true" ]] && t=gui
    [[ "${ARG_api:-}" == "true" ]] && t=api
    if [[ -n "$t" ]]; then
        _zt_access_drop "$t"
        st=$(_zt_state)
        _zt_dns_delete "$(echo "$st" | jq -r --arg t "$t" '.[$t].zone_id // empty')" "$(echo "$st" | jq -r --arg t "$t" '.[$t].dns_id // empty')"
        st=$(echo "$st" | jq --arg t "$t" '.[$t] = {}')
        _zt_state_write "$st"
        _zt_reload_tunnel || true
        log_action "ZT HOSTNAME REMOVE ${t}"
        success "$( [[ "$t" == gui ]] && echo GUI || echo API ) removed from the tunnel"
        return 0
    fi
    [[ -z "$app" ]] && { error "Usage: cipi zt hostname remove <app|--gui|--api>"; exit 1; }
    st=$(_zt_state)
    echo "$st" | jq -e --arg a "$app" '.hostnames[$a] != null' >/dev/null 2>&1 || {
        error "App '${app}' is not on the tunnel"
        exit 1
    }
    _zt_access_drop "$app"
    echo "$st" | jq -r --arg a "$app" \
        '.hostnames[$a].domains[]? | select(.zone_id != null) | "\(.zone_id) \(.dns_id)"' \
        | while read -r z r; do _zt_dns_delete "$z" "$r"; done
    st=$(_zt_state | jq --arg a "$app" 'del(.hostnames[$a])')
    _zt_state_write "$st"
    _zt_reload_tunnel || true
    log_action "ZT HOSTNAME REMOVE ${app}"
    success "${app} removed from the tunnel"
}

# ── access ───────────────────────────────────────────────────
#
# A target is an app, the panel (--gui) or the API (--api). Each keeps its
# Access application in the state: .hostnames[app], .gui or .api, with
#   access_id, access_policy_id   the application and its allow policy
#   access_paths, access_allow    what --path= and --allow= asked for
#   webhook_access_id             apps: the Bypass of /cipi/webhook
# and service tokens add policies of their own (cipi zt service-token).

_zt_access() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable|update) _zt_access_enable "$@" ;;
        disable)       _zt_access_disable "$@" ;;
        *) error "Usage: cipi zt access enable|disable <app|--gui|--api> [--path=/admin,/horizon] [--allow=me@example.com,@example.com|none]"; exit 1 ;;
    esac
}

# The target named by the arguments: an app name, gui or api ("" if none).
_zt_target_of() {
    parse_args "$@"
    if [[ "${ARG_gui:-}" == "true" ]]; then echo gui; return 0; fi
    if [[ "${ARG_api:-}" == "true" ]]; then echo api; return 0; fi
    _zt_first_arg "$@"
}

# Where a target lives in the state, as a jq path.
_zt_target_path() {
    case "$1" in
        gui) echo '["gui"]' ;;
        api) echo '["api"]' ;;
        *)   jq -cn --arg a "$1" '["hostnames", $a]' ;;
    esac
}

_zt_target_label() {
    case "$1" in
        gui) echo "the panel" ;;
        api) echo "the API" ;;
        *)   echo "$1" ;;
    esac
}

_zt_target_get() {   # <target> <key>
    local p; p=$(_zt_target_path "$1")
    _zt_state | jq -r --argjson p "$p" --arg k "$2" 'getpath($p)[$k] // empty' 2>/dev/null
}

# The hostname Access protects: the app's domain (a wildcard's apex), or the
# one the panel / the API is on. Nothing when the target is not on the tunnel.
_zt_target_domain() {
    local t="$1" st d
    st=$(_zt_state)
    case "$t" in
        gui|api) echo "$st" | jq -r --arg t "$t" '.[$t].domain // empty' ;;
        *)
            echo "$st" | jq -e --arg a "$t" '.hostnames[$a] != null' >/dev/null 2>&1 || return 0
            d=$(app_get "$t" domain)
            [[ "$d" == \*.* ]] && d="${d#*.}"
            printf '%s' "$d"
            ;;
    esac
}

# Removes the Access application of a target (and its webhook bypass). The
# service tokens that pointed at it are dropped from the state: their
# policies went with the application.
_zt_access_drop() {
    local t="$1" st p
    st=$(_zt_state)
    p=$(_zt_target_path "$t")
    _zt_access_delete "$(echo "$st" | jq -r --argjson p "$p" 'getpath($p).access_id // empty')"
    _zt_access_delete "$(echo "$st" | jq -r --argjson p "$p" 'getpath($p).webhook_access_id // empty')"
    st=$(echo "$st" | jq --argjson p "$p" --arg t "$t" '
        if getpath($p) == null then . else
            setpath($p; getpath($p) + {access_id:"", webhook_access_id:"", access_policy_id:"", access_paths:"", access_allow:""})
        end
        | .service_tokens = ((.service_tokens // {}) | with_entries(select(.value.for != $t)))')
    _zt_state_write "$st"
}

_zt_access_enable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local t; t=$(_zt_target_of "$@")
    [[ -z "$t" ]] && { error "Usage: cipi zt access enable <app|--gui|--api> [--path=/admin] [--allow=me@example.com,@example.com|none]"; exit 1; }
    if [[ "$t" != gui && "$t" != api ]]; then
        app_exists "$t" || { error "App '$t' not found"; exit 1; }
    fi
    local d
    d=$(_zt_target_domain "$t")
    if [[ -z "$d" ]]; then
        case "$t" in
            gui) error "The panel is not on the tunnel. Run: cipi zt hostname add --gui" ;;
            api) error "The API is not on the tunnel. Run: cipi zt hostname add --api" ;;
            *)   error "${t} is not on the tunnel. Run: cipi zt hostname add ${t}" ;;
        esac
        exit 1
    fi

    # What was asked, or what the target had: `access enable` again with no
    # --path / --allow keeps them, `--path=` (empty) or `--allow=all` clears.
    local paths allow include
    if [[ -n "${ARG_path+x}" ]]; then
        [[ "${ARG_path}" == "true" ]] && { error "--path needs a value: --path=/admin,/horizon"; exit 1; }
        paths=$(_zt_access_paths_norm "${ARG_path}") || exit 1
    else
        paths=$(_zt_target_get "$t" access_paths)
    fi
    if [[ -n "${ARG_allow+x}" ]]; then
        [[ "${ARG_allow}" == "true" ]] && { error "--allow needs a value: --allow=me@example.com,@example.com"; exit 1; }
        allow=$(_zt_access_allow_norm "${ARG_allow}")
    else
        allow=$(_zt_target_get "$t" access_allow)
    fi
    if [[ "$allow" != "none" ]]; then
        include=$(_zt_access_include "$allow") || exit 1
    fi

    local had; had=$(_zt_target_get "$t" access_id)
    if [[ -n "$had" ]]; then
        step "Replacing the Access application of $(_zt_target_label "$t")..."
        local keep_tokens
        keep_tokens=$(_zt_state | jq -c --arg t "$t" '[(.service_tokens // {}) | to_entries[] | select(.value.for == $t) | .key]')
        _zt_access_delete "$had"
        _zt_access_delete "$(_zt_target_get "$t" webhook_access_id)"
        [[ "$keep_tokens" != "[]" ]] && _ZT_REATTACH_TOKENS="$keep_tokens"
    fi

    local name="cipi:${t}"
    [[ "$t" == gui ]] && name="cipi:gui"
    [[ "$t" == api ]] && name="cipi:api"
    step "Creating Access application for ${d}${paths:+ (${paths//,/, })}..."
    local aid
    aid=$(_zt_access_create "$name" "$d" "self_hosted" "$paths") || aid=""
    if [[ -z "$aid" ]]; then
        error "Access API failed. Token needs Account.Access: Apps and Policies: Edit"
        echo "  Connect an IdP (Google, GitHub, One-time PIN) in the Zero Trust dashboard first."
        exit 1
    fi
    local pid=""
    if [[ "$allow" != "none" ]]; then
        pid=$(_zt_access_policy "$aid" "allow" "$include") || {
            pid=""
            warn "Allow policy was not created — set it in the dashboard"
        }
    fi

    local st p
    st=$(_zt_state)
    p=$(_zt_target_path "$t")
    st=$(echo "$st" | jq --argjson p "$p" --arg id "$aid" --arg pid "$pid" --arg paths "$paths" --arg allow "$allow" '
        setpath($p; (getpath($p) // {}) + {access_id:$id, access_policy_id:$pid, access_paths:$paths, access_allow:$allow, webhook_access_id:""})')
    _zt_state_write "$st"

    # The forge's deploy hook carries no identity: a Bypass for its path,
    # when Access covers it (the whole site, or a path above /cipi/webhook).
    if [[ "$t" != gui && "$t" != api && -n "$(app_get "$t" webhook_token)" ]] && _zt_paths_cover "$paths" "/cipi/webhook"; then
        step "Bypassing Access on /cipi/webhook (Git forge deploy hook)..."
        local wid path
        path="${d}/cipi/webhook"
        wid=$(_zt_access_create "cipi:${t}:webhook" "$path" "self_hosted") || wid=""
        if [[ -n "$wid" ]]; then
            _zt_access_policy "$wid" "bypass" >/dev/null \
                || warn "Webhook bypass policy failed — Git webhooks will 403 until you add a Bypass path in Access"
            st=$(_zt_state | jq --arg a "$t" --arg id "$wid" '.hostnames[$a].webhook_access_id = $id')
            _zt_state_write "$st"
            success "Webhook bypass: https://${path}"
        else
            warn "Could not create the /cipi/webhook bypass. Git webhooks will hit Access."
            echo "  Add a Bypass policy for ${d}/cipi/webhook in the Zero Trust dashboard."
        fi
    fi

    # Service tokens the old application had: their policy, on the new one.
    if [[ -n "${_ZT_REATTACH_TOKENS:-}" ]]; then
        local n
        while IFS= read -r n; do
            [[ -n "$n" ]] && _zt_service_token_attach "$n" "$aid"
        done < <(jq -r '.[]' <<< "$_ZT_REATTACH_TOKENS")
        unset _ZT_REATTACH_TOKENS
    fi

    log_action "ZT ACCESS ENABLE ${t} paths=${paths:-/} allow=${allow:-all}"
    local who="anyone who signs in with your identity provider"
    [[ -n "$allow" ]] && who="${allow//,/, }"
    [[ "$allow" == "none" ]] && who="service tokens only (cipi zt service-token create)"
    if [[ -n "$paths" ]]; then
        success "Access in front of ${d}${paths//,/, ${d}}: ${who}. The rest of the site is public."
    else
        success "Access in front of ${d}: ${who}"
    fi
}

# Does a list of path prefixes (empty = the whole site) cover a path?
_zt_paths_cover() {
    local paths="${1:-}" want="$2" p
    [[ -z "$paths" ]] && return 0
    local -a list
    IFS=',' read -ra list <<< "$paths"
    for p in "${list[@]}"; do
        [[ "$p" == "/" || "$want" == "$p" || "$want" == "$p"/* ]] && return 0
    done
    return 1
}

_zt_access_disable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local t; t=$(_zt_target_of "$@")
    [[ -z "$t" ]] && { error "Usage: cipi zt access disable <app|--gui|--api>"; exit 1; }
    [[ -n "$(_zt_target_get "$t" access_id)" ]] || { info "No Access in front of $(_zt_target_label "$t")"; return 0; }
    local tokens
    tokens=$(_zt_state | jq -r --arg t "$t" '[(.service_tokens // {}) | to_entries[] | select(.value.for == $t) | .key] | join(", ")')
    _zt_access_drop "$t"
    log_action "ZT ACCESS DISABLE ${t}"
    [[ -n "$tokens" ]] && warn "Service tokens for $(_zt_target_label "$t") have nothing to open now (${tokens}); revoke them: cipi zt service-token revoke <name>"
    case "$t" in
        gui|api) success "Access removed from $(_zt_target_label "$t") (hostname stays on the tunnel)" ;;
        *)       success "Access removed from ${t} (hostname stays public on the tunnel)" ;;
    esac
}

# ── service tokens ───────────────────────────────────────────
#
# A client that cannot sign in — the panel calling a server's API, a CI
# deploy, a monitor — passes Access with CF-Access-Client-Id and
# CF-Access-Client-Secret headers. Cipi creates the token and a Service Auth
# policy on the target's Access application; the secret is printed once.

_zt_service_token() {
    local action="${1:-}"; shift || true
    case "$action" in
        create|add)          _zt_service_token_create "$@" ;;
        list|ls)             _zt_service_token_list "$@" ;;
        revoke|remove|delete) _zt_service_token_revoke "$@" ;;
        *) error "Usage: cipi zt service-token create <name> --for=<app>|gui|api [--duration=8760h] [--json] | list [--json] | revoke <name>"; exit 1 ;;
    esac
}

_zt_service_token_attach() {   # <name> <access app id> — the Service Auth policy
    local n="$1" aid="$2" tid pid st
    st=$(_zt_state)
    tid=$(echo "$st" | jq -r --arg n "$n" '.service_tokens[$n].id // empty')
    [[ -n "$tid" && -n "$aid" ]] || return 1
    pid=$(_zt_access_policy "$aid" "non_identity" "$(jq -cn --arg i "$tid" '[{service_token:{token_id:$i}}]')" "cipi-service-${n}") || return 1
    st=$(echo "$st" | jq --arg n "$n" --arg p "$pid" --arg a "$aid" '.service_tokens[$n].policy_id = $p | .service_tokens[$n].access_id = $a')
    _zt_state_write "$st"
}

_zt_service_token_create() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local n t dur
    n=$(_zt_first_arg "$@")
    t="${ARG_for:-}"
    dur="${ARG_duration:-8760h}"
    [[ -z "$n" || -z "$t" ]] && { error "Usage: cipi zt service-token create <name> --for=<app>|gui|api [--duration=8760h]"; exit 1; }
    [[ "$n" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { error "Name: lowercase letters, digits and dashes, up to 40 (e.g. panel, github-actions)"; exit 1; }
    [[ "$dur" =~ ^([0-9]+h|forever)$ ]] || { error "--duration: hours (8760h is a year) or forever"; exit 1; }
    _zt_state | jq -e --arg n "$n" '.service_tokens[$n] != null' >/dev/null 2>&1 && { error "A service token '${n}' exists. Revoke it first: cipi zt service-token revoke ${n}"; exit 1; }
    local aid; aid=$(_zt_target_get "$t" access_id)
    if [[ -z "$aid" ]]; then
        local flag="$t"
        [[ "$t" == gui || "$t" == api ]] && flag="--${t}"
        error "No Access application in front of $(_zt_target_label "$t"). Run first: cipi zt access enable ${flag}"
        echo "  For a target only machines reach: cipi zt access enable ${flag} --allow=none"
        exit 1
    fi
    local account body resp tid cid secret
    account=$(_zt_account)
    body=$(jq -n --arg n "cipi-${n}" --arg d "$dur" '{name:$n, duration:$d}')
    [[ "${ARG_json:-}" == "true" ]] || step "Creating service token ${n}..."
    resp=$(_zt_api POST "/accounts/${account}/access/service_tokens" "$body") || resp=""
    if ! _zt_api_ok "$resp"; then
        error "Could not create the service token: $(_zt_api_err "$resp")"
        echo "  Token needs Account.Access: Service Tokens: Edit"
        exit 1
    fi
    tid=$(echo "$resp" | jq -r '.result.id // empty')
    cid=$(echo "$resp" | jq -r '.result.client_id // empty')
    secret=$(echo "$resp" | jq -r '.result.client_secret // empty')
    local st
    st=$(_zt_state | jq --arg n "$n" --arg i "$tid" --arg c "$cid" --arg t "$t" --arg d "$dur" \
        --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.service_tokens[$n] = {id:$i, client_id:$c, for:$t, duration:$d, created_at:$at}')
    _zt_state_write "$st"
    if ! _zt_service_token_attach "$n" "$aid"; then
        warn "The Service Auth policy was not created: add one for cipi-${n} on the Access application in the dashboard"
    fi
    log_action "ZT SERVICE TOKEN CREATE ${n} for=${t}"
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg n "$n" --arg c "$cid" --arg s "$secret" --arg t "$t" --arg h "$(_zt_target_domain "$t")" \
            '{name:$n, for:$t, hostname:$h, client_id:$c, client_secret:$s}'
        return 0
    fi
    success "Service token ${n} opens $(_zt_target_label "$t") ($(_zt_target_domain "$t"))"
    echo ""
    echo -e "  ${BOLD}CF-Access-Client-Id${NC}:     ${cid}"
    echo -e "  ${BOLD}CF-Access-Client-Secret${NC}: ${secret}"
    echo ""
    echo -e "  ${YELLOW}The secret is shown only now.${NC} Send both as headers with every request."
    [[ "$t" == api ]] && echo -e "  ${DIM}In the panel: Connections → edit the server → Cloudflare Access.${NC}"
    echo ""
}

_zt_service_token_list() {
    parse_args "$@"
    local st; st=$(_zt_state)
    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$st" | jq '[(.service_tokens // {}) | to_entries[] | {name:.key, for:.value.for, client_id:.value.client_id, duration:.value.duration, created_at:.value.created_at}]'
        return 0
    fi
    local rows
    rows=$(echo "$st" | jq -r '(.service_tokens // {}) | to_entries[] | "\(.key)\t\(.value.for)\t\(.value.client_id)\t\(.value.created_at)"')
    if [[ -z "$rows" ]]; then
        info "No service tokens. Create one: cipi zt service-token create <name> --for=<app>|gui|api"
        return 0
    fi
    printf "  %-20s %-16s %-40s %s\n" "NAME" "FOR" "CLIENT ID" "CREATED"
    while IFS=$'\t' read -r n f c a; do
        printf "  %-20s %-16s %-40s %s\n" "$n" "$f" "$c" "$a"
    done <<< "$rows"
}

_zt_service_token_revoke() {
    parse_args "$@"
    _zt_require_token || exit 1
    local n; n=$(_zt_first_arg "$@")
    [[ -z "$n" ]] && { error "Usage: cipi zt service-token revoke <name>"; exit 1; }
    local st tid aid pid account
    st=$(_zt_state)
    tid=$(echo "$st" | jq -r --arg n "$n" '.service_tokens[$n].id // empty')
    [[ -n "$tid" ]] || { error "No service token '${n}' (cipi zt service-token list)"; exit 1; }
    aid=$(echo "$st" | jq -r --arg n "$n" '.service_tokens[$n].access_id // empty')
    pid=$(echo "$st" | jq -r --arg n "$n" '.service_tokens[$n].policy_id // empty')
    _zt_access_policy_delete "$aid" "$pid"
    account=$(_zt_account)
    _zt_api DELETE "/accounts/${account}/access/service_tokens/${tid}" >/dev/null 2>&1 || true
    st=$(_zt_state | jq --arg n "$n" 'del(.service_tokens[$n])')
    _zt_state_write "$st"
    log_action "ZT SERVICE TOKEN REVOKE ${n}"
    success "Service token ${n} revoked"
}

# ── TCP services ─────────────────────────────────────────────
#
# A database or Valkey from a laptop without opening its port or an SSH
# tunnel: a hostname on the tunnel that reaches 127.0.0.1:<port>, always
# behind Access, and `cloudflared access tcp` on the client.

_zt_tcp() {
    local action="${1:-}"; shift || true
    case "$action" in
        add|enable)            _zt_tcp_add "$@" ;;
        remove|disable|delete) _zt_tcp_remove "$@" ;;
        list|ls|status)        _zt_tcp_list "$@" ;;
        *) error "Usage: cipi zt tcp add <mysql|mariadb|pgsql|redis|valkey|PORT> --hostname=db.example.com [--allow=…] | remove <hostname> | list"; exit 1 ;;
    esac
}

_zt_tcp_port_of() {
    case "$1" in
        mysql|mariadb|db)        echo 3306 ;;
        pgsql|postgres|postgresql) echo 5432 ;;
        redis|valkey)            echo 6379 ;;
        *) [[ "$1" =~ ^[0-9]{1,5}$ && "$1" -ge 1 && "$1" -le 65535 ]] && echo "$1" ;;
    esac
}

_zt_tcp_add() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local svc host port
    svc=$(_zt_first_arg "$@")
    host="${ARG_hostname:-}"
    [[ -z "$svc" || -z "$host" ]] && { error "Usage: cipi zt tcp add <mysql|pgsql|redis|PORT> --hostname=db.example.com [--allow=me@example.com]"; exit 1; }
    port=$(_zt_tcp_port_of "$svc")
    [[ -n "$port" ]] || { error "Unknown service '${svc}': mysql, mariadb, pgsql, redis, valkey or a port number"; exit 1; }
    case "$port" in
        22)     error "SSH has its own: cipi zt ssh enable --hostname=${host}"; exit 1 ;;
        80|443) error "Websites go through cipi zt hostname add <app>"; exit 1 ;;
    esac
    validate_domain "$host" || { error "Invalid hostname '${host}'"; exit 1; }
    _zt_state | jq -e --arg h "$host" '.tcp[$h] != null' >/dev/null 2>&1 && { error "${host} is already on the tunnel (cipi zt tcp list)"; exit 1; }
    local allow include
    allow=$(_zt_access_allow_norm "${ARG_allow:-}")
    [[ "$allow" == "none" ]] && { error "A TCP service is for people: --allow=none would open it to service tokens alone"; exit 1; }
    include=$(_zt_access_include "$allow") || exit 1

    step "Publishing 127.0.0.1:${port} on ${host} through the tunnel..."
    local pair zone rec
    pair=$(_zt_dns_upsert "$host") || exit 1
    zone="${pair%% *}"
    rec="${pair#* }"
    step "Creating Access application for ${host}..."
    local aid pid
    aid=$(_zt_access_create "cipi:tcp:${host}" "$host" "self_hosted") || aid=""
    if [[ -z "$aid" ]]; then
        # Never a database on the tunnel without Access in front.
        _zt_dns_delete "$zone" "$rec"
        error "Access API failed — nothing was published. Token needs Account.Access: Apps and Policies: Edit"
        exit 1
    fi
    pid=$(_zt_access_policy "$aid" "allow" "$include") || pid=""
    [[ -z "$pid" ]] && warn "Allow policy was not created — until you add one in the dashboard, nobody gets through"
    local st
    st=$(_zt_state | jq --arg h "$host" --arg s "$svc" --argjson p "$port" --arg z "$zone" --arg r "$rec" \
        --arg a "$aid" --arg pid "$pid" --arg al "$allow" \
        '.tcp[$h] = {service:$s, port:$p, zone_id:$z, dns_id:$r, access_id:$a, access_policy_id:$pid, access_allow:$al}')
    _zt_state_write "$st"
    _zt_reload_tunnel || exit 1
    log_action "ZT TCP ADD ${host} port=${port}"
    success "${svc} (127.0.0.1:${port}) on ${host}, behind Access${allow:+: ${allow//,/, }}"
    local local_port=$(( port + 10000 ))
    (( local_port > 65535 )) && local_port=$port
    echo ""
    echo -e "  ${BOLD}On your laptop${NC}:"
    echo -e "    ${CYAN}cloudflared access tcp --hostname ${host} --url 127.0.0.1:${local_port}${NC}"
    echo -e "  then connect TablePlus, DBeaver or the client to ${BOLD}127.0.0.1:${local_port}${NC}."
    echo -e "  ${DIM}The port stays closed on the server; the user and password are the database's own.${NC}"
    echo ""
}

_zt_tcp_remove() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local host st
    host=$(_zt_first_arg "$@")
    [[ -z "$host" ]] && host="${ARG_hostname:-}"
    [[ -z "$host" ]] && { error "Usage: cipi zt tcp remove <hostname>"; exit 1; }
    st=$(_zt_state)
    echo "$st" | jq -e --arg h "$host" '.tcp[$h] != null' >/dev/null 2>&1 || { error "${host} is not a TCP service on the tunnel (cipi zt tcp list)"; exit 1; }
    _zt_access_delete "$(echo "$st" | jq -r --arg h "$host" '.tcp[$h].access_id // empty')"
    _zt_dns_delete "$(echo "$st" | jq -r --arg h "$host" '.tcp[$h].zone_id // empty')" "$(echo "$st" | jq -r --arg h "$host" '.tcp[$h].dns_id // empty')"
    st=$(echo "$st" | jq --arg h "$host" 'del(.tcp[$h])')
    _zt_state_write "$st"
    _zt_reload_tunnel || true
    log_action "ZT TCP REMOVE ${host}"
    success "${host} removed from the tunnel"
}

_zt_tcp_list() {
    parse_args "$@"
    local st; st=$(_zt_state)
    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$st" | jq '[(.tcp // {}) | to_entries[] | {hostname:.key, service:.value.service, port:.value.port, allow:(.value.access_allow // "")}]'
        return 0
    fi
    local rows
    rows=$(echo "$st" | jq -r '(.tcp // {}) | to_entries[] | "\(.key)\t\(.value.service)\t\(.value.port)\t\(.value.access_allow // "")"')
    if [[ -z "$rows" ]]; then
        info "No TCP services. Add one: cipi zt tcp add mysql --hostname=db.example.com"
        return 0
    fi
    printf "  %-32s %-10s %-6s %s\n" "HOSTNAME" "SERVICE" "PORT" "ALLOW"
    while IFS=$'\t' read -r h s p a; do
        printf "  %-32s %-10s %-6s %s\n" "$h" "$s" "$p" "${a:-anyone signed in}"
    done <<< "$rows"
}

# ── SSH ──────────────────────────────────────────────────────

_zt_ssh() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable)  _zt_ssh_enable "$@" ;;
        disable) _zt_ssh_disable "$@" ;;
        unlock)  _zt_unlock ssh "$@" ;;
        cert|certs|certificate|certificates) _zt_ssh_cert "$@" ;;
        *) error "Usage: cipi zt ssh enable --hostname=HOST [--allow=…] | cert enable --principals=… | cert disable | disable | unlock"; exit 1 ;;
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

    local allow include
    allow=$(_zt_access_allow_norm "${ARG_allow:-}")
    [[ "$allow" == "none" ]] && allow=""
    include=$(_zt_access_include "$allow") || exit 1
    step "Creating Access SSH application..."
    local aid pid
    aid=$(_zt_access_create "cipi:ssh" "$host" "ssh") || aid=""
    if [[ -n "$aid" ]]; then
        pid=$(_zt_access_policy "$aid" "allow" "$include") || { pid=""; warn "SSH Access allow policy failed — add it in the dashboard"; }
        st=$(_zt_state)
        st=$(echo "$st" | jq --arg id "$aid" --arg p "$pid" --arg al "$allow" '.ssh.access_id = $id | .ssh.access_policy_id = $p | .ssh.access_allow = $al')
        _zt_state_write "$st"
        success "Access SSH on ${host}${allow:+ (${allow//,/, })}"
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
    echo -e "  ${DIM}No keys to hand out: cipi zt ssh cert enable --principals=<your email before the @>${NC}"
    echo -e "  ${DIM}Deployer uses localhost SSH and is not affected.${NC}"
    echo ""
}

# ── SSH with short-lived certificates ────────────────────────
#
# Cloudflare Access signs a certificate at every sign-in, valid for minutes
# and for the principal of the user's email (andrea@example.com → andrea).
# sshd trusts the CA of the SSH Access application and, per Unix user, the
# principals listed in ${ZT_SSH_PRINCIPALS}/<user>. Keys in authorized_keys
# keep working; nobody needs one any more.

_zt_ssh_cert() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable|update) _zt_ssh_cert_enable "$@" ;;
        disable)       _zt_ssh_cert_disable "$@" ;;
        status)        _zt_ssh_cert_status "$@" ;;
        *) error "Usage: cipi zt ssh cert enable --principals=andrea,mario [--user=cipi] | disable | status"; exit 1 ;;
    esac
}

# Principals: email prefixes (a full email is cut at the @), comma-separated.
_zt_principals_norm() {
    local raw="${1:-}" p out=""
    local -a list
    IFS=',' read -ra list <<< "$raw"
    for p in "${list[@]}"; do
        p=$(printf '%s' "$p" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        p="${p%%@*}"
        [[ -z "$p" ]] && continue
        [[ "$p" =~ ^[a-z0-9._+-]{1,64}$ ]] || { error "Not a principal (the part of an email before the @): ${p}"; return 1; }
        [[ ",${out}," == *",${p},"* ]] || out+="${out:+,}${p}"
    done
    [[ -n "$out" ]] || { error "--principals needs at least one name: the part of an email before the @"; return 1; }
    printf '%s' "$out"
}

_zt_sshd_reload() {
    local bin
    bin=$(command -v sshd 2>/dev/null || true)
    [[ -z "$bin" && -x /usr/sbin/sshd ]] && bin=/usr/sbin/sshd
    [[ -n "$bin" ]] || return 0
    "$bin" -t >/dev/null 2>&1 || return 1
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
}

_zt_ssh_cert_remove_files() {
    local had=false
    [[ -f "$ZT_SSHD_DROPIN" ]] && had=true
    rm -f "$ZT_SSHD_DROPIN" "$ZT_SSH_CA"
    rm -rf "$ZT_SSH_PRINCIPALS"
    if [[ "$had" == true ]]; then
        _zt_sshd_reload || true
    fi
    return 0
}

_zt_ssh_cert_enable() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local st aid host user principals
    st=$(_zt_state)
    aid=$(echo "$st" | jq -r '.ssh.access_id // empty')
    host=$(echo "$st" | jq -r '.ssh.hostname // empty')
    [[ -n "$host" && -n "$aid" ]] || { error "SSH is not on the tunnel behind Access. Run: cipi zt ssh enable --hostname=ssh.example.com"; exit 1; }
    user="${ARG_user:-cipi}"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { error "Invalid --user '${user}'"; exit 1; }
    id "$user" >/dev/null 2>&1 || { error "No Unix user '${user}' on this server"; exit 1; }
    if [[ -z "${ARG_principals:-}" || "${ARG_principals}" == "true" ]]; then
        principals=$(echo "$st" | jq -r --arg u "$user" '.ssh.cert.users[$u] // empty')
        [[ -n "$principals" ]] || { error "Usage: cipi zt ssh cert enable --principals=andrea,mario [--user=cipi] — the part of each email before the @"; exit 1; }
    else
        principals=$(_zt_principals_norm "${ARG_principals}") || exit 1
    fi

    step "Fetching the short-lived certificate CA of the SSH application..."
    local account resp pub
    account=$(_zt_account)
    resp=$(_zt_api GET "/accounts/${account}/access/apps/${aid}/ca") || resp=""
    pub=$(echo "$resp" | jq -r '.result.public_key // empty' 2>/dev/null)
    if [[ -z "$pub" ]]; then
        resp=$(_zt_api POST "/accounts/${account}/access/apps/${aid}/ca" "{}") || resp=""
        pub=$(echo "$resp" | jq -r '.result.public_key // empty' 2>/dev/null)
    fi
    if [[ -z "$pub" ]]; then
        error "Could not get the CA: $(_zt_api_err "$resp")"
        echo "  Token needs Account.Access: SSH Auditing: Edit (short-lived certificates)"
        exit 1
    fi
    [[ "$pub" =~ ^(ecdsa-sha2-nistp256|ssh-ed25519|ssh-rsa)\ [A-Za-z0-9+/=]+ ]] || { error "The CA Cloudflare returned is not an SSH public key"; exit 1; }

    mkdir -p "$(dirname "$ZT_SSH_CA")" "$ZT_SSH_PRINCIPALS" "$(dirname "$ZT_SSHD_DROPIN")"
    printf '%s\n' "$pub" > "$ZT_SSH_CA"
    chmod 644 "$ZT_SSH_CA"
    chmod 755 "$ZT_SSH_PRINCIPALS"
    tr ',' '\n' <<< "$principals" > "${ZT_SSH_PRINCIPALS}/${user}"
    chmod 644 "${ZT_SSH_PRINCIPALS}/${user}"
    local had_dropin=false
    [[ -f "$ZT_SSHD_DROPIN" ]] && had_dropin=true
    {
        echo "# Written by Cipi (cipi zt ssh cert). Short-lived certificates from Cloudflare"
        echo "# Access for ${host}: the principals each user accepts are in ${ZT_SSH_PRINCIPALS}/<user>."
        echo "# Keys in authorized_keys keep working."
        echo "PubkeyAuthentication yes"
        echo "TrustedUserCAKeys ${ZT_SSH_CA}"
        echo "AuthorizedPrincipalsFile ${ZT_SSH_PRINCIPALS}/%u"
    } > "$ZT_SSHD_DROPIN"
    chmod 644 "$ZT_SSHD_DROPIN"
    if ! _zt_sshd_reload; then
        [[ "$had_dropin" == true ]] || rm -f "$ZT_SSHD_DROPIN"
        error "sshd refused the configuration (sshd -t): nothing changed for SSH"
        exit 1
    fi
    st=$(_zt_state | jq --arg u "$user" --arg p "$principals" '.ssh.cert = ((.ssh.cert // {}) + {enabled:true}) | .ssh.cert.users[$u] = $p')
    _zt_state_write "$st"
    log_action "ZT SSH CERT ENABLE user=${user} principals=${principals}"
    success "Short-lived certificates for ${user}@${host}: ${principals//,/, }"
    echo ""
    echo -e "  ${BOLD}On your laptop${NC}, once:"
    echo -e "    ${CYAN}cloudflared access ssh-config --hostname ${host} --short-lived-cert >> ~/.ssh/config${NC}"
    echo -e "  then ${CYAN}ssh ${user}@${host}${NC}: the browser asks you to sign in, no key needed."
    echo -e "  ${DIM}Another user: cipi zt ssh cert enable --user=<name> --principals=…${NC}"
    echo ""
}

_zt_ssh_cert_disable() {
    parse_args "$@"
    _zt_ssh_cert_remove_files
    local st; st=$(_zt_state | jq '.ssh.cert = {enabled:false}')
    _zt_state_write "$st"
    log_action "ZT SSH CERT DISABLE"
    success "Short-lived certificates off: SSH takes keys only"
}

_zt_ssh_cert_status() {
    parse_args "$@"
    local st; st=$(_zt_state)
    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$st" | jq '{enabled:(.ssh.cert.enabled // false), users:(.ssh.cert.users // {} | map_values(split(",")))}'
        return 0
    fi
    if [[ "$(echo "$st" | jq -r '.ssh.cert.enabled // false')" != "true" ]]; then
        info "Short-lived certificates are off. cipi zt ssh cert enable --principals=…"
        return 0
    fi
    echo "$st" | jq -r '.ssh.cert.users // {} | to_entries[] | "  \(.key): \(.value | split(",") | join(", "))"'
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
    _zt_ssh_cert_remove_files
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

# ── tunnel health (status, monitor) ──────────────────────────

# What Cloudflare says of the tunnel: {"status":"healthy|degraded|down|inactive",
# "connectors":[{"id","origin_ips":[...],"version","conns"}]} — empty output
# when the API cannot be asked (no token, no answer).
_zt_tunnel_remote() {
    local account id resp
    account=$(_zt_account)
    id=$(_zt_tunnel_id)
    [[ -n "$account" && -n "$id" ]] || return 1
    _zt_read_token >/dev/null 2>&1 || return 1
    resp=$(ZT_API_TIMEOUT="${ZT_STATUS_TIMEOUT:-10}" _zt_api GET "/accounts/${account}/cfd_tunnel/${id}") || return 1
    _zt_api_ok "$resp" || return 1
    echo "$resp" | jq -c '.result | {
        status: (.status // "unknown"),
        connectors: ([.connections[]? | {id: (.client_id // .id), origin_ip: (.origin_ip // ""), version: (.client_version // ""), colo: (.colo_name // "")}]
            | group_by(.id) | map({id: .[0].id, origin_ips: (map(.origin_ip) | unique), version: .[0].version, colos: (map(.colo) | unique), conns: length}))
    }' 2>/dev/null
}

# This server's addresses, one per line: what a connector's origin_ip is
# compared with to tell this replica from the others.
_zt_self_ips() {
    server_public_ip 2>/dev/null; echo
    server_local_ips 2>/dev/null
}

# How many connectors of the tunnel run on other servers (0 when unknown).
_zt_replica_connectors_elsewhere() {
    local remote mine
    remote=$(_zt_tunnel_remote) || { echo 0; return 0; }
    mine=$(_zt_self_ips | grep . | jq -R . | jq -sc .)
    echo "$remote" | jq -r --argjson mine "$mine" '[.connectors[] | select((.origin_ips - $mine) == .origin_ips and (.origin_ips | length) > 0)] | length' 2>/dev/null || echo 0
}

# ── replicas ─────────────────────────────────────────────────
#
# The same tunnel on more servers: each runs a connector, Cloudflare sends a
# request to any of them (no steering). Good for moving a server without
# touching DNS (the records point at the tunnel, not at an address) and for
# keeping stateless apps up while one server is down.

_zt_replica() {
    local action="${1:-}"; shift || true
    case "$action" in
        export)        _zt_replica_export "$@" ;;
        join)          _zt_replica_join "$@" ;;
        leave)         _zt_replica_leave "$@" ;;
        list|ls|status) _zt_replica_list "$@" ;;
        *) error "Usage: cipi zt replica export | join <bundle> | leave [--yes] | list [--json]"; exit 1 ;;
    esac
}

_zt_replica_export() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local id cred st
    id=$(_zt_tunnel_id)
    cred="${ZT_CF_DIR}/${id}.json"
    [[ -f "$cred" ]] || { error "Missing tunnel credentials ${cred}"; exit 1; }
    st=$(_zt_state)
    local bundle
    bundle=$(jq -cn --argjson c "$(cat "$cred")" --argjson st "$st" --arg from "$(hostname)" '{
        v: 1, from: $from,
        account_id: $st.account_id, tunnel_id: $st.tunnel_id, tunnel_name: ($st.tunnel_name // ""),
        credentials: $c,
        hostnames: ($st.hostnames // {} | map_values({domains: [.domains[]? | {name}]})),
        gui: ($st.gui // {} | {domain}), api: ($st.api // {} | {domain}),
        ssh: ($st.ssh // {} | {hostname}),
        tcp: ($st.tcp // {} | map_values({service, port}))
    }' | gzip -9c | base64 -w0)
    log_action "ZT REPLICA EXPORT"
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg b "cipi-zt1:${bundle}" '{bundle:$b}'
        return 0
    fi
    echo ""
    echo -e "  ${YELLOW}This bundle runs the tunnel: treat it as a password.${NC}"
    echo -e "  On the other server (Cipi installed, the same apps on it):"
    echo ""
    echo "    cipi zt replica join cipi-zt1:${bundle}"
    echo ""
    echo -e "  ${DIM}Cloudflare then sends each request to either server. Moving a server: join the new one,${NC}"
    echo -e "  ${DIM}check it, then on this one: cipi zt replica leave (the tunnel, DNS and Access stay).${NC}"
    echo ""
}

_zt_replica_join() {
    parse_args "$@"
    local raw; raw=$(_zt_first_arg "$@")
    [[ -z "$raw" ]] && raw="${ARG_bundle:-}"
    [[ "$raw" == cipi-zt1:* ]] || { error "Usage: cipi zt replica join cipi-zt1:… (from: cipi zt replica export)"; exit 1; }
    local b
    b=$(printf '%s' "${raw#cipi-zt1:}" | base64 -d 2>/dev/null | gunzip -c 2>/dev/null) || b=""
    echo "$b" | jq -e '.v == 1 and (.tunnel_id | type == "string" and length > 0) and (.credentials.TunnelSecret | type == "string")' >/dev/null 2>&1 \
        || { error "Not a bundle of cipi zt replica export (damaged, or from another version)"; exit 1; }
    local id; id=$(echo "$b" | jq -r '.tunnel_id')
    [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]] || { error "The bundle names no valid tunnel"; exit 1; }
    if _zt_enabled && [[ "$(_zt_tunnel_id)" != "$id" ]]; then
        error "Zero Trust already runs another tunnel here ($(_zt_tunnel_id)). Disable it first: cipi zt disable"
        exit 1
    fi

    # Hostnames whose app this server does not have: Nginx answers them with
    # its default site, so say which before the first request lands here.
    local missing="" a
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        app_exists "$a" 2>/dev/null || missing+=" ${a}"
    done < <(echo "$b" | jq -r '.hostnames | keys[]?')
    if [[ -n "$missing" && "${ARG_force:-}" != "true" ]]; then
        error "These apps of the tunnel are not on this server:${missing}"
        echo "  Cloudflare would send some of their visitors here. Create or import them first (cipi sync import),"
        echo "  or pass --force to join anyway."
        exit 1
    fi

    _zt_install_cloudflared || exit 1
    step "Writing nginx real_ip from Cloudflare IP ranges..."
    _zt_apply_realip || exit 1
    _zt_write_cron
    mkdir -p "$ZT_CF_DIR"
    chmod 700 "$ZT_CF_DIR"
    echo "$b" | jq '.credentials' > "${ZT_CF_DIR}/${id}.json"
    chmod 600 "${ZT_CF_DIR}/${id}.json"
    local st
    st=$(_zt_state | jq --argjson b "$b" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .enabled = true | .replica = true | .replica_from = $b.from | .enabled_at = $t
        | .account_id = (.account_id // $b.account_id) | .tunnel_id = $b.tunnel_id | .tunnel_name = $b.tunnel_name
        | .hostnames = $b.hostnames | .gui = $b.gui | .api = $b.api | .ssh = $b.ssh | .tcp = $b.tcp
        | .lock_http = (.lock_http // false) | .lock_ssh = (.lock_ssh // false)')
    _zt_state_write "$st"
    _zt_write_unit
    _zt_reload_tunnel || exit 1
    log_action "ZT REPLICA JOIN tunnel=${id} from=$(echo "$b" | jq -r .from)"
    log_event "Joined Cloudflare Tunnel $(echo "$b" | jq -r '.tunnel_name // .tunnel_id') as a replica on $(hostname)"
    success "This server runs tunnel $(echo "$b" | jq -r '.tunnel_name // .tunnel_id') too (replica of $(echo "$b" | jq -r .from))"
    echo -e "  ${DIM}DNS, Access and service tokens stay with the server that created them.${NC}"
    echo -e "  ${DIM}For status and locks here: cipi zt token set --token=… (the same token works)${NC}"
    echo -e "  ${DIM}Stop it here only: cipi zt replica leave${NC}"
}

_zt_replica_leave() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    if [[ "$(_zt_state | jq -r '.replica // false')" != "true" ]]; then
        local others
        others=$(_zt_replica_connectors_elsewhere 2>/dev/null || echo 0)
        if [[ ! "${others:-0}" =~ ^[0-9]+$ || "${others:-0}" -eq 0 ]]; then
            error "No other server runs this tunnel: leaving would take every hostname offline."
            echo "  To remove Zero Trust from this server: cipi zt disable"
            exit 1
        fi
    fi
    if [[ "${ARG_yes:-}" != "true" ]]; then
        confirm "Stop the tunnel on this server? The other servers keep serving it." || { info "Aborted"; return 0; }
    fi
    if [[ "$(_zt_state | jq -r '.lock_http // false')" == "true" || "$(_zt_state | jq -r '.lock_ssh // false')" == "true" ]]; then
        step "Reopening this server's firewall ports..."
        _zt_unlock_http_apply
        _zt_unlock_ssh_apply
    fi
    systemctl disable --now "$ZT_UNIT" 2>/dev/null || true
    rm -f "/etc/systemd/system/${ZT_UNIT}.service"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$ZT_CF_DIR"
    local st
    st=$(_zt_state | jq '.enabled = false | .replica = false | .lock_http = false | .lock_ssh = false | .lock_http_mode = ""
        | .hostnames = {} | .gui = {} | .api = {} | .ssh = {} | .tcp = {} | .service_tokens = {} | .tunnel_id = "" | .tunnel_name = ""')
    _zt_state_write "$st"
    log_action "ZT REPLICA LEAVE"
    log_event "Left the Cloudflare Tunnel on $(hostname)"
    success "The tunnel no longer runs here; the other servers keep it. cloudflared stays installed."
}

_zt_replica_list() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local remote mine
    remote=$(_zt_tunnel_remote) || remote=""
    mine=$(_zt_self_ips | grep . | jq -R . | jq -sc .)
    if [[ "${ARG_json:-}" == "true" ]]; then
        if [[ -z "$remote" ]]; then
            jq -n '{status:null, connectors:[], error:"Cloudflare did not answer (token?)"}'
        else
            echo "$remote" | jq --argjson mine "$mine" '.connectors |= map(. + {this_server: ((.origin_ips - $mine) != .origin_ips)})'
        fi
        return 0
    fi
    [[ -n "$remote" ]] || { error "Cloudflare did not answer. Needs the token: cipi zt token set"; exit 1; }
    echo ""
    echo -e "  Tunnel ${BOLD}$(_zt_state | jq -r '.tunnel_name // .tunnel_id')${NC}: $(echo "$remote" | jq -r .status)"
    echo "$remote" | jq -r --argjson mine "$mine" '.connectors[] | "  \(if (.origin_ips - $mine) != .origin_ips then "▸ this server" else "  replica    " end)  \(.origin_ips | join(", "))  \(.conns) connections  \(.colos | join(" "))  \(.version)"'
    echo ""
}

# ── lockdown: no inbound ports ───────────────────────────────
#
# Every site, the panel and the API through the tunnel, then 80/443 closed
# and, when SSH runs through the tunnel too, port 22. A server behind NAT
# with no port forwarding ends up exactly like that from the start.

_zt_lockdown() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    if [[ "${ARG_yes:-}" != "true" ]]; then
        echo ""
        echo -e "  Lockdown puts every app, the panel and the API on the tunnel, then closes"
        echo -e "  ${BOLD}80/443${NC} to everyone and, if SSH runs through the tunnel, ${BOLD}port 22${NC}."
        echo ""
        confirm "Go ahead?" || { info "Aborted"; return 0; }
    fi
    local st a added=""
    st=$(_zt_state)
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        echo "$st" | jq -e --arg a "$a" '.hostnames[$a] != null' >/dev/null 2>&1 && continue
        ( _zt_hostname_add "$a" ) || { error "Could not put ${a} on the tunnel — nothing was locked"; exit 1; }
        added+=" ${a}"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]?' 2>/dev/null)
    if _zt_gui_domain >/dev/null 2>&1 && [[ -z "$(_zt_state | jq -r '.gui.domain // empty')" ]]; then
        ( _zt_hostname_add_special gui ) || { error "Could not put the panel on the tunnel — nothing was locked"; exit 1; }
        added+=" gui"
    fi
    if _zt_api_domain >/dev/null 2>&1 && [[ -z "$(_zt_state | jq -r '.api.domain // empty')" ]]; then
        ( _zt_hostname_add_special api ) || { error "Could not put the API on the tunnel — nothing was locked"; exit 1; }
        added+=" api"
    fi
    [[ -n "$added" ]] && success "On the tunnel now:${added}"

    local lockargs=(--yes)
    [[ "${ARG_force:-}" == "true" ]] && lockargs+=(--force)
    ( _zt_lock_http "${lockargs[@]}" ) || { error "80/443 were not closed (see above)"; exit 1; }

    if _zt_ssh_ingress_present && _zt_tunnel_healthy; then
        ( _zt_lock_ssh --yes ) || warn "Port 22 stays open (see above)"
    else
        warn "Port 22 stays open: SSH is not on the tunnel yet."
        echo "  cipi zt ssh enable --hostname=ssh.example.com   then, once ssh works through it:"
        echo "  cipi zt lock ssh --yes"
    fi
    log_action "ZT LOCKDOWN"
    echo ""
    echo -e "  ${BOLD}Inbound ports open now${NC}:"
    if command -v ufw >/dev/null 2>&1; then
        ufw status 2>/dev/null | awk 'NR>4 && $2 ~ /ALLOW/ {print "    " $0}' | sort -u
    fi
    echo -e "  ${DIM}The tunnel only goes out (port 7844). Undo: cipi zt unlock http, cipi zt ssh unlock${NC}"
    echo ""
}

# ── previews per branch ──────────────────────────────────────
#
# An app of its own for a branch: same repository and PHP as its parent, its
# own database and .env, on <branch>-<parent host>.<zone> — one level below
# the zone, so Cloudflare's Universal certificate covers it — through the
# tunnel and behind Access unless --public.

_zt_preview() {
    local action="${1:-}"; shift || true
    case "$action" in
        create|add|new)       _zt_preview_create "$@" ;;
        remove|delete|destroy) _zt_preview_remove "$@" ;;
        list|ls)              _zt_preview_list "$@" ;;
        *) error "Usage: cipi zt preview create <app> --branch=<branch> [--hostname=] [--allow=] [--public] [--no-deploy] | remove <preview> | list [<app>]"; exit 1 ;;
    esac
}

_zt_preview_slug() {   # <branch> → feature-login
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's#^refs/heads/##; s#[^a-z0-9]\+#-#g; s#^-*##; s#-*$##' | cut -c1-40 | sed 's#-*$##'
}

# <parent domain> <slug> → the preview's hostname, one level below the zone.
_zt_preview_host() {
    local d="$1" slug="$2" first rest
    d="${d#\*.}"
    first="${d%%.*}"
    rest="${d#*.}"
    if [[ "$rest" == *.* ]]; then
        printf '%s-%s.%s' "$slug" "$first" "$rest"
    else
        # An apex (example.com): feature-login.example.com
        printf '%s.%s' "$slug" "$d"
    fi
}

_zt_preview_user() {   # <parent> <slug> → a free app name (cipi app create's rule)
    local base cand n=2
    base=$(printf '%s%s' "$1" "${2//-/}" | tr -cd 'a-z0-9' | cut -c1-30)
    [[ "$base" =~ ^[a-z] ]] || base="p${base}"
    base="${base:0:30}"
    cand="$base"
    while app_exists "$cand" 2>/dev/null || id "$cand" >/dev/null 2>&1; do
        cand="${base:0:29}${n}"
        n=$((n + 1))
        (( n > 9 )) && return 1
    done
    printf '%s' "$cand"
}

_zt_preview_create() {
    parse_args "$@"
    _zt_require_enabled || exit 1
    local parent branch
    parent=$(_zt_first_arg "$@")
    branch="${ARG_branch:-}"
    [[ -z "$parent" || -z "$branch" || "$branch" == "true" ]] && { error "Usage: cipi zt preview create <app> --branch=<branch> [--hostname=] [--allow=] [--public]"; exit 1; }
    app_exists "$parent" || { error "App '$parent' not found"; exit 1; }
    validate_git_branch "$branch" 2>/dev/null || { error "Invalid branch name '${branch}'"; exit 1; }
    [[ -n "$(_zt_state | jq -r --arg a "$parent" '.previews[$a].parent // empty')" ]] && { error "${parent} is a preview itself: create it from $(_zt_state | jq -r --arg a "$parent" '.previews[$a].parent')"; exit 1; }
    local repo php runtime engine
    repo=$(app_get "$parent" repository)
    php=$(app_get "$parent" php)
    runtime=$(app_get "$parent" runtime)
    engine=$(app_get "$parent" db_engine)
    [[ -n "$repo" ]] || { error "${parent} has no repository: nothing to build a preview from"; exit 1; }
    [[ "$runtime" == "node" ]] && { error "Previews are for PHP apps for now (${parent} is a Node app)"; exit 1; }
    local existing
    existing=$(_zt_state | jq -r --arg p "$parent" --arg b "$branch" '(.previews // {}) | to_entries[] | select(.value.parent == $p and .value.branch == $b) | .key' | head -1)
    [[ -n "$existing" ]] && { error "${parent} already has a preview of ${branch}: ${existing} (cipi deploy ${existing} to update it)"; exit 1; }

    local slug host user allow
    slug=$(_zt_preview_slug "$branch")
    [[ -n "$slug" ]] || { error "Cannot make a hostname from branch '${branch}'"; exit 1; }
    host="${ARG_hostname:-}"
    [[ -z "$host" || "$host" == "true" ]] && host=$(_zt_preview_host "$(app_get "$parent" domain)" "$slug")
    validate_domain "$host" || { error "Invalid hostname '${host}'"; exit 1; }
    user=$(_zt_preview_user "$parent" "$slug") || { error "No free app name for this preview"; exit 1; }
    allow=$(_zt_access_allow_norm "${ARG_allow:-}")

    step "Creating ${user} for ${parent}@${branch} on ${host}..."
    local -a create=(app create "--user=${user}" "--domain=${host}" "--repository=${repo}" "--branch=${branch}" "--env=preview")
    [[ -n "$php" ]] && create+=("--php=${php}")
    [[ -n "$engine" ]] && create+=("--engine=${engine}")
    "$CIPI_BIN" "${create[@]}" </dev/null || { error "cipi app create failed — no preview was made"; exit 1; }

    local st
    st=$(_zt_state | jq --arg u "$user" --arg p "$parent" --arg b "$branch" --arg h "$host" \
        --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg pub "$([[ "${ARG_public:-}" == "true" ]] && echo true || echo false)" \
        '.previews[$u] = {parent:$p, branch:$b, hostname:$h, created_at:$t, public:($pub == "true")}')
    _zt_state_write "$st"

    "$CIPI_BIN" zt hostname add "$user" </dev/null || { error "The app ${user} exists but is not on the tunnel: cipi zt hostname add ${user}"; exit 1; }
    if [[ "${ARG_public:-}" != "true" ]]; then
        "$CIPI_BIN" zt access enable "$user" ${allow:+"--allow=${allow}"} </dev/null \
            || warn "No Access in front of the preview yet: cipi zt access enable ${user}"
    fi
    if [[ "${ARG_no_deploy:-}" != "true" ]]; then
        step "First deploy of ${branch}..."
        "$CIPI_BIN" deploy "$user" </dev/null \
            || warn "The first deploy failed: if the repository is private, add the deploy key of ${user} (cipi app show ${user}), then cipi deploy ${user}"
    fi
    log_action "ZT PREVIEW CREATE ${user} parent=${parent} branch=${branch}"
    success "Preview of ${parent}@${branch}: https://${host} (app ${user})"
    echo -e "  ${DIM}Update it: cipi deploy ${user}   Remove it: cipi zt preview remove ${user}${NC}"
}

_zt_preview_remove() {
    parse_args "$@"
    local user st
    user=$(_zt_first_arg "$@")
    st=$(_zt_state)
    if [[ -n "$user" && -n "${ARG_branch:-}" ]]; then
        # cipi zt preview remove <parent> --branch=<branch>
        user=$(echo "$st" | jq -r --arg p "$user" --arg b "${ARG_branch}" '(.previews // {}) | to_entries[] | select(.value.parent == $p and .value.branch == $b) | .key' | head -1)
    fi
    [[ -z "$user" ]] && { error "Usage: cipi zt preview remove <preview app>  or  <app> --branch=<branch>"; exit 1; }
    echo "$st" | jq -e --arg u "$user" '.previews[$u] != null' >/dev/null 2>&1 || { error "${user} is not a preview (cipi zt preview list)"; exit 1; }
    if [[ "${ARG_yes:-}" != "true" && "${ARG_force:-}" != "true" ]]; then
        confirm "Delete preview ${user} — app, database and hostname?" || { info "Aborted"; return 0; }
    fi
    if echo "$st" | jq -e --arg u "$user" '.hostnames[$u] != null' >/dev/null 2>&1; then
        "$CIPI_BIN" zt hostname remove "$user" </dev/null || warn "Could not remove ${user} from the tunnel"
    fi
    if app_exists "$user" 2>/dev/null; then
        "$CIPI_BIN" app delete "$user" --force </dev/null || { error "cipi app delete ${user} failed"; exit 1; }
    fi
    st=$(_zt_state | jq --arg u "$user" 'del(.previews[$u])')
    _zt_state_write "$st"
    log_action "ZT PREVIEW REMOVE ${user}"
    success "Preview ${user} removed"
}

_zt_preview_list() {
    parse_args "$@"
    local parent st
    parent=$(_zt_first_arg "$@")
    st=$(_zt_state)
    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$st" | jq --arg p "$parent" '[(.previews // {}) | to_entries[] | select($p == "" or .value.parent == $p) | {app:.key} + .value]'
        return 0
    fi
    local rows
    rows=$(echo "$st" | jq -r --arg p "$parent" '(.previews // {}) | to_entries[] | select($p == "" or .value.parent == $p) | "\(.key)\t\(.value.parent)\t\(.value.branch)\t\(.value.hostname)\t\(if .value.public then "public" else "Access" end)"')
    if [[ -z "$rows" ]]; then
        info "No previews. cipi zt preview create <app> --branch=<branch>"
        return 0
    fi
    printf "  %-24s %-16s %-24s %-40s %s\n" "PREVIEW" "APP" "BRANCH" "URL" ""
    while IFS=$'\t' read -r u p b h a; do
        printf "  %-24s %-16s %-24s %-40s %s\n" "$u" "$p" "$b" "https://${h}" "$a"
    done <<< "$rows"
}

# ── cache purge ──────────────────────────────────────────────
#
# Purge by hostname is on every Cloudflare plan: the app's domain and
# aliases, zone by zone. `--on-deploy=on` purges after every successful
# deploy (cipi deploy and the webhook alike). Needs the Zero Trust token
# (Zone.Cache Purge), not the tunnel: proxied records are enough.

_zt_purge() {
    parse_args "$@"
    local app; app=$(_zt_first_arg "$@")
    [[ -z "$app" ]] && { error "Usage: cipi zt purge <app> [--everything] | --on-deploy=on|off"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    if [[ -n "${ARG_on_deploy:-}" ]]; then
        case "${ARG_on_deploy}" in
            on|true|yes)  app_set "$app" cf_purge "true";  log_action "ZT PURGE ON-DEPLOY ${app} on"; success "${app}: Cloudflare's cache is purged after every successful deploy" ;;
            off|false|no) app_set "$app" cf_purge "false"; log_action "ZT PURGE ON-DEPLOY ${app} off"; success "${app}: no purge after deploys" ;;
            *) error "--on-deploy=on|off"; exit 1 ;;
        esac
        return 0
    fi
    _zt_require_token || exit 1
    _zt_purge_app "$app" "${ARG_everything:-false}" || exit 1
}

# _zt_purge_app <app> [everything] — prints one line per zone; 1 if any failed.
_zt_purge_app() {
    local app="$1" everything="${2:-false}" h zone zones="{}" rc=0
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        h="${h#\*.}"
        zone=$(_zt_zone_id "$h") || { warn "No Cloudflare zone for ${h}: skipped"; continue; }
        zones=$(jq -c --arg z "$zone" --arg h "$h" '.[$z] = ((.[$z] // []) + [$h] | unique)' <<< "$zones")
    done < <(_zt_app_domains "$app")
    [[ "$zones" == "{}" ]] && { error "No domain of ${app} is on a Cloudflare zone this token sees"; return 1; }
    local z hosts body resp
    while IFS=$'\t' read -r z hosts; do
        if [[ "$everything" == "true" ]]; then
            body='{"purge_everything":true}'
        else
            body=$(jq -cn --argjson h "$hosts" '{hosts:$h}')
        fi
        resp=$(_zt_api POST "/zones/${z}/purge_cache" "$body") || resp=""
        if _zt_api_ok "$resp"; then
            if [[ "$everything" == "true" ]]; then
                success "Cloudflare cache purged: the whole zone of $(jq -r '.[0]' <<< "$hosts")"
            else
                success "Cloudflare cache purged: $(jq -r 'join(", ")' <<< "$hosts")"
            fi
        else
            error "Purge failed for $(jq -r 'join(", ")' <<< "$hosts"): $(_zt_api_err "$resp")"
            echo "  Token needs Zone.Cache Purge: Purge"
            rc=1
        fi
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | tojson)"' <<< "$zones")
    log_action "ZT PURGE ${app}$([[ "$everything" == "true" ]] && echo " everything")"
    return $rc
}

# After a successful deploy (lib/deploy.sh, cipi-app-notify): purge when the
# app asked for it. Never fails the deploy; one line for its log.
zt_purge_after_deploy() {
    local app="$1"
    [[ "$(app_get "$app" cf_purge 2>/dev/null)" == "true" ]] || return 0
    _zt_read_token >/dev/null 2>&1 || { echo "Cloudflare purge: skipped (no token: cipi zt token set)"; return 0; }
    local out
    if out=$(ZT_API_TIMEOUT=20 _zt_purge_app "$app" false 2>&1); then
        echo "Cloudflare purge: done"
    else
        echo "Cloudflare purge: failed — $(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -m1 -i 'fail' || echo 'see cipi zt purge')"
    fi
    return 0
}

# ── status as JSON (panel, API) ──────────────────────────────

_zt_status_json() {
    local st running=false remote="" mine
    st=$(_zt_state)
    systemctl is-active --quiet "$ZT_UNIT" 2>/dev/null && running=true
    if _zt_enabled; then
        remote=$(_zt_tunnel_remote 2>/dev/null) || remote=""
    fi
    [[ -n "$remote" ]] || remote='null'
    mine=$(_zt_self_ips 2>/dev/null | grep . | jq -R . | jq -sc . 2>/dev/null) || mine='[]'
    local apps_json gui api
    apps_json=$(vault_read apps.json 2>/dev/null || echo '{}')
    gui=$(_zt_gui_domain 2>/dev/null || true)
    api=$(_zt_api_domain 2>/dev/null || true)
    jq -n --argjson st "$st" --argjson apps "$apps_json" --argjson remote "$remote" --argjson mine "$mine" \
        --arg running "$running" --arg realip "$([[ -f "$ZT_REALIP" ]] && echo true || echo false)" \
        --arg token "$([[ -s "$ZT_TOKEN_FILE" ]] && echo true || echo false)" --arg gui "$gui" --arg api "$api" '
        def access($x): {
            enabled: (($x.access_id // "") != ""),
            paths: (($x.access_paths // "") | if . == "" then [] else split(",") end),
            allow: (($x.access_allow // "") | if . == "" then [] elif . == "none" then ["none"] else split(",") end)
        };
        def tokens_for($t): [($st.service_tokens // {}) | to_entries[] | select(.value.for == $t) | .key];
        {
            enabled: ($st.enabled // false),
            token: ($token == "true"),
            account_id: ($st.account_id // null),
            tunnel: (if ($st.enabled // false) then {
                id: ($st.tunnel_id // null), name: ($st.tunnel_name // null),
                running: ($running == "true"),
                status: ($remote.status // null),
                replica: ($st.replica // false), replica_from: ($st.replica_from // null),
                connectors: (($remote.connectors // []) | map(. + {this_server: ((.origin_ips - $mine) != .origin_ips)}))
            } else null end),
            real_ip: ($realip == "true"),
            lock: {http: ($st.lock_http // false), http_mode: (($st.lock_http_mode // "") | if . == "" then null else . end), ssh: ($st.lock_ssh // false)},
            hostnames: [($st.hostnames // {}) | to_entries[] | {
                app: .key, domains: [.value.domains[]?.name],
                access: access(.value), service_tokens: tokens_for(.key),
                webhook_bypass: ((.value.webhook_access_id // "") != ""),
                origin_cert: (.value.origin_cert // false),
                purge_on_deploy: (($apps[.key].cf_purge // "") == "true"),
                preview: ($st.previews[.key] // null)
            }],
            gui: (if ($gui != "") then {domain: $gui, on_tunnel: (($st.gui.domain // "") != ""), access: access($st.gui // {}), service_tokens: tokens_for("gui")} else null end),
            api: (if ($api != "") then {domain: $api, on_tunnel: (($st.api.domain // "") != ""), access: access($st.api // {}), service_tokens: tokens_for("api")} else null end),
            ssh: (if (($st.ssh.hostname // "") != "") then {
                hostname: $st.ssh.hostname, access: access($st.ssh),
                certificates: {enabled: ($st.ssh.cert.enabled // false), users: (($st.ssh.cert.users // {}) | map_values(split(",")))}
            } else null end),
            tcp: [($st.tcp // {}) | to_entries[] | {hostname: .key, service: .value.service, port: .value.port, allow: ((.value.access_allow // "") | if . == "" then [] else split(",") end)}],
            service_tokens: [($st.service_tokens // {}) | to_entries[] | {name: .key, for: .value.for, client_id: .value.client_id, duration: .value.duration, created_at: .value.created_at}],
            previews: [($st.previews // {}) | to_entries[] | {app: .key} + .value],
            missing: ([$apps | keys[] | select(($st.hostnames // {})[.] == null)]
                + (if $gui != "" and (($st.gui.domain // "") == "") then ["gui"] else [] end)
                + (if $api != "" and (($st.api.domain // "") == "") then ["api"] else [] end))
        }'
}

# ── Origin CA ────────────────────────────────────────────────

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
    # The vhost is rewritten with it (_create_nginx_vhost → nginx_vhost_apply_tls),
    # :443 included, whether or not the app had HTTPS before.
    app_set "$app" ssl_origin_ca "true"
    app_set "$app" force_https "true"
    declare -f _create_nginx_vhost >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
    _create_nginx_vhost "$app" "$d" "$(app_get "$app" php)"
    reload_nginx || exit 1
    local st
    st=$(_zt_state)
    st=$(echo "$st" | jq --arg a "$app" '
        if .hostnames[$a] then .hostnames[$a].origin_cert = true else . end')
    _zt_state_write "$st"
    log_action "ZT ORIGIN CERT ${app}"
    success "Cloudflare Origin CA installed for ${d}"
    echo -e "  ${DIM}Names: $(echo "$hosts_json" | jq -r 'join(" ")')${NC}"
    echo -e "  ${DIM}Trusted by Cloudflare only: keep these records proxied (orange cloud), SSL/TLS mode Full (strict).${NC}"
    echo -e "  ${DIM}cipi ssl install HTTP-01 will refuse this app. Tunnel can keep talking HTTP to :80.${NC}"
}
