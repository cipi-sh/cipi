#!/bin/bash
#############################################
# Cipi — Worker Helper (sudoers-restricted)
#############################################
set -euo pipefail
ACTION="${1:-}"; APP="${2:-}"
[[ -z "$ACTION" || -z "$APP" ]] && { echo "Usage: cipi-worker {restart|stop|status} <app>"; exit 1; }
CALLER=$(logname 2>/dev/null || whoami)
[[ "$CALLER" != "root" && "$CALLER" != "$APP" ]] && { echo "Permission denied"; exit 1; }

_restart_workers() {
    local conf="/etc/supervisor/conf.d/${APP}.conf"
    [[ ! -f "$conf" ]] && return 0
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
    for group in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//'); do
        supervisorctl restart "${group}:*" 2>/dev/null || true
    done
}

_stop_workers() {
    local conf="/etc/supervisor/conf.d/${APP}.conf"
    [[ ! -f "$conf" ]] && return 0
    for group in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//'); do
        supervisorctl stop "${group}:*" 2>/dev/null || true
    done
}

case "$ACTION" in
    restart) _restart_workers ;;
    stop)    _stop_workers ;;
    status)  supervisorctl status "${APP}-worker-"* 2>/dev/null || echo "No workers" ;;
    *) echo "Use: restart|stop|status"; exit 1 ;;
esac
