#!/bin/bash
#############################################
# Cipi — Queue Workers (Supervisor)
#############################################

worker_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        add)     _worker_add "$@" ;;
        list|ls) _worker_list "$@" ;;
        remove)  _worker_remove "$@" ;;
        stop)    _worker_stop "$@" ;;
        restart) _worker_restart "$@" ;;
        edit)    _worker_edit "$@" ;;
        *) error "Use: add list remove stop restart edit"; exit 1 ;;
    esac
}

_worker_add() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi worker add <app> [--queue=Q] [--processes=N]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local queue="${ARG_queue:-}" procs="${ARG_processes:-1}" tries="${ARG_tries:-3}" timeout="${ARG_timeout:-3600}"
    [[ -z "$queue" ]] && read_input "Queue name" "" queue
    [[ -z "$queue" ]] && { error "Queue name required"; exit 1; }
    grep -q "\[program:${app}-worker-${queue}\]" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null && \
        { error "Worker '${queue}' already exists"; exit 1; }
    local v; v=$(app_get "$app" php)
    _create_supervisor_worker "$app" "$v" "$queue" "$procs" "$tries" "$timeout"
    reload_supervisor
    supervisorctl start "${app}-worker-${queue}:*" 2>/dev/null
    log_action "WORKER ADD: $app queue=$queue procs=$procs"
    success "Worker '${queue}' added (${procs} processes)"
}

_worker_list() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker list <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ ! -f "$conf" ]] && { info "No workers"; return; }
    echo -e "\n${BOLD}Workers for '${app}'${NC}"
    printf "  ${BOLD}%-28s %-10s %-6s %s${NC}\n" "PROGRAM" "QUEUE" "PROCS" "STATUS"
    grep "^\[program:" "$conf" | sed 's/\[program://;s/\]//' | while read -r prog; do
        local q; q=$(echo "$prog"|sed "s/${app}-worker-//")
        local np; np=$(grep -A20 "\[program:${prog}\]" "$conf"|grep numprocs|head -1|cut -d= -f2)
        local st; st=$(supervisorctl status "${prog}:*" 2>/dev/null|head -1|awk '{print $2}'||echo "?")
        local c="${GREEN}"; [[ "$st" != "RUNNING" ]] && c="${RED}"
        printf "  %-28s %-10s %-6s ${c}%s${NC}\n" "$prog" "$q" "${np:-1}" "$st"
    done; echo ""
}

_worker_remove() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi worker remove <app> <queue>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local queue="${ARG_queue:-${1:-}}"
    [[ -z "$queue" ]] && { error "Queue name required"; exit 1; }
    [[ "$queue" == "default" ]] && confirm "Remove default worker?" || { [[ "$queue" == "default" ]] && return; }
    supervisorctl stop "${app}-worker-${queue}:*" 2>/dev/null||true
    local conf="/etc/supervisor/conf.d/${app}.conf" tmp; tmp=$(mktemp)
    awk -v p="[program:${app}-worker-${queue}]" '$0==p{s=1;next}/^\[program:/{s=0}!s' "$conf">"$tmp"
    mv "$tmp" "$conf"; [[ ! -s "$conf" ]] && rm -f "$conf"
    reload_supervisor
    log_action "WORKER REMOVE: $app queue=$queue"
    success "Worker '${queue}' removed"
}

_worker_stop() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker stop <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    supervisorctl stop "${app}-worker-*" 2>/dev/null||true
    success "Workers stopped for '${app}'"
}

_worker_restart() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker restart <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    supervisorctl restart "${app}-worker-*" 2>/dev/null||true
    success "Workers restarted for '${app}'"
}

_worker_edit() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi worker edit <app> --queue=Q --processes=N"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local queue="${ARG_queue:-}" procs="${ARG_processes:-}"
    [[ -z "$queue" ]] && { error "Need --queue"; exit 1; }
    local conf="/etc/supervisor/conf.d/${app}.conf"
    grep -q "\[program:${app}-worker-${queue}\]" "$conf" 2>/dev/null || { error "Worker '${queue}' not found"; exit 1; }
    if [[ -n "$procs" ]]; then
        local tmp; tmp=$(mktemp)
        awk -v p="[program:${app}-worker-${queue}]" -v n="numprocs=${procs}" \
            '$0==p{b=1}/^\[program:/&&$0!=p{b=0} b&&/^numprocs=/{$0=n}{print}' "$conf">"$tmp"
        mv "$tmp" "$conf"; reload_supervisor
        supervisorctl restart "${app}-worker-${queue}:*" 2>/dev/null
        success "Worker '${queue}' → ${procs} processes"
    fi
}
