#!/bin/bash
#############################################
# Cipi Migration 5.5.2
#
# Opens `cipi disk` to the panel API (cipi/api ≥ 1.33.0): GET /api/disk and
# GET /api/disk/dbs serve what `cipi disk --json` and `cipi disk db --json`
# print, read-only, behind the token ability disk-view. Nothing else changes
# on the server. It only:
#
#  1. Regenerates the panel API sudoers so www-data may run `cipi disk` and
#     `cipi disk *` (--json, db --json). Setting a limit goes through
#     `cipi app limits`, which the sudoers already allow.
#
# The command itself exists since 5.5.0; this migration only updates
# /etc/sudoers.d/cipi-api.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.5.2 — panel API sudoers (disk)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if type write_cipi_api_sudoers &>/dev/null; then
        write_cipi_api_sudoers
        if command -v visudo >/dev/null 2>&1; then
            if visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
                echo "  wrote /etc/sudoers.d/cipi-api (disk, disk *)"
            else
                echo "  WARN: cipi-api sudoers did not validate — check visudo -cf /etc/sudoers.d/cipi-api"
            fi
        else
            echo "  wrote /etc/sudoers.d/cipi-api (disk; visudo not available)"
        fi
    fi
else
    echo "  WARN: ${CIPI_LIB}/cipi-api-sudoers.sh not found"
fi

echo "Migration 5.5.2 complete"
