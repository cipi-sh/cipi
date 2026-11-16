#!/bin/bash
#############################################
# Cipi Migration 5.9.0 — app isolation, and what the panel may run
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
#  3. /etc/sudoers.d/cipi-api, the commands www-data may run as root for the
#     panel. On servers with neither the panel API nor the GUI it is removed:
#     setup.sh wrote it everywhere, and it lets www-data run `cipi ssh add`,
#     i.e. become root; `cipi api` / `cipi gui` write it from now on. On
#     servers with a panel it is rewritten with what the panel's new pages
#     run (cipi/api 1.39.0, cipi/gui 4.2.0): Node runtimes
#     (`cipi node install|default|upgrade|remove`), a database shown as an
#     app's (`cipi db link|unlink`), and the backup profiles
#     (`cipi backup status --json`, `list --json`, `run --detach`, `verify`,
#     `profile add|edit|remove|enable|disable`, `destination test`). The
#     new file is checked with visudo; one it refuses is replaced by the file
#     that was there.
#  4. Moves the logs root writes for each app — nginx access/error,
#     supervisor programs, deploy.log — from /home/<app>/logs, which the app
#     user owns, to /var/log/cipi-apps/<app>, which it only reads: a symlink
#     put in ~/logs in place of a log was followed by root (lib/app-logs.sh
#     has the whole of it; common.sh, app_log_dir, the why). Vhosts are
#     tested with nginx -t before the reload and put back if refused;
#     running supervisor programs are restarted on the new path, stopped
#     ones are not started (they take it, and start, at the next deploy);
#     ~/logs keeps a symlink per moved log.
#  5. Root's crontab: the daily `swapoff -a && swapon -a` runs only when
#     what is in swap fits in the available RAM twice over.
#  6. Restarts PHP-FPM, then what each of those apps has running under
#     supervisor (queue workers, Horizon, Octane, Reverb — what every
#     deploy restarts anyway): a running process keeps the groups it
#     started with, so without this the old membership would live on in
#     the workers. Only what is running: a program someone stopped
#     (`cipi worker stop`) stays stopped. A Node SSR app is restarted the
#     way a deploy does it, blue/green, with no downtime; if the new
#     process does not come up the old one keeps serving, and the
#     migration says so. Open SSH sessions of app users keep the old
#     membership until they log out.
#
#  7. logrotate: Laravel's logs and the PHP-FPM error log are the app's own
#     files in the app's own home, and one rule on /home/*/… had root copy,
#     truncate and compress them there. Each app gets a rule of its own,
#     /etc/logrotate.d/cipi-home-<app>, with `su <app> <group>`: logrotate
#     does that work as the app user. The two /home/* lines leave the shared
#     rule first (a log named twice makes logrotate drop a whole file); a
#     shared rule someone has rearranged is left as it is, and said.
#  8. sshd: the server's SSH keys (the cipi user's — cipi ssh list) are
#     accepted for every app user, through /usr/local/bin/cipi-ssh-keys. An
#     app with SSH access disabled accepted nothing from outside; it now
#     accepts those keys and nothing else. An app with access enabled keeps
#     its password and its own keys, next to them. Cipi's two older blocks
#     in sshd_config become one managed section; the new file is validated
#     by sshd before it replaces the live one, and sshd is reloaded, not
#     restarted.
#  9. Nightly patch updates (cipi autoupdate, 04:20) of nginx, MariaDB,
#     PostgreSQL, Valkey, Node.js and Composer — on for all of them unless
#     switched off — and the daily look at what is waiting (cipi pending,
#     07:30): a reboot, a patch, a warning. Composer below 2.10.3 is updated
#     now.
#
# 10. Appends `after('deploy:failed', 'deploy:unlock');` to the deploy.php of
#     Laravel apps that do not have it: a failed deploy left its lock behind
#     and every later one stopped at "Deploy locked".
#
# cipi-app-notify, the other half of this release, needs no migration:
# self-update copies the new helper to /usr/local/bin before this runs.
# The panel's trees (composer and artisan as www-data) and Valkey per app
# need none either: the first is how the update itself now runs, the second
# starts with the next `cipi app create` or `cipi valkey isolate`.
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
# common.sh's warn/info print with these: unset, a helper that spoke would
# abort the migration under set -u.
RED="${RED:-}"; GREEN="${GREEN:-}"; YELLOW="${YELLOW:-}"; CYAN="${CYAN:-}"; DIM="${DIM:-}"; BOLD="${BOLD:-}"; NC="${NC:-}"

echo "Migration 5.9.0 — app users out of www-data, www pool socket, panel sudoers, root-written logs out of ~/logs..."

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
    id "$u" &>/dev/null || continue
    if ! printf '%s\n' "$www_members" | grep -Fxq "$u"; then
        continue
    fi
    # Listed as an app and in www-data, but not a name `cipi app create`
    # gives out (a reserved word, an odd shape): said, never touched.
    if ! validate_username "$u" 2>/dev/null; then
        echo "  WARNING: ${u}: listed as an app but not an app-shaped name — left in www-data (if it is an app user: gpasswd -d ${u} www-data)"
        n_kept=$((n_kept + 1))
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

# ── 3. Panel sudoers: only with a panel, and with the 5.9.0 rules ──
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if _cipi_panel_installed; then
        # The file that is there is kept aside until sudo's own parser has
        # accepted the new one: a file in sudoers.d that does not parse stops
        # sudo for everybody.
        prev=""
        if [[ -f /etc/sudoers.d/cipi-api ]]; then
            prev=$(mktemp 2>/dev/null) && cat /etc/sudoers.d/cipi-api > "$prev" 2>/dev/null || prev=""
        fi
        write_cipi_api_sudoers 2>/dev/null || true
        if ! command -v visudo >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api (visudo not available to check it)"
        elif visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api — the panel may also run: node install|default|upgrade|remove, db link|unlink, backup status|list|run --detach|verify|profile"
        elif [[ -n "$prev" ]]; then
            install -m 0440 "$prev" /etc/sudoers.d/cipi-api 2>/dev/null || true
            echo "  WARNING: the new /etc/sudoers.d/cipi-api did not validate — the previous file was put back; the panel's Node, backup and database-link pages will be refused by sudo. Check: visudo -cf /etc/sudoers.d/cipi-api"
        else
            rm -f /etc/sudoers.d/cipi-api
            echo "  WARNING: /etc/sudoers.d/cipi-api did not validate and was removed — the panel cannot run cipi until: cipi api update"
        fi
        [[ -n "$prev" ]] && rm -f "$prev"
    else
        ensure_cipi_api_sudoers || true
    fi
fi

# ── 4. Root-written logs out of ~/logs ───────────────────────
# After step 1 on purpose: a supervisor program restarted here on its new
# log path starts without www-data, so step 6 does not restart it again.
APP_LOGS_FPM_VERSIONS=""; APP_LOGS_UPDATED=""; APP_LOGS_NODE_SWITCHED=""; APP_LOGS_LEFT=0
if [[ -f "${CIPI_LIB}/app-logs.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/app-logs.sh"
    app_logs_relocate --fpm=defer || echo "  WARNING: moving the logs stopped early — run: cipi app fix-permissions"
    restart="${restart} ${APP_LOGS_FPM_VERSIONS}"
    if (( APP_LOGS_LEFT > 0 )); then
        echo "  WARNING: ${APP_LOGS_LEFT} thing(s) still log to ~/logs — see above; retry with: cipi app fix-permissions"
    fi
else
    echo "  WARNING: ${CIPI_LIB}/app-logs.sh not found — logs not moved"
fi

# ── 5. Root crontab: swap emptied only when it fits in RAM ───
old_swap='50 5 * * * echo 3 > /proc/sys/vm/drop_caches && swapoff -a && swapon -a 2>/dev/null'
IFS= read -r new_swap <<'CRON' || true
50 5 * * * echo 3 > /proc/sys/vm/drop_caches && awk '/^MemAvailable:/{a=$2} /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{exit !(t>f && a>(t-f)*2)}' /proc/meminfo && swapoff -a && swapon -a 2>/dev/null
CRON
cron_now=$(crontab -l 2>/dev/null || true)
if grep -qxF -- "$old_swap" <<< "$cron_now"; then
    # The one line, replaced whole; a crontab that would come out shorter or
    # empty is not installed.
    cron_new=$(awk -v old="$old_swap" -v new="$new_swap" '$0 == old { print new; next } { print }' <<< "$cron_now" || true)
    if [[ -n "$cron_new" && "$(wc -l <<< "$cron_new")" == "$(wc -l <<< "$cron_now")" ]] \
       && grep -qxF -- "$new_swap" <<< "$cron_new" && crontab - <<< "$cron_new" 2>/dev/null; then
        echo "  cron: the daily swap flush runs only when the RAM can take back what is in swap"
    else
        echo "  WARNING: could not rewrite the root crontab — the 05:50 'swapoff -a && swapon -a' line is unchanged"
    fi
elif grep -F 'swapoff -a' <<< "$cron_now" | grep -qvF '/proc/meminfo'; then
    # Not the line Cipi installed, word for word: someone's, or edited.
    echo "  NOTE: root's crontab has a 'swapoff -a' line that is not the one Cipi wrote — left as it is (it runs without a memory check)"
fi

# ── 6. Restart PHP-FPM and the apps' workers ─────────────────
# FPM: every installed version when a user left www-data (its workers
# were forked with the old groups), otherwise only where www.conf or an
# app's pool (open_basedir, step 4) changed.
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
            # Only what is running. A process that is not there holds no old
            # group, and a program someone stopped must not come back at night.
            # Restarted by step 4 on its new log path, after it left www-data.
            [[ " ${APP_LOGS_UPDATED} " == *" ${group} "* ]] && continue
            running=$(supervisorctl status "${group}:*" 2>/dev/null \
                | awk '$2 == "RUNNING" || $2 == "STARTING" { print $1 }' || true)
            [[ -n "$running" ]] || continue
            for proc in $running; do
                supervisorctl restart "$proc" >/dev/null 2>&1 || true
            done
            n_workers=$((n_workers + 1))
        done
    done
    (( n_workers > 0 )) && echo "  ${n_workers} supervisor program(s) restarted (workers forked before this kept the old groups)"

    # Node SSR apps: their process runs under <app>-node-blue|green, outside
    # <app>.conf. cipi-node-switch starts the release on the idle slot, waits
    # for it to answer, moves nginx and stops the old process — the restart
    # every deploy makes. A failure leaves the old process serving. When the
    # app's switch lock is held (a deploy is making that same switch right
    # now) the app is left alone rather than waited for. SUDO_USER is
    # dropped: the switch refuses a sudo caller that is not the app, and this
    # is root's own maintenance, whoever typed `sudo cipi self-update`.
    if [[ -x /usr/local/bin/cipi-node-switch ]]; then
        for u in $removed; do
            # Switched by step 4 already (new log path), after it left www-data.
            [[ " ${APP_LOGS_NODE_SWITCHED} " == *" ${u} "* ]] && continue
            state="/var/lib/cipi/node/${u}.json"
            [[ -f "$state" && -f "/etc/supervisor/conf.d/${u}-node.conf" && -L "/home/${u}/current" ]] || continue
            [[ "$(jq -r '.mode // "ssr"' "$state" 2>/dev/null || true)" == "ssr" ]] || continue
            active=$(jq -r '.active // -1' "$state" 2>/dev/null || true)
            [[ "$active" == "0" || "$active" == "1" ]] || continue
            if ! ( exec 8>"/run/lock/cipi-node-${u}.lock" && flock -n 8 ) 2>/dev/null; then
                echo "  ${u}: Node switch in progress (a deploy?) — left alone; if it was not a deploy: cipi node restart ${u}"
                continue
            fi
            if env -u SUDO_USER /usr/local/bin/cipi-node-switch "$u" current >/dev/null 2>&1; then
                echo "  ${u}: Node process restarted (blue/green, no downtime)"
            else
                echo "  WARNING: ${u}: Node process not restarted — it keeps the old groups until the next deploy or: cipi node restart ${u}"
            fi
        done
    fi
    echo "  Open SSH/SFTP sessions of app users keep www-data until they log out"
fi

# ── 7. logrotate: each app's own logs, as the app user ───────
if [[ -d /etc/logrotate.d ]] && declare -f app_logrotate_all >/dev/null; then
    lr_apps=""
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        lr_apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    fi
    # shellcheck disable=SC2086
    if app_logrotate_all $lr_apps; then
        if ! lr_err=$(logrotate_cipi_check); then
            echo "  WARNING: logrotate reports a problem with Cipi's rules:"
            printf '%s\n' "$lr_err" | sed 's/^/    /'
        fi
    fi
fi

# ── 8. sshd: the server's keys for every app user ────────────
if [[ -f /etc/ssh/sshd_config && -f "${CIPI_LIB}/ssh.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/ssh.sh"
    if declare -f _ssh_apps_ensure_block >/dev/null && _ssh_apps_ensure_block; then
        echo "  sshd: the server's SSH keys (cipi ssh list) now open a shell as any app user; an app with SSH access disabled accepts nothing else from outside"
    else
        echo "  WARNING: sshd_config not updated — app users are as they were; retry with: cipi ssh apps sync"
    fi
fi

# ── 9. Nightly patch updates, daily pending check ────────────
declare -f cipi_notify >/dev/null || cipi_notify() { :; }
if [[ -f "${CIPI_LIB}/autoupdate.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/autoupdate.sh"
    if autoupdate_cron_sync 2>/dev/null && [[ -f "$AUTOUPDATE_CRON" ]]; then
        echo "  cron: nginx, MariaDB, PostgreSQL, Valkey, Node.js and Composer are patched every night at 04:20 (cipi autoupdate — off: cipi autoupdate off [name])"
    else
        echo "  WARNING: could not write ${AUTOUPDATE_CRON} — run: cipi autoupdate on"
    fi
    if [[ -x /usr/local/bin/composer ]]; then
        cv=$(_autoupdate_composer_version || true)
        if [[ -n "$cv" ]] && ! version_at_least "$cv" "$(composer_security_floor)"; then
            echo "  Composer ${cv} is below $(composer_security_floor) (security releases) — updating..."
            ( _autoupdate_composer ) || echo "  WARNING: Composer not updated — run: cipi autoupdate run composer"
        fi
    fi
fi
if [[ -f "${CIPI_LIB}/pending.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/pending.sh"
    if pending_cron_write 2>/dev/null && [[ -f "$PENDING_CRON" ]]; then
        echo "  cron: what is waiting — a reboot, a patch, a warning — is checked every morning and mailed when it changes (cipi pending)"
    else
        echo "  WARNING: could not write ${PENDING_CRON}"
    fi
    if r=$(reboot_needed); then
        echo "  NOTE: this server is waiting for a reboot (running kernel $(uname -r)) — cipi reboot"
    fi
fi

# ── 10. A failed deploy releases its own lock ────────────────
if declare -f deployer_unlock_ensure_hook >/dev/null && [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    n_unlock=0
    while IFS= read -r u; do
        [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
        id "$u" &>/dev/null || continue
        [[ -f "/home/${u}/.deployer/deploy.php" ]] || continue
        before_sum=$(app_read "$u" "/home/${u}/.deployer/deploy.php" 2>/dev/null | md5sum || true)
        deployer_unlock_ensure_hook "$u" || { echo "  WARNING: ${u}: deploy.php not updated — a failed deploy still needs: cipi deploy ${u} --unlock"; continue; }
        [[ "$(app_read "$u" "/home/${u}/.deployer/deploy.php" 2>/dev/null | md5sum || true)" != "$before_sum" ]] && n_unlock=$((n_unlock + 1))
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    (( n_unlock > 0 )) && echo "  deploy.php: ${n_unlock} Laravel app(s) now release the deploy lock when a deploy fails"
fi

(( n_kept > 0 )) && echo "  WARNING: ${n_kept} app user(s) still in www-data — see above"
echo "Migration 5.9.0 complete"
