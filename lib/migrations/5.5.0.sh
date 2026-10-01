#!/bin/bash
#############################################
# Cipi Migration 5.5.0
#
# Laravel app logs: one file, rotated once.
#
# `cipi app create` wrote LOG_CHANNEL=daily into every Laravel app's .env, and
# logrotate (cipi-app-logs) rotated storage/logs/*.log on top of it. Each
# laravel-<date>.log was therefore rotated exactly once: its content went to
# laravel-<date>.log.1, which was never compressed and never expired, and an
# empty laravel-<date>.log stayed behind — the file `cipi app logs` and the
# panel read. Apps now log to laravel.log, and logrotate alone rotates it
# (daily, compressed, 365 rotations).
#
#  1. Rewrites /etc/logrotate.d/cipi-app-logs: a log whose name ends in a date
#     is no longer rotated. An app that still uses `daily` on purpose gets what
#     Laravel does by itself (one file per day, pruned by LOG_DAILY_DAYS).
#  2. Every Laravel app: LOG_CHANNEL=daily becomes single in shared/.env, and
#     so does a `daily` inside LOG_STACK. Other channels are left as they are.
#     Done as the app user, through a copy that replaces the .env in one
#     rename: the file is never truncated, and root writes nothing there.
#  3. Where the .env changed, so that nothing keeps the old channel in memory:
#     rebuilds the config cache if the current release has one, sends SIGTERM
#     to the app's running Supervisor programs (queue workers, Horizon, Octane,
#     Reverb: they finish the job in hand and Supervisor starts them again;
#     stopped ones stay stopped) and reloads PHP-FPM once per PHP version.
#  4. Folds each app's dated files into laravel.log, oldest first:
#     laravel-<date>.log, .log.N, .log.N.gz and the empty stubs. Done as the
#     app user. A file is removed only after its content is in laravel.log;
#     one that a process still has open is left where it is.
#
# Nothing is deployed.
#############################################
# Every step tolerates failure and carries on: an aborted migration pins the
# server on the old version and retries every night.
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

# common.sh's info/warn/success print these; the cipi binary defines them, a
# migration runs without it (and under set -u).
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.5.0 — Laravel logs: one file, rotated once..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. logrotate ─────────────────────────────────────────────
if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/cipi-app-logs <<'EOF'
/home/*/shared/storage/logs/*[!0-9].log
/home/*/logs/php-fpm-*.log
/home/*/logs/worker-*.log
/home/*/logs/deploy.log
/var/log/cipi/*.log
/var/log/cipi-queue.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
    echo "  /etc/logrotate.d/cipi-app-logs: dated Laravel logs are no longer rotated"
fi

# Dated Laravel logs in a directory that a process still has open (a job or a
# request that started before the switch), as file names.
open_dated_logs() {
    [[ -d /proc/1/fd ]] || return 0
    find /proc/[0-9]*/fd -lname "${1}/laravel-[0-9]*" -printf '%l\n' 2>/dev/null \
        | sed 's|.*/||; s| (deleted)$||' | sort -u || true
}

# Laravel apps only: custom and Node apps have no Laravel logs.
apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'to_entries[]
        | select(((.value.custom // false) | tostring) != "true" and (.value.runtime // "") != "node")
        | "\(.key)|\(.value.php // "")|\(.value.octane // "")"' 2>/dev/null || true)
fi

# ── 2/3. .env, config cache, workers ─────────────────────────
switched=" "
fpm_reload=""
while IFS='|' read -r app php_ver octane; do
    [[ -n "$app" ]] || continue
    id "$app" &>/dev/null || continue
    home="/home/${app}"

    if ! laravel_app_env_single_log "$app"; then
        # Nothing to change, or the app user cannot rewrite its own .env.
        if grep -qE "^LOG_CHANNEL=[\"']?daily" "${home}/shared/.env" 2>/dev/null; then
            echo "  WARNING: ${app}: .env still has LOG_CHANNEL=daily and could not be rewritten — run: cipi app fix-permissions ${app}"
        fi
        continue
    fi
    switched+="${app} "
    echo "  ${app}: .env now logs to laravel.log (single)"

    php_bin="/usr/bin/php${php_ver}"
    if [[ -f "${home}/current/bootstrap/cache/config.php" && -x "$php_bin" ]]; then
        if _cipi_run_timed 120 sudo -u "$app" "$php_bin" "${home}/current/artisan" config:cache >/dev/null 2>&1; then
            echo "  ${app}: config cache rebuilt"
        else
            echo "  WARNING: ${app}: could not rebuild the config cache — the app keeps the daily channel until its next deploy"
        fi
    fi

    if command -v supervisorctl >/dev/null 2>&1; then
        running=$(supervisorctl status 2>/dev/null \
            | awk -v p="${app}-" '$2 == "RUNNING" && index($1, p) == 1 { print $1 }' || true)
        if [[ -n "$running" ]]; then
            # shellcheck disable=SC2086
            if supervisorctl signal TERM $running >/dev/null 2>&1; then
                echo "  ${app}: workers restarting ($(wc -w <<< "$running" | tr -d ' ') process(es))"
            else
                echo "  WARNING: ${app}: could not signal the workers — restart them: cipi worker restart ${app}"
            fi
        fi
    fi

    if [[ -z "$octane" && -n "$php_ver" ]]; then
        fpm_reload+="${php_ver}"$'\n'
    fi
done <<< "$apps"

while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    systemctl is-active --quiet "php${v}-fpm" 2>/dev/null || continue
    if systemctl reload "php${v}-fpm" 2>/dev/null || systemctl restart "php${v}-fpm" 2>/dev/null; then
        echo "  php${v}-fpm reloaded"
    else
        echo "  WARNING: could not reload php${v}-fpm"
    fi
done <<< "$(printf '%s' "$fpm_reload" | sort -u)"

# ── 4. dated files → laravel.log ─────────────────────────────
while IFS='|' read -r app _ _; do
    [[ -n "$app" ]] || continue
    id "$app" &>/dev/null || continue
    logs="/home/${app}/shared/storage/logs"
    [[ -d "$logs" ]] || continue
    compgen -G "${logs}/laravel-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log*" >/dev/null || continue

    # Root-owned leftovers of the old logrotate rules go back to the app user.
    ensure_app_logs_permissions "$app" || true

    # Workers that just got SIGTERM let go of today's file within seconds.
    busy=$(open_dated_logs "$logs")
    if [[ -n "$busy" && "$switched" == *" ${app} "* ]]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            busy=$(open_dated_logs "$logs")
            if [[ -z "$busy" ]]; then break; fi
        done
    fi

    # shellcheck disable=SC2086
    n=$(laravel_logs_unify "$app" $busy 2>/dev/null || true)
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        echo "  WARNING: ${app}: could not fold the dated logs into laravel.log — left as they are"
    elif [[ "$n" -gt 0 ]]; then
        echo "  ${app}: ${n} dated log file(s) folded into laravel.log"
    fi
    if [[ -n "$busy" ]]; then
        echo "  ${app}: still open, left in place: $(tr '\n' ' ' <<< "$busy")"
    fi

    # The new laravel.log gets the same mode and cipi ACL as any other log.
    ensure_app_logs_permissions "$app" || true
done <<< "$apps"

echo "Migration 5.5.0 complete"
