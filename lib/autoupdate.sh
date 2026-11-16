#!/bin/bash
#############################################
# Cipi — Automatic patch updates of the stack
#
# unattended-upgrades installs Ubuntu's security pocket and `cipi php
# upgrade` the PHP packages. Neither touches what Cipi installs from somewhere
# else or holds back on purpose: nginx (nginx.org), MariaDB, PostgreSQL and
# Valkey — blacklisted, because apt restarts them — the Node.js runtimes and
# Composer. Until 5.9.0 those waited for someone to run `cipi … upgrade`,
# and nothing said there was something to run.
#
# `cipi autoupdate run` (root cron, nightly) applies the patch releases of
# every component that is switched on, one after the other, with the code
# the manual commands use: only packages already installed (`apt
# --only-upgrade`), Cipi's configuration files kept, nginx tested before it
# is reloaded, a Node runtime checked against its published SHA-256.
#
#   cipi autoupdate                      what is on, what ran last
#   cipi autoupdate on|off [component]   all of them, or one
#   cipi autoupdate run [component]      now (what cron runs)
#
# Components: nginx mariadb pgsql valkey node composer
#############################################

[[ -z "${AUTOUPDATE_CRON:-}" ]]  && readonly AUTOUPDATE_CRON="/etc/cron.d/cipi-autoupdate"
[[ -z "${AUTOUPDATE_STATE:-}" ]] && readonly AUTOUPDATE_STATE="/var/lib/cipi/autoupdate.state"
[[ -z "${AUTOUPDATE_LOCK:-}" ]]  && readonly AUTOUPDATE_LOCK="/run/cipi-autoupdate.lock"
# Cheapest and least disruptive first; the databases last, so a night in
# which one of them fails has already patched everything else.
[[ -z "${AUTOUPDATE_COMPONENTS:-}" ]] && readonly AUTOUPDATE_COMPONENTS="composer node nginx valkey pgsql mariadb"

_autoupdate_normalize() {
    case "${1:-}" in
        nginx) echo nginx ;;
        mariadb|mysql) echo mariadb ;;
        pgsql|postgres|postgresql) echo pgsql ;;
        valkey|valkey-server|redis) echo valkey ;;
        node|nodejs) echo node ;;
        composer) echo composer ;;
        *) return 1 ;;
    esac
}

_autoupdate_label() {
    case "${1:-}" in
        nginx) echo "Nginx" ;;
        mariadb) echo "MariaDB" ;;
        pgsql) echo "PostgreSQL" ;;
        valkey) echo "Valkey" ;;
        node) echo "Node.js" ;;
        composer) echo "Composer" ;;
        *) echo "${1:-unknown}" ;;
    esac
}

# On unless switched off: a component nobody decided about is patched.
autoupdate_enabled() {
    local v
    v=$(vault_read autoupdate.json 2>/dev/null | jq -r --arg c "$1" '.[$c] != false' 2>/dev/null) || v="true"
    [[ "$v" != "false" ]]
}

_autoupdate_set() {   # <component> <true|false>
    local j
    j=$(vault_read autoupdate.json 2>/dev/null) || j=""
    [[ -n "$j" ]] || j='{}'
    j=$(jq --arg c "$1" --argjson v "$2" 'if type == "object" then . else {} end | .[$c] = $v' <<< "$j" 2>/dev/null) || j=""
    [[ -n "$j" ]] || { error "Could not update autoupdate.json"; return 1; }
    printf '%s\n' "$j" | vault_write autoupdate.json
}

autoupdate_installed() {
    case "${1:-}" in
        nginx|mariadb|pgsql|valkey) _stack_upgrade_present "$1" ;;
        node)     [[ -x /usr/bin/node ]] || compgen -G "${NODE_ROOT}/[0-9]*" >/dev/null ;;
        composer) [[ -x /usr/local/bin/composer ]] ;;
        *) return 1 ;;
    esac
}

# The nightly job. A file in /etc/cron.d, not a line in root's crontab:
# switching it on and off never rewrites what else is in there.
autoupdate_cron_write() {
    [[ -d /etc/cron.d ]] || return 0
    cat > "$AUTOUPDATE_CRON" <<'EOF'
# Cipi — nightly patch updates of nginx, MariaDB, PostgreSQL, Valkey, Node.js
# and Composer (cipi autoupdate). Per component: cipi autoupdate off <name>.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
20 4 * * * root /usr/local/bin/cipi-cron-notify autoupdate /usr/local/bin/cipi autoupdate run >> /var/log/cipi/autoupdate.log 2>&1
EOF
    chmod 644 "$AUTOUPDATE_CRON"
}

_autoupdate_any_enabled() {
    local c
    for c in $AUTOUPDATE_COMPONENTS; do
        autoupdate_enabled "$c" && return 0
    done
    return 1
}

# Keeps the cron file in step with the switches: there while anything is on.
autoupdate_cron_sync() {
    if _autoupdate_any_enabled; then
        autoupdate_cron_write
    else
        rm -f "$AUTOUPDATE_CRON"
    fi
}

# ── state of the last run, one line per component ────────────
# "<component> <ok|failed|skipped> <epoch> <note…>"
_autoupdate_state_set() {
    local c="$1" st="$2" note="${3:-}" tmp
    mkdir -p "$(dirname "$AUTOUPDATE_STATE")" 2>/dev/null || return 0
    tmp=$(mktemp "${AUTOUPDATE_STATE}.XXXXXX") || return 0
    { grep -v "^${c} " "$AUTOUPDATE_STATE" 2>/dev/null || true
      printf '%s %s %s %s\n' "$c" "$st" "$(date +%s)" "$note"; } > "$tmp"
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$AUTOUPDATE_STATE" 2>/dev/null || rm -f "$tmp"
}

autoupdate_state_get() {   # <component> → "<status> <epoch> <note…>" or nothing
    [[ -f "$AUTOUPDATE_STATE" ]] || return 0
    awk -v c="$1" '$1 == c { $1 = ""; sub(/^ /, ""); print; exit }' "$AUTOUPDATE_STATE" 2>/dev/null || true
}

# ── what must not be interrupted ─────────────────────────────
# A database restarted under a dump leaves a truncated backup, and under a
# deploy a half-run migration. Either way it can wait for tomorrow night.
_autoupdate_db_busy() {
    if pgrep -x 'mariadb-dump|mysqldump|mariabackup|mariadb-backup|pg_dump|pg_dumpall|pg_basebackup|pg_restore' >/dev/null 2>&1; then
        echo "a database dump is running"; return 0
    fi
    if pgrep -f '/usr/local/bin/dep (deploy|rollback) ' >/dev/null 2>&1; then
        echo "a deploy is running"; return 0
    fi
    return 1
}

# ── Composer ─────────────────────────────────────────────────
_autoupdate_composer_version() {
    COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer --version --no-ansi 2>/dev/null \
        | sed -n 's/.*Composer version \([0-9][0-9.]*\).*/\1/p' | head -1
}

# `self-update --2` stays on Composer 2's stable channel and checks the
# download against Composer's own signing keys. A phar that then does not
# start is rolled back to the one that did.
_autoupdate_composer() {
    local before after out rc=0
    export COMPOSER_ALLOW_SUPERUSER=1
    [[ -n "${HOME:-}" ]] || export HOME=/root
    before=$(_autoupdate_composer_version || true)
    [[ -n "$before" ]] || { error "composer --version failed — not touched"; return 1; }
    out=$(/usr/local/bin/composer self-update --2 --no-interaction --no-ansi 2>&1) || rc=$?
    after=$(_autoupdate_composer_version || true)
    if [[ -z "$after" ]]; then
        /usr/local/bin/composer self-update --rollback --no-interaction >/dev/null 2>&1 || true
        after=$(_autoupdate_composer_version || true)
        error "Composer did not start after the update — rolled back to ${after:-?}"
        return 1
    fi
    if [[ "$rc" -ne 0 ]]; then
        printf '%s\n' "$out" | tail -n 5
        error "composer self-update failed (still ${after})"
        return 1
    fi
    if [[ "$after" == "$before" ]]; then
        info "Composer is up to date (${after})"
        return 0
    fi
    log_action "COMPOSER UPGRADE: ${before} → ${after}"
    cipi_notify \
        "Cipi Composer upgraded on $(hostname)" \
        "Composer was upgraded.\n\nServer: $(hostname)\nFrom: ${before}\nTo: ${after}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        composer_upgrade
    success "Composer upgraded (${before} → ${after})"
}

# ── Node.js ──────────────────────────────────────────────────
# The runtimes under /opt/cipi/node (one per major, from nodejs.org) and the
# system package (NodeSource — a repository unattended-upgrades does not
# follow). An SSR app is restarted, blue/green, only when the runtime it runs
# on actually changed: `cipi node upgrade --restart` restarts them all.
_autoupdate_node() {
    local l m before after app rc=0 changed=""
    for l in "${NODE_ROOT}"/[0-9]*; do
        [[ -L "$l" ]] || continue
        m=$(basename "$l")
        node_is_installed "$m" || continue
        before=$(node_full_version "$m" || true)
        if ! _node_install_major "$m"; then
            rc=1; continue
        fi
        after=$(node_full_version "$m" || true)
        [[ -n "$after" && "$after" != "$before" ]] || continue
        changed="${changed} ${before}→${after}"
        for app in $(_node_apps_on "$m"); do
            [[ "$(app_get "$app" node_mode)" == "ssr" ]] || continue
            step "Restarting ${app} on Node ${after} (blue/green)..."
            _node_switch "$app" current \
                || { warn "${app}: restart failed — still on the previous process (cipi node restart ${app})"; rc=1; }
        done
        _node_prune_major "$m"
    done

    if dpkg-query -W -f='${db:Status-Status}' nodejs 2>/dev/null | grep -qx installed; then
        before=$(/usr/bin/node --version 2>/dev/null | tr -d v || true)
        if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -qq \
           && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
                -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
                --only-upgrade nodejs >/dev/null 2>&1; then
            after=$(/usr/bin/node --version 2>/dev/null | tr -d v || true)
            if [[ -n "$after" && "$after" != "$before" ]]; then
                changed="${changed} system:${before}→${after}"
            fi
        else
            error "apt could not upgrade the system nodejs package"
            rc=1
        fi
    fi

    if [[ -n "$changed" ]]; then
        log_action "NODE UPGRADE:${changed}"
        cipi_notify \
            "Cipi Node.js upgraded on $(hostname)" \
            "Node.js runtimes were upgraded.\n\nServer: $(hostname)\nChanged:${changed}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            node_upgrade
        success "Node.js upgraded:${changed}"
    elif [[ "$rc" -eq 0 ]]; then
        info "Node.js runtimes are up to date"
    fi
    return "$rc"
}

# ── one component ────────────────────────────────────────────
_autoupdate_one() {
    local c="$1" why
    case "$c" in
        composer) _autoupdate_composer ;;
        node)     _autoupdate_node ;;
        nginx)    _stack_upgrade nginx --yes ;;
        valkey)   _stack_upgrade valkey --yes ;;
        mariadb|pgsql)
            if why=$(_autoupdate_db_busy); then
                info "$(_autoupdate_label "$c"): ${why} — left for the next run"
                return 75
            fi
            _stack_upgrade "$c" --yes
            ;;
    esac
}

_autoupdate_run() {
    local only="" c rc st failed="" had_e
    if [[ -n "${1:-}" && "${1:-}" != --* ]]; then
        only=$(_autoupdate_normalize "$1") || { error "Unknown component: $1 (nginx mariadb pgsql valkey node composer)"; return 1; }
    fi
    exec 8>"$AUTOUPDATE_LOCK"
    if ! flock -n 8; then
        info "An automatic update is already running — skip"
        return 0
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] cipi autoupdate run${only:+ ${only}}"
    for c in $AUTOUPDATE_COMPONENTS; do
        [[ -n "$only" && "$c" != "$only" ]] && continue
        if [[ -z "$only" ]] && ! autoupdate_enabled "$c"; then
            continue
        fi
        if ! autoupdate_installed "$c"; then
            [[ -n "$only" ]] && info "$(_autoupdate_label "$c") is not installed"
            continue
        fi
        step "$(_autoupdate_label "$c")..."
        # In a subshell: `exit` in the code this borrows ends that component,
        # not the run. Not as one side of `||`: errexit would then be off
        # inside, and the manual commands this reuses are written to stop at
        # the first failure. The lock is not passed on (8>&-): a service apt
        # restarts would otherwise hold it for as long as it lives.
        had_e=false; [[ $- == *e* ]] && had_e=true
        set +e
        ( set -e; _autoupdate_one "$c" ) 8>&-
        rc=$?
        [[ "$had_e" == true ]] && set -e
        case "$rc" in
            0)  st=ok ;;
            75) st=skipped ;;
            *)  st=failed; failed="${failed} ${c}" ;;
        esac
        _autoupdate_state_set "$c" "$st"
    done
    if [[ -n "$failed" ]]; then
        error "Automatic update failed for:${failed} — see /var/log/cipi/autoupdate.log; by hand: cipi autoupdate run <component>"
        return 1
    fi
    return 0
}

_autoupdate_status() {
    local c label state st ts note when
    echo -e "\n${BOLD}Automatic updates${NC} ${DIM}(nightly, 04:20 — patch releases only)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for c in nginx mariadb pgsql valkey node composer; do
        label=$(_autoupdate_label "$c")
        if ! autoupdate_installed "$c"; then
            printf "  ${DIM}○${NC} %-12s ${DIM}not installed${NC}\n" "$label"
            continue
        fi
        state=$(autoupdate_state_get "$c")
        when=""
        if [[ -n "$state" ]]; then
            read -r st ts note <<< "$state"
            when="last run $(date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?'): ${st}"
        fi
        if autoupdate_enabled "$c"; then
            printf "  ${GREEN}●${NC} %-12s ${GREEN}on${NC}   ${DIM}%s${NC}\n" "$label" "$when"
        else
            printf "  ${YELLOW}●${NC} %-12s ${YELLOW}off${NC}  ${DIM}%s${NC}\n" "$label" "${when:-patch by hand — cipi pending lists what is waiting}"
        fi
    done
    echo ""
    echo -e "  ${DIM}PHP: ${NC}${CYAN}cipi php upgrade${NC}${DIM} (daily 03:30).  Ubuntu security updates: unattended-upgrades.${NC}"
    echo -e "  ${DIM}Kernel updates need a reboot: ${NC}${CYAN}cipi reboot${NC}"
    if [[ ! -f "$AUTOUPDATE_CRON" ]] && _autoupdate_any_enabled; then
        echo -e "  ${YELLOW}The nightly job is missing (${AUTOUPDATE_CRON}) — cipi autoupdate on${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}cipi autoupdate on|off [nginx|mariadb|pgsql|valkey|node|composer]${NC}"
    echo -e "  ${CYAN}cipi autoupdate run [component]${NC}"
    echo ""
}

_autoupdate_switch() {   # <on|off> [component]
    local to="$1" raw="${2:-}" c val list
    [[ "$to" == "on" ]] && val=true || val=false
    if [[ -n "$raw" ]]; then
        c=$(_autoupdate_normalize "$raw") || { error "Unknown component: ${raw} (nginx mariadb pgsql valkey node composer)"; return 1; }
        list="$c"
    else
        list="$AUTOUPDATE_COMPONENTS"
    fi
    for c in $list; do
        _autoupdate_set "$c" "$val" || return 1
    done
    autoupdate_cron_sync
    log_action "AUTOUPDATE ${to^^}: ${raw:-all}"
    if [[ "$to" == "on" ]]; then
        success "Automatic updates on: ${raw:-all components} (nightly, 04:20)"
    else
        success "Automatic updates off: ${raw:-all components}"
        info "What is waiting is listed by: cipi pending"
    fi
}

autoupdate_command() {
    local sub="${1:-status}"; shift || true
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/stack-upgrade.sh"
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/node.sh"
    case "$sub" in
        status|"") _autoupdate_status ;;
        on|enable)   _autoupdate_switch on "$@" ;;
        off|disable) _autoupdate_switch off "$@" ;;
        run)       _autoupdate_run "$@" ;;
        *) error "Use: cipi autoupdate [status|on|off|run] [nginx|mariadb|pgsql|valkey|node|composer]"; return 1 ;;
    esac
}
