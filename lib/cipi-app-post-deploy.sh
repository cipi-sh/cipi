#!/bin/bash
#############################################
# Cipi — Post-deploy steps from cipi.yml (app user)
#
# Runs allowlisted commands declared under deploy.post in the release's cipi.yml.
# Invoked by cipi-app-deploy after a successful Deployer run, before the
# post-deploy healthcheck.
#
# Usage: cipi-app-post-deploy <app> <php_version> [log_file]
#############################################
set -uo pipefail

APP="${1:-}"; PHP_VER="${2:-}"; LOG="${3:-}"
[[ -z "$APP" || -z "$PHP_VER" ]] && { echo "Usage: cipi-app-post-deploy <app> <php_version> [log_file]" >&2; exit 2; }

[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]]   || { echo "cipi-app-post-deploy: invalid app name" >&2; exit 2; }
[[ "$PHP_VER" =~ ^8\.[0-9]$ ]]          || { echo "cipi-app-post-deploy: invalid php version" >&2; exit 2; }
if [[ "$(id -un)" != "$APP" && "$(id -u)" -ne 0 ]]; then
    echo "cipi-app-post-deploy: must run as '${APP}' (or root)" >&2
    exit 2
fi

HOME_DIR="/home/${APP}"
[[ -z "$LOG" ]] && LOG="${HOME_DIR}/logs/deploy.log"
mkdir -p "${HOME_DIR}/logs" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true

CIPI_LIB="/opt/cipi/lib"
[[ -f "${CIPI_LIB}/yml.sh" ]] || { echo "cipi-app-post-deploy: missing ${CIPI_LIB}/yml.sh" >&2; exit 2; }

RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
info(){ :; }; warn(){ printf '[WARN] %s\n' "$*" >> "$LOG" 2>/dev/null || true; }
error(){ printf '[ERROR] %s\n' "$*" >> "$LOG" 2>/dev/null || true; }
success(){ :; }
step(){ :; }

# shellcheck source=/dev/null
source "${CIPI_LIB}/yml.sh"

AS="self"
[[ "$(id -u)" -eq 0 ]] && AS="root"

summary=""
rc=0
summary=$(_yml_post_deploy_run "$APP" "$PHP_VER" "$LOG" true "$AS") || rc=$?

printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy summary: %s (exit=%s)\n' -1 "$summary" "$rc" >> "$LOG" 2>/dev/null || true
exit "$rc"
