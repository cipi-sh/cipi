#!/bin/bash
#############################################
# Cipi — Service Management
#############################################

readonly CIPI_SERVICES=(nginx mariadb valkey-server supervisor fail2ban)

_svc_label() {
    local svc="$1"
    printf "%-20s" "$svc"
}

_svc_status_line() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        local since; since=$(systemctl show "$svc" --property=ActiveEnterTimestamp --value 2>/dev/null | sed 's/ [A-Z]*$//')
        printf "  $(_svc_label "$svc") ${GREEN}● running${NC}"
        [[ -n "$since" ]] && printf "  ${DIM}since %s${NC}" "$since"
        echo
    elif systemd_unit_exists "$svc"; then
        printf "  $(_svc_label "$svc") ${RED}● stopped${NC}\n"
    else
        printf "  $(_svc_label "$svc") ${DIM}● not installed${NC}\n"
    fi
}

_resolve_services() {
    local name="$1"
    case "$name" in
        all|"")
            local list=("${CIPI_SERVICES[@]}")
            systemd_unit_exists postgresql && list+=("postgresql")
            systemd_unit_exists crowdsec && list+=("crowdsec")
            systemd_unit_exists crowdsec-firewall-bouncer && list+=("crowdsec-firewall-bouncer")
            for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
                systemd_unit_exists "php${v}-fpm" && list+=("php${v}-fpm")
            done
            echo "${list[@]}"
            ;;
        php)
            for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
                systemd_unit_exists "php${v}-fpm" && echo -n "php${v}-fpm "
            done
            ;;
        nginx|mariadb|valkey-server|supervisor|fail2ban|postgresql|crowdsec|crowdsec-firewall-bouncer)
            echo "$name"
            ;;
        pgsql|postgres)
            echo "postgresql"
            ;;
        redis-server|valkey|redis)
            echo "valkey-server"
            ;;
        php*-fpm)
            echo "$name"
            ;;
        *)
            error "Unknown service: ${name}"
            echo -e "  Valid names: ${CYAN}nginx mariadb postgresql valkey-server supervisor fail2ban crowdsec php<ver>-fpm all${NC}" >&2
            return 1
            ;;
    esac
}

service_status() {
    parse_args "$@"
    local target="all"
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        target="$arg"
        break
    done
    local services; services=$(_resolve_services "$target") || return 1

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]"
        for svc in $services; do
            local st="not_installed"
            local since=""
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                st="running"
                since=$(systemctl show "$svc" --property=ActiveEnterTimestamp --value 2>/dev/null | sed 's/ [A-Z]*$//')
            elif systemd_unit_exists "$svc"; then
                st="stopped"
            fi
            items=$(echo "$items" | jq -c --arg n "$svc" --arg s "$st" --arg since "$since" \
                '. + [{name:$n, status:$s, since:(if $since == "" then null else $since end)}]')
        done
        jq -n --argjson services "$items" '{services: $services}'
        return 0
    fi

    echo -e "\n${BOLD}Services${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for svc in $services; do
        _svc_status_line "$svc"
    done
    echo
}

service_restart() {
    local target="${1:-all}"
    local services; services=$(_resolve_services "$target") || return 1

    for svc in $services; do
        if ! systemd_unit_exists "$svc"; then
            warn "Service ${svc} is not installed — skipping"
            continue
        fi
        step "Restarting ${svc}..."
        if [[ "$svc" == "nginx" ]]; then
            reload_nginx && success "${svc} reloaded" || error "Failed to reload ${svc}"
        else
            systemctl restart "$svc" 2>/dev/null \
                && success "${svc} restarted" \
                || error "Failed to restart ${svc}"
        fi
        log_action "service restart ${svc}"
        cipi_notify \
            "Cipi service restarted: ${svc} on $(hostname)" \
            "A system service was restarted.\n\nServer: $(hostname)\nService: ${svc}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            service_restart
    done
}

service_start() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { error "Usage: cipi service start <service>"; return 1; }
    _resolve_services "$svc" > /dev/null || return 1

    step "Starting ${svc}..."
    systemctl start "$svc" 2>/dev/null \
        && success "${svc} started" \
        || error "Failed to start ${svc}"
    log_action "service start ${svc}"
    cipi_notify \
        "Cipi service started: ${svc} on $(hostname)" \
        "A system service was started.\n\nServer: $(hostname)\nService: ${svc}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        service_start
}

service_stop() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && { error "Usage: cipi service stop <service>"; return 1; }
    _resolve_services "$svc" > /dev/null || return 1

    [[ "$svc" == "nginx" ]] && warn "Stopping nginx will make all sites unreachable"
    confirm "Stop ${svc}?" || { info "Aborted"; return 0; }

    step "Stopping ${svc}..."
    systemctl stop "$svc" 2>/dev/null \
        && success "${svc} stopped" \
        || error "Failed to stop ${svc}"
    log_action "service stop ${svc}"
    cipi_notify \
        "Cipi service stopped: ${svc} on $(hostname)" \
        "A system service was stopped.\n\nServer: $(hostname)\nService: ${svc}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        service_stop
}

service_command() {
    local subcmd="${1:-list}"; shift || true

    case "$subcmd" in
        list|status)  service_status  "$@" ;;
        restart)      service_restart "${1:-all}" ;;
        start)        service_start   "${1:-}" ;;
        stop)         service_stop    "${1:-}" ;;
        *)
            error "Unknown service subcommand: ${subcmd}"
            echo -e "  Usage: ${CYAN}cipi service <list|restart|start|stop> [service] [--json]${NC}"
            exit 1
            ;;
    esac
}
