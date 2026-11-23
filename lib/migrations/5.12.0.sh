#!/bin/bash
#############################################
# Cipi Migration 5.12.0
#
# The panel manages every notification channel and trigger, not only SMTP:
# its sudoers whitelist gains `cipi notification status|triggers|add|update|
# remove|test|enable|disable`. Nothing else changes on the server: channels
# (alerts.json, smtp.json) and triggers (notifications.json) stay as they are.
#############################################
set -euo pipefail
export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'
# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
echo "Migration 5.12.0 — notifications in the panel..."
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if _cipi_panel_installed; then
        if write_cipi_api_sudoers; then
            echo "  wrote /etc/sudoers.d/cipi-api — the panel may also run: notification (channels, triggers, tests)"
        else
            echo "  WARNING: /etc/sudoers.d/cipi-api kept as it was (see above) — the panel cannot manage notifications until it is rewritten"
        fi
    else
        ensure_cipi_api_sudoers || true
    fi
fi
echo "Migration 5.12.0 complete"
