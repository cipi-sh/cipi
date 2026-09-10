#!/bin/bash
#############################################
# Cipi — Manual stack package upgrades
#
# Nginx, MariaDB, PostgreSQL and Valkey are blacklisted from
# unattended-upgrades: a database restart is not something to do at 4am
# unattended. PHP has its own weekly cron (`cipi php upgrade`). These
# helpers are the operator-facing equivalent — patch-level only
# (`apt --only-upgrade` of packages already installed), Cipi configs
# kept (`--force-confold`), confirmation unless `--yes`.
#
# Entry points:
#   cipi nginx upgrade [--yes]
#   cipi db upgrade [mariadb|pgsql] [--yes]
#   cipi service upgrade [nginx|mariadb|postgresql|valkey] [--yes]
#############################################

_stack_upgrade_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

# Canonical id, or empty + nonzero for anything else (including `all`).
_stack_upgrade_normalize() {
    case "${1:-}" in
        nginx) echo nginx ;;
        mariadb|mysql) echo mariadb ;;
        pgsql|postgres|postgresql) echo pgsql ;;
        valkey|valkey-server|redis|redis-server) echo valkey ;;
        *) return 1 ;;
    esac
}

_stack_upgrade_label() {
    case "${1:-}" in
        nginx)   echo "Nginx" ;;
        mariadb) echo "MariaDB" ;;
        pgsql)   echo "PostgreSQL" ;;
        valkey)  echo "Valkey" ;;
        *)       echo "${1:-unknown}" ;;
    esac
}

# dpkg name of the package whose version we show, and the systemd unit
# that must come back up afterwards.
_stack_upgrade_main_pkg() {
    case "${1:-}" in
        nginx)   echo nginx ;;
        mariadb) echo mariadb-server ;;
        pgsql)   echo postgresql ;;
        valkey)  echo valkey-server ;;
    esac
}

_stack_upgrade_unit() {
    case "${1:-}" in
        nginx)   echo nginx ;;
        mariadb) echo mariadb ;;
        pgsql)   echo postgresql ;;
        valkey)  echo valkey-server ;;
    esac
}

_stack_upgrade_notify_id() {
    case "${1:-}" in
        nginx)   echo nginx_upgrade ;;
        mariadb) echo mariadb_upgrade ;;
        pgsql)   echo pgsql_upgrade ;;
        valkey)  echo valkey_upgrade ;;
    esac
}

# Installed packages we are allowed to --only-upgrade. Scoped on purpose:
# a loose `mariadb` match would be fine, a loose `php` match would not.
_stack_upgrade_pkg_pattern() {
    case "${1:-}" in
        nginx)   echo '^nginx(-|$)' ;;
        mariadb) echo '^mariadb-' ;;
        pgsql)   echo '^postgresql' ;;
        valkey)  echo '^valkey' ;;
        *)       return 1 ;;
    esac
}

_stack_upgrade_list_pkgs() {
    local pattern
    pattern=$(_stack_upgrade_pkg_pattern "$1") || return 1
    dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null \
        | awk -v p="$pattern" '$1 == "installed" && $2 ~ p { print $2 }'
}

_stack_upgrade_present() {
    local unit
    unit=$(_stack_upgrade_unit "$1") || return 1
    systemd_unit_exists "$unit"
}

_stack_upgrade_version() {
    case "${1:-}" in
        nginx)
            nginx -v 2>&1 | sed -n 's/.*nginx\///p' | awk '{print $1}'
            ;;
        mariadb)
            mariadb --version 2>&1 | awk '{
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit }
                }
            }' | sed 's/[,].*//; s/-MariaDB.*//'
            ;;
        pgsql)
            psql --version 2>/dev/null | awk '{print $3}'
            ;;
        valkey)
            valkey-server --version 2>/dev/null | awk '{
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^v=/) { sub(/^v=/, "", $i); print $i; exit }
                    if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit }
                }
            }'
            ;;
    esac
}

_stack_upgrade_candidate() {
    local pkg
    pkg=$(_stack_upgrade_main_pkg "$1") || return 1
    apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2; exit}'
}

# Third-party repos Cipi already configured at install time. Re-assert them
# so a server whose sources were wiped still sees the same stream.
_stack_upgrade_ensure_repo() {
    case "${1:-}" in
        nginx)
            if ! declare -f nginx_setup_mainline_repo >/dev/null; then
                # shellcheck source=/dev/null
                source "${CIPI_LIB}/nginx.sh"
            fi
            nginx_setup_mainline_repo
            ;;
        mariadb)
            # shellcheck source=/dev/null
            source "${CIPI_LIB}/php-apt.sh"
            mariadb_setup_apt_repo || true
            ;;
    esac
}

# Prints the apt plan. Sets _STACK_UPGRADE_NEWLY to the Inst count
# (stdout is for the operator, so the caller cannot capture it).
_stack_upgrade_preview() {
    local sim newly space
    _STACK_UPGRADE_NEWLY=0
    sim=$(_stack_upgrade_apt install -s \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --only-upgrade "$@" 2>/dev/null) || return 1
    newly=$(grep -cE '^Inst ' <<< "$sim" || true)
    space=$(grep -E 'additional disk space|freed' <<< "$sim" | head -1 | sed 's/^[[:space:]]*//')
    echo ""
    echo -e "  ${BOLD}apt would upgrade ${newly} package(s)${NC}"
    [[ -n "$space" ]] && echo -e "  ${DIM}${space}${NC}"
    echo ""
    _STACK_UPGRADE_NEWLY="$newly"
}

# nginx: config test + reload (keep connections). DBs/Valkey: dpkg postinst
# usually restarts already — only start the unit if it came up stopped.
_stack_upgrade_reload() {
    local kind="$1" unit
    unit=$(_stack_upgrade_unit "$kind")
    case "$kind" in
        nginx)
            if ! nginx -t 2>&1; then
                error "nginx -t failed after the upgrade — the new packages are installed, fix the config before reloading"
                return 1
            fi
            reload_nginx
            ;;
        *)
            if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
                step "Starting ${unit}..."
                systemctl start "$unit" 2>/dev/null \
                    || { error "${unit} is not running after the upgrade"; return 1; }
            fi
            ;;
    esac
    return 0
}

_stack_upgrade_usage() {
    error "Use: cipi service upgrade <nginx|mariadb|postgresql|valkey> [--yes]"
    echo -e "  Also: ${CYAN}cipi nginx upgrade${NC}   ${CYAN}cipi db upgrade [mariadb|pgsql]${NC}"
    echo -e "  ${DIM}Patch-level only. PHP: cipi php upgrade. Cipi itself: cipi self-update.${NC}"
}

# Status of the four blacklisted components. Uses the current apt index
# (no update) so `cipi service upgrade` with no argument is a cheap look.
_stack_upgrade_status() {
    local kind unit ver cand label
    echo -e "\n${BOLD}Stack upgrades${NC} ${DIM}(manual — not unattended)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for kind in nginx mariadb pgsql valkey; do
        label=$(_stack_upgrade_label "$kind")
        if ! _stack_upgrade_present "$kind"; then
            printf "  ${DIM}○${NC} %-12s ${DIM}not installed${NC}\n" "$label"
            continue
        fi
        ver=$(_stack_upgrade_version "$kind")
        ver="${ver:-?}"
        cand=$(_stack_upgrade_candidate "$kind")
        if [[ -n "$cand" && "$cand" != "(none)" && "$cand" != "$ver" ]] \
           && [[ "$cand" != *"$ver"* ]]; then
            printf "  ${YELLOW}●${NC} %-12s ${CYAN}%s${NC}  ${DIM}candidate %s${NC}\n" "$label" "$ver" "$cand"
        else
            printf "  ${GREEN}●${NC} %-12s ${CYAN}%s${NC}\n" "$label" "$ver"
        fi
    done
    echo ""
    echo -e "  ${CYAN}cipi nginx upgrade${NC}"
    echo -e "  ${CYAN}cipi db upgrade [mariadb|pgsql]${NC}"
    echo -e "  ${CYAN}cipi service upgrade valkey${NC}"
    echo ""
    echo -e "  ${DIM}PHP patches: ${CYAN}cipi php upgrade${NC}${DIM} (Sunday 03:30). Cipi: ${CYAN}cipi self-update${NC}${DIM}.${NC}"
    echo ""
}

# Apply a patch upgrade for one component. `--yes` skips the prompt.
# Never accepts `all` — upgrading a database and nginx in the same breath
# is exactly what the blacklist exists to prevent.
_stack_upgrade() {
    local raw="${1:-}"; shift || true
    parse_args "$@"

    local kind
    kind=$(_stack_upgrade_normalize "$raw") || {
        _stack_upgrade_usage
        return 1
    }

    if ! _stack_upgrade_present "$kind"; then
        error "$(_stack_upgrade_label "$kind") is not installed"
        return 1
    fi

    (
        flock -n 9 || { info "A stack upgrade is already running — skip"; exit 0; }

        local label
        label=$(_stack_upgrade_label "$kind")

        step "Refreshing the package index..."
        _stack_upgrade_ensure_repo "$kind"
        if ! _stack_upgrade_apt update -qq; then
            error "apt-get update failed — cannot check for ${label} upgrades"
            exit 1
        fi

        local -a installed=()
        local pkg
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] && installed+=("$pkg")
        done < <(_stack_upgrade_list_pkgs "$kind")
        if [[ ${#installed[@]} -eq 0 ]]; then
            error "No ${label} packages found in dpkg"
            exit 1
        fi

        local before after newly
        before=$(_stack_upgrade_version "$kind")
        before="${before:-unknown}"

        echo -e "  ${DIM}${label} ${before}${NC}"
        _stack_upgrade_preview "${installed[@]}" || {
            error "apt cannot resolve an upgrade for: ${installed[*]}"
            exit 1
        }
        newly="${_STACK_UPGRADE_NEWLY:-0}"

        if [[ "${newly:-0}" -eq 0 ]]; then
            info "${label} packages are up to date (${before})"
            exit 0
        fi

        if [[ "${ARG_yes:-}" != "true" && "${ARG_force:-}" != "true" ]]; then
            local prompt="Upgrade ${label} now?"
            case "$kind" in
                mariadb|pgsql)
                    prompt="Upgrade ${label}? This restarts the database (brief downtime)."
                    ;;
                valkey)
                    prompt="Upgrade ${label}? This restarts the cache."
                    ;;
                nginx)
                    prompt="Upgrade ${label}? Config is tested, then nginx is reloaded."
                    ;;
            esac
            confirm "$prompt" || { info "Aborted"; exit 0; }
        fi

        step "Upgrading ${label} packages..."
        local out rc=0
        out=$(_stack_upgrade_apt install -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            --only-upgrade "${installed[@]}" 2>&1) || rc=$?
        echo "$out"
        if [[ "$rc" -ne 0 ]]; then
            error "${label} upgrade failed"
            exit 1
        fi

        _stack_upgrade_reload "$kind" || exit 1

        after=$(_stack_upgrade_version "$kind")
        after="${after:-unknown}"

        log_action "STACK UPGRADE: ${kind} ${before} → ${after} (${newly} package(s))"
        cipi_notify \
            "Cipi ${label} upgraded on $(hostname)" \
            "${label} packages were upgraded.\n\nServer: $(hostname)\nFrom: ${before}\nTo: ${after}\nPackages upgraded: ${newly}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            "$(_stack_upgrade_notify_id "$kind")"
        success "${label} upgraded (${before} → ${after})"
        exit 0
    ) 9>/run/cipi-stack-upgrade.lock
}

# cipi db upgrade [mariadb|pgsql] [--yes]
# No engine → every installed engine, one after the other.
_stack_upgrade_db() {
    parse_args "$@"
    local raw="" arg
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        raw="$arg"
        break
    done

    if [[ -n "$raw" ]]; then
        local engine
        engine=$(db_normalize_engine "$raw" 2>/dev/null) || {
            error "Usage: cipi db upgrade [mariadb|pgsql] [--yes]"
            return 1
        }
        _stack_upgrade "$engine" "$@"
        return $?
    fi

    local did=0 rc=0
    if _stack_upgrade_present mariadb; then
        _stack_upgrade mariadb "$@" || rc=$?
        did=1
    fi
    if _stack_upgrade_present pgsql; then
        _stack_upgrade pgsql "$@" || rc=$?
        did=1
    fi
    if [[ "$did" -eq 0 ]]; then
        error "No database engine installed"
        return 1
    fi
    return "$rc"
}

# cipi service upgrade [name] [--yes]
_stack_upgrade_service() {
    local raw="" arg
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        raw="$arg"
        break
    done

    if [[ -z "$raw" ]]; then
        _stack_upgrade_status
        return 0
    fi

    case "$raw" in
        php|php-fpm|php*-fpm)
            error "PHP is upgraded separately: cipi php upgrade"
            echo -e "  ${DIM}Weekly cron, Sunday 03:30. Not part of this command.${NC}"
            return 1
            ;;
        all)
            error "Refusing to upgrade every service at once"
            echo -e "  ${DIM}Name one: nginx, mariadb, postgresql, valkey.${NC}"
            return 1
            ;;
    esac

    _stack_upgrade "$raw" "$@"
}
