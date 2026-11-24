#!/bin/bash
#############################################
# Cipi — Worker Helper (sudoers-restricted)
#
# What a deploy runs, as the app user through sudo, around the switch of
# `current` (lib/deployer/laravel*.php): `stop` before it, `restart` after.
#
# Deployer swaps `current` atomically (mv -T), so nothing has to stop before
# the swap. `stop` ran `supervisorctl stop` on every program of the app, which
# waits for each one to exit — up to stopwaitsecs, an hour for Horizon and the
# queue workers so that a running job can finish — while Deployer gives a
# command 300 seconds. With a long job in progress the deploy failed on
# workers:stop (exit 255), Horizon stayed in STOPPING with nothing to start it
# again, and every other deploy waited for the jobs in hand (#536).
#
#   stop     changes nothing any more: kept for the deploy.php files that call it.
#   restart  after the swap, without waiting for the jobs in progress:
#            - Horizon and the queue workers get SIGTERM: they finish the job
#              in hand and exit, and Supervisor (autorestart) starts them
#              again, on the new release;
#            - Octane, Reverb and any other program are restarted, waiting
#              CIPI_WORKER_RESTART_WAIT seconds at most for each;
#            - a program that is not running is started; one still STOPPING
#              is started in the background as soon as it has stopped.
#   status   unchanged.
#############################################
set -euo pipefail
ACTION="${1:-}"; APP="${2:-}"
[[ -z "$ACTION" || -z "$APP" ]] && { echo "Usage: cipi-worker {restart|stop|status} <app>"; exit 1; }
CALLER=$(logname 2>/dev/null || whoami)
[[ "$CALLER" != "root" && "$CALLER" != "$APP" ]] && { echo "Permission denied"; exit 1; }
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "Invalid app name"; exit 1; }

CONF="${CIPI_SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}/${APP}.conf"
RESTART_WAIT="${CIPI_WORKER_RESTART_WAIT:-90}"
[[ "$RESTART_WAIT" =~ ^[0-9]+$ ]] || RESTART_WAIT=90

# "<process name> <state>" for every process of the app's programs.
_processes() {
    local programs p
    programs=$(grep '^\[program:' "$CONF" 2>/dev/null | sed 's/\[program://;s/\]//' || true)
    [[ -n "$programs" ]] || return 0
    supervisorctl status 2>/dev/null | awk '{ print $1, $2 }' | while read -r name state; do
        for p in $programs; do
            if [[ "$name" == "$p" || "$name" == "${p}:"* ]]; then
                echo "$name $state"
                break
            fi
        done
    done || true
}

# Jobs in hand finish first: a worker that gets SIGTERM ends after its job.
_graceful() {   # <process name>
    case "$1" in
        "${APP}-horizon"|"${APP}-horizon:"*|"${APP}-worker-"*) return 0 ;;
        *) return 1 ;;
    esac
}

# In the background, detached from the deploy: start the program as soon as
# Supervisor has finished stopping it (stopwaitsecs at most).
_start_when_stopped() {   # <process name>
    setsid bash -c '
        for _ in $(seq 1 3700); do
            s=$(supervisorctl status "$1" 2>/dev/null | awk "{ print \$2 }")
            case "$s" in
                STOPPED|EXITED|FATAL) supervisorctl start "$1" >/dev/null 2>&1; exit 0 ;;
                STOPPING) sleep 1 ;;
                *) exit 0 ;;
            esac
        done' _ "$1" </dev/null >/dev/null 2>&1 &
}

_restart_workers() {
    [[ -f "$CONF" ]] || return 0
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true
    local name state
    while read -r name state; do
        [[ -n "$name" ]] || continue
        case "$state" in
            RUNNING|STARTING)
                if _graceful "$name"; then
                    supervisorctl signal TERM "$name" >/dev/null 2>&1 \
                        && echo "${name}: finishing its job, then starts again on the new release" \
                        || echo "${name}: could not be signalled" >&2
                elif timeout "$RESTART_WAIT" supervisorctl restart "$name" >/dev/null 2>&1; then
                    echo "${name}: restarted"
                else
                    echo "${name}: still stopping after ${RESTART_WAIT}s — it starts as soon as it has stopped"
                    _start_when_stopped "$name"
                fi
                ;;
            STOPPING)
                echo "${name}: still stopping — it starts as soon as it has stopped"
                _start_when_stopped "$name"
                ;;
            STOPPED|EXITED|FATAL)
                timeout "$RESTART_WAIT" supervisorctl start "$name" >/dev/null 2>&1 \
                    && echo "${name}: started" || echo "${name}: did not start — supervisorctl status ${name}" >&2
                ;;
            *)  # BACKOFF: Supervisor is already starting it again, from the new release.
                echo "${name}: ${state}"
                ;;
        esac
    done < <(_processes)
    return 0
}

case "$ACTION" in
    restart) _restart_workers ;;
    stop)    echo "cipi-worker: nothing to stop — current is swapped atomically, and the workers reload after it" ;;
    status)
        supervisorctl status "${APP}-worker-"* 2>/dev/null || true
        supervisorctl status "${APP}-octane" 2>/dev/null || true
        supervisorctl status "${APP}-reverb" 2>/dev/null || true
        supervisorctl status "${APP}-horizon" 2>/dev/null || true
        if ! supervisorctl status "${APP}-worker-"* &>/dev/null \
           && ! supervisorctl status "${APP}-octane" &>/dev/null \
           && ! supervisorctl status "${APP}-reverb" &>/dev/null \
           && ! supervisorctl status "${APP}-horizon" &>/dev/null; then
            echo "No workers"
        fi
        ;;
    *) echo "Use: restart|stop|status"; exit 1 ;;
esac
