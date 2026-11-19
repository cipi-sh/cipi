#!/bin/bash
#############################################
# Cipi — PHP Version Management
#############################################

readonly _PHP_EXT="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached redis zip xml soap gd imagick intl"

# True when apt can install every package given, now. A simulation, not a
# look at the candidate: on the Ubuntu archive some of these names are
# virtual packages, and a package can be listed and still not install.
_php_pkg_installable() {
    DEBIAN_FRONTEND=noninteractive apt-get install -s -qq "$@" >/dev/null 2>&1
}

# PHP_EXT_PENDING and its reader (php_ext_pending) are in common.sh:
# `cipi pending` reads the list too. Here, what writes it. Replaces the
# lines of <version> with the extensions given (none: forgets the version).
_php_ext_pending_set() {
    local v="$1" tmp e; shift
    mkdir -p "$(dirname "$PHP_EXT_PENDING")" 2>/dev/null || return 0
    tmp=$(mktemp "${PHP_EXT_PENDING}.XXXXXX" 2>/dev/null) || return 0
    {
        # The other versions' lines, and only lines of the shape the reader
        # accepts: anything else would keep the file alive for ever.
        php_ext_pending | awk -v v="$v" '$1 != v' || true
        for e in "$@"; do printf '%s %s\n' "$v" "$e"; done
    } > "$tmp"
    if [[ -s "$tmp" ]]; then
        chmod 644 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$PHP_EXT_PENDING" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp" "$PHP_EXT_PENDING"
    fi
    return 0
}

# Installs the listed extensions apt has by now. Sets _PHP_EXT_ADDED to the
# PHP versions that got one (their FPM has to be restarted to load it).
_php_ext_pending_install() {
    _PHP_EXT_ADDED=""
    [[ -s "$PHP_EXT_PENDING" ]] || return 0
    local v e still got
    for v in $(php_ext_pending | awk '{ print $1 }' | sort -u); do
        if ! php_is_installed "$v"; then
            _php_ext_pending_set "$v"
            continue
        fi
        still=""; got=""
        for e in $(php_ext_pending "$v"); do
            if _php_pkg_installable "php${v}-${e}" \
               && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq \
                    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
                    "php${v}-${e}" >/dev/null 2>&1; then
                got="${got} ${e}"
            else
                still="${still} ${e}"
            fi
        done
        # shellcheck disable=SC2086
        _php_ext_pending_set "$v" $still
        if [[ -n "$got" ]]; then
            _PHP_EXT_ADDED="${_PHP_EXT_ADDED} ${v}"
            log_action "PHP EXTENSIONS: ${v} +${got# }"
            success "PHP ${v}: installed${got} (now in the repository)"
        fi
        if [[ -n "$still" ]]; then
            info "PHP ${v}: still not in the repository:${still}"
        fi
    done
    return 0
}

php_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install) _php_install "$@" ;;
        remove)  _php_remove "$@" ;;
        switch)  _php_switch "$@" ;;
        upgrade) _php_upgrade "$@" ;;
        list|ls) _php_list "$@" ;;
        *) error "Use: install remove switch upgrade list"; exit 1 ;;
    esac
}

# Daily cron + migration hook — idempotent root crontab entry.
# Daily since 5.6.3: the weekly run left a server up to six days behind a
# PHP security release. apt only restarts FPM when a package changed, so a
# quiet day costs one `apt-get update`.
_php_setup_upgrade_cron() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] && return 0
    local cur
    cur=$(crontab -l 2>/dev/null || true)
    if grep -qF 'cipi php upgrade' <<< "$cur"; then
        # The weekly line Cipi wrote before 5.6.3 becomes daily. A schedule
        # the operator changed by hand is theirs and is left alone.
        if grep -qE '^30 3 \* \* 0 .*cipi php upgrade' <<< "$cur"; then
            sed -e 's/^# PHP security patch check (Sunday 3:30 AM)$/# PHP security patch check (daily 3:30 AM)/' \
                -e 's/^30 3 \* \* 0 \(.*cipi php upgrade\)/30 3 * * * \1/' <<< "$cur" | crontab -
        fi
        return 0
    fi
    grep -q "CIPI CRON" <<< "$cur" || return 0
    {
        printf '%s\n' "$cur"
        echo "# PHP security patch check (daily 3:30 AM)"
        echo '30 3 * * * /usr/local/bin/cipi-cron-notify php-upgrade /usr/local/bin/cipi php upgrade >> /var/log/cipi/php-upgrade.log 2>&1'
    } | crontab -
}

# End of security support for a branch that still gets fixes, if it is near.
_php_branch_eol() {
    case "$1" in
        8.2) echo "2026-12-31" ;;
    esac
}

# One line per installed PHP branch: the version and how it stands against
# php_security_floor. Returns 1 when a branch is below the floor on a
# repository that ships upstream versions — the fix exists, this server
# does not have it yet.
_php_security_report() {
    local v state full floor eol ext bad=0
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        php_is_installed "$v" || continue
        read -r state full <<< "$(php_security_state "$v")"
        floor=$(php_security_floor "$v")
        eol=$(_php_branch_eol "$v")
        case "$state" in
            patched)
                echo -e "  PHP ${v}  ${GREEN}${full}${NC}  patched${eol:+ ${YELLOW}— security fixes end ${eol}, move apps to 8.3+${NC}}"
                ;;
            vulnerable)
                echo -e "  PHP ${v}  ${RED}${full}${NC}  ${RED}VULNERABLE${NC} — ${floor} fixes it; if the repository does not have it yet, run cipi php upgrade again later"
                bad=1
                ;;
            distro)
                echo -e "  PHP ${v}  ${YELLOW}${full}${NC}  Ubuntu archive build — fixes are backported without a version bump; check: apt changelog php${v}-fpm"
                ;;
            eol)
                echo -e "  PHP ${v}  ${RED}${full}${NC}  ${RED}END OF LIFE${NC} — the PHP project no longer patches ${v}; move its apps: cipi app edit <app> --php=8.5"
                ;;
            prerelease)
                echo -e "  PHP ${v}  ${YELLOW}${full}${NC}  ${YELLOW}pre-release${NC} — not for production; the repository does not have ${floor} yet, this command installs it when it does"
                ;;
            *)
                echo -e "  PHP ${v}  ${YELLOW}php${v} CLI not found${NC} — version unknown"
                ;;
        esac
        ext=$(php_ext_pending "$v" | paste -sd' ' - || true)
        if [[ -n "$ext" ]]; then
            echo -e "           ${YELLOW}without: ${ext}${NC} — not in the repository for ${v} yet; installed by this command when they are"
        fi
    done
    return "$bad"
}

# Octane apps answer requests from the FrankenPHP binary Octane downloads
# into the release, and that binary carries a PHP of its own: apt never
# patches it. One line per Octane app with the PHP inside the binary. The
# binary belongs to the app user, so it runs as that user, never as root.
# Returns 1 when a binary embeds a PHP below php_security_floor.
_php_frankenphp_report() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    local app bin out full floor bad=0
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        bin="/home/${app}/current/frankenphp"
        if [[ ! -x "$bin" ]] || ! id "$app" &>/dev/null; then
            echo -e "  ${app}  ${YELLOW}no FrankenPHP binary in current/${NC} — check the PHP it runs on with: frankenphp -v"
            continue
        fi
        # …and with no terminal: this is the app's own program, and with the
        # admin's terminal as its own it could type into it (TIOCSTI).
        out=$(runuser -u "$app" -- setsid -w timeout 10 "$bin" -v 2>/dev/null < /dev/null || true)
        full=$(grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' <<< "$out" | head -1 | cut -d' ' -f2 || true)
        if [[ -z "$full" ]]; then
            echo -e "  ${app}  ${YELLOW}FrankenPHP did not report its PHP version${NC} — check: ${bin} -v"
            continue
        fi
        floor=$(php_security_floor "${full%.*}")
        if [[ -n "$floor" ]] && version_at_least "$full" "$floor"; then
            echo -e "  ${app}  FrankenPHP on PHP ${GREEN}${full}${NC}  patched"
        else
            echo -e "  ${app}  FrankenPHP on PHP ${RED}${full}${NC}  ${RED}VULNERABLE${NC} — needs a FrankenPHP build on PHP ${floor:-8.3+}: run php artisan octane:install --server=frankenphp in /home/${app}/current as ${app}, then supervisorctl restart ${app}-octane"
            bad=1
        fi
    done < <(vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select(.value.octane == "frankenphp") | .key' 2>/dev/null || true)
    return "$bad"
}

_php_upgrade() {
    local LOCK=/run/cipi-php-upgrade.lock apt_opts='-o DPkg::Lock::Timeout=300'
    exec 9>"$LOCK"
    if ! flock -n 9; then
        info "PHP upgrade check already running — skip"
        return 0
    fi

    local has_php=false v
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        if php_is_installed "$v"; then
            has_php=true
            break
        fi
    done
    [[ "$has_php" == false ]] && { info "No PHP installed — skip"; return 0; }

    local -a installed=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && installed+=("$pkg")
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(php[0-9]|php-|libphp)' || true)
    [[ ${#installed[@]} -eq 0 ]] && { info "No PHP packages found — skip"; return 0; }

    step "Checking for PHP package upgrades..."
    apt-get $apt_opts update -qq

    local out rc upgraded
    out=$(DEBIAN_FRONTEND=noninteractive apt-get $apt_opts install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        --only-upgrade "${installed[@]}" 2>&1) || rc=$?
    rc=${rc:-0}
    echo "$out"

    upgraded=$(echo "$out" | grep -oE '^[0-9]+ upgraded' | grep -oE '^[0-9]+' | head -1)
    upgraded=${upgraded:-0}

    # Extensions the repository did not have when the version was installed.
    _php_ext_pending_install || true

    if [[ "$upgraded" -eq 0 ]]; then
        info "PHP packages are up to date"
        rc=0
        # A new extension is loaded by the FPM that starts after it.
        for v in ${_PHP_EXT_ADDED:-}; do
            php_is_installed "$v" && reload_php_fpm "$v" 2>/dev/null || true
        done
    else
        # A restart, not a reload: every worker has to go, since a stale
        # worker can hold request state across requests (CVE-2026-109619).
        step "Restarting PHP-FPM services..."
        for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
            php_is_installed "$v" && reload_php_fpm "$v" 2>/dev/null || true
        done

        log_action "PHP UPGRADE: ${upgraded} package(s)"
        cipi_notify \
            "Cipi PHP upgraded on $(hostname)" \
            "Installed PHP packages were upgraded.\n\nServer: $(hostname)\nPackages upgraded: ${upgraded}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            php_upgrade
        success "PHP packages upgraded (${upgraded})"
    fi

    step "Security patch level..."
    _php_security_report || { [[ $rc -ne 0 ]] || rc=1; }
    if vault_read apps.json 2>/dev/null | jq -e 'any(.[]; .octane == "frankenphp")' &>/dev/null; then
        step "Octane apps (FrankenPHP ships its own PHP — apt does not patch it)..."
        _php_frankenphp_report || { [[ $rc -ne 0 ]] || rc=1; }
    fi
    return "$rc"
}

# setup.sh and `cipi php switch` set the `php` alternative by hand, and a
# package installed later leaves it alone. Where it is still automatic (a
# server whose alternative was never set, or reset with --auto), apt gives
# `php` to the highest version it has just installed: 8.6 would become the
# server's PHP by being installed. Put back what it was ($1).
_php_keep_system() {
    local was="${1:-}" now
    [[ -n "$was" ]] || return 0
    now=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    [[ "$now" == "$was" ]] && return 0
    update-alternatives --set php "/usr/bin/php${was}" >/dev/null 2>&1 || true
    now=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    if [[ "$now" == "$was" ]]; then
        info "The server's PHP stays ${was} (cipi php switch changes it)"
    else
        warn "The php command now answers ${now:-nothing}, it was ${was} — put it back: cipi php switch ${was}"
    fi
}

_php_install() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php install <8.3|8.4|8.5|8.6>"; exit 1; }
    validate_php_version "$v" || { error "Invalid PHP version: $v (Deployer 8 requires PHP >= 8.3; use 8.3, 8.4, 8.5 or 8.6)"; exit 1; }
    php_is_installed "$v" && { info "PHP $v already installed"; return; }
    # Installing a version adds it; it does not make it the server's PHP
    # (the `php` command, the panel's pools, what a new app gets by default).
    local sys_before
    sys_before=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/php-apt.sh"
    step "Configuring PHP APT sources..."
    if ! php_setup_apt_sources; then
        info "No multi-PHP repo — using Ubuntu archive for PHP ${v} (single version only)"
    else
        info "PHP packages via $(php_apt_source_label)"
    fi
    apt-get update -qq
    step "Installing PHP ${v}..."
    # What the repository has. FPM, common and the CLI are PHP itself: without
    # them there is nothing to install. The rest is installed where it exists
    # and remembered where it does not (PHP_EXT_PENDING above).
    local pkgs="" missing="" e
    for e in $_PHP_EXT; do pkgs+=" php${v}-${e}"; done
    # shellcheck disable=SC2086
    if ! _php_pkg_installable $pkgs; then
        # Not all of them: one by one, to know which.
        pkgs=""
        for e in $_PHP_EXT; do
            if _php_pkg_installable "php${v}-${e}"; then
                pkgs+=" php${v}-${e}"
                continue
            fi
            case "$e" in
                fpm|common|cli)
                    error "apt cannot install php${v}-${e} (packages from: $(php_apt_source_label)) — PHP ${v} is not available here"
                    echo -e "  ${DIM}Check: apt-get install -s php${v}-${e}${NC}"
                    exit 1
                    ;;
            esac
            missing+=" ${e}"
        done
    fi
    # shellcheck disable=SC2086
    apt-get install -y -qq $pkgs
    _php_keep_system "$sys_before"
    # shellcheck disable=SC2086
    _php_ext_pending_set "$v" $missing
    # The hardening lines (php_fpm_ini_hardening) reach every pool of this
    # version, including the stock `www` pool below, which no Cipi vhost uses
    # but which still answers on its socket.
    cat > "/etc/php/${v}/fpm/conf.d/99-cipi.ini" <<EOF
memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
$(php_fpm_ini_hardening)
EOF
    # Placeholder pool (same as setup.sh): no vhost uses it, socket 0600 so
    # only www-data itself can reach a pool that runs without open_basedir.
    cat > "/etc/php/${v}/fpm/pool.d/www.conf" <<POOLEOF
[www]
user = www-data
group = www-data
listen = /run/php/php${v}-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0600
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
POOLEOF
    systemctl restart "php${v}-fpm"; systemctl enable "php${v}-fpm"
    log_action "PHP INSTALLED: $v${missing:+ (without:${missing})}"
    cipi_notify \
        "Cipi PHP installed: ${v} on $(hostname)" \
        "A PHP version was installed.\n\nServer: $(hostname)\nVersion: ${v}${missing:+\nNot in the repository yet, installed later by cipi php upgrade:${missing}}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        php_install
    success "PHP ${v} installed"
    if [[ -n "$sys_before" && "$sys_before" != "$v" ]]; then
        echo -e "  ${DIM}The server's PHP is still ${sys_before}: an app moves with cipi app edit <app> --php=${v}, the server with cipi php switch ${v}${NC}"
    fi

    # What a new branch looks like on its first days: said here, once, and
    # every morning by `cipi pending` for as long as it lasts.
    local sec full
    read -r sec full <<< "$(php_security_state "$v")"
    if [[ "$sec" == "prerelease" ]]; then
        warn "The repository's PHP ${v} is a pre-release (${full}) — not for production. cipi php upgrade (daily, 03:30) moves it to $(php_security_floor "$v") when the repository has it."
    fi
    if [[ -n "$missing" ]]; then
        warn "PHP ${v} is installed without:${missing} — the repository ($(php_apt_source_label)) has no package of them for ${v} yet."
        echo -e "  ${DIM}cipi php upgrade (daily, 03:30) installs them when it has. Until then an app that needs one${NC}"
        echo -e "  ${DIM}does not work on ${v} — Laravel's default Redis client (phpredis) is the redis extension —${NC}"
        echo -e "  ${DIM}and cipi app create / cipi app edit --php=${v} ask for --force.${NC}"
    fi
}

# update-alternatives + FPM pool moves need a writable /etc (same remount-ro
# class as smtp / basicauth / vault).
_php_ensure_etc_writable() {
    if ! _cipi_ensure_config_writable; then
        error "Cannot write config (read-only filesystem)"
        [[ -n "${_CIPI_REMOUNT_ERR:-}" ]] && error "Remount failed: ${_CIPI_REMOUNT_ERR}"
        error "Try as root: mount -n -o remount,rw / && cipi php switch <ver>"
        return 1
    fi
    if ! _cipi_path_writable /etc; then
        _cipi_remount_rw /etc || _cipi_remount_rw / || true
    fi
    if ! _cipi_path_writable /etc; then
        error "Cannot write /etc (read-only file system)"
        [[ -n "${_CIPI_REMOUNT_ERR:-}" ]] && error "Remount failed: ${_CIPI_REMOUNT_ERR}"
        error "Try as root: mount -n -o remount,rw / && cipi php switch <ver>"
        return 1
    fi
    # Stale atomic-swap leftovers from a previous RO failure block --set.
    rm -f /etc/alternatives/php.dpkg-tmp \
          /etc/alternatives/phar.dpkg-tmp \
          /etc/alternatives/phar.phar.dpkg-tmp \
          /etc/alternatives/phpdbg.dpkg-tmp 2>/dev/null || true
    return 0
}

_PHP_API_SOCK="${_PHP_API_SOCK:-/run/php/cipi-api.sock}"
_PHP_GUI_SOCK="${_PHP_GUI_SOCK:-/run/php/cipi-gui.sock}"

_php_pool_path() {
    # $1=php version  $2=pool name (cipi-api|cipi-gui)
    echo "/etc/php/${1}/fpm/pool.d/${2}.conf"
}

_php_find_pool_version() {
    # $1=pool name — prints first PHP version that has it, or empty.
    local name="$1" pv
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        if [[ -f "$(_php_pool_path "$pv" "$name")" ]]; then
            echo "$pv"
            return 0
        fi
    done
    return 1
}

_php_clear_named_pools_except() {
    # $1=keep version (empty=all)  $2=pool name
    local keep="${1:-}" name="$2" pv
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        [[ "$pv" == "$keep" ]] && continue
        rm -f "$(_php_pool_path "$pv" "$name")" 2>/dev/null || true
    done
}

# Compat alias used by older call sites / mental model.
_php_clear_api_fpm_pools_except() { _php_clear_named_pools_except "${1:-}" "cipi-api"; }

_php_prepare_run_php() {
    mkdir -p /run/php
    chown root:root /run/php 2>/dev/null || true
    chmod 755 /run/php 2>/dev/null || true
}

_php_wait_socket() {
    local sock="$1" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [[ -S "$sock" ]] && return 0
        sleep 0.2
    done
    return 1
}

# Write (or rewrite) the panel API FPM pool for PHP $1.
_php_write_api_fpm_pool() {
    local v="$1"
    local api_root="${CIPI_API_ROOT:-/opt/cipi/api}"
    local pool; pool="$(_php_pool_path "$v" "cipi-api")"

    [[ -n "$v" ]] || return 1
    _php_ensure_etc_writable || return 1
    _php_prepare_run_php
    mkdir -p "$(dirname "$pool")"

    cat > "$pool" <<POOL
[cipi-api]
user = www-data
group = www-data
listen = ${_PHP_API_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
listen.backlog = 1024
pm = dynamic
pm.max_children = 25
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 200
pm.process_idle_timeout = 60s
pm.status_path = /cipi-api-fpm-status
request_terminate_timeout = 300
request_slowlog_timeout = 30
slowlog = /var/log/cipi-api-fpm-slow.log
catch_workers_output = yes
decorate_workers_output = no
php_admin_value[open_basedir] = ${api_root}/:/tmp/:/etc/cipi/:/proc/:/usr/local/bin/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/cipi-api-php-error.log
php_admin_flag[log_errors] = on
$(fpm_pool_hardening "$v")
POOL

    : > /var/log/cipi-api-fpm-slow.log 2>/dev/null || true
    : > /var/log/cipi-api-php-error.log 2>/dev/null || true
    chown www-data:adm /var/log/cipi-api-fpm-slow.log /var/log/cipi-api-php-error.log 2>/dev/null || true
    chmod 640 /var/log/cipi-api-fpm-slow.log /var/log/cipi-api-php-error.log 2>/dev/null || true
}

# Write (or rewrite) the GUI FPM pool for PHP $1.
_php_write_gui_fpm_pool() {
    local v="$1"
    local gui_root="${CIPI_GUI_ROOT:-/opt/cipi/gui}"
    # Mirror lib/gui.sh _gui_open_basedir — allow path package dir if symlink slips through.
    local basedir="${gui_root}/:/opt/cipi/cipi-gui/:/tmp/:/proc/:/var/tmp/"
    local pool; pool="$(_php_pool_path "$v" "cipi-gui")"

    [[ -n "$v" ]] || return 1
    _php_ensure_etc_writable || return 1
    _php_prepare_run_php
    mkdir -p "$(dirname "$pool")"

    cat > "$pool" <<POOL
[cipi-gui]
user = www-data
group = www-data
listen = ${_PHP_GUI_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 20
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500
request_terminate_timeout = 300s
slowlog = /var/log/cipi-gui-fpm-slow.log
request_slowlog_timeout = 30s
catch_workers_output = yes
php_admin_value[error_log] = /var/log/cipi-gui-php-error.log
php_admin_value[open_basedir] = ${basedir}
$(fpm_pool_hardening "$v")
POOL

    touch /var/log/cipi-gui-fpm-slow.log /var/log/cipi-gui-php-error.log 2>/dev/null || true
    chown www-data:adm /var/log/cipi-gui-fpm-slow.log /var/log/cipi-gui-php-error.log 2>/dev/null || true
}

_php_gui_is_present() {
    [[ -f "${CIPI_CONFIG}/gui.json" ]] \
        || [[ -f "${CIPI_GUI_ROOT:-/opt/cipi/gui}/artisan" ]] \
        || [[ -f /etc/nginx/sites-available/cipi-gui ]] \
        || _php_find_pool_version "cipi-gui" >/dev/null
}

# Restart php$1-fpm and require the given sockets (paths) when their pools exist.
_php_ensure_panel_fpm() {
    local v="$1"; shift || true
    local sock

    _php_prepare_run_php
    for sock in "$@"; do
        if [[ -e "$sock" && ! -S "$sock" ]]; then
            rm -f "$sock" 2>/dev/null || true
        fi
    done

    systemctl enable "php${v}-fpm" 2>/dev/null || true
    if ! systemctl restart "php${v}-fpm"; then
        error "Failed to restart php${v}-fpm"
        systemctl --no-pager -l status "php${v}-fpm" 2>&1 | tail -20 >&2 || true
        return 1
    fi

    for sock in "$@"; do
        if ! _php_wait_socket "$sock"; then
            error "php${v}-fpm started but ${sock} is missing (nginx would 502)"
            systemctl --no-pager -l status "php${v}-fpm" 2>&1 | tail -20 >&2 || true
            journalctl -u "php${v}-fpm" -n 30 --no-pager 2>&1 | tail -30 >&2 || true
            return 1
        fi
    done
    return 0
}

# Place API (and GUI, if installed) FPM pools + sockets on PHP $1.
# Rewrites pools, clears other versions, restarts FPM, verifies socks.
# Rolls both back together on failure.
_php_migrate_panel_pools() {
    local v="$1"
    local want_api=false want_gui=false
    local api_old="" gui_old="" old_ver="" pv
    local -a socks=()

    [[ -f "${CIPI_CONFIG}/api.json" ]] && want_api=true
    _php_gui_is_present && want_gui=true
    [[ "$want_api" == "true" || "$want_gui" == "true" ]] || return 0

    if ! systemctl cat "php${v}-fpm" &>/dev/null; then
        error "php${v}-fpm is not installed — cannot host panel pools"
        return 1
    fi
    _php_ensure_etc_writable || return 1

    if [[ "$want_api" == "true" ]]; then
        api_old=$(_php_find_pool_version "cipi-api" || true)
        [[ "$api_old" == "$v" ]] && api_old=""
        socks+=("$_PHP_API_SOCK")
    fi
    if [[ "$want_gui" == "true" ]]; then
        gui_old=$(_php_find_pool_version "cipi-gui" || true)
        [[ "$gui_old" == "$v" ]] && gui_old=""
        socks+=("$_PHP_GUI_SOCK")
    fi

    # Prefer a single "previous" FPM to bounce (usually both pools share it).
    old_ver="${api_old:-${gui_old:-}}"

    step "Placing panel FPM pools on PHP ${v}..."
    [[ "$want_api" == "true" ]] && { _php_write_api_fpm_pool "$v" || return 1; _php_clear_named_pools_except "$v" "cipi-api"; }
    [[ "$want_gui" == "true" ]] && { _php_write_gui_fpm_pool "$v" || return 1; _php_clear_named_pools_except "$v" "cipi-gui"; }

    # Release listen sockets from the previous FPM master before the new one binds.
    if [[ -n "$old_ver" ]]; then
        systemctl stop "php${old_ver}-fpm" 2>/dev/null || true
    else
        systemctl stop "php${v}-fpm" 2>/dev/null || true
    fi
    for sock in "${socks[@]}"; do
        rm -f "$sock" 2>/dev/null || true
    done
    # Also bounce the other old version if API/GUI lived on different PHPs.
    if [[ -n "$api_old" && -n "$gui_old" && "$api_old" != "$gui_old" ]]; then
        systemctl stop "php${api_old}-fpm" 2>/dev/null || true
        systemctl stop "php${gui_old}-fpm" 2>/dev/null || true
    fi
    if [[ -n "$old_ver" ]]; then
        systemctl start "php${old_ver}-fpm" 2>/dev/null || true
    fi
    if [[ -n "$api_old" && -n "$gui_old" && "$api_old" != "$gui_old" ]]; then
        systemctl start "php${api_old}-fpm" 2>/dev/null || true
        systemctl start "php${gui_old}-fpm" 2>/dev/null || true
    fi

    if _php_ensure_panel_fpm "$v" "${socks[@]}"; then
        [[ "$want_api" == "true" ]] && success "API FPM on PHP ${v} — ${_PHP_API_SOCK} ready"
        [[ "$want_gui" == "true" ]] && success "GUI FPM on PHP ${v} — ${_PHP_GUI_SOCK} ready"
        return 0
    fi

    # Rollback both pools to their previous homes (default: old_ver / 8.5).
    local api_back="${api_old:-8.5}" gui_back="${gui_old:-8.5}"
    error "Rolling back panel FPM pools..."
    _php_ensure_etc_writable || true
    systemctl stop "php${v}-fpm" 2>/dev/null || true
    for sock in "${socks[@]}"; do
        rm -f "$sock" 2>/dev/null || true
    done
    if [[ "$want_api" == "true" ]]; then
        _php_write_api_fpm_pool "$api_back" || true
        _php_clear_named_pools_except "$api_back" "cipi-api"
    fi
    if [[ "$want_gui" == "true" ]]; then
        _php_write_gui_fpm_pool "$gui_back" || true
        _php_clear_named_pools_except "$gui_back" "cipi-gui"
    fi
    systemctl start "php${v}-fpm" 2>/dev/null || true

    local ok=true
    if [[ "$want_api" == "true" ]]; then
        _php_ensure_panel_fpm "$api_back" "$_PHP_API_SOCK" || ok=false
    fi
    if [[ "$want_gui" == "true" ]]; then
        # If GUI rolled back to a different PHP than API, ensure that FPM too.
        if [[ "$want_api" == "true" && "$gui_back" == "$api_back" ]]; then
            _php_wait_socket "$_PHP_GUI_SOCK" || ok=false
        else
            _php_ensure_panel_fpm "$gui_back" "$_PHP_GUI_SOCK" || ok=false
        fi
    fi
    if [[ "$ok" == "true" ]]; then
        error "Panel pool migration to PHP ${v} failed — restored previous PHP + sockets"
    else
        error "Panel pool migration failed AND rollback could not restore all sockets"
    fi
    return 1
}

# Back-compat name used by earlier 5.0.12 drafts.
_php_migrate_api_pool() { _php_migrate_panel_pools "$@"; }

_php_switch() {
    local v="${1:-}"
    # Panel API builds args with escapeshellarg; strip leftover wrapping quotes.
    v="${v#\'}"; v="${v%\'}"; v="${v#\"}"; v="${v%\"}"
    [[ -z "$v" ]] && { error "Usage: cipi php switch <8.3|8.4|8.5|8.6>"; exit 1; }
    validate_php_version "$v" || { error "Invalid PHP version: $v (use 8.3, 8.4, 8.5 or 8.6)"; exit 1; }
    php_is_installed "$v" || { error "PHP $v not installed. Run: cipi php install $v"; exit 1; }

    local cur; cur=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    local already=false
    [[ "$cur" == "$v" ]] && already=true

    if [[ "$already" == "true" ]]; then
        info "PHP $v is already the system default"
        # A previous attempt may have switched CLI then aborted before
        # migrating panel pools — finish that work if needed.
        _php_migrate_panel_pools "$v" || exit 1
        return 0
    fi

    local alt_bin="/usr/bin/php${v}"
    [[ -x "$alt_bin" ]] || { error "PHP binary not found: ${alt_bin}"; exit 1; }

    # Kernel may have remounted / read-only; update-alternatives needs to
    # rewrite /etc/alternatives/* (fails with php.dpkg-tmp on RO root).
    _php_ensure_etc_writable || exit 1

    step "Switching system PHP CLI to ${v}..."
    # Prefer exit code, but also verify the resolved /usr/bin/php target
    # (slave-link warnings can leave a non-zero status after a good master set).
    local alt_out="" alt_rc=0
    alt_out=$(/usr/bin/update-alternatives --set php "$alt_bin" 2>&1) && alt_rc=0 || alt_rc=$?
    [[ -n "$alt_out" ]] && echo "$alt_out"

    # If RO aborted mid-swap, remount + clean tmp and retry once.
    if [[ "$alt_rc" -ne 0 ]] && echo "$alt_out" | grep -qiE 'Read-only file system|php\.dpkg-tmp'; then
        info "Retrying php switch after remount..."
        _php_ensure_etc_writable || exit 1
        alt_out=$(/usr/bin/update-alternatives --set php "$alt_bin" 2>&1) && alt_rc=0 || alt_rc=$?
        [[ -n "$alt_out" ]] && echo "$alt_out"
    fi

    local now resolved
    now=$(readlink -f /usr/bin/php 2>/dev/null || true)
    resolved=$(readlink -f "$alt_bin" 2>/dev/null || true)
    if [[ -z "$resolved" || "$now" != "$resolved" ]]; then
        error "Failed to switch system PHP to ${v} (php → ${now:-unknown}, want ${resolved:-$alt_bin})"
        if echo "$alt_out" | grep -qi 'Read-only file system'; then
            error "Root filesystem is read-only. As root: mount -n -o remount,rw / && cipi php switch ${v}"
        fi
        exit 1
    fi
    if [[ "$alt_rc" -ne 0 ]]; then
        info "update-alternatives exited ${alt_rc} (slave link warning); CLI already points to PHP ${v}"
    fi
    success "CLI: php → ${alt_bin}"

    _php_migrate_panel_pools "$v" || exit 1

    # Restart cipi-queue (uses /usr/bin/php which is now the new version)
    if systemctl is-active --quiet cipi-queue 2>/dev/null; then
        step "Restarting API queue worker..."
        systemctl restart cipi-queue
        success "Queue worker restarted"
    fi

    log_action "PHP SWITCH: ${cur:-?} → $v"

    cipi_notify \
        "Cipi system PHP switched on $(hostname)" \
        "The system default PHP was changed.\n\nServer: $(hostname)\nFrom: ${cur:-unknown}\nTo: ${v}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        php_switch

    echo ""
    echo -e "  ${GREEN}${BOLD}System PHP switched to ${v}${NC}"
    [[ -n "$cur" ]] && echo -e "  ${DIM}Previous: ${cur}${NC}"
    echo -e "  ${DIM}App PHP versions are independent (per-app setting)${NC}"
    echo ""
}

_php_remove() {
    local v="${1:-}"; shift || true
    parse_args "$@"
    [[ -z "$v" ]] && { error "Usage: cipi php remove <ver> [--force]"; exit 1; }
    validate_php_version_known "$v" || { error "Invalid: $v"; exit 1; }
    local sys_ver; sys_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
    [[ "$v" == "$sys_ver" ]] && { error "PHP $v is the system default. Switch first: cipi php switch <other-ver>"; exit 1; }
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local using; using=$(vault_read apps.json | jq -r --arg v "$v" 'to_entries[]|select(.value.php==$v)|.key' 2>/dev/null)
        [[ -n "$using" ]] && { error "In use by: $using"; exit 1; }
    fi
    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        confirm "Remove PHP ${v}?" || return
    fi
    systemctl stop "php${v}-fpm" 2>/dev/null; systemctl disable "php${v}-fpm" 2>/dev/null
    apt-get purge -y "php${v}-*" &>/dev/null; apt-get autoremove -y &>/dev/null
    _php_ext_pending_set "$v"
    log_action "PHP REMOVED: $v"
    cipi_notify \
        "Cipi PHP removed: ${v} on $(hostname)" \
        "A PHP version was removed.\n\nServer: $(hostname)\nVersion: ${v}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        php_remove
    success "PHP ${v} removed"
}

_php_list() {
    parse_args "$@"
    local sys_ver; sys_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]"
        for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
            if php_is_installed "$v"; then
                local st="stopped"
                systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && st="running"
                local n=0
                [[ -f "${CIPI_CONFIG}/apps.json" ]] && n=$(vault_read apps.json | jq --arg v "$v" '[to_entries[]|select(.value.php==$v)]|length' 2>/dev/null || echo 0)
                n=${n:-0}
                [[ "$n" =~ ^[0-9]+$ ]] || n=0
                local is_default=false
                [[ "$v" == "$sys_ver" ]] && is_default=true
                local sec full
                read -r sec full <<< "$(php_security_state "$v")"
                items=$(echo "$items" | jq -c --arg v "$v" --arg s "$st" --argjson n "$n" --argjson d "$is_default" \
                    --arg full "$full" --arg sec "$sec" --arg floor "$(php_security_floor "$v")" \
                    '. + [{version:$v, status:$s, apps:$n, default:$d,
                           patch:(if $full == "-" then null else $full end), security:$sec,
                           security_floor:(if $floor == "" then null else $floor end)}]')
            fi
        done
        jq -n --argjson versions "$items" --arg default "$sys_ver" \
            --argjson installable '["8.3","8.4","8.5","8.6"]' \
            '{default: (if $default == "" then null else $default end), installable: $installable, versions: $versions}'
        return 0
    fi

    echo -e "\n${BOLD}PHP Versions${NC}"
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        if php_is_installed "$v"; then
            local st="${RED}stopped" c="${RED}"
            systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && st="running" && c="${GREEN}"
            local n=0; [[ -f "${CIPI_CONFIG}/apps.json" ]] && n=$(vault_read apps.json | jq --arg v "$v" '[to_entries[]|select(.value.php==$v)]|length' 2>/dev/null||echo 0)
            local def=""; [[ "$v" == "$sys_ver" ]] && def=" ${CYAN}← system default${NC}"
            local sec full sc
            read -r sec full <<< "$(php_security_state "$v")"
            case "$sec" in
                patched) sc="${GREEN}" ;;
                vulnerable|eol) sc="${RED}" ;;
                *) sc="${YELLOW}" ;;
            esac
            printf "  PHP %-6s ${c}● %-8s${NC}  %-8s ${sc}%-10s${NC}  %d apps%b\n" "$v" "$st" "$full" "$sec" "$n" "$def"
        fi
    done; echo ""
    echo -e "  ${DIM}Security detail and fix: cipi php upgrade${NC}"
    echo ""
}
