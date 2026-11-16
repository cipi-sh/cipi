#!/bin/bash
#############################################
# Cipi — an existing app's root-written logs, out of ~/logs
#
# Since 5.9.0 nginx, supervisord and `cipi deploy` log to
# /var/log/cipi-apps/<app> (root's directory; the why is at app_log_dir in
# common.sh). Everything Cipi writes from 5.9.0 on already names that
# directory: vhosts, supervisor programs, PHP-FPM pools, the deploy log. This
# file moves an app that was configured before — by migration 5.9.0 for every
# app, and by `cipi app fix-permissions [app]` afterwards, which is the retry
# when a step was refused.
#
#   app_logs_relocate [--fpm=reload|defer] [app…]     every app when none is named
#
# What it changes, per app, each file backed up first under
# /var/lib/cipi/app-logs-backup/<time>/:
#   nginx       access_log / error_log in the app's vhost(s). Tested with
#               nginx -t before the reload; a refused configuration puts every
#               vhost back and nginx is not reloaded.
#   supervisor  stdout_logfile of the app's programs. A program that is running
#               is restarted on the new configuration (supervisorctl update, what
#               a deploy does); one that is stopped is not started here —
#               supervisord applies its new configuration, and starts it, at
#               the next `supervisorctl update` (any deploy on the server). A
#               file supervisord does not re-read is put back.
#   Node SSR    the blue/green switch a deploy makes (cipi-node-switch), which
#               writes the slots' configuration itself. No downtime.
#   PHP-FPM     the pool's open_basedir gains the log directory, so the app's
#               own PHP (cipi/agent) still reads its logs through ~/logs.
#               Tested with php-fpm -t; a refused pool is put back.
#   ~/logs      one symlink per moved log, made as the app user; the file that
#               was there stays as <name>.old.
#   logrotate   the two Cipi files name the new directory — and keep the old
#               lines for as long as something still logs there.
#   CrowdSec    the nginx acquisition names the new directory — once no vhost
#               is left on the old one.
#
# Every step tolerates failure and says what it left alone. Nothing here
# aborts the caller.
#
# For the caller (migration 5.9.0 merges these into its own restarts):
#   APP_LOGS_FPM_VERSIONS    PHP versions whose pools changed and still need a
#                            restart (with --fpm=defer)
#   APP_LOGS_UPDATED         supervisor program groups restarted here
#   APP_LOGS_NODE_SWITCHED   Node SSR apps switched here
#   APP_LOGS_LEFT            how many things stayed on the old path
#############################################

APP_LOGS_FPM_VERSIONS=""
APP_LOGS_UPDATED=""
APP_LOGS_NODE_SWITCHED=""
APP_LOGS_LEFT=0

# cron runs root's jobs with /usr/bin:/bin: nginx and php-fpm live in /usr/sbin.
_app_logs_bin() {
    local b
    b=$(command -v "$1" 2>/dev/null || true)
    [[ -n "$b" ]] || b="/usr/sbin/$1"
    [[ -x "$b" ]] && echo "$b"
    return 0
}

_app_logs_say() { echo "  $*"; }

# Names of the logs a supervisor file sends to /var/log/cipi-apps/<app>.
_app_logs_supervisor_names() {   # <app> <conf>
    sed -n "s#^stdout_logfile=/var/log/cipi-apps/${1}/\\([A-Za-z0-9._-]*\\)\$#\\1#p" "$2" 2>/dev/null | sort -u
}

app_logs_relocate() {
    local fpm_mode="reload" a
    local -a want=()
    for a in "$@"; do
        case "$a" in
            --fpm=reload|--fpm=defer) fpm_mode="${a#--fpm=}" ;;
            --*) ;;
            *) want+=("$a") ;;
        esac
    done

    APP_LOGS_FPM_VERSIONS=""; APP_LOGS_UPDATED=""; APP_LOGS_NODE_SWITCHED=""; APP_LOGS_LEFT=0

    local -a apps=()
    if [[ ${#want[@]} -gt 0 ]]; then
        apps=("${want[@]}")
    elif [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        mapfile -t apps < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    fi

    local -a ok_apps=()
    local app
    for app in "${apps[@]}"; do
        [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
        [[ "$app" != "root" && "$app" != "cipi" && "$app" != "www-data" ]] || continue
        id "$app" &>/dev/null || continue
        if ! app_log_dir_ensure "$app"; then
            _app_logs_say "WARNING: ${app}: could not create $(app_log_dir "$app") — its logs stay where they are"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
            continue
        fi
        ok_apps+=("$app")
    done
    [[ ${#ok_apps[@]} -gt 0 ]] || return 0

    local backup
    backup="/var/lib/cipi/app-logs-backup/$(date +%Y%m%d%H%M%S)"
    mkdir -p "${backup}/nginx" "${backup}/supervisor" "${backup}/fpm" 2>/dev/null || true
    chmod 700 /var/lib/cipi/app-logs-backup "$backup" 2>/dev/null || true

    # The deploy log first: nothing to reload, and the app user's own deploy
    # script already writes the new file as soon as it is there.
    for app in "${ok_apps[@]}"; do
        app_log_links "$app" deploy.log
    done

    _app_logs_nginx "$backup" "${ok_apps[@]}"
    _app_logs_supervisor "$backup" "${ok_apps[@]}"
    _app_logs_node "${ok_apps[@]}"
    _app_logs_fpm "$backup" "$fpm_mode" "${ok_apps[@]}"
    _app_logs_logrotate
    _app_logs_crowdsec

    # Nothing was changed: no empty backup left behind.
    find "$backup" -depth -type d -empty -delete 2>/dev/null || true
    return 0
}

# ── nginx ────────────────────────────────────────────────────
_app_logs_nginx() {   # <backup> <app>…
    local backup="$1"; shift
    local nginx_bin app f n=0
    local -a changed_files=() changed_apps=()
    nginx_bin=$(_app_logs_bin nginx)
    [[ -n "$nginx_bin" && -d /etc/nginx/sites-available ]] || return 0

    local -A files_of=()
    for app in "$@"; do
        while IFS= read -r f; do
            [[ -f "$f" && ! -L "$f" ]] || continue
            files_of["$f"]="$app"
        done < <(grep -rlF "/home/${app}/logs/nginx-" /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null || true)
    done
    if [[ ${#files_of[@]} -eq 0 ]]; then
        # Vhosts already on the new directory: only the symlinks may be missing.
        for app in "$@"; do
            grep -qsF "/var/log/cipi-apps/${app}/nginx-" "/etc/nginx/sites-available/${app}" && app_log_links "$app" nginx-access.log nginx-error.log
        done
        return 0
    fi

    # A configuration that does not pass as it is cannot tell us whether our
    # change is good: leave nginx alone.
    if ! "$nginx_bin" -t &>/dev/null; then
        _app_logs_say "WARNING: nginx: the configuration does not pass 'nginx -t' as it is — vhosts not touched (${#files_of[@]} still log to ~/logs). Fix it, then: cipi app fix-permissions"
        APP_LOGS_LEFT=$((APP_LOGS_LEFT + ${#files_of[@]}))
        return 0
    fi

    for f in "${!files_of[@]}"; do
        app="${files_of[$f]}"
        # One backup name per file: sites-available/x and conf.d/x would collide.
        if ! cp -p "$f" "${backup}/nginx/$(printf '%s' "$f" | tr '/' '_')" 2>/dev/null; then
            _app_logs_say "WARNING: nginx: could not back up ${f} — left alone"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
            continue
        fi
        if sed -i "s#/home/${app}/logs/nginx-#/var/log/cipi-apps/${app}/nginx-#g" "$f" 2>/dev/null; then
            changed_files+=("$f")
            [[ " ${changed_apps[*]:-} " == *" ${app} "* ]] || changed_apps+=("$app")
        else
            _app_logs_say "WARNING: nginx: could not edit ${f} — left alone"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
        fi
    done
    [[ ${#changed_files[@]} -gt 0 ]] || return 0

    local restore=false
    if ! "$nginx_bin" -t &>/dev/null; then
        restore=true
        _app_logs_say "WARNING: nginx refused the vhosts with the new log directory — every vhost put back, nginx not reloaded. Check: nginx -t, then: cipi app fix-permissions"
    elif ! systemctl reload nginx 2>/dev/null; then
        restore=true
        _app_logs_say "WARNING: nginx did not reload — every vhost put back. Check: systemctl status nginx, then: cipi app fix-permissions"
    fi
    if [[ "$restore" == true ]]; then
        for f in "${changed_files[@]}"; do
            cp -p "${backup}/nginx/$(printf '%s' "$f" | tr '/' '_')" "$f" 2>/dev/null || _app_logs_say "WARNING: nginx: could not put ${f} back — the copy is in ${backup}/nginx"
        done
        APP_LOGS_LEFT=$((APP_LOGS_LEFT + ${#changed_files[@]}))
        return 0
    fi

    # nginx writes the new files now: the old ones become <name>.old and
    # ~/logs/nginx-*.log point at the new ones.
    for app in "${changed_apps[@]}"; do
        app_log_links "$app" nginx-access.log nginx-error.log
        n=$((n + 1))
    done
    _app_logs_say "nginx: ${n} app(s) now log to /var/log/cipi-apps (${#changed_files[@]} vhost file(s), nginx reloaded)"
    return 0
}

# ── supervisor ───────────────────────────────────────────────
_app_logs_supervisor() {   # <backup> <app>…
    local backup="$1"; shift
    local app conf group running out
    local -a changed=() names=()
    command -v supervisorctl &>/dev/null || return 0

    for app in "$@"; do
        conf="/etc/supervisor/conf.d/${app}.conf"
        [[ -f "$conf" && ! -L "$conf" ]] || continue
        if grep -q "^stdout_logfile=/home/${app}/logs/" "$conf" 2>/dev/null; then
            if cp -p "$conf" "${backup}/supervisor/${app}.conf" 2>/dev/null \
               && sed -i "s#^stdout_logfile=/home/${app}/logs/#stdout_logfile=/var/log/cipi-apps/${app}/#" "$conf" 2>/dev/null; then
                changed+=("$app")
            else
                _app_logs_say "WARNING: supervisor: could not edit ${conf} — left alone"
                APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
                continue
            fi
            continue
        fi
        # Nothing to edit (a second run, or an app created on 5.9.0): only
        # make sure ~/logs/<name> is there for what this file already sends
        # to the new directory.
        mapfile -t names < <(_app_logs_supervisor_names "$app" "$conf")
        [[ ${#names[@]} -gt 0 ]] && app_log_links "$app" "${names[@]}"
    done
    [[ ${#changed[@]} -gt 0 ]] || return 0

    if ! supervisorctl reread &>/dev/null; then
        # supervisord not running, or it refused a file: put ours back so the
        # next start reads what it read before.
        for app in "${changed[@]}"; do
            cp -p "${backup}/supervisor/${app}.conf" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null || true
        done
        supervisorctl reread &>/dev/null || true
        _app_logs_say "WARNING: supervisor: 'supervisorctl reread' failed — ${#changed[@]} app(s) keep their worker logs in ~/logs. Check: supervisorctl status, then: cipi app fix-permissions"
        APP_LOGS_LEFT=$((APP_LOGS_LEFT + ${#changed[@]}))
        return 0
    fi

    local n_run=0 n_stopped=0
    for app in "${changed[@]}"; do
        conf="/etc/supervisor/conf.d/${app}.conf"
        # supervisord accepted the file: only now does ~/logs/<name> become a
        # link (a file that went back keeps its regular log files).
        mapfile -t names < <(_app_logs_supervisor_names "$app" "$conf")
        [[ ${#names[@]} -gt 0 ]] && app_log_links "$app" "${names[@]}"
        for group in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//'); do
            running=$(supervisorctl status "${group}:*" 2>/dev/null \
                | awk '$2 == "RUNNING" || $2 == "STARTING" || $2 == "BACKOFF" { print $1 }' || true)
            if [[ -z "$running" ]]; then
                # Stopped by someone (or FATAL): not started here. supervisord
                # holds its new configuration as a pending change and applies
                # it — starting the program, as a deploy of the app always
                # did — at the next `supervisorctl update`: every deploy on
                # this server and every `cipi worker add|edit` run one.
                n_stopped=$((n_stopped + 1))
                continue
            fi
            # `update <group>` restarts the group only when its section
            # changed, and says so; a program of the same file that logs
            # somewhere else is not touched (and not counted as restarted).
            if out=$(supervisorctl update "$group" 2>&1); then
                if grep -q 'updated process group' <<< "$out"; then
                    APP_LOGS_UPDATED="${APP_LOGS_UPDATED} ${group}"
                    n_run=$((n_run + 1))
                fi
            else
                _app_logs_say "WARNING: supervisor: could not restart ${group} on its new configuration — run: supervisorctl update ${group}"
                APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
            fi
        done
    done
    _app_logs_say "supervisor: ${n_run} program(s) restarted with their log in /var/log/cipi-apps$( (( n_stopped > 0 )) && echo "; ${n_stopped} stopped one(s) not started now — supervisor applies their new configuration, and starts them, at the next deploy on this server (to keep one stopped after that: cipi worker stop <app>)")"
    return 0
}

# ── Node SSR (blue/green) ────────────────────────────────────
_app_logs_node() {   # <app>…
    local app state active
    [[ -x /usr/local/bin/cipi-node-switch ]] || return 0
    for app in "$@"; do
        grep -qs "^stdout_logfile=/home/${app}/logs/" "/etc/supervisor/conf.d/${app}-node.conf" || continue
        state="/var/lib/cipi/node/${app}.json"
        [[ -f "$state" && -L "/home/${app}/current" ]] || continue
        [[ "$(jq -r '.mode // "ssr"' "$state" 2>/dev/null || true)" == "ssr" ]] || continue
        active=$(jq -r '.active // -1' "$state" 2>/dev/null || true)
        [[ "$active" == "0" || "$active" == "1" ]] || continue
        if ! ( exec 8>"/run/lock/cipi-node-${app}.lock" && flock -n 8 ) 2>/dev/null; then
            _app_logs_say "${app}: Node switch in progress (a deploy?) — left alone; if it was not a deploy: cipi node restart ${app}"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
            continue
        fi
        # SUDO_USER dropped: the switch refuses a sudo caller that is not the
        # app, and this is root's own work whoever typed `sudo cipi …`.
        if env -u SUDO_USER /usr/local/bin/cipi-node-switch "$app" current >/dev/null 2>&1; then
            APP_LOGS_NODE_SWITCHED="${APP_LOGS_NODE_SWITCHED} ${app}"
            _app_logs_say "${app}: Node process restarted (blue/green, no downtime), its log is in /var/log/cipi-apps"
        else
            _app_logs_say "WARNING: ${app}: Node process not restarted — its log stays in ~/logs until the next deploy or: cipi node restart ${app}"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
        fi
    done
    return 0
}

# ── PHP-FPM pools: open_basedir ──────────────────────────────
_app_logs_fpm() {   # <backup> <reload|defer> <app>…
    local backup="$1" mode="$2"; shift 2
    local app pool v fpm_bin
    local -a versions=()
    for app in "$@"; do
        for pool in /etc/php/*/fpm/pool.d/"${app}.conf"; do
            [[ -f "$pool" && ! -L "$pool" ]] || continue
            v=$(printf '%s' "$pool" | sed -n 's#.*/php/\([0-9]\.[0-9]\)/fpm/pool\.d/.*#\1#p')
            [[ -n "$v" ]] || continue
            # Only the line Cipi writes: the app's home first. A pool someone
            # rewrote by hand is not guessed at.
            grep -qE "^php_admin_value\[open_basedir\][[:space:]]*=[[:space:]]*/home/${app}/:" "$pool" 2>/dev/null || continue
            grep -qE "^php_admin_value\[open_basedir\].*[=:]/var/log/cipi-apps/${app}/(:|\$)" "$pool" 2>/dev/null && continue
            mkdir -p "${backup}/fpm/${v}" 2>/dev/null || true
            if cp -p "$pool" "${backup}/fpm/${v}/${app}.conf" 2>/dev/null \
               && sed -i -E "s#^(php_admin_value\[open_basedir\][[:space:]]*=[[:space:]]*/home/${app}/:)#\1/var/log/cipi-apps/${app}/:#" "$pool" 2>/dev/null; then
                [[ " ${versions[*]:-} " == *" ${v} "* ]] || versions+=("$v")
            else
                _app_logs_say "WARNING: php ${v}: could not edit ${pool} — left alone"
            fi
        done
    done
    [[ ${#versions[@]} -gt 0 ]] || return 0

    for v in "${versions[@]}"; do
        fpm_bin=$(_app_logs_bin "php-fpm${v}")
        if [[ -n "$fpm_bin" ]] && ! "$fpm_bin" -t &>/dev/null; then
            # Ours, or something that was already wrong: either way the pools
            # go back, and FPM is left to whoever looks at php-fpm -t.
            for pool in "${backup}/fpm/${v}"/*.conf; do
                [[ -f "$pool" ]] && cp -p "$pool" "/etc/php/${v}/fpm/pool.d/" 2>/dev/null || true
            done
            _app_logs_say "WARNING: php ${v}: FPM configuration test failed with the new open_basedir — pools put back (the app's own PHP cannot read the moved logs through ~/logs until: cipi app fix-permissions)"
            APP_LOGS_LEFT=$((APP_LOGS_LEFT + 1))
            continue
        fi
        if [[ "$mode" == "defer" ]]; then
            APP_LOGS_FPM_VERSIONS="${APP_LOGS_FPM_VERSIONS} ${v}"
        elif systemctl reload "php${v}-fpm" 2>/dev/null || systemctl restart "php${v}-fpm" 2>/dev/null; then
            _app_logs_say "php ${v}: pools may read /var/log/cipi-apps/<app> (FPM reloaded)"
        else
            _app_logs_say "WARNING: php ${v}: FPM did not reload — run: systemctl reload php${v}-fpm"
        fi
    done
    return 0
}

# ── logrotate ────────────────────────────────────────────────
# The two files setup.sh writes. A moved log is rotated where it now is; the
# old lines would match the symlinks in ~/logs, which logrotate refuses.
_app_logs_logrotate_line() {   # <file> <keep old: true|false> <old line> <new line>
    local f="$1" keep="$2" old="$3" new="$4" has=0 tmp
    [[ -f "$f" && ! -L "$f" ]] || return 1
    grep -qxF -- "$old" "$f" 2>/dev/null || return 1
    grep -qxF -- "$new" "$f" 2>/dev/null && has=1
    [[ "$keep" == true && "$has" == 1 ]] && return 1
    tmp=$(mktemp) || return 1
    if awk -v o="$old" -v n="$new" -v keep="$keep" -v has="$has" '
            $0 == o { if (keep == "true") print; if (has != "1") print n; next }
            { print }' "$f" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        cat "$tmp" > "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}
_app_logs_logrotate() {
    local changed=false keep_http=false keep_app=false
    # Whatever could not be moved keeps being rotated where it is: the old
    # lines go only when nothing writes there any more. (A name that is now a
    # symlink is skipped by logrotate, so the two sets of lines never rotate
    # the same file twice.)
    grep -rqsE '/home/[a-z][a-z0-9]*/logs/nginx-' /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null && keep_http=true
    grep -qsE '^stdout_logfile=/home/[a-z][a-z0-9]*/logs/' /etc/supervisor/conf.d/*.conf 2>/dev/null && keep_app=true

    local f=/etc/logrotate.d/cipi-app-logs
    _app_logs_logrotate_line "$f" "$keep_app" '/home/*/logs/worker-*.log' '/var/log/cipi-apps/*/worker-*.log' && changed=true
    _app_logs_logrotate_line "$f" "$keep_app" '/home/*/logs/deploy.log'   '/var/log/cipi-apps/*/deploy.log'   && changed=true
    f=/etc/logrotate.d/cipi-http-logs
    _app_logs_logrotate_line "$f" "$keep_http" '/home/*/logs/nginx-access.log' '/var/log/cipi-apps/*/nginx-access.log' && changed=true
    _app_logs_logrotate_line "$f" "$keep_http" '/home/*/logs/nginx-error.log'  '/var/log/cipi-apps/*/nginx-error.log'  && changed=true

    [[ "$changed" == true ]] && _app_logs_say "logrotate: nginx, worker and deploy logs are rotated in /var/log/cipi-apps"
    return 0
}
_app_logs_crowdsec() {
    local f=/etc/crowdsec/acquis.d/cipi-nginx.yaml
    [[ -f "$f" ]] && grep -qF '/home/*/logs/nginx-access.log' "$f" 2>/dev/null || return 0
    grep -rqsE '/home/[a-z][a-z0-9]*/logs/nginx-' /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null && return 0
    if sed -i -e 's#/home/\*/logs/nginx-access\.log#/var/log/cipi-apps/*/nginx-access.log#' \
              -e 's#/home/\*/logs/nginx-error\.log#/var/log/cipi-apps/*/nginx-error.log#' "$f" 2>/dev/null; then
        systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
        _app_logs_say "CrowdSec: nginx logs read from /var/log/cipi-apps"
    fi
    return 0
}
