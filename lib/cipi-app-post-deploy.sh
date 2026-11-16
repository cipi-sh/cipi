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
if [[ -z "$LOG" ]]; then
    # Root's directory since 5.9.0 (see cipi-app-deploy); the old place otherwise.
    LOG="/var/log/cipi-apps/${APP}/deploy.log"
    [[ -f "$LOG" && ! -L "$LOG" && -w "$LOG" ]] || LOG="${HOME_DIR}/logs/deploy.log"
fi
mkdir -p "${HOME_DIR}/logs" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true

CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
YML_LIB="${CIPI_LIB}/yml.sh"

RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
info(){ :; }; warn(){ printf '[WARN] %s\n' "$*" >> "$LOG" 2>/dev/null || true; }
error(){ printf '[ERROR] %s\n' "$*" >> "$LOG" 2>/dev/null || true; }
success(){ :; }
step(){ :; }

# The runner itself could not start: said in the log, where the deploy
# wrapper reads the summary from, and on stderr. Exit 2 keeps it apart from a
# step that failed (1) and from a step's own exit code.
_runner_unavailable() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy runner: %s\n' -1 "$1" >> "$LOG" 2>/dev/null || true
    printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy summary: runner unavailable (exit=2)\n' -1 >> "$LOG" 2>/dev/null || true
    echo "cipi-app-post-deploy: $1" >&2
    exit 2
}

# This runs as the app user. Until 5.7.2 the lib was installed 0700 root, so
# the source failed, the function below did not exist, and every webhook
# deploy logged "post-deploy summary:  (exit=127)".
[[ -f "$YML_LIB" ]] || _runner_unavailable "missing ${YML_LIB} — run: cipi self-update"
[[ -r "$YML_LIB" ]] || _runner_unavailable "cannot read ${YML_LIB} as $(id -un) (mode $(stat -c '%a' "$YML_LIB" 2>/dev/null || echo '?')) — as root: chmod 644 ${YML_LIB}"
# shellcheck source=/dev/null
source "$YML_LIB" 2>/dev/null || _runner_unavailable "could not load ${YML_LIB}"
declare -F _yml_post_deploy_run >/dev/null 2>&1 || _runner_unavailable "${YML_LIB} has no post-deploy runner — run: cipi self-update"

AS="self"
[[ "$(id -u)" -eq 0 ]] && AS="root"

summary=""
rc=0
summary=$(_yml_post_deploy_run "$APP" "$PHP_VER" "$LOG" true "$AS") || rc=$?

printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy summary: %s (exit=%s)\n' -1 "$summary" "$rc" >> "$LOG" 2>/dev/null || true
exit "$rc"
