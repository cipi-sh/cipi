#!/bin/bash
#############################################
# Cipi — Cron wrapper with error notification
# Usage: cipi-cron-notify <label> <command...>
# Runs command; on failure notifies every channel that takes cron_fail.
#############################################
set -uo pipefail

LABEL="${1:-cron}"; shift || { echo "Usage: cipi-cron-notify <label> <command...>"; exit 1; }

if [[ -z "${CIPI_LIB:-}" ]]; then readonly CIPI_LIB="/opt/cipi/lib"; fi
if [[ -z "${CIPI_CONFIG:-}" ]]; then readonly CIPI_CONFIG="/etc/cipi"; fi
if [[ -z "${CIPI_LOG:-}" ]]; then readonly CIPI_LOG="/var/log/cipi"; fi
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"

source "${CIPI_LIB}/vault.sh"
source "${CIPI_LIB}/notifications.sh" 2>/dev/null || true
source "${CIPI_LIB}/smtp.sh" 2>/dev/null || true

OUTPUT=$("$@" 2>&1)
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "$OUTPUT"

    HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    SUBJECT="Cipi cron failed: ${LABEL} (${HOSTNAME})"
    declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }
    BODY="Cron job '${LABEL}' failed with exit code ${RC} on ${HOSTNAME} at $(notify_now 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z').

Output:
${OUTPUT:-<no output>}"

    # Log event (always)
    mkdir -p "$CIPI_LOG" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [local] [key:n/a] ${SUBJECT}" >> "${CIPI_LOG}/events.log" 2>/dev/null || true

    # Every channel that takes cron_fail (SMTP and the others), when the trigger is on.
    if declare -f _notify_trigger_enabled &>/dev/null && ! _notify_trigger_enabled "cron_fail"; then
        exit $RC
    fi
    if declare -f _notify_fanout &>/dev/null; then
        _notify_fanout "$SUBJECT" "$BODY" cron_fail
    elif declare -f _smtp_send &>/dev/null; then
        _smtp_send "$SUBJECT" "$BODY" 2>/dev/null || true
    fi
fi

exit $RC
