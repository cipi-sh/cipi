#!/bin/bash
#############################################
# Cipi Migration 5.11.0
#
# Metrics & health history, and cipi/agent behind basic auth.
#
#  1. sqlite3 (the CLI): the metrics are kept in SQLite. Installed with apt
#     when missing; when apt cannot, the collector waits for it quietly and
#     `cipi metrics status` says what to run.
#  2. /usr/local/bin/cipi-metrics, /var/lib/cipi-metrics (root:www-data 0750)
#     and /etc/cron.d/cipi-metrics (every minute). The configuration starts
#     on the defaults — raw 7 days, 15-minute rollups 30 days, events 90 days,
#     healthcheck probed every minute — without a file: `cipi metrics
#     retention` writes one when it is changed.
#  3. The panel's sudoers: cipi metrics overview|status|show|uptime|events|
#     retention|probe|enable|disable|heartbeat, cipi basicauth agent. Not
#     openmetrics (it opens a port), prune or reset.
#  4. Apps with basic auth: when the live release has cipi/agent, its routes
#     are left out of basic auth from now on (they check their own tokens).
#     Each such vhost is rewritten once here; `cipi basicauth agent <app>
#     protected` puts them back behind it.
#
# Nothing restarts but nginx (a reload, only when a vhost changed). Nothing
# listens on a new port. Each step tolerates failure and says so.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.11.0 — metrics & health history, cipi/agent behind basic auth..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/metrics.sh"

# ── 1. sqlite3 ───────────────────────────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
    echo "  sqlite3 present"
elif DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq sqlite3 >/dev/null 2>&1 \
     || { DEBIAN_FRONTEND=noninteractive timeout 300 apt-get update -qq >/dev/null 2>&1 \
          && DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq sqlite3 >/dev/null 2>&1; }; then
    echo "  sqlite3 installed"
else
    echo "  WARNING: could not install sqlite3 — nothing is collected until: apt-get install -y sqlite3"
fi

# ── 2. collector ─────────────────────────────────────────────
HELPER="${METRICS_HELPER}"
if [[ -f "${CIPI_LIB}/cipi-metrics.sh" ]] \
   && install -m 755 -o root -g root "${CIPI_LIB}/cipi-metrics.sh" "$HELPER" 2>/dev/null; then
    echo "  ${HELPER} installed"
else
    echo "  WARNING: could not install ${HELPER}"
fi
if install -d -m 750 -o root -g www-data "$METRICS_DIR" 2>/dev/null || mkdir -p "$METRICS_DIR" 2>/dev/null; then
    if command -v sqlite3 >/dev/null 2>&1; then
        _met_db_init && echo "  ${METRICS_DB} ready" || echo "  WARNING: could not create ${METRICS_DB}"
    fi
else
    echo "  WARNING: could not create ${METRICS_DIR}"
fi
if [[ -f "$METRICS_CRON" ]]; then
    echo "  ${METRICS_CRON} present"
elif cat > "$METRICS_CRON" 2>/dev/null <<EOF
# Cipi metrics & health history (every minute) — cipi metrics
* * * * * root ${HELPER} >/dev/null 2>&1
EOF
then
    chmod 644 "$METRICS_CRON" 2>/dev/null || true
    echo "  ${METRICS_CRON} written — the first values arrive within a minute"
else
    echo "  WARNING: could not write ${METRICS_CRON}"
fi

# ── 3. Panel sudoers ─────────────────────────────────────────
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if _cipi_panel_installed; then
        prev=""
        if [[ -f /etc/sudoers.d/cipi-api ]]; then
            prev=$(mktemp 2>/dev/null) && cat /etc/sudoers.d/cipi-api > "$prev" 2>/dev/null || prev=""
        fi
        write_cipi_api_sudoers 2>/dev/null || true
        if ! command -v visudo >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api (visudo not available to check it)"
        elif visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api — the panel may also run: metrics (read, retention, probe, heartbeat), basicauth agent"
        elif [[ -n "$prev" ]]; then
            install -m 0440 "$prev" /etc/sudoers.d/cipi-api 2>/dev/null || true
            echo "  WARNING: the new /etc/sudoers.d/cipi-api did not validate — the previous file was put back. Check: visudo -cf /etc/sudoers.d/cipi-api"
        else
            rm -f /etc/sudoers.d/cipi-api
            echo "  WARNING: /etc/sudoers.d/cipi-api did not validate and was removed — the panel cannot run cipi until: cipi api update"
        fi
        [[ -n "$prev" ]] && rm -f "$prev"
    else
        ensure_cipi_api_sudoers || true
    fi
fi

# ── 4. basic auth + cipi/agent ───────────────────────────────
# shellcheck source=/dev/null
source "${CIPI_LIB}/app.sh"
changed=0
apps=$(vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select(.value.basic_auth == "true") | .key' 2>/dev/null || true)
if [[ -z "$apps" ]]; then
    echo "  no app with basic auth"
else
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        want=$(_basicauth_agent_prefix "$app" 2>/dev/null || true)
        if [[ -z "$want" ]]; then
            echo "  ${app}: basic auth on, no cipi/agent in the live release — unchanged"
            continue
        fi
        [[ "$(_basicauth_agent_in_vhost "$app")" == "$want" ]] && { echo "  ${app}: /${want}/ already public"; continue; }
        if _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)" >/dev/null 2>&1; then
            changed=$(( changed + 1 ))
            echo "  ${app}: /${want}/ (cipi/agent) left out of basic auth — to keep it protected: cipi basicauth agent ${app} protected"
        else
            echo "  WARNING: ${app}: could not rewrite its vhost"
        fi
    done <<< "$apps"
    if (( changed > 0 )); then
        if reload_nginx >/dev/null 2>&1; then
            echo "  nginx reloaded"
        else
            echo "  WARNING: nginx -t refused the new configuration — check: nginx -t"
        fi
    fi
fi

echo ""
echo "  See it: cipi metrics · cipi metrics uptime · cipi metrics show --app=<app> --range=7d"
echo "  An outside check of the server itself: cipi metrics heartbeat set <url>"
echo "Migration 5.11.0 complete"
