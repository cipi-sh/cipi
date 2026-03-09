#!/bin/bash
#############################################
# Cipi — Cron wrapper with error notification
# Usage: cipi-cron-notify <label> <command...>
# Runs command; on failure sends email via cipi smtp (if configured).
#############################################
set -uo pipefail

LABEL="${1:-cron}"; shift || { echo "Usage: cipi-cron-notify <label> <command...>"; exit 1; }

readonly CIPI_LIB="/opt/cipi/lib"
readonly CIPI_CONFIG="/etc/cipi"
readonly CIPI_LOG="/var/log/cipi"
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

source "${CIPI_LIB}/vault.sh"

OUTPUT=$("$@" 2>&1)
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "$OUTPUT"

    HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    SUBJECT="Cipi cron failed: ${LABEL} (${HOSTNAME})"
    BODY="Cron job '${LABEL}' failed with exit code ${RC} on ${HOSTNAME} at $(date '+%Y-%m-%d %H:%M:%S').

Output:
${OUTPUT:-<no output>}"

    # Log event (always)
    mkdir -p "$CIPI_LOG" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [local] [key:n/a] ${SUBJECT}" >> "${CIPI_LOG}/events.log" 2>/dev/null || true

    # Send email (only if SMTP configured)
    [[ ! -f "$SMTP_CFG" ]] && exit $RC
    _SJ=$(vault_read smtp.json 2>/dev/null) || exit $RC
    [[ "$(echo "$_SJ" | jq -r '.enabled // false')" != "true" ]] && exit $RC

    TO=$(echo "$_SJ" | jq -r '.to // empty')
    FROM=$(echo "$_SJ" | jq -r '.from // "noreply@localhost"')
    [[ -z "$TO" ]] && exit $RC

    printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$FROM" "$TO" "$SUBJECT" "$BODY" | \
        msmtp -C "$SMTP_RC" "$TO" 2>/dev/null || true
fi

exit $RC
