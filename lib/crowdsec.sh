#!/bin/bash
#############################################
# Cipi — CrowdSec (opt-in IP reputation)
#
# Off by default. enable installs the engine AND a firewall bouncer
# registered with `cscli bouncers add` — decisions without a bouncer
# ban nothing. disable flushes CrowdSec chains/tables, then purges.
# Never a WAF / AppSec / nginx module.
# Rescue: TLS listener, one-shot token, allowlists the TCP peer. Not a login.
#############################################

[[ -z "${CROWDSEC_ALLOW_FILE:-}" ]] && readonly CROWDSEC_ALLOW_FILE="${CIPI_CONFIG}/crowdsec-allow.list"
[[ -z "${CROWDSEC_CRON:-}" ]]       && readonly CROWDSEC_CRON="/etc/cron.d/cipi-crowdsec"
[[ -z "${CROWDSEC_PARSER_DIR:-}" ]] && readonly CROWDSEC_PARSER_DIR="/etc/crowdsec/parsers/s02-enrich"
[[ -z "${CROWDSEC_ACQUIS_DIR:-}" ]] && readonly CROWDSEC_ACQUIS_DIR="/etc/crowdsec/acquis.d"
[[ -z "${CROWDSEC_BOUNCER_NAME:-}" ]] && readonly CROWDSEC_BOUNCER_NAME="cipi-firewall"
[[ -z "${CROWDSEC_MIN_RAM_KB:-}" ]] && readonly CROWDSEC_MIN_RAM_KB=524288
[[ -z "${CROWDSEC_RESCUE_PORT:-}" ]] && readonly CROWDSEC_RESCUE_PORT="${CIPI_CONFIG}/crowdsec-rescue.port"
[[ -z "${CROWDSEC_RESCUE_TOKEN:-}" ]] && readonly CROWDSEC_RESCUE_TOKEN="${CIPI_CONFIG}/crowdsec-rescue.token"
[[ -z "${CROWDSEC_RESCUE_CERT:-}" ]] && readonly CROWDSEC_RESCUE_CERT="${CIPI_CONFIG}/crowdsec-rescue.crt"
[[ -z "${CROWDSEC_RESCUE_KEY:-}" ]] && readonly CROWDSEC_RESCUE_KEY="${CIPI_CONFIG}/crowdsec-rescue.key"
[[ -z "${CROWDSEC_RESCUE_BIN:-}" ]] && readonly CROWDSEC_RESCUE_BIN="/usr/local/bin/cipi-crowdsec-rescue"
[[ -z "${CROWDSEC_RESCUE_HOLE:-}" ]] && readonly CROWDSEC_RESCUE_HOLE="/usr/local/bin/cipi-crowdsec-rescue-hole"

crowdsec_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        enable)  _crowdsec_enable "$@" ;;
        disable) _crowdsec_disable "$@" ;;
        status)  _crowdsec_status "$@" ;;
        allow)   _crowdsec_allow "$@" ;;
        unallow) _crowdsec_unallow "$@" ;;
        refresh) _crowdsec_refresh_allowlists ;;
        rescue)  _crowdsec_rescue_cli "$@" ;;
        redeem)  _crowdsec_rescue_redeem "$@" ;;
        *) error "Usage: cipi crowdsec enable|disable|status|allow|unallow|refresh|rescue [args]"; exit 1 ;;
    esac
}

_crowdsec_installed() {
    command -v cscli >/dev/null 2>&1 && systemd_unit_exists crowdsec
}

_crowdsec_running() {
    command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec 2>/dev/null
}

_crowdsec_bouncer_unit() {
    if systemd_unit_exists crowdsec-firewall-bouncer; then
        echo crowdsec-firewall-bouncer
    fi
}

_crowdsec_valid_net() {
    local n="${1:-}"
    [[ -z "$n" ]] && return 1
    [[ "$n" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] && return 0
    [[ "$n" == *:* ]] && return 0
    return 1
}

_crowdsec_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

# Ubuntu 24.04+: iptables is the nft backend, fail2ban uses iptables-multiport
# (iptables-nft). The CrowdSec bouncer must use nftables too, or its DROP
# rules live in a different netfilter world than fail2ban.
_crowdsec_fw_mode() {
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        if iptables -V 2>&1 | grep -q nf_tables; then
            echo nftables
            return 0
        fi
    fi
    echo iptables
}

_crowdsec_bouncer_pkg() {
    if [[ "$(_crowdsec_fw_mode)" == "nftables" ]]; then
        echo crowdsec-firewall-bouncer-nftables
    else
        echo crowdsec-firewall-bouncer-iptables
    fi
}

_crowdsec_mem_available_kb() {
    awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0
}

_crowdsec_check_ram() {
    local avail force="${ARG_force:-}"
    avail=$(_crowdsec_mem_available_kb)
    if [[ "${avail:-0}" -lt "$CROWDSEC_MIN_RAM_KB" ]]; then
        local have_mb=$((avail / 1024)) need_mb=$((CROWDSEC_MIN_RAM_KB / 1024))
        if [[ "$force" == "true" ]]; then
            warn "Only ${have_mb}MB RAM free (CrowdSec wants ≥${need_mb}MB) — continuing because --force"
            return 0
        fi
        error "CrowdSec needs at least ${need_mb}MB free RAM (MemAvailable=${have_mb}MB)."
        echo "  Engine + firewall bouncer sit resident. Free memory, or pass --force."
        return 1
    fi
}

# Ban the reverse proxy, take the site down. Refuse unless real_ip is set
# or the operator passes --force.
# Cipi vhosts are /etc/nginx/sites-available/<app> with no extension, so an
# --include='*.conf' filter would only ever read nginx.conf — and real_ip is
# configured in the vhost. Enumerate the files nginx actually includes.
_crowdsec_nginx_files() {
    local f
    for f in /etc/nginx/nginx.conf \
             /etc/nginx/conf.d/*.conf \
             /etc/nginx/snippets/* \
             /etc/nginx/sites-enabled/* \
             /etc/nginx/sites-available/*; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

_crowdsec_nginx_grep() {
    local pattern="$1"
    _crowdsec_nginx_files | tr '\n' '\0' \
        | xargs -0 -r grep -slE "$pattern" 2>/dev/null | grep -q .
}

_crowdsec_nginx_has_real_ip() {
    _crowdsec_nginx_grep '^\s*set_real_ip_from\s' \
        && _crowdsec_nginx_grep '^\s*real_ip_header\s'
}

_crowdsec_looks_behind_proxy() {
    _crowdsec_nginx_grep 'CF-Connecting-IP|cf-connecting-ip|real_ip_header\s+X-Forwarded-For|include cloudflare|set_real_ip_from 173\.245\.|set_real_ip_from 103\.21\.'
}

_crowdsec_check_real_ip() {
    if _crowdsec_nginx_has_real_ip; then
        return 0
    fi
    if _crowdsec_looks_behind_proxy; then
        if [[ "${ARG_force:-}" == "true" ]]; then
            warn "Nginx looks like it sits behind a reverse proxy without set_real_ip_from."
            warn "CrowdSec will ban the proxy (Cloudflare edge), not the attacker. --force noted."
            return 0
        fi
        error "Nginx appears to be behind a reverse proxy without real_ip."
        echo "  Without set_real_ip_from + real_ip_header (e.g. CF-Connecting-IP),"
        echo "  CrowdSec sees only the proxy. One scanner → the proxy is banned → the site is dark."
        echo "  Fix nginx, or pass --force if you really mean it."
        return 1
    fi
    return 0
}

# CrowdSec's packagecloud repo (any/any). Falls back to Ubuntu universe.
_crowdsec_setup_apt_repo() {
    mkdir -p /etc/apt/keyrings
    local key="/etc/apt/keyrings/crowdsec.gpg"
    local list="/etc/apt/sources.list.d/crowdsec.list"
    if [[ ! -s "$key" ]]; then
        if ! _cipi_run_timed 30 curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
            | gpg --batch --yes --dearmor --output "$key" 2>/dev/null; then
            rm -f "$key"
            return 1
        fi
        chmod 644 "$key"
    fi
    echo "deb [signed-by=${key}] https://packagecloud.io/crowdsec/crowdsec/any/ any main" > "$list"
    # A source list left behind after a failed update makes every later
    # apt-get on the box noisy, forever, for a feature the operator did not get.
    if ! _crowdsec_apt update -qq; then
        rm -f "$list"
        _crowdsec_apt update -qq >/dev/null 2>&1 || true
        return 1
    fi
}

_crowdsec_install_packages() {
    local bpkg mode
    mode=$(_crowdsec_fw_mode)
    bpkg=$(_crowdsec_bouncer_pkg)
    step "Installing CrowdSec (engine + ${mode} firewall bouncer)..."
    if _crowdsec_setup_apt_repo; then
        _crowdsec_apt install -y -qq crowdsec "$bpkg" \
            || _crowdsec_apt install -y -qq crowdsec crowdsec-firewall-bouncer \
            || { error "CrowdSec install from the vendor repo failed"; return 1; }
    else
        warn "CrowdSec vendor repo unavailable — trying Ubuntu packages"
        _crowdsec_apt update -qq || true
        _crowdsec_apt install -y -qq crowdsec "$bpkg" \
            || _crowdsec_apt install -y -qq crowdsec crowdsec-firewall-bouncer \
            || { error "CrowdSec is not available from APT. Check outbound HTTPS."; return 1; }
    fi

    local f
    for f in "${CROWDSEC_ACQUIS_DIR}"/appsec.yaml /etc/crowdsec/acquis.yaml; do
        [[ -f "$f" ]] || continue
        grep -q 'appsec' "$f" 2>/dev/null || continue
        grep -q 'listen_addr' "$f" 2>/dev/null || continue
        mv "$f" "${f}.cipi-disabled" 2>/dev/null || true
    done
    return 0
}

_crowdsec_bouncer_yaml() {
    local y
    for y in /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml \
             /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-nftables.yaml \
             /etc/crowdsec/bouncers/crowdsec-firewall-bouncer-iptables.yaml; do
        [[ -f "$y" ]] && { echo "$y"; return 0; }
    done
    ls /etc/crowdsec/bouncers/*.yaml 2>/dev/null | head -1
}

_crowdsec_wait_lapi() {
    local i
    for i in $(seq 1 45); do
        systemctl is-active --quiet crowdsec 2>/dev/null || return 1
        cscli lapi status >/dev/null 2>&1 && return 0
        curl -fsS --max-time 2 http://127.0.0.1:8080/v1/heartbeat >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

_crowdsec_bouncer_diag() {
    local unit="${1:-crowdsec-firewall-bouncer}" log
    echo "  Check:  systemctl status ${unit}" >&2
    echo "  Start:   systemctl start ${unit}   (then re-run cipi crowdsec enable)" >&2
    echo "  Logs:    journalctl -u ${unit} -n 25 --no-pager" >&2
    # The bouncer defaults to log_mode: file — an empty journal usually means it
    # never started, not that nothing went wrong.
    for log in /var/log/crowdsec-firewall-bouncer.log \
               /var/log/crowdsec-firewall-bouncer*.log; do
        [[ -f "$log" ]] || continue
        echo "  File:    tail -30 ${log}" >&2
        break
    done
}

_crowdsec_bouncer_registered() {
    cscli bouncers list -o json 2>/dev/null \
        | jq -r --arg n "$CROWDSEC_BOUNCER_NAME" '[.[]? | select(.name==$n)] | length' 2>/dev/null \
        || echo 0
}

_crowdsec_read_bouncer_key() {
    local yaml="${1:-}" raw
    [[ -n "$yaml" && -f "$yaml" ]] || return 1
    raw=$(awk '/^api_key:/{sub(/^api_key:[[:space:]]*/,""); print; exit}' "$yaml")
    raw="${raw#\"}"; raw="${raw%\"}"
    raw="${raw#\'}"; raw="${raw%\'}"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

_crowdsec_write_bouncer_yaml() {
    local yaml="$1" key="$2" mode="$3"
    local tmp; tmp=$(mktemp)
    if [[ -f "$yaml" ]]; then
        grep -Ev '^(mode|api_key|api_url):' "$yaml" > "$tmp" || true
    fi
    {
        echo "mode: ${mode}"
        echo "api_url: http://127.0.0.1:8080/"
        echo "api_key: ${key}"
        cat "$tmp"
    } > "${yaml}.new"
    mv "${yaml}.new" "$yaml"
    rm -f "$tmp"
}

# Decisions without a registered bouncer never hit the firewall.
_crowdsec_register_bouncer() {
    command -v cscli >/dev/null 2>&1 || { error "cscli missing after install"; return 1; }
    systemctl enable --now crowdsec 2>/dev/null || true
    _crowdsec_wait_lapi || {
        error "CrowdSec LAPI did not become ready — cannot register the bouncer"
        echo "  Check:  systemctl status crowdsec" >&2
        echo "  Logs:    journalctl -u crowdsec -n 25 --no-pager" >&2
        return 1
    }

    local yaml key mode unit registered i ok=0
    yaml=$(_crowdsec_bouncer_yaml)
    [[ -n "$yaml" ]] || { error "Firewall bouncer config not found under /etc/crowdsec/bouncers/"; return 1; }
    mode=$(_crowdsec_fw_mode)
    registered=$(_crowdsec_bouncer_registered)
    key=$(_crowdsec_read_bouncer_key "$yaml" 2>/dev/null || true)

    if [[ "${registered:-0}" -eq 0 ]] \
        || [[ -z "${key:-}" || "$key" == '${API_KEY}' || "$key" == "API_KEY" || "$key" == "<"* ]]; then
        cscli bouncers delete "$CROWDSEC_BOUNCER_NAME" >/dev/null 2>&1 || true
        key=$(cscli bouncers add "$CROWDSEC_BOUNCER_NAME" -o raw 2>/dev/null | tr -d '[:space:]')
        [[ -n "$key" ]] || {
            error "cscli bouncers add ${CROWDSEC_BOUNCER_NAME} produced no API key"
            echo "  Try:  cscli bouncers add ${CROWDSEC_BOUNCER_NAME}" >&2
            return 1
        }
    fi

    # Pin mode to the same netfilter world as fail2ban (iptables-nft → nftables).
    _crowdsec_write_bouncer_yaml "$yaml" "$key" "$mode"

    unit=$(_crowdsec_bouncer_unit)
    [[ -n "$unit" ]] || { error "Firewall bouncer package installed but no systemd unit"; return 1; }
    systemctl enable "$unit" 2>/dev/null || true
    systemctl restart "$unit" 2>/dev/null || systemctl start "$unit" 2>/dev/null || {
        error "Could not start ${unit}"
        _crowdsec_bouncer_diag "$unit"
        return 1
    }
    for i in $(seq 1 15); do
        systemctl is-active --quiet "$unit" && { ok=1; break; }
        sleep 1
    done
    if [[ "$ok" -eq 0 ]]; then
        error "${unit} is not running — no IP will be banned"
        _crowdsec_bouncer_diag "$unit"
        return 1
    fi
}

# Drop every CrowdSec netfilter artefact *before* purge, or DROP rules stay
# forever with no cscli left to undo them.
_crowdsec_flush_firewall() {
    local unit c
    unit=$(_crowdsec_bouncer_unit)
    [[ -n "$unit" ]] && systemctl stop "$unit" 2>/dev/null || true

    if command -v cscli >/dev/null 2>&1; then
        cscli decisions delete --all >/dev/null 2>&1 || true
    fi

    if command -v nft >/dev/null 2>&1; then
        nft delete table inet crowdsec 2>/dev/null || true
        nft delete table ip crowdsec 2>/dev/null || true
        nft delete table ip6 crowdsec6 2>/dev/null || true
        nft delete table ip crowdsec6 2>/dev/null || true
        nft delete table inet crowdsec6 2>/dev/null || true
    fi

    for c in CROWDSEC CROWDSEC_CHAIN CROWDSEC_BLOCK CROWDSEC-BLACKLIST crowdsec-blacklists; do
        iptables -D INPUT -j "$c" 2>/dev/null || true
        iptables -F "$c" 2>/dev/null || true
        iptables -X "$c" 2>/dev/null || true
        ip6tables -D INPUT -j "$c" 2>/dev/null || true
        ip6tables -F "$c" 2>/dev/null || true
        ip6tables -X "$c" 2>/dev/null || true
    done
}

_crowdsec_ensure_config_writable() {
    local d
    for d in /etc/crowdsec "$CROWDSEC_PARSER_DIR" "$CROWDSEC_ACQUIS_DIR"; do
        [[ -n "$d" ]] || continue
        mkdir -p "$d" 2>/dev/null || true
        chmod u+rwx "$d" 2>/dev/null || true
    done
}

_crowdsec_write_static_whitelist() {
    _crowdsec_ensure_config_writable
    mkdir -p "$CROWDSEC_PARSER_DIR" || return 1
    cat > "${CROWDSEC_PARSER_DIR}/cipi-whitelists.yaml" <<'EOF'
name: crowdsecurity/cipi-whitelists
description: "Cipi never-ban list (localhost, RFC1918, GitLab.com webhooks)"
filter: "1 == 1"
whitelist:
  reason: "cipi allowlist"
  ip:
    - "127.0.0.1"
    - "::1"
    # GitLab.com webhook egress — docs.gitlab.com, captured 2026-09-07.
    # There is no api.github.com/meta equivalent; these CIDRs rot.
    # Self-hosted GitLab: cipi crowdsec allow <cidr>
    - "35.231.145.151"
    - "34.75.54.95"
    - "34.73.53.207"
    - "35.185.202.190"
    - "35.185.200.150"
  cidr:
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
    - "169.254.0.0/16"
    - "34.74.90.64/28"
    - "34.74.226.0/24"
EOF
    return 0
}

_crowdsec_write_acme_whitelist() {
    _crowdsec_ensure_config_writable
    mkdir -p "$CROWDSEC_PARSER_DIR" || return 1
    cat > "${CROWDSEC_PARSER_DIR}/cipi-acme-whitelists.yaml" <<'EOF'
name: crowdsecurity/cipi-acme-whitelists
description: "Let's Encrypt HTTP-01"
filter: "evt.Meta.http_path startsWith '/.well-known/acme-challenge/' || evt.Parsed.request contains '/.well-known/acme-challenge/'"
whitelist:
  reason: "letsencrypt http-01"
  expression:
    - "true"
EOF
    return 0
}

_crowdsec_write_extra_whitelist() {
    _crowdsec_ensure_config_writable
    mkdir -p "$CROWDSEC_PARSER_DIR" || return 1
    local extra="${CROWDSEC_PARSER_DIR}/cipi-extra-whitelists.yaml"
    if [[ ! -s "$CROWDSEC_ALLOW_FILE" ]]; then
        rm -f "$extra"
        return 0
    fi
    local ips="" cidrs="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        _crowdsec_valid_net "$line" || continue
        if [[ "$line" == */* ]]; then
            cidrs+="    - \"${line}\""$'\n'
        else
            ips+="    - \"${line}\""$'\n'
        fi
    done < "$CROWDSEC_ALLOW_FILE"
    if [[ -z "$ips" && -z "$cidrs" ]]; then
        rm -f "$extra"
        return 0
    fi
    {
        echo "name: crowdsecurity/cipi-extra-whitelists"
        echo "description: \"Cipi operator allowlist (cipi crowdsec allow)\""
        echo "filter: \"1 == 1\""
        echo "whitelist:"
        echo "  reason: \"cipi crowdsec allow\""
        if [[ -n "$ips" ]]; then
            echo "  ip:"
            printf '%s' "$ips"
        fi
        if [[ -n "$cidrs" ]]; then
            echo "  cidr:"
            printf '%s' "$cidrs"
        fi
    } > "$extra" || return 1
    return 0
}

# Fail-open: never replace a good file with an empty fetch.
_crowdsec_write_github_whitelist() {
    mkdir -p "$CROWDSEC_PARSER_DIR"
    local out="${CROWDSEC_PARSER_DIR}/cipi-github-whitelists.yaml"
    local raw cidrs tmp
    raw=$(_cipi_run_timed 15 curl -fsSL \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: cipi' \
        https://api.github.com/meta 2>/dev/null) || raw=""
    # hooks = webhook egress; not .web (that is github.com frontends).
    cidrs=$(echo "$raw" | jq -r '.hooks[]? // empty' 2>/dev/null || true)
    if [[ -z "$cidrs" ]]; then
        [[ -s "$out" ]] && return 0
        return 1
    fi
    tmp="${out}.tmp"
    {
        echo "name: crowdsecurity/cipi-github-whitelists"
        echo "description: \"GitHub webhook CIDRs from api.github.com/meta (hooks)\""
        echo "filter: \"1 == 1\""
        echo "whitelist:"
        echo "  reason: \"github webhooks\""
        echo "  cidr:"
        echo "$cidrs" | while IFS= read -r c; do
            [[ -n "$c" ]] && echo "    - \"${c}\""
        done
    } > "$tmp"
    if grep -q '    - "' "$tmp"; then
        mv "$tmp" "$out"
    else
        rm -f "$tmp"
        [[ -s "$out" ]] && return 0
        return 1
    fi
}

# Every Cipi vhost overrides access_log to /home/<app>/logs/nginx-access.log
# (lib/app.sh), so /var/log/nginx holds only the catch-all server block. Reading
# just that made the whole nginx half of CrowdSec inert: no app traffic, no
# http-probing / bad-user-agent / bruteforce scenario ever fires. Globs pick up
# apps created after `crowdsec enable` on their own.
_crowdsec_write_nginx_acquis() {
    _crowdsec_ensure_config_writable
    mkdir -p "$CROWDSEC_ACQUIS_DIR" || return 1
    cat > "${CROWDSEC_ACQUIS_DIR}/cipi-nginx.yaml" <<'EOF'
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
  - /home/*/logs/nginx-access.log
  - /home/*/logs/nginx-error.log
labels:
  type: nginx
EOF
    return 0
}

_crowdsec_reload() {
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
}

_crowdsec_apply_allowlists() {
    _crowdsec_write_static_whitelist || { error "Could not write static allowlist"; return 1; }
    _crowdsec_write_acme_whitelist || { error "Could not write ACME allowlist"; return 1; }
    _crowdsec_write_extra_whitelist || { error "Could not write extra allowlist"; return 1; }
    _crowdsec_write_github_whitelist || warn "GitHub webhook CIDRs unchanged (fetch failed — kept the previous list)"
    _crowdsec_write_nginx_acquis || { error "Could not write nginx log acquisition config"; return 1; }
    _crowdsec_reload
    return 0
}

# Hub update + collections can take minutes and spike RAM. Never run this before
# the bouncer and rescue are up — a OOM kill mid-enable must not leave the
# operator without break-glass.
_crowdsec_install_collections() {
    command -v cscli >/dev/null 2>&1 || return 0
    cscli hub update >/dev/null 2>&1 || {
        warn "cscli hub update failed — scenarios may be stale"
        return 0
    }
    cscli collections install crowdsecurity/linux --force >/dev/null 2>&1 || true
    cscli collections install crowdsecurity/nginx --force >/dev/null 2>&1 || true
    cscli collections install crowdsecurity/sshd --force >/dev/null 2>&1 || true
    _crowdsec_reload
}

_crowdsec_apply_parsers() {
    _crowdsec_apply_allowlists || return 1
    _crowdsec_install_collections || true
}

_crowdsec_write_cron() {
    cat > "$CROWDSEC_CRON" <<'EOF'
# Cipi CrowdSec allowlist refresh (GitHub webhook CIDRs). Engine itself is systemd.
25 4 * * 0 root /usr/local/bin/cipi crowdsec refresh >/dev/null 2>&1
EOF
    chmod 644 "$CROWDSEC_CRON"
}

_crowdsec_allow_silent() {
    local net="${1:-}"
    _crowdsec_valid_net "$net" || return 1
    mkdir -p "$(dirname "$CROWDSEC_ALLOW_FILE")"
    touch "$CROWDSEC_ALLOW_FILE"
    grep -qxF "$net" "$CROWDSEC_ALLOW_FILE" 2>/dev/null && return 0
    echo "$net" >> "$CROWDSEC_ALLOW_FILE"
}

# sudo resets the environment, and installs made before 5.2.0 only kept
# SSH_USER_AUTH — so `sudo cipi crowdsec enable` sees no SSH_CLIENT and would
# silently allowlist nothing. Fall back to the tty owner, then to the sshd
# process this shell descends from.
_crowdsec_ip_from_utmp() {
    local ip
    # "cipi pts/0 2026-09-08 09:00 (203.0.113.9)" — a hostname there is no use
    # to us, _crowdsec_valid_net rejects it and we fall through to /proc.
    ip=$(who am i 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p' | head -1)
    [[ -n "$ip" ]] && _crowdsec_valid_net "$ip" && { echo "$ip"; return 0; }
    return 1
}

_crowdsec_ip_from_proc() {
    local pid="${PPID:-0}" i ip
    for i in $(seq 1 12); do
        [[ "${pid:-0}" -gt 1 ]] || return 1
        if [[ -r "/proc/${pid}/environ" ]]; then
            ip=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
                | sed -n 's/^SSH_CONNECTION=//p; s/^SSH_CLIENT=//p' \
                | awk 'NF {print $1; exit}')
            if [[ -n "${ip:-}" ]] && _crowdsec_valid_net "$ip"; then
                echo "$ip"
                return 0
            fi
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    done
    return 1
}

_crowdsec_session_ip() {
    local ip
    ip=$(_get_client_ip 2>/dev/null || echo "local")
    case "$ip" in
        local|n/a|"") ip="" ;;
    esac
    [[ -n "$ip" ]] || ip=$(_crowdsec_ip_from_utmp 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(_crowdsec_ip_from_proc 2>/dev/null || true)
    [[ -n "$ip" ]] || return 1
    echo "$ip"
}

_crowdsec_allow_this_ssh() {
    local ip
    ip=$(_crowdsec_session_ip 2>/dev/null || echo "")
    case "$ip" in
        127.0.0.1|::1) return 0 ;;
    esac
    if [[ -z "$ip" ]] || ! _crowdsec_valid_net "$ip"; then
        warn "Could not determine the IP of this session — it was NOT allowlisted."
        echo "  A ban on your own address would lock you out of SSH. Add it now:"
        echo -e "    ${CYAN}cipi crowdsec allow <your-ip-or-cidr>${NC}"
        echo "  The rescue URL below is the fallback if that happens anyway."
        return 0
    fi
    _crowdsec_allow_silent "$ip"
    info "Allowed this SSH session: ${ip}"
}

# ── Rescue TLS listener (allowlist the peer, never a login) ──

_crowdsec_rescue_install_helpers() {
    local src="${CIPI_LIB:-/opt/cipi/lib}"
    if [[ -f "${src}/cipi-crowdsec-rescue.py" ]]; then
        cp "${src}/cipi-crowdsec-rescue.py" "$CROWDSEC_RESCUE_BIN"
        chmod 700 "$CROWDSEC_RESCUE_BIN"
    fi
    if [[ -f "${src}/cipi-crowdsec-rescue-hole.sh" ]]; then
        cp "${src}/cipi-crowdsec-rescue-hole.sh" "$CROWDSEC_RESCUE_HOLE"
        chmod 700 "$CROWDSEC_RESCUE_HOLE"
    fi
    [[ -x "$CROWDSEC_RESCUE_BIN" && -x "$CROWDSEC_RESCUE_HOLE" ]]
}

_crowdsec_rescue_write_token() {
    mkdir -p "$(dirname "$CROWDSEC_RESCUE_TOKEN")"
    openssl rand -hex 32 > "$CROWDSEC_RESCUE_TOKEN"
    chmod 600 "$CROWDSEC_RESCUE_TOKEN"
}

_crowdsec_rescue_read_token() {
    [[ -s "$CROWDSEC_RESCUE_TOKEN" ]] || return 1
    tr -d '[:space:]' < "$CROWDSEC_RESCUE_TOKEN"
}

_crowdsec_rescue_read_port() {
    [[ -s "$CROWDSEC_RESCUE_PORT" ]] || return 1
    tr -d '[:space:]' < "$CROWDSEC_RESCUE_PORT"
}

_crowdsec_rescue_pick_port() {
    local p i
    if p=$(_crowdsec_rescue_read_port 2>/dev/null); then
        if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 47000 && "$p" -le 47999 ]]; then
            echo "$p"
            return 0
        fi
    fi
    for i in $(seq 1 30); do
        p=$((47000 + RANDOM % 1000))
        ss -lnt 2>/dev/null | grep -qE ":${p}[[:space:]]" && continue
        echo "$p"
        return 0
    done
    echo 47811
}

_crowdsec_rescue_ensure_cert() {
    [[ -s "$CROWDSEC_RESCUE_CERT" && -s "$CROWDSEC_RESCUE_KEY" ]] && return 0
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$CROWDSEC_RESCUE_KEY" -out "$CROWDSEC_RESCUE_CERT" \
        -days 3650 -nodes -batch \
        -subj "/CN=cipi-crowdsec-rescue/O=Cipi" >/dev/null 2>&1 \
        || openssl req -x509 -newkey rsa:2048 \
            -keyout "$CROWDSEC_RESCUE_KEY" -out "$CROWDSEC_RESCUE_CERT" \
            -days 3650 -nodes -batch \
            -subj "/CN=cipi-crowdsec-rescue/O=Cipi" >/dev/null 2>&1
    chmod 600 "$CROWDSEC_RESCUE_KEY"
    chmod 644 "$CROWDSEC_RESCUE_CERT"
}

_crowdsec_rescue_fingerprint() {
    [[ -s "$CROWDSEC_RESCUE_CERT" ]] || return 1
    openssl x509 -in "$CROWDSEC_RESCUE_CERT" -noout -fingerprint -sha256 2>/dev/null \
        | awk -F= '{print $2}' | tr -d ':'
}

_crowdsec_rescue_public_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-$(hostname)}"
}

_crowdsec_rescue_hostport() {
    local ip port
    ip=$(_crowdsec_rescue_public_ip)
    port=$(_crowdsec_rescue_read_port) || return 1
    if [[ "$ip" == *:* ]]; then
        echo "[${ip}]:${port}"
    else
        echo "${ip}:${port}"
    fi
}

_crowdsec_rescue_curl() {
    local token hp
    token=$(_crowdsec_rescue_read_token) || return 1
    hp=$(_crowdsec_rescue_hostport) || return 1
    echo "curl -k https://${hp}/${token}"
}

_crowdsec_rescue_ufw_allow() {
    local port
    port=$(_crowdsec_rescue_read_port) || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow "${port}/tcp" comment 'cipi-crowdsec-rescue' >/dev/null 2>&1 || \
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
}

_crowdsec_rescue_ufw_delete() {
    local port
    port=$(_crowdsec_rescue_read_port) || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    yes | ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
}

_crowdsec_rescue_write_unit() {
    cat > /etc/systemd/system/cipi-crowdsec-rescue.service <<EOF
[Unit]
Description=Cipi CrowdSec rescue (TLS allowlist, not a login)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=CIPI_CONFIG=${CIPI_CONFIG}
ExecStartPre=-${CROWDSEC_RESCUE_HOLE}
ExecStart=/usr/bin/python3 -u ${CROWDSEC_RESCUE_BIN}
Restart=always
RestartSec=3
TimeoutStopSec=5

# A root HTTP server on a permanently open port is the largest surface this
# release adds, so trim what a bug in it could reach. It stays root because
# redeeming runs \`cipi crowdsec redeem\` (writes /etc/cipi and /etc/crowdsec,
# reloads units, drives cscli and fail2ban-client) — ProtectSystem and
# SystemCallFilter are deliberately absent: breaking break-glass to harden it
# is a bad trade. ProtectKernelModules is out too, because the ExecStartPre
# hole punch may need nft/iptables to autoload netfilter modules.
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
TasksMax=64
MemoryHigh=192M

[Install]
WantedBy=multi-user.target
EOF
}

_crowdsec_rescue_write_dropin() {
    local unit dir
    unit=$(_crowdsec_bouncer_unit)
    [[ -n "$unit" ]] || return 0
    dir="/etc/systemd/system/${unit}.service.d"
    mkdir -p "$dir"
    cat > "${dir}/cipi-rescue.conf" <<EOF
[Service]
ExecStartPost=-${CROWDSEC_RESCUE_HOLE}
EOF
}

_crowdsec_rescue_punch() {
    [[ -x "$CROWDSEC_RESCUE_HOLE" ]] && "$CROWDSEC_RESCUE_HOLE" || true
}

_crowdsec_rescue_start() {
    command -v python3 >/dev/null 2>&1 || {
        error "python3 is required for the CrowdSec rescue listener"
        return 1
    }
    _crowdsec_rescue_install_helpers || {
        error "Rescue helpers missing — run cipi self-update, then cipi crowdsec enable"
        return 1
    }
    mkdir -p "$CIPI_CONFIG"
    local port
    port=$(_crowdsec_rescue_pick_port)
    echo "$port" > "$CROWDSEC_RESCUE_PORT"
    chmod 644 "$CROWDSEC_RESCUE_PORT"
    [[ -s "$CROWDSEC_RESCUE_TOKEN" ]] || _crowdsec_rescue_write_token
    _crowdsec_rescue_ensure_cert || { error "Could not write the rescue TLS certificate"; return 1; }
    _crowdsec_rescue_ufw_allow
    _crowdsec_rescue_write_unit
    _crowdsec_rescue_write_dropin
    systemctl daemon-reload
    systemctl enable --now cipi-crowdsec-rescue >/dev/null 2>&1 || {
        error "Could not start cipi-crowdsec-rescue"
        return 1
    }
    _crowdsec_rescue_punch
    systemctl is-active --quiet cipi-crowdsec-rescue || {
        error "Rescue listener is not running"
        return 1
    }
}

_crowdsec_rescue_stop() {
    systemctl disable --now cipi-crowdsec-rescue >/dev/null 2>&1 || true
    _crowdsec_rescue_ufw_delete
    local unit dir
    unit=$(_crowdsec_bouncer_unit)
    if [[ -n "$unit" ]]; then
        dir="/etc/systemd/system/${unit}.service.d"
        rm -f "${dir}/cipi-rescue.conf"
        rmdir "$dir" 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/cipi-crowdsec-rescue.service
    systemctl daemon-reload 2>/dev/null || true
    local port bin
    port=$(_crowdsec_rescue_read_port 2>/dev/null || true)
    if [[ -n "${port:-}" ]]; then
        iptables -D INPUT -p tcp --dport "$port" -m comment --comment cipi-crowdsec-rescue -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport "$port" -m comment --comment cipi-crowdsec-rescue -j ACCEPT 2>/dev/null || true
    fi
    rm -f "$CROWDSEC_RESCUE_PORT" "$CROWDSEC_RESCUE_TOKEN" \
        "$CROWDSEC_RESCUE_CERT" "$CROWDSEC_RESCUE_KEY" \
        "${CIPI_CONFIG}/crowdsec-rescue.lock"
}

_crowdsec_rescue_print() {
    local curl fp port
    curl=$(_crowdsec_rescue_curl) || return 0
    fp=$(_crowdsec_rescue_fingerprint) || fp="n/a"
    port=$(_crowdsec_rescue_read_port) || port="?"
    echo ""
    echo -e "  ${BOLD}Rescue (not a login)${NC}"
    echo "  TLS listener on port ${port}. One GET with the token allowlists"
    echo "  the calling IP and mails you a new token. No shell, no SSH key."
    echo -e "  ${CYAN}${curl}${NC}"
    echo -e "  SHA256 ${DIM}${fp}${NC}"
    echo "  Save the curl. After one use the token is dead — the mail has the next."
    echo "  Rotate: cipi crowdsec rescue rotate    Show: cipi crowdsec rescue token"
    echo ""
}

_crowdsec_rescue_mail() {
    local reason="$1"
    local curl fp
    curl=$(_crowdsec_rescue_curl) || curl="(token missing — cipi crowdsec rescue rotate)"
    fp=$(_crowdsec_rescue_fingerprint) || fp="n/a"
    cipi_notify \
        "Cipi CrowdSec rescue on $(hostname)" \
        "${reason}\n\nThis is not a login. The URL only allowlists the IP that fetches it.\n\n${curl}\nFingerprint SHA256: ${fp}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        crowdsec_rescue
}

_crowdsec_rescue_cli() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|"")
            _crowdsec_status
            ;;
        token|url|curl)
            _crowdsec_installed || { error "CrowdSec is not installed"; exit 1; }
            local curl unit
            curl=$(_crowdsec_rescue_curl) || {
                error "Rescue is not configured"
                if _crowdsec_running; then
                    echo "  enable stopped before the rescue listener started." >&2
                    unit=$(_crowdsec_bouncer_unit)
                    if [[ -n "${unit:-}" ]] && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
                        echo "  The firewall bouncer is not running — fix it, then re-run enable:" >&2
                        _crowdsec_bouncer_diag "$unit"
                    else
                        echo "  Re-run:  cipi crowdsec enable" >&2
                    fi
                else
                    echo "  Run:  cipi crowdsec enable" >&2
                fi
                exit 1
            }
            echo "$curl"
            ;;
        rotate)
            _crowdsec_installed || { error "CrowdSec is not installed"; exit 1; }
            [[ -s "$CROWDSEC_RESCUE_PORT" ]] || { error "Rescue is not configured — cipi crowdsec enable"; exit 1; }
            _crowdsec_rescue_write_token
            _crowdsec_rescue_mail "The rescue token was rotated on $(hostname)."
            success "Token rotated"
            _crowdsec_rescue_print
            ;;
        *)
            error "Usage: cipi crowdsec rescue status|token|rotate"
            exit 1
            ;;
    esac
}

_crowdsec_rescue_redeem() {
    local ip="${1:-}"
    [[ "${CIPI_RESCUE_REDEEM:-}" == "1" ]] || { error "redeem is internal to the rescue listener"; return 1; }
    [[ -n "$ip" ]] || { error "Usage: cipi crowdsec redeem <ip>"; return 1; }
    [[ "$ip" == */* ]] && { error "Redeem expects a single IP, not a CIDR"; return 1; }
    _crowdsec_valid_net "$ip" || { error "Not an IP: ${ip}"; return 1; }
    case "$ip" in
        127.0.0.1|::1|0.0.0.0) error "Refusing to redeem ${ip}"; return 1 ;;
    esac
    _crowdsec_installed || { error "CrowdSec is not installed"; return 1; }

    _crowdsec_allow_silent "$ip"
    _crowdsec_write_extra_whitelist
    _crowdsec_reload
    command -v cscli >/dev/null 2>&1 && cscli decisions delete --ip "$ip" >/dev/null 2>&1 || true
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local jails jail
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)
        for jail in $jails; do
            fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 || true
        done
    fi
    _crowdsec_rescue_write_token
    local new
    new=$(_crowdsec_rescue_read_token)
    log_action "crowdsec rescue redeem ${ip}"
    log_event "CrowdSec rescue allowlisted ${ip}"
    # Parsed by /usr/local/bin/cipi-crowdsec-rescue — keep this prefix stable.
    # Printed before the mail: SMTP is the slow part, and the caller must get
    # the replacement token even if the mail carrying it never goes out.
    echo "RESCUE_OK ${new}"
    # Detached with its own fds so the listener's capture pipe reaches EOF and
    # does not wait on the mail.
    ( _crowdsec_rescue_mail "Rescue used on $(hostname). Allowlisted ${ip}. The previous token is dead." \
        >/dev/null 2>&1 </dev/null & ) &
    return 0
}

_crowdsec_enable() {
    parse_args "$@"
    _crowdsec_check_ram || exit 1
    _crowdsec_check_real_ip || exit 1
    _crowdsec_allow_this_ssh

    local fresh=0 rescue_was=0 fwmode
    if _crowdsec_installed && _crowdsec_running; then
        info "CrowdSec engine already running — completing setup"
    else
        fresh=1
        _crowdsec_install_packages || exit 1
        if ! _crowdsec_running; then
            error "CrowdSec installed but the engine did not start"
            echo "  Check:  systemctl status crowdsec"
            echo "  Logs:    journalctl -u crowdsec -n 25 --no-pager"
            exit 1
        fi
    fi

    # Bouncer + rescue first. cscli hub update (later) can take minutes and has
    # killed enable mid-flight on small boxes — leaving engine up, bouncer down,
    # rescue missing.
    step "Registering firewall bouncer (cscli bouncers add)..."
    _crowdsec_register_bouncer || exit 1

    systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null && rescue_was=1
    step "Starting rescue TLS listener (allowlist only, not a login)..."
    _crowdsec_rescue_start || exit 1

    step "Allowlists (localhost, private nets, Let's Encrypt, GitHub/GitLab webhooks, this SSH)..."
    if ! _crowdsec_apply_allowlists; then
        warn "Allowlist write failed — bouncer and rescue are up; fix with: cipi crowdsec refresh"
    fi
    if [[ "$fresh" -eq 1 ]]; then
        step "Installing CrowdSec scenarios (hub update — may take a minute)..."
        _crowdsec_install_collections || warn "Scenario install did not finish — run: cipi crowdsec refresh"
    fi
    _crowdsec_write_cron

    fwmode=$(_crowdsec_fw_mode)
    log_action "crowdsec enable"
    log_event "CrowdSec enabled on $(hostname)"
    local rescue_curl
    rescue_curl=$(_crowdsec_rescue_curl 2>/dev/null || echo "")
    cipi_notify \
        "Cipi CrowdSec enabled on $(hostname)" \
        "CrowdSec is reading sshd and nginx logs. Bans are enforced by the ${fwmode} firewall bouncer (registered via cscli bouncers add).\n\nFail2ban is unchanged. This is not a WAF.\n\nAllowlists: localhost, RFC1918, Let's Encrypt HTTP-01, GitHub/GitLab webhook ranges, this SSH session.\nAdd more with: cipi crowdsec allow <ip|cidr>\n\nRescue (not a login — one GET allowlists the calling IP, then the token dies):\n${rescue_curl}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        crowdsec_enable
    success "CrowdSec enabled (engine + ${fwmode} bouncer)"
    info "cipi ban list|unban now includes CrowdSec decisions"
    _crowdsec_rescue_print
    if [[ "$rescue_was" -eq 0 ]]; then
        _crowdsec_rescue_mail "CrowdSec rescue listener is on $(hostname). Save this curl; one use, then the token dies."
    fi
}

_crowdsec_disable() {
    parse_args "$@"
    if ! _crowdsec_installed && [[ ! -f "$CROWDSEC_CRON" ]]; then
        info "CrowdSec is not installed"
        return 0
    fi
    if [[ "${ARG_force:-}" != "true" ]]; then
        confirm "Disable CrowdSec, stop the rescue listener, flush its firewall rules, and remove packages? Fail2ban stays." || { info "Aborted"; return 0; }
    fi

    step "Stopping rescue listener..."
    _crowdsec_rescue_stop
    step "Flushing CrowdSec firewall chains (before purge)..."
    _crowdsec_flush_firewall
    systemctl disable --now crowdsec-firewall-bouncer 2>/dev/null || true
    systemctl disable --now crowdsec 2>/dev/null || true
    rm -f "$CROWDSEC_CRON"

    step "Removing CrowdSec packages..."
    _crowdsec_apt purge -y -qq crowdsec \
        crowdsec-firewall-bouncer-iptables crowdsec-firewall-bouncer-nftables \
        crowdsec-firewall-bouncer >/dev/null 2>&1 || true
    _crowdsec_apt autoremove -y -qq >/dev/null 2>&1 || true
    rm -rf /etc/crowdsec /var/lib/crowdsec
    rm -f /etc/apt/sources.list.d/crowdsec.list /etc/apt/keyrings/crowdsec.gpg
    # A second flush in case purge restarted anything.
    _crowdsec_flush_firewall
    _crowdsec_apt update -qq >/dev/null 2>&1 || true

    log_action "crowdsec disable"
    log_event "CrowdSec disabled on $(hostname)"
    cipi_notify \
        "Cipi CrowdSec disabled on $(hostname)" \
        "CrowdSec, its bouncer and its firewall chains were removed. Fail2ban is unchanged.\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        crowdsec_disable
    success "CrowdSec removed — firewall is back to fail2ban only"
}

_crowdsec_status() {
    parse_args "$@"
    echo ""
    echo -e "  ${BOLD}CrowdSec${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ! _crowdsec_installed; then
        echo -e "  ${DIM}not installed${NC}  —  ${CYAN}cipi crowdsec enable${NC}"
        echo ""
        return 0
    fi
    local st="stopped" unit bouncer="not installed" mode
    systemctl is-active --quiet crowdsec 2>/dev/null && st="running"
    unit=$(_crowdsec_bouncer_unit)
    mode=$(_crowdsec_fw_mode)
    if [[ -n "$unit" ]]; then
        bouncer="stopped"
        systemctl is-active --quiet "$unit" 2>/dev/null && bouncer="running"
    fi
    printf "  %-16s ${CYAN}%s${NC}\n" "Engine" "$st"
    printf "  %-16s ${CYAN}%s${NC}\n" "Bouncer" "${bouncer} (${mode})"
    printf "  %-16s ${CYAN}%s${NC}\n" "WAF / AppSec" "off (never installed)"
    local rst="stopped" rport rfp
    systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null && rst="listening"
    rport=$(_crowdsec_rescue_read_port 2>/dev/null || echo "n/a")
    rfp=$(_crowdsec_rescue_fingerprint 2>/dev/null || echo "")
    printf "  %-16s ${CYAN}%s${NC}\n" "Rescue" "${rst} :${rport}"
    if [[ -n "$rfp" ]]; then
        printf "  %-16s ${DIM}%s${NC}\n" "TLS SHA256" "$rfp"
    fi
    echo -e "  ${DIM}not a login — cipi crowdsec rescue token|rotate${NC}"
    if command -v cscli >/dev/null 2>&1; then
        local bn
        bn=$(_crowdsec_bouncer_registered)
        printf "  %-16s ${CYAN}%s${NC}\n" "Registered" "${bn:-0} bouncer(s)"
    fi
    if [[ -s "$CROWDSEC_ALLOW_FILE" ]]; then
        echo -e "  ${BOLD}Extra allow${NC}"
        sed -e '/^$/d' -e '/^#/d' "$CROWDSEC_ALLOW_FILE" | sed 's/^/    /'
    fi
    if _crowdsec_running; then
        local n
        n=$(cscli decisions list -o json 2>/dev/null \
            | jq '[.[]?.decisions[]?] | length' 2>/dev/null || echo 0)
        printf "  %-16s ${CYAN}%s${NC}\n" "Decisions" "${n:-0}"
        echo -e "  ${DIM}cipi ban list${NC} shows them next to fail2ban"
        if [[ "$bouncer" != "running" ]]; then
            warn "Engine is up but the bouncer is not — decisions are not enforced"
        fi
    fi
    echo ""
}

_crowdsec_allow() {
    local net="${1:-}"
    [[ -z "$net" ]] && { error "Usage: cipi crowdsec allow <ip|cidr>"; exit 1; }
    _crowdsec_valid_net "$net" || { error "Not an IP or CIDR: ${net}"; exit 1; }
    _crowdsec_installed || { error "CrowdSec is not installed — cipi crowdsec enable"; exit 1; }
    _crowdsec_allow_silent "$net"
    _crowdsec_write_extra_whitelist
    _crowdsec_reload
    log_action "crowdsec allow ${net}"
    success "Allowed ${net} (never banned by CrowdSec)"
}

_crowdsec_unallow() {
    local net="${1:-}"
    [[ -z "$net" ]] && { error "Usage: cipi crowdsec unallow <ip|cidr>"; exit 1; }
    if [[ ! -s "$CROWDSEC_ALLOW_FILE" ]] || ! grep -qxF "$net" "$CROWDSEC_ALLOW_FILE" 2>/dev/null; then
        warn "${net} is not on the extra allowlist"
        return 0
    fi
    grep -vxF "$net" "$CROWDSEC_ALLOW_FILE" > "${CROWDSEC_ALLOW_FILE}.tmp" || true
    mv "${CROWDSEC_ALLOW_FILE}.tmp" "$CROWDSEC_ALLOW_FILE"
    _crowdsec_write_extra_whitelist
    _crowdsec_reload
    log_action "crowdsec unallow ${net}"
    success "Removed ${net} from the extra allowlist"
}

_crowdsec_refresh_allowlists() {
    _crowdsec_installed || return 0
    _crowdsec_apply_parsers
}
