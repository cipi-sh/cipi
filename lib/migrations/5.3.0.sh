#!/bin/bash
#############################################
# Cipi Migration 5.3.0
#
# Cloudflare Zero Trust (`cipi zt`) is opt-in, and alert channels are
# user-configured: this migration does not install cloudflared, does not
# create a tunnel, does not call `cipi zt enable`, and does not configure
# any notification channel or trigger. It only:
#
#  1. Installs the monitor cron helper (/usr/local/bin/cipi-monitor) and
#     /etc/cron.d/cipi-monitor so system checks run every 5 minutes.
#  2. Writes default monitor.json / alerts.json if missing (all checks
#     on, no channels — email-only delivery, same as before).
#  3. Regenerates panel API sudoers so `cipi zt status` and
#     `cipi monitor list` are allowed (enable / lock / set stay CLI-root,
#     like `cipi package install`).
#  4. Refreshes shell completion so `zt` and `monitor` are on the verb list.
#
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.3.0 — monitor cron + alert channels scaffolding, sudoers, completion..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ -f "${CIPI_LIB}/monitor.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/monitor.sh"
    _mon_ensure_config
    _mon_ensure_cron
    if [[ -f /etc/cron.d/cipi-monitor && -x /usr/local/bin/cipi-monitor ]]; then
        echo "  installed /etc/cron.d/cipi-monitor + /usr/local/bin/cipi-monitor"
    else
        echo "  WARN: monitor cron/helper not fully installed — run: cipi monitor"
    fi
else
    echo "  WARN: ${CIPI_LIB}/monitor.sh not found"
fi

if [[ -f "${CIPI_LIB}/alerts.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/alerts.sh"
    _alerts_ensure_config
    echo "  alerts.json ready (no channels configured — email delivery unchanged)"
else
    echo "  WARN: ${CIPI_LIB}/alerts.sh not found"
fi

if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if type write_cipi_api_sudoers &>/dev/null; then
        write_cipi_api_sudoers
        if command -v visudo >/dev/null 2>&1; then
            if visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
                echo "  wrote /etc/sudoers.d/cipi-api (zt status, monitor list)"
            else
                echo "  WARN: cipi-api sudoers did not validate — check visudo -cf /etc/sudoers.d/cipi-api"
            fi
        else
            echo "  wrote /etc/sudoers.d/cipi-api (zt status, monitor list; visudo not available)"
        fi
    fi
else
    echo "  WARN: ${CIPI_LIB}/cipi-api-sudoers.sh not found"
fi

if [[ -f "${CIPI_LIB}/completion.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/completion.sh"
    if type _completion_install_system &>/dev/null; then
        _completion_install_system || true
        echo "  refreshed shell completion"
    fi
fi

echo "Migration 5.3.0 complete"
