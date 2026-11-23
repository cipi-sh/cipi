#!/bin/bash
#############################################
# Cipi — cron helper: collect metrics & health history (every minute)
# See lib/metrics.sh. Never alerts: cipi monitor and cipi health do.
#############################################
# No `set -e`: one metric that cannot be read must not lose the others.
set -uo pipefail

CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh" || exit 0
# shellcheck source=/dev/null
source "${CIPI_LIB}/metrics.sh" || exit 0

# A run that takes longer than a minute (a host under heavy load) must not
# pile up behind the next one: the late one is skipped.
exec 9>/run/cipi-metrics.lock 2>/dev/null || exit 0
flock -n 9 || exit 0

nice -n 10 true 2>/dev/null && renice -n 10 $$ >/dev/null 2>&1
metrics_collect
exit 0
