#!/bin/bash
#############################################
# Cipi Migration 5.4.1
#
# Opens redirects, proxies and Node app management to the panel API
# (cipi/api ≥ 1.30.0). Nothing else changes on the server. It only:
#
#  1. Regenerates the panel API sudoers so www-data may run
#     `cipi redirect …`, `cipi proxy …` and `cipi node list|status|restart`.
#     Runtime installs (`cipi node install|default|upgrade|remove`), search
#     install/upgrade/key-rotate, package install/remove and every `zt`
#     mutation stay CLI-root, like `cipi package install`.
#
# The commands themselves exist since 5.3.1 (redirect/proxy) and 5.4.0
# (node); this migration only updates /etc/sudoers.d/cipi-api.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.4.1 — panel API sudoers (redirect, proxy, node)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if type write_cipi_api_sudoers &>/dev/null; then
        write_cipi_api_sudoers
        if command -v visudo >/dev/null 2>&1; then
            if visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
                echo "  wrote /etc/sudoers.d/cipi-api (redirect *, proxy *, node list|status|restart)"
            else
                echo "  WARN: cipi-api sudoers did not validate — check visudo -cf /etc/sudoers.d/cipi-api"
            fi
        else
            echo "  wrote /etc/sudoers.d/cipi-api (redirect, proxy, node; visudo not available)"
        fi
    fi
else
    echo "  WARN: ${CIPI_LIB}/cipi-api-sudoers.sh not found"
fi

echo "Migration 5.4.1 complete"
