#!/bin/bash
#############################################
# Cipi — PAM auth notification
# Logs security events and optionally sends
# email on sudo/su elevation or SSH login.
# Called by pam_exec.so (session open).
#
# Internal operations (API, queue workers,
# cron) are silently skipped so only real
# interactive security events trigger alerts.
#############################################

[[ "${PAM_TYPE:-}" == "open_session" ]] || exit 0

readonly CIPI_CONFIG="/etc/cipi"
readonly CIPI_LIB="/opt/cipi/lib"
readonly CIPI_LOG="/var/log/cipi"
readonly EVENTS_LOG="${CIPI_LOG}/events.log"

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SERVICE="${PAM_SERVICE:-unknown}"
USER="${PAM_USER:-unknown}"
RHOST="${PAM_RHOST:-local}"
TTY="${PAM_TTY:-unknown}"

# ── Helper functions ─────────────────────────────────────────

_resolve_ssh_key_name() {
    local fp=""

    local auth_file="${SSH_USER_AUTH:-}"
    if [[ -n "$auth_file" && -f "$auth_file" ]]; then
        fp=$(awk '/^publickey / {print $3; exit}' "$auth_file" 2>/dev/null)
    fi

    if [[ -z "$fp" && -f /var/log/auth.log ]]; then
        local log_line
        log_line=$(grep "Accepted publickey for ${USER} from ${RHOST}" /var/log/auth.log 2>/dev/null | tail -1)
        [[ -n "$log_line" ]] && fp=$(echo "$log_line" | grep -o 'SHA256:[^ ]*')
    fi

    [[ -z "$fp" ]] && return

    local ak="/home/cipi/.ssh/authorized_keys"
    [[ -f "$ak" ]] || { echo "$fp"; return; }

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local line_fp
        line_fp=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        if [[ "$line_fp" == "$fp" ]]; then
            local comment
            comment=$(echo "$line" | awk '{$1=$2=""; print}' | xargs)
            [[ -n "$comment" ]] && echo "$comment" || echo "$fp"
            return
        fi
    done < "$ak"
    echo "$fp"
}

_is_internal() {
    local luid
    luid=$(cat /proc/self/loginuid 2>/dev/null) || luid=""
    [[ "$luid" == "4294967295" ]] && return 0

    local pid=$$ i=0
    while [[ $pid -gt 1 && $i -lt 20 ]]; do
        local cmd
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        case "$cmd" in
            *php-fpm*|*php*artisan*queue*|*supervisord*|*cipi-queue*) return 0 ;;
        esac
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
        i=$((i + 1))
    done
    return 1
}

_resolve_sudo_user() {
    [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "unknown" ]] && { echo "$SUDO_USER"; return; }
    local luid
    luid=$(cat /proc/self/loginuid 2>/dev/null) || luid=""
    if [[ -n "$luid" && "$luid" != "4294967295" ]]; then
        local name
        name=$(getent passwd "$luid" 2>/dev/null | cut -d: -f1)
        [[ -n "$name" ]] && { echo "$name"; return; }
    fi
    echo "unknown"
}

# ── Resolve context ──────────────────────────────────────────

SSH_KEY_NAME=$(_resolve_ssh_key_name)
[[ -z "$SSH_KEY_NAME" ]] && SSH_KEY_NAME="unknown"

# ── Build event ──────────────────────────────────────────────

case "$SERVICE" in
    sudo)
        _is_internal && exit 0
        SUDO_BY=$(_resolve_sudo_user)
        SUBJECT="Cipi security: sudo by ${SUDO_BY} (${HOSTNAME})"
        BODY="Sudo elevation detected on ${HOSTNAME}

User:      ${SUDO_BY}
Target:    ${USER}
SSH Key:   ${SSH_KEY_NAME}
TTY:       ${TTY}
Time:      ${TIMESTAMP}"
        ;;
    sshd)
        if [[ "$USER" != "root" ]]; then
            id -nG "$USER" 2>/dev/null | grep -qw sudo || exit 0
        fi
        SUBJECT="Cipi security: SSH login ${USER}@${HOSTNAME}"
        BODY="SSH login detected on ${HOSTNAME}

User:      ${USER}
From:      ${RHOST}
SSH Key:   ${SSH_KEY_NAME}
TTY:       ${TTY}
Time:      ${TIMESTAMP}"
        ;;
    su)
        _is_internal && exit 0
        SU_BY=$(_resolve_sudo_user)
        SUBJECT="Cipi security: su to ${USER} by ${SU_BY} (${HOSTNAME})"
        BODY="su elevation detected on ${HOSTNAME}

User:      ${SU_BY}
Target:    ${USER}
SSH Key:   ${SSH_KEY_NAME}
From:      ${RHOST}
TTY:       ${TTY}
Time:      ${TIMESTAMP}"
        ;;
    *)
        exit 0
        ;;
esac

# ── Log event (always, regardless of SMTP) ───────────────────

mkdir -p "$CIPI_LOG" 2>/dev/null || true
echo "[${TIMESTAMP}] [${RHOST}] [key:${SSH_KEY_NAME}] ${SUBJECT}" >> "$EVENTS_LOG" 2>/dev/null || true

# ── Send email (only if SMTP configured) ─────────────────────

readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"
readonly SMTP_RC="${CIPI_CONFIG}/.msmtprc"

[[ -f "$SMTP_CFG" ]] || exit 0
[[ -f "$SMTP_RC" ]] || exit 0

source "${CIPI_LIB}/vault.sh" 2>/dev/null || exit 0

_SJ=$(vault_read smtp.json 2>/dev/null) || exit 0
[[ "$(echo "$_SJ" | jq -r '.enabled // false')" == "true" ]] || exit 0

TO=$(echo "$_SJ" | jq -r '.to // empty')
FROM=$(echo "$_SJ" | jq -r '.from // "noreply@localhost"')
[[ -z "$TO" ]] && exit 0

printf "From: %s\nTo: %s\nSubject: %s\n\n%s\n" "$FROM" "$TO" "$SUBJECT" "$BODY" | \
    msmtp -C "$SMTP_RC" "$TO" 2>/dev/null &

exit 0
