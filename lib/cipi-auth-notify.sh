#!/bin/bash
#############################################
# Cipi — PAM auth notification
# Sends email on successful sudo elevation
# or root/sudoer SSH login.
# Called by pam_exec.so (session open).
#############################################

[[ "${PAM_TYPE:-}" == "open_session" ]] || exit 0

readonly CIPI_CONFIG="/etc/cipi"
readonly CIPI_LIB="/opt/cipi/lib"
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

# Quick exit if SMTP not configured
[[ -f "$SMTP_CFG" ]] || exit 0
[[ -f "$SMTP_RC" ]] || exit 0

source "${CIPI_LIB}/vault.sh" 2>/dev/null || exit 0

_SJ=$(vault_read smtp.json 2>/dev/null) || exit 0
[[ "$(echo "$_SJ" | jq -r '.enabled // false')" == "true" ]] || exit 0

TO=$(echo "$_SJ" | jq -r '.to // empty')
FROM=$(echo "$_SJ" | jq -r '.from // "noreply@localhost"')
[[ -z "$TO" ]] && exit 0

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SERVICE="${PAM_SERVICE:-unknown}"
USER="${PAM_USER:-unknown}"
RHOST="${PAM_RHOST:-local}"
TTY="${PAM_TTY:-unknown}"

case "$SERVICE" in
    sudo)
        SUDO_BY="${SUDO_USER:-unknown}"
        SUBJECT="Cipi security: sudo by ${SUDO_BY} (${HOSTNAME})"
        BODY="Sudo elevation detected on ${HOSTNAME}

User:      ${SUDO_BY}
Target:    ${USER}
TTY:       ${TTY}
Time:      ${TIMESTAMP}"
        ;;
    sshd)
        # Only notify for root or sudoers
        if [[ "$USER" != "root" ]]; then
            id -nG "$USER" 2>/dev/null | grep -qw sudo || exit 0
        fi
        SUBJECT="Cipi security: SSH login ${USER}@${HOSTNAME}"
        BODY="SSH login detected on ${HOSTNAME}

User:      ${USER}
From:      ${RHOST}
TTY:       ${TTY}
Time:      ${TIMESTAMP}"
        ;;
    *)
        exit 0
        ;;
esac

printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$FROM" "$TO" "$SUBJECT" "$BODY" | \
    msmtp -C "$SMTP_RC" "$TO" 2>/dev/null &

exit 0
