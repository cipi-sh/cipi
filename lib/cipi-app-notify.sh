#!/bin/bash
#############################################
# Cipi — App-level failure notification
# Sends SMTP alert when an app deploy or cron
# job fails. Called by app users via sudo.
# Usage: cipi-app-notify <app> <label> <exit_code> [log_file] [extra]
#
# This runs as root on behalf of an unprivileged app user, through the
# per-app sudoers rule `cipi-app-notify <app> *`: everything after the app
# name is chosen by that user. Every argument is therefore checked against
# the shape the only legitimate caller (cipi-app-deploy) produces before it
# is used, and nothing here is ever evaluated by the shell. In particular
# the exit code is matched as digits and compared as a string: bash's -eq
# evaluates its operand as an arithmetic expression, and an argument such as
# `BASH_VERSINFO[$(cmd)]` ran that command as root (5.9.0).
#############################################
set -uo pipefail

# Called through sudo by an app user: nothing from that environment is trusted.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    unset CIPI_LIB CIPI_CONFIG CIPI_LOG
fi

APP="${1:-}"; LABEL="${2:-}"; EXIT_CODE="${3:-}"; LOG_FILE="${4:-}"; EXTRA="${5:-}"
[[ -z "$APP" || -z "$LABEL" || -z "$EXIT_CODE" ]] && exit 0

# The app name is fixed by the sudoers rule; still, only an app-shaped name
# (cipi app create's own rule) and only the caller's own app.
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || exit 2
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && "${SUDO_USER}" != "$APP" ]]; then
    exit 2
fi
# A label is a short word: deploy, deploy-ok, cron, a cipi.yml step name.
[[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$ ]] || exit 2
# An exit status is 0-255. Never -eq / (( )) on it: see the header.
[[ "$EXIT_CODE" =~ ^[0-9]{1,3}$ ]] || exit 2
# The log is the app's own: a regular file that resolves under its home or
# under /var/log/cipi-apps/<app>, where the deploy log lives (symlinks
# followed, so a link to /etc/shadow does not qualify). Anything else is read
# as "no log", not as a reason to drop the notification.
if [[ -n "$LOG_FILE" ]]; then
    _resolved=$(realpath -e -- "$LOG_FILE" 2>/dev/null || true)
    if [[ -z "$_resolved" || ! -f "$_resolved" ]] \
       || [[ "$_resolved" != "/home/${APP}/"* && "$_resolved" != "/var/log/cipi-apps/${APP}/"* ]]; then
        LOG_FILE=""
    else
        LOG_FILE="$_resolved"
    fi
fi
# Free text for the mail body: bounded, printable, no escape sequences.
if [[ -n "$EXTRA" ]]; then
    EXTRA=$(printf '%s' "$EXTRA" | head -c 4096 | tr -d '\000-\010\013-\015\016-\037\177')
fi

# `deploy-ok` is the success counterpart used by cipi-app-deploy: the automatic
# (webhook) path had no way to report a *successful* deploy, so the only signal
# was silence — indistinguishable from a deploy that never ran.
IS_SUCCESS=false
[[ "$LABEL" == "deploy-ok" ]] && IS_SUCCESS=true
if [[ "$IS_SUCCESS" == false ]]; then
    [[ "$EXIT_CODE" =~ ^0+$ ]] && exit 0
fi

if [[ -z "${CIPI_LIB:-}" ]]; then readonly CIPI_LIB="/opt/cipi/lib"; fi
if [[ -z "${CIPI_CONFIG:-}" ]]; then readonly CIPI_CONFIG="/etc/cipi"; fi
if [[ -z "${CIPI_LOG:-}" ]]; then readonly CIPI_LOG="/var/log/cipi"; fi
readonly SMTP_CFG="${CIPI_CONFIG}/smtp.json"

source "${CIPI_LIB}/vault.sh"
source "${CIPI_LIB}/notifications.sh" 2>/dev/null || true
source "${CIPI_LIB}/smtp.sh" 2>/dev/null || true

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
LABEL_LC=$(printf '%s' "$LABEL" | tr '[:upper:]' '[:lower:]')

# The webhook deploy succeeded: Cloudflare's cache of the app's hostnames
# when the app asked for it (cipi zt purge <app> --on-deploy=on). Root work
# on the caller's own app only (the sudoers rule fixes APP); never fatal.
PURGE_LINE=""
if [[ "$IS_SUCCESS" == true ]] && vault_read apps.json 2>/dev/null | jq -e --arg a "$APP" '.[$a].cf_purge == "true"' >/dev/null 2>&1; then
    # A sourced file's status is its last line's: checked by what it defines.
    source "${CIPI_LIB}/common.sh" >/dev/null 2>&1 || true
    source "${CIPI_LIB}/zt.sh" >/dev/null 2>&1 || true
    if declare -f zt_purge_after_deploy >/dev/null 2>&1 && declare -f app_get >/dev/null 2>&1; then
        # Said in the notification only: the deploy log is the app user's
        # file, and root does not write where that user can plant a link.
        PURGE_LINE=$(zt_purge_after_deploy "$APP" 2>/dev/null) || PURGE_LINE=""
    fi
fi

if [[ "$IS_SUCCESS" == true ]]; then
    NOTIFY_TRIGGER="deploy_success"
    SUBJECT="Cipi deploy succeeded: ${APP} (${HOSTNAME})"
    BODY="Automatic deploy for '${APP}' completed on ${HOSTNAME} at $(date '+%Y-%m-%d %H:%M:%S').
${EXTRA:+
${EXTRA}}${PURGE_LINE:+
${PURGE_LINE}}"
else
    NOTIFY_TRIGGER="cron_fail"
    [[ "$LABEL_LC" == "deploy" ]] && NOTIFY_TRIGGER="deploy_fail"
    SUBJECT="Cipi ${LABEL} failed: ${APP} (${HOSTNAME})"

    # Read as the app user: the path was checked above, but under the app's
    # home it can be swapped between that check and this read.
    OUTPUT="<no output>"
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        if id "$APP" &>/dev/null; then
            OUTPUT=$(cd / && sudo -u "$APP" tail -n 30 -- "$LOG_FILE" 2>/dev/null || echo "<could not read log>")
        else
            OUTPUT=$(tail -n 30 -- "$LOG_FILE" 2>/dev/null || echo "<could not read log>")
        fi
    fi

    BODY="${LABEL^} for '${APP}' failed with exit code ${EXIT_CODE} on ${HOSTNAME} at $(date '+%Y-%m-%d %H:%M:%S').
${EXTRA:+
${EXTRA}}
Output (last 30 lines):
${OUTPUT}"
fi

# Log event
mkdir -p "$CIPI_LOG" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [local] [key:n/a] ${SUBJECT}" >> "${CIPI_LOG}/events.log" 2>/dev/null || true

# Every channel that takes the trigger (SMTP and the others), when it is on.
if [[ -n "$NOTIFY_TRIGGER" ]] && declare -f _notify_trigger_enabled &>/dev/null && ! _notify_trigger_enabled "$NOTIFY_TRIGGER"; then
    exit 0
fi
if declare -f _notify_fanout &>/dev/null; then
    _notify_fanout "$SUBJECT" "$BODY" "$NOTIFY_TRIGGER"
elif declare -f _smtp_send &>/dev/null; then
    _smtp_send "$SUBJECT" "$BODY" 2>/dev/null || true
fi

exit 0
