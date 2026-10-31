#!/bin/bash
#############################################
# Cipi Migration 5.8.6 — app isolation
#
#  1. Takes every app user out of the www-data group. Every PHP-FPM socket
#     on the server (each app's, the stock `www` pool's, the panel's) is
#     group www-data and 0660, so an app user — or code running in an
#     app — could send FastCGI requests to every other pool and run PHP
#     as any other app or as www-data. nginx and the panel reach an app
#     the other way round (www-data is in each app's group); that
#     membership is kept, nothing an app does needs www-data.
#  2. Locks the stock `www` pool socket (listen.mode = 0600) of every
#     installed PHP: that pool runs as www-data without open_basedir and
#     no vhost uses it. nginx is www-data, the owner, so 0600 still lets
#     it connect should anything ever point there.
#  3. Removes /etc/sudoers.d/cipi-api on servers with neither the panel
#     API nor the GUI installed: setup.sh wrote it everywhere, and it lets
#     www-data run `cipi ssh add`, i.e. become root. Servers with a panel
#     keep it as it is; `cipi api` / `cipi gui` write it from now on.
#  4. Restarts PHP-FPM, then every app's supervisor programs (queue
#     workers, Horizon, Octane, Reverb — what every deploy restarts
#     anyway): a running process keeps the groups it started with, so
#     without this the old membership would live on in the workers.
#     Open SSH sessions of app users keep it until they log out.
#
# cipi-app-notify, the other half of this release, needs no migration:
# self-update copies the new helper to /usr/local/bin before this runs.
#
# Every step tolerates failure and says so: a migration that aborts pins the
# server on the old release and retries every night.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"
export CIPI_API_ROOT="${CIPI_API_ROOT:-/opt/cipi/api}"
export CIPI_GUI_ROOT="${CIPI_GUI_ROOT:-/opt/cipi/gui}"

echo "Migration 5.8.6 — app users out of www-data, www pool socket, panel sudoers..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. App users out of www-data ─────────────────────────────
# An app user is a member of cipi-apps (what `cipi app create` writes and
# what the SSH policy is keyed on) or a key of apps.json. Nothing else —
# root, cipi, www-data, an admin's own account — is ever touched.
users=""
if getent group cipi-apps >/dev/null 2>&1; then
    users=$(getent group cipi-apps | cut -d: -f4 | tr ',' '\n')
fi
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    users="${users}"$'\n'"$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)"
fi
www_members=$(getent group www-data 2>/dev/null | cut -d: -f4 | tr ',' '\n' || true)

removed=""
n_removed=0
n_kept=0
while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    [[ "$u" == "root" || "$u" == "cipi" || "$u" == "www-data" ]] && continue
    validate_username "$u" 2>/dev/null || continue
    id "$u" &>/dev/null || continue
    if ! printf '%s\n' "$www_members" | grep -Fxq "$u"; then
        continue
    fi
    if gpasswd -d "$u" www-data >/dev/null 2>&1; then
        removed="${removed} ${u}"
        n_removed=$((n_removed + 1))
    else
        echo "  WARNING: ${u}: could not remove from www-data — run: gpasswd -d ${u} www-data"
        n_kept=$((n_kept + 1))
    fi
done < <(printf '%s\n' "$users" | sort -u)
if (( n_removed > 0 )); then
    echo "  ${n_removed} app user(s) removed from www-data:${removed}"
else
    echo "  No app user in www-data — nothing to change"
fi

# ── 2. Stock www pool socket 0600 ────────────────────────────
restart=""
for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
    php_is_installed "$v" || continue
    pool="/etc/php/${v}/fpm/pool.d/www.conf"
    [[ -f "$pool" ]] || continue
    # Only the placeholder Cipi wrote (user www-data, the stock socket): a
    # www.conf someone edited by hand is reported, not rewritten.
    if ! grep -qE '^[[:space:]]*user[[:space:]]*=[[:space:]]*www-data[[:space:]]*$' "$pool" \
       || ! grep -qE "^[[:space:]]*listen[[:space:]]*=[[:space:]]*/run/php/php${v}-fpm\.sock[[:space:]]*$" "$pool"; then
        echo "  php ${v}: pool.d/www.conf is not the Cipi placeholder — left alone (set listen.mode = 0600 by hand)"
        continue
    fi
    if grep -qE '^[[:space:]]*listen\.mode[[:space:]]*=' "$pool"; then
        if grep -qE '^[[:space:]]*listen\.mode[[:space:]]*=[[:space:]]*0600[[:space:]]*$' "$pool"; then
            continue
        fi
        if sed -i -E 's/^([[:space:]]*listen\.mode[[:space:]]*=[[:space:]]*).*$/\10600/' "$pool" 2>/dev/null; then
            echo "  php ${v}: www pool listen.mode set to 0600"
            restart="${restart} ${v}"
        else
            echo "  WARNING: php ${v}: could not edit ${pool}"
        fi
    else
        if sed -i -E "/^[[:space:]]*listen\.group[[:space:]]*=/a listen.mode = 0600" "$pool" 2>/dev/null \
           && grep -q '^listen.mode = 0600$' "$pool"; then
            echo "  php ${v}: www pool listen.mode = 0600 added"
            restart="${restart} ${v}"
        else
            echo "  WARNING: php ${v}: could not add listen.mode to ${pool}"
        fi
    fi
done

# ── 3. Panel sudoers only with a panel ───────────────────────
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if _cipi_panel_installed; then
        echo "  Panel API or GUI installed — /etc/sudoers.d/cipi-api kept"
    else
        ensure_cipi_api_sudoers || true
    fi
fi

# ── 4. Restart PHP-FPM and the apps' workers ─────────────────
# FPM: every installed version when a user left www-data (its workers
# were forked with the old groups), otherwise only where www.conf changed.
if (( n_removed > 0 )); then
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        php_is_installed "$v" && restart="${restart} ${v}"
    done
fi
for v in $(tr ' ' '\n' <<< "$restart" | grep -v '^$' | sort -u); do
    systemd_unit_exists "php${v}-fpm" || continue
    if command -v "php-fpm${v}" &>/dev/null && ! "php-fpm${v}" -t &>/dev/null; then
        echo "  WARNING: php ${v}: FPM configuration test failed — not restarting (php-fpm${v} -t)"
        continue
    fi
    if systemctl restart "php${v}-fpm" 2>/dev/null; then
        echo "  php ${v}: FPM restarted"
    else
        echo "  WARNING: php ${v}: FPM restart failed — run: systemctl status php${v}-fpm"
    fi
done

if (( n_removed > 0 )) && command -v supervisorctl &>/dev/null; then
    n_workers=0
    for u in $removed; do
        conf="/etc/supervisor/conf.d/${u}.conf"
        [[ -f "$conf" ]] || continue
        for group in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//'); do
            supervisorctl restart "${group}:*" >/dev/null 2>&1 \
                || supervisorctl restart "${group}" >/dev/null 2>&1 || true
            n_workers=$((n_workers + 1))
        done
    done
    (( n_workers > 0 )) && echo "  ${n_workers} supervisor program(s) restarted (workers forked before this kept the old groups)"
    echo "  Open SSH/SFTP sessions of app users keep www-data until they log out"
fi

(( n_kept > 0 )) && echo "  WARNING: ${n_kept} app user(s) still in www-data — see above"
echo "Migration 5.8.6 complete"
