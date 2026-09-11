#!/bin/bash
#############################################
# Cipi — cron helper: run system monitor checks
# Alerts fire on state transitions only (see lib/monitor.sh).
#############################################
set -euo pipefail

CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/monitor.sh"

_mon_run_all true >/dev/null
