#!/bin/bash
#############################################
# Cipi Migration 5.9.0 — what the panel may run
#
#  1. Rewrites /etc/sudoers.d/cipi-api on servers where the panel API or the
#     GUI is installed, so that www-data may run what the new pages of the
#     panel are made of (cipi/api ≥ 1.39.0, cipi/gui ≥ 4.2.0):
#       cipi node install|default|upgrade|remove      Node runtimes
#       cipi db link|unlink                           a database shown as an app's
#       cipi backup status --json, list --json        the backup page
#       cipi backup run --detach, verify              a run in the background
#       cipi backup profile add|edit|remove|enable|disable
#       cipi backup destination test
#     `cipi deploy` was already there: the deploy history (`cipi deploy
#     --history <app>`) and every app's last deploy (`cipi deploy --last`) need
#     no new rule. A server with neither panel has no such file and gets none
#     (5.8.6).
#  2. Makes sure www-data can reach the directory the panel API keeps
#     uploaded database dumps in: nothing to do — it is in the API's own
#     storage, and `cipi db restore` opens a file found there as www-data.
#
# Nothing else changes on the server. The Horizon detection, the deploy
# history and the database links are code, and take effect with the files.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.9.0 — panel sudoers (Node runtimes, backup profiles, database links)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if declare -f ensure_cipi_api_sudoers >/dev/null 2>&1 && _cipi_panel_installed; then
        # Kept aside: a file sudo refuses to parse disables sudo for everyone.
        prev=""
        if [[ -f /etc/sudoers.d/cipi-api ]]; then
            prev=$(mktemp)
            cat /etc/sudoers.d/cipi-api > "$prev"
        fi
        ensure_cipi_api_sudoers || true
        if command -v visudo >/dev/null 2>&1; then
            if visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
                echo "  wrote /etc/sudoers.d/cipi-api (node install|default|upgrade|remove, db link|unlink, backup status|list|run --detach|verify|profile)"
            elif [[ -n "$prev" ]]; then
                cat "$prev" > /etc/sudoers.d/cipi-api
                chmod 440 /etc/sudoers.d/cipi-api 2>/dev/null || true
                echo "  WARNING: the new cipi-api sudoers did not validate — the previous file was put back; the panel's Node, backup and database-link pages will be refused by sudo"
            else
                rm -f /etc/sudoers.d/cipi-api
                echo "  WARNING: the cipi-api sudoers did not validate and was removed — run: cipi api update"
            fi
        else
            echo "  wrote /etc/sudoers.d/cipi-api (visudo not available to check it)"
        fi
        [[ -n "$prev" ]] && rm -f "$prev"
    else
        echo "  no panel API or GUI on this server — nothing to write"
    fi
else
    echo "  WARNING: ${CIPI_LIB}/cipi-api-sudoers.sh not found"
fi

echo "Migration 5.9.0 complete"
