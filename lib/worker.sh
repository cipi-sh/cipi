#!/bin/bash
#############################################
# Cipi — Queue Workers (Supervisor)
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

worker_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        add)     _worker_add "$@" ;;
        list|ls) _worker_list "$@" ;;
        remove)  _worker_remove "$@" ;;
        stop)    _worker_stop "$@" ;;
        restart) _worker_restart "$@" ;;
        edit)    _worker_edit "$@" ;;
        horizon) _worker_horizon "$@" ;;
        *) error "Use: add list remove stop restart edit horizon"; exit 1 ;;
    esac
}

_worker_horizon() {
    local action="${1:-}"; shift || true
    case "$action" in
        enable)  _horizon_enable "$@" ;;
        disable) _horizon_disable "$@" ;;
        status)  _horizon_status "$@" ;;
        *) error "Usage: cipi worker horizon enable|disable|status <app>"; exit 1 ;;
    esac
}

_horizon_enable() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi worker horizon enable <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    [[ "$(app_get "$app" custom)" == "true" ]] && { error "Horizon is only for Laravel apps"; exit 1; }
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        info "Horizon already enabled for '${app}'"
        _horizon_status "$app"
        return 0
    fi

    local php_ver conf
    php_ver=$(app_get "$app" php)
    [[ -z "$php_ver" ]] && { error "App config incomplete (php). Run: cipi app edit ${app}"; exit 1; }
    conf="/etc/supervisor/conf.d/${app}.conf"
    [[ -f "$conf" ]] || echo "" > "$conf"

    step "Enabling Horizon for '${app}' (replaces queue:work workers)..."
    # Stop and remove all queue:work programs
    local prog
    for prog in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//' | grep -- "-worker-" || true); do
        supervisorctl stop "${prog}:"* 2>/dev/null || true
        _supervisor_remove_program "$app" "$prog"
    done
    _supervisor_remove_program "$app" "${app}-horizon"
    _create_supervisor_horizon "$app" "$php_ver"
    # Keep octane/reverb programs intact (they are separate)

    # `reload_supervisor` returns 1 when supervisorctl reread/update complains
    # (a common, usually harmless condition). Under `set -e` that aborted the
    # function right here: the supervisor program was written but apps.json was
    # never updated, so `enable` printed nothing and `status` still said
    # "disabled". Never let a supervisor hiccup skip the state write.
    local reload_rc=0
    reload_supervisor || reload_rc=$?
    supervisorctl start "${app}-horizon" 2>/dev/null || true

    app_set "$app" horizon "true"
    app_unset "$app" horizon_auto
    log_action "HORIZON ENABLE: $app"

    # Report what supervisor actually did, rather than assuming it worked.
    local state; state=$(_horizon_supervisor_state "$app")
    if [[ "$state" == "RUNNING" ]]; then
        success "Horizon enabled and running for '${app}'"
    else
        success "Horizon enabled for '${app}'"
        warn "Supervisor reports '${app}-horizon' as ${state:-UNKNOWN}."
        if (( reload_rc != 0 )); then
            warn "supervisorctl reread/update reported a problem — check: supervisorctl status"
        fi
        warn "Horizon starts once the app has been deployed, laravel/horizon is required"
        warn "in composer.json, and QUEUE_CONNECTION=redis is set in .env."
        warn "Log: /home/${app}/logs/horizon.log"
    fi
    info "Use QUEUE_CONNECTION=redis (Valkey) in .env. Require laravel/horizon in the app."
}

# Supervisor's own view of the program: RUNNING, STOPPED, FATAL, NOT-FOUND, ...
_horizon_supervisor_state() {
    local app="$1" line
    line=$(supervisorctl status "${app}-horizon" 2>/dev/null | head -1 || true)
    [[ -z "$line" ]] && { echo "NOT-FOUND"; return 0; }
    echo "$line" | awk '{print $2}'
}

_horizon_disable() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi worker horizon disable <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    if [[ "$(app_get "$app" horizon)" != "true" ]]; then
        info "Horizon already disabled for '${app}'"
        return 0
    fi

    local php_ver
    php_ver=$(app_get "$app" php)
    step "Disabling Horizon for '${app}'..."
    supervisorctl stop "${app}-horizon" 2>/dev/null || true
    _supervisor_remove_program "$app" "${app}-horizon"
    # Restore default queue:work worker
    if ! grep -q "\[program:${app}-worker-default\]" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null; then
        [[ -f "/etc/supervisor/conf.d/${app}.conf" ]] || echo "" > "/etc/supervisor/conf.d/${app}.conf"
        _create_supervisor_worker "$app" "$php_ver" "default"
    fi
    # Same guard as _horizon_enable: a supervisor hiccup must not leave
    # apps.json claiming Horizon is still on.
    reload_supervisor || warn "supervisorctl reread/update reported a problem — check: supervisorctl status"
    app_unset "$app" horizon
    # Someone decided: a deploy that finds laravel/horizon installed does
    # not switch it on again (_deploy_horizon_detect in deploy.sh).
    app_set "$app" horizon_auto "off"
    log_action "HORIZON DISABLE: $app"
    success "Horizon disabled — default queue worker restored"
}

_horizon_status() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi worker horizon status <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local configured state
    configured=$(app_get "$app" horizon)
    state=$(_horizon_supervisor_state "$app")

    if [[ "$configured" == "true" ]]; then
        echo -e "  Horizon: ${GREEN}enabled${NC}"
    else
        echo -e "  Horizon: ${DIM}disabled${NC}"
    fi
    echo -e "  Supervisor: ${CYAN}${state}${NC}"
    supervisorctl status "${app}-horizon" 2>/dev/null | sed 's/^/  /' || true

    # Surface drift between what apps.json claims and what supervisor holds —
    # the state that used to be reachable when enable aborted halfway.
    if [[ "$configured" == "true" && "$state" == "NOT-FOUND" ]]; then
        warn "Config says enabled but supervisor has no '${app}-horizon' program."
        warn "Repair: cipi worker horizon disable ${app} && cipi worker horizon enable ${app}"
    elif [[ "$configured" != "true" && "$state" != "NOT-FOUND" ]]; then
        warn "Supervisor still runs '${app}-horizon' but config says disabled."
        warn "Repair: cipi worker horizon disable ${app}"
    elif [[ "$configured" == "true" && "$state" == "FATAL" ]]; then
        warn "Horizon keeps crashing — check /home/${app}/logs/horizon.log"
        warn "Common causes: laravel/horizon not installed, no deploy yet, QUEUE_CONNECTION not redis."
    fi
}

_worker_add() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi worker add <app> [--queue=Q] [--processes=N]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        error "Horizon is enabled for '${app}'. Disable it first: cipi worker horizon disable ${app}"
        exit 1
    fi
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
    cipi_notify \
        "Cipi worker added: ${app} (${queue}) on $(hostname)" \
        "A queue worker was added.\n\nServer: $(hostname)\nApp: ${app}\nQueue: ${queue}\nProcesses: ${procs}\nTime: $(notify_now)" \
        worker_add
    success "Worker '${queue}' added (${procs} processes)"
}

_worker_list() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker list <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ ! -f "$conf" ]] && { info "No workers"; return; }
    echo -e "\n${BOLD}Workers for '${app}'${NC}"
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        echo -e "  ${CYAN}Mode: Horizon${NC}"
    fi
    tbl_start
    tbl_head "PROGRAM" "QUEUE" "PROCS" "STATUS"
    local prog q np st c
    while read -r prog; do
        [[ -n "$prog" ]] || continue
        if [[ "$prog" == "${app}-horizon" ]]; then
            q="horizon"
        elif [[ "$prog" == "${app}-octane" ]]; then
            q="octane"
        elif [[ "$prog" == "${app}-reverb" ]]; then
            q="reverb"
        else
            q=$(echo "$prog"|sed "s/${app}-worker-//")
        fi
        np=$(grep -A20 "\[program:${prog}\]" "$conf"|grep numprocs|head -1|cut -d= -f2)
        st=$(supervisorctl status "${prog}:*" 2>/dev/null|head -1|awk '{print $2}'||echo "?")
        [[ -z "$st" || "$st" == "?" ]] && st=$(supervisorctl status "${prog}" 2>/dev/null|awk '{print $2}'||echo "?")
        c="${GREEN}"; [[ "$st" != "RUNNING" ]] && c="${RED}"
        tbl_row "$prog" "$q" "${np:-1}" "${c}${st}${NC}"
    done < <(grep "^\[program:" "$conf" | sed 's/\[program://;s/\]//')
    tbl_print
    echo ""
}

_worker_remove() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi worker remove <app> <queue>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        error "Horizon is enabled. Use: cipi worker horizon disable ${app}"
        exit 1
    fi
    parse_args "$@"
    local queue="${ARG_queue:-${1:-}}"
    [[ -z "$queue" ]] && { error "Queue name required"; exit 1; }
    [[ "$queue" == "default" ]] && confirm "Remove default worker?" || { [[ "$queue" == "default" ]] && return; }
    supervisorctl stop "${app}-worker-${queue}:*" 2>/dev/null||true
    _supervisor_remove_program "$app" "${app}-worker-${queue}"
    reload_supervisor
    log_action "WORKER REMOVE: $app queue=$queue"
    cipi_notify \
        "Cipi worker removed: ${app} (${queue}) on $(hostname)" \
        "A queue worker was removed.\n\nServer: $(hostname)\nApp: ${app}\nQueue: ${queue}\nTime: $(notify_now)" \
        worker_remove
    success "Worker '${queue}' removed"
}

_worker_stop() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker stop <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        supervisorctl stop "${app}-horizon" 2>/dev/null||true
    else
        supervisorctl stop "${app}-worker-*" 2>/dev/null||true
    fi
    success "Workers stopped for '${app}'"
}

_worker_restart() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi worker restart <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        supervisorctl restart "${app}-horizon" 2>/dev/null||true
    else
        supervisorctl restart "${app}-worker-*" 2>/dev/null||true
    fi
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
