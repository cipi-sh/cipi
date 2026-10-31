#!/bin/bash
# lib/gui.sh — Cipi GUI panel provisioning (mirror lib/api.sh)
#
# Copy to cipi-sh/cipi/lib/gui.sh and wire in the main `cipi` router:
#   gui) require_root; source "${CIPI_LIB}/gui.sh"; gui_command "$@" ;;

# When sourced inside migrations/self-update, CIPI_GUI_* may already be readonly — only assign when unset.
if [[ -z "${CIPI_GUI_ROOT:-}" ]]; then
    readonly CIPI_GUI_ROOT="/opt/cipi/gui"
fi
if [[ -z "${CIPI_GUI_CONFIG:-}" ]]; then
    readonly CIPI_GUI_CONFIG="${CIPI_CONFIG}/gui.json"
fi
if [[ -z "${CIPI_GUI_REPO:-}" ]]; then
    readonly CIPI_GUI_REPO="https://github.com/cipi-sh/gui"
fi
if [[ -z "${CIPI_GUI_BRANCH:-}" ]]; then
    readonly CIPI_GUI_BRANCH="main"
fi

# Composer GitHub prep for cipi/gui. Mirrors _api_composer_prepare_github so
# self-update can source this file before common.sh is reloaded (old process
# still has pre-update helpers in memory).
_gui_composer_prepare_github() {
    if declare -f _cipi_composer_prepare_github >/dev/null 2>&1; then
        _cipi_composer_prepare_github "$@"
        return
    fi
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    local ssh_dir="/root/.ssh"
    local kh="${ssh_dir}/known_hosts"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    if ! grep -qE '(^|[,[:space:]])github\.com[,[:space:]]' "$kh" 2>/dev/null; then
        if command -v timeout >/dev/null 2>&1; then
            timeout --foreground 10 ssh-keyscan -T 5 -H github.com >> "$kh" 2>/dev/null || true
        else
            ssh-keyscan -T 5 -H github.com >> "$kh" 2>/dev/null || true
        fi
        if ! grep -qE '(^|[,[:space:]])github\.com[,[:space:]]' "$kh" 2>/dev/null; then
            cat >> "$kh" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
        fi
    fi
    chmod 600 "$kh" 2>/dev/null || true
    export GIT_TERMINAL_PROMPT=0
    export COMPOSER_PROCESS_TIMEOUT="${COMPOSER_PROCESS_TIMEOUT:-300}"
    export COMPOSER_ALLOW_SUPERUSER=1
    (cd "$dir" && composer config --json github-protocols '["https"]' 2>/dev/null) || true
    (cd "$dir" && composer config preferred-install dist 2>/dev/null) || true
}

# cipi/gui is not on Packagist. A Composer VCS repo on GitHub hangs the same way
# cipi/api VCS did (full git clone/scan). Sync a shallow zipball into
# /opt/cipi/cipi-gui and use a path repository instead.
_gui_sync_path_package() {
    local branch="${CIPI_GUI_BRANCH:-main}"
    local dest="/opt/cipi/cipi-gui"
    local tmp="/tmp/cipi-gui-pkg-$$"
    local url="https://github.com/cipi-sh/gui/archive/refs/heads/${branch}.tar.gz"
    local extracted=""

    rm -rf "$tmp"
    mkdir -p "$tmp" || return 1

    # Always close stdin: with an interactive TTY, `timeout --foreground curl -s`
    # can stop on SIGTTIN (looks "hung" until Enter). Curl has its own timeouts.
    step "Downloading cipi/gui (${branch}) from GitHub (zipball/tar, not VCS)..."
    if ! curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "${tmp}/gui.tar.gz" </dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    if declare -f _cipi_run_timed >/dev/null 2>&1; then
        _cipi_run_timed 60 tar -xzf "${tmp}/gui.tar.gz" -C "$tmp" </dev/null || {
            rm -rf "$tmp"
            return 1
        }
    else
        tar -xzf "${tmp}/gui.tar.gz" -C "$tmp" </dev/null || {
            rm -rf "$tmp"
            return 1
        }
    fi

    extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name '.' | head -1)
    if [[ -z "$extracted" || ! -f "${extracted}/composer.json" ]]; then
        rm -rf "$tmp"
        return 1
    fi

    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$extracted" "$dest"
    rm -rf "$tmp"
    # open_basedir allows /opt/cipi/cipi-gui/ — keep it root-owned like cipi libs
    chown -R root:root "$dest" 2>/dev/null || true
    return 0
}

_gui_composer_path_repo() {
    local dir="$1"
    local pkg="${2:-/opt/cipi/cipi-gui}"
    [[ -d "$dir" && -d "$pkg" ]] || return 1
    _gui_composer_prepare_github "$dir"
    # Drop stale VCS entry that hangs soft updates.
    (cd "$dir" && composer config --unset repositories.cipi-gui 2>/dev/null) || true
    # symlink=false: copy into vendor/ so FPM open_basedir (/opt/cipi/gui) can load it.
    # A plain `path` repo defaults to symlink → /opt/cipi/cipi-gui → HTTP 500.
    (cd "$dir" && composer config --json repositories.cipi-gui \
        "{\"type\":\"path\",\"url\":\"${pkg}\",\"options\":{\"symlink\":false}}" 2>/dev/null) || true
    (cd "$dir" && composer config minimum-stability dev 2>/dev/null) || true
    (cd "$dir" && composer config prefer-stable true 2>/dev/null) || true
}

# The version a copy of the package carries (src/Support/Theme.php), or "".
_gui_pkg_version() {
    sed -n "s/.*public const VERSION = '\([^']*\)'.*/\1/p" "${1}/src/Support/Theme.php" 2>/dev/null | head -1
}

# Copy the synced package into vendor/ again. Composer identifies a path
# repository by the sha1 of its composer.json, not by its files: as long as
# composer.json is unchanged (cipi/gui's last changed at 3.0.0), `composer
# require cipi/gui:@dev` sees the same reference, says nothing changed and
# leaves vendor/cipi/gui as it was — /opt/cipi/cipi-gui moved on every night
# and every panel stayed where it was. `reinstall` copies regardless.
_gui_reinstall_package() {
    local dir="${1:-${CIPI_GUI_ROOT}}"
    (cd "$dir" && composer reinstall cipi/gui --no-interaction --prefer-dist --no-ansi) \
        || (cd "$dir" && composer update cipi/gui --no-interaction --prefer-dist --no-ansi)
}

# If vendor/cipi/gui is still a symlink outside the app root, force a real copy.
_gui_ensure_vendor_copy() {
    local dir="${1:-${CIPI_GUI_ROOT}}"
    local vendor="${dir}/vendor/cipi/gui"
    [[ -d "$dir" ]] || return 0
    if [[ -L "$vendor" ]] || [[ -d /opt/cipi/cipi-gui && ! -d "$vendor" ]]; then
        _gui_composer_path_repo "$dir" /opt/cipi/cipi-gui || return 1
        (cd "$dir" && composer reinstall cipi/gui --no-interaction --prefer-dist --no-ansi 2>/dev/null) \
            || (cd "$dir" && composer update cipi/gui --no-interaction --prefer-dist --no-ansi) \
            || return 1
    fi
    return 0
}

# Compat for historical migrations (4.7.5) — never wire a real VCS repo.
_gui_composer_vcs_repo() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    _gui_sync_path_package || return 1
    _gui_composer_path_repo "$dir" /opt/cipi/cipi-gui
}

_gui_require_package() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    _gui_sync_path_package || return 1
    _gui_composer_path_repo "$dir" /opt/cipi/cipi-gui || return 1
    (cd "$dir" && composer require cipi/gui:@dev --no-interaction --prefer-dist --no-ansi) \
        || return 1
    _gui_ensure_vendor_copy "$dir" || return 1
    return 0
}

_gui_open_basedir() {
    # Include /opt/cipi/cipi-gui/ as a safety net if a path symlink slips through.
    echo "${CIPI_GUI_ROOT}/:/opt/cipi/cipi-gui/:/tmp/:/proc/:/var/tmp/"
}

# Shell cwd may point at /tmp/cipi-gui-build or /opt/cipi/gui while we rm -rf them — escape first.
_gui_cd_safe() {
    pwd >/dev/null 2>&1 || cd / 2>/dev/null || cd /root 2>/dev/null || true
}

# The directory exists, empty and 0700, when this returns: composer
# create-project accepts an empty target. mktemp rather than $$.$RANDOM, so
# no local user can own the tree root later moves to /opt/cipi/gui (5.8.6).
_gui_new_build_dir() {
    _gui_cd_safe
    rm -rf /tmp/cipi-gui-build /var/tmp/cipi-gui-build.* 2>/dev/null || true
    local dir
    dir=$(mktemp -d /var/tmp/cipi-gui-build.XXXXXXXX) && [[ -n "$dir" && -d "$dir" ]] || return 1
    chmod 700 "$dir"
    echo "$dir"
}

_gui_clear_host_routes() {
    local base="$1"
    echo '<?php' > "${base}/routes/web.php"
}

_gui_ensure_log_stack_env() {
    local envf="${CIPI_GUI_ROOT}/.env"
    [[ ! -f "$envf" ]] && return
    grep -q '^LOG_CHANNEL=' "$envf" \
        && sed -i 's|^LOG_CHANNEL=.*|LOG_CHANNEL=stack|' "$envf" \
        || echo 'LOG_CHANNEL=stack' >> "$envf"
    grep -q '^LOG_STACK=' "$envf" \
        && sed -i 's|^LOG_STACK=.*|LOG_STACK=single,stderr|' "$envf" \
        || echo 'LOG_STACK=single,stderr' >> "$envf"
}

_gui_ensure_session_driver_env() {
    local envf="${CIPI_GUI_ROOT}/.env"
    [[ ! -f "$envf" ]] && return
    grep -q '^SESSION_DRIVER=' "$envf" \
        && sed -i 's|^SESSION_DRIVER=.*|SESSION_DRIVER=file|' "$envf" \
        || echo 'SESSION_DRIVER=file' >> "$envf"
}

_gui_apply_sqlite_pragmas() {
    local envf="${CIPI_GUI_ROOT}/.env" db=""
    [[ ! -f "$envf" ]] && return
    grep -q '^DB_CONNECTION=sqlite' "$envf" 2>/dev/null || return
    local raw
    raw=$(grep '^DB_DATABASE=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')
    [[ -z "$raw" || "$raw" == "null" ]] && raw="database/database.sqlite"
    [[ "$raw" =~ ^/ ]] && db="$raw" || db="${CIPI_GUI_ROOT}/${raw}"
    [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1 \
        && sqlite3 "$db" "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;" >/dev/null 2>&1 || true
}

ensure_cipi_gui_permissions() {
    [[ ! -d "${CIPI_GUI_ROOT}" ]] && return
    mkdir -p "${CIPI_GUI_ROOT}/storage/logs" "${CIPI_GUI_ROOT}/database" "${CIPI_GUI_ROOT}/bootstrap/cache" 2>/dev/null || true
    chown -R www-data:www-data "${CIPI_GUI_ROOT}/storage" "${CIPI_GUI_ROOT}/database" "${CIPI_GUI_ROOT}/bootstrap/cache" 2>/dev/null || true
    chmod -R ug+rwx "${CIPI_GUI_ROOT}/storage" "${CIPI_GUI_ROOT}/bootstrap/cache" 2>/dev/null || true
    # self-update does chown -R root:root /opt/cipi — .env must stay www-data-readable
    # or PHP-FPM returns HTTP 500 (same class as ensure_cipi_api_permissions).
    if [[ -f "${CIPI_GUI_ROOT}/.env" ]]; then
        chown www-data:www-data "${CIPI_GUI_ROOT}/.env" 2>/dev/null || true
        chmod 640 "${CIPI_GUI_ROOT}/.env" 2>/dev/null || true
    fi
    [[ -f "${CIPI_GUI_ROOT}/database/database.sqlite" ]] \
        && chown www-data:www-data "${CIPI_GUI_ROOT}/database/database.sqlite" 2>/dev/null || true
}

# ── Admin credentials (first install + reset) ────────────────────

_gui_validate_admin_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

_gui_validate_admin_password() {
    local pass="$1"
    [[ ${#pass} -ge 12 ]] || { echo "Password must be at least 12 characters"; return 1; }
    [[ "$pass" =~ [A-Z] ]] || { echo "Password must include an uppercase letter"; return 1; }
    [[ "$pass" =~ [a-z] ]] || { echo "Password must include a lowercase letter"; return 1; }
    [[ "$pass" =~ [0-9] ]] || { echo "Password must include a number"; return 1; }
    [[ "$pass" =~ [^a-zA-Z0-9] ]] || { echo "Password must include a special character"; return 1; }
    if [[ "$pass" =~ (.)\1\1\1\1 ]]; then
        echo "Password must not contain more than 4 identical characters in a row"
        return 1
    fi
    return 0
}

_gui_read_password() {
    local prompt="$1" var="$2"
    local _pw=""
    echo -ne "${CYAN}${prompt}${NC}: "
    if [[ -r /dev/tty ]]; then
        read -rs _pw < /dev/tty
    else
        read -rs _pw
    fi
    echo
    printf -v "$var" '%s' "$_pw"
}

_gui_prompt_admin_password() {
    local var="$1"
    local _pass="" _pass2="" err=""

    echo -e "${DIM}  Min 12 chars · upper + lower + digit + special · max 4 identical in a row${NC}"
    while true; do
        _gui_read_password "Admin password" _pass
        _gui_read_password "Confirm password" _pass2
        [[ "$_pass" == "$_pass2" ]] || { error "Passwords do not match"; continue; }
        if err=$(_gui_validate_admin_password "$_pass"); then
            printf -v "$var" '%s' "$_pass"
            return 0
        fi
        error "$err"
    done
}

_gui_prompt_admin_credentials() {
    local email="" pass="" err=""

    echo ""
    info "Create the GUI admin account"
    echo ""
    while true; do
        read_input "Admin email" "" email
        if _gui_validate_admin_email "$email"; then break; fi
        error "Invalid email address"
    done
    _gui_prompt_admin_password pass
    _GUI_ADMIN_EMAIL="$email"
    _GUI_ADMIN_PASSWORD="$pass"
}

_gui_resolve_admin_password() {
    local var="$1"
    local pass="${2:-}" err

    if [[ -n "$pass" ]]; then
        if err=$(_gui_validate_admin_password "$pass"); then
            printf -v "$var" '%s' "$pass"
            return 0
        fi
        error "$err"
        return 1
    fi

    if [[ -t 0 || -r /dev/tty ]]; then
        local pass=""
        _gui_prompt_admin_password pass
        printf -v "$var" '%s' "$pass"
        return 0
    fi

    error "Password required (--password=) or run from an interactive terminal"
    return 1
}

# ── Laravel host + cipi/gui package ─────────────────────────────

_gui_ensure_laravel_app() {
    if [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]]; then
        _gui_cd_safe
        step "Installing Laravel GUI app..."
        local build_dir
        build_dir=$(_gui_new_build_dir) || {
            error "Failed to create GUI build directory"
            exit 1
        }

        composer create-project laravel/laravel "$build_dir" --no-interaction --prefer-dist 2>/dev/null || {
            rm -rf "$build_dir" 2>/dev/null || true
            error "Failed to create Laravel app. Ensure composer is available."
            exit 1
        }

        step "Installing cipi/gui from GitHub..."
        _gui_require_package "$build_dir" || {
            rm -rf "$build_dir" 2>/dev/null || true
            error "Failed to install cipi/gui from ${CIPI_GUI_REPO}"
            exit 1
        }

        sed -i "s|^APP_ENV=.*|APP_ENV=production|" "${build_dir}/.env"
        sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" "${build_dir}/.env"
        sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=file|" "${build_dir}/.env"

        _gui_clear_host_routes "$build_dir"

        (cd "$build_dir" && php artisan vendor:publish --tag=cipi-gui-config --force 2>/dev/null) || true
        (cd "$build_dir" && php artisan key:generate --force 2>/dev/null) || true
        (cd "$build_dir" && php artisan migrate --force 2>/dev/null) || true

        local seed_cmd=(php artisan cipi:seed-gui-user)
        [[ -n "${_GUI_ADMIN_EMAIL:-}" ]] && seed_cmd+=(--email="${_GUI_ADMIN_EMAIL}")
        [[ -n "${_GUI_ADMIN_PASSWORD:-}" ]] && seed_cmd+=(--password="${_GUI_ADMIN_PASSWORD}")
        (cd "$build_dir" && "${seed_cmd[@]}") || {
            rm -rf "$build_dir" 2>/dev/null || true
            error "Failed to create GUI admin user"
            exit 1
        }

        _gui_cd_safe
        rm -rf "${CIPI_GUI_ROOT}" 2>/dev/null
        chmod 755 "$build_dir"  # private (0700) only while it was being built
        mv "$build_dir" "${CIPI_GUI_ROOT}"
        chown -R www-data:www-data "${CIPI_GUI_ROOT}"
        success "Laravel GUI app + cipi/gui package"
    else
        step "Updating cipi/gui package..."
        _gui_update_package
    fi
}

_gui_repair_runtime() {
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && {
        error "Laravel GUI app not found."
        return 1
    }
    step "Repairing GUI runtime (vendor copy + open_basedir + permissions)..."
    if [[ -d /opt/cipi/cipi-gui ]]; then
        _gui_composer_path_repo "${CIPI_GUI_ROOT}" /opt/cipi/cipi-gui || true
        _gui_ensure_vendor_copy "${CIPI_GUI_ROOT}" || true
    fi
    chown -R www-data:www-data "${CIPI_GUI_ROOT}" 2>/dev/null || true
    ensure_cipi_gui_permissions
    local gui_php
    gui_php=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    _gui_create_fpm_pool "$gui_php"
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan optimize:clear 2>/dev/null) || true
    reload_php_fpm "$gui_php" 2>/dev/null || true
}

_gui_refresh_theme() {
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && return 0
    if ! (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan list --raw 2>/dev/null \
        | grep -qx 'cipi:gui-refresh-theme'); then
        return 0
    fi
    step "Refreshing GUI theme..."
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan cipi:gui-refresh-theme) || return 1
    return 0
}

_gui_update_package() {
    local composer_rc=0

    if ! _gui_sync_path_package; then
        warn "Failed to download cipi/gui from GitHub — package unchanged (run: cipi gui update)"
        return 1
    fi
    _gui_composer_path_repo "${CIPI_GUI_ROOT}" /opt/cipi/cipi-gui || {
        warn "Failed to configure path repo for cipi/gui"
        return 1
    }

    step "Composer require cipi/gui:@dev (timeout ${CIPI_COMPOSER_TIMEOUT:-600}s)..."
    if ! (cd "${CIPI_GUI_ROOT}" && composer require cipi/gui:@dev --no-interaction --prefer-dist --no-ansi); then
        composer_rc=$?
        warn "Composer require cipi/gui:@dev failed (exit ${composer_rc})"
    fi
    _gui_ensure_vendor_copy "${CIPI_GUI_ROOT}" || true
    # require is a no-op on an unchanged composer.json (see _gui_reinstall_package).
    local synced vendored
    synced=$(_gui_pkg_version /opt/cipi/cipi-gui)
    step "Composer reinstall cipi/gui${synced:+ ${synced}} (refresh the copy in vendor/)..."
    if ! _gui_reinstall_package "${CIPI_GUI_ROOT}"; then
        warn "Composer reinstall cipi/gui failed — the panel may still run the previous version (run: cipi gui update)"
        [[ "$composer_rc" -ne 0 ]] || composer_rc=1
    fi
    vendored=$(_gui_pkg_version "${CIPI_GUI_ROOT}/vendor/cipi/gui")
    if [[ -n "$synced" && "$vendored" != "$synced" ]]; then
        warn "vendor/cipi/gui is ${vendored:-unknown}, the synced package is ${synced} — the panel did not update (run: cipi gui update)"
        [[ "$composer_rc" -ne 0 ]] || composer_rc=1
    fi
    chown -R www-data:www-data "${CIPI_GUI_ROOT}" 2>/dev/null || true
    ensure_cipi_gui_permissions
    local gui_php
    gui_php=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    _gui_create_fpm_pool "$gui_php"
    if declare -f _cipi_run_timed >/dev/null 2>&1; then
        (cd "${CIPI_GUI_ROOT}" && _cipi_run_timed 120 sudo -u www-data php artisan vendor:publish --tag=cipi-gui-config --force) || true
        (cd "${CIPI_GUI_ROOT}" && _cipi_run_timed 180 sudo -u www-data php artisan migrate --force) || true
    else
        (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan vendor:publish --tag=cipi-gui-config --force 2>/dev/null) || true
        (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
    fi
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan optimize:clear 2>/dev/null) || true
    reload_php_fpm "$gui_php" 2>/dev/null || true
    _gui_refresh_theme || true
    if [[ "$composer_rc" -ne 0 ]]; then
        return "$composer_rc"
    fi
    success "cipi/gui package updated${vendored:+ (${vendored})}"
    return 0
}

# ── PHP-FPM + Nginx ───────────────────────────────────────────────

_gui_create_fpm_pool() {
    # Optional $1 = PHP version (default: current system CLI, fallback 8.5).
    # Twin writer in php.sh (_php_write_gui_fpm_pool) is used by `cipi php switch`.
    local v="${1:-}" pv basedir
    if [[ -z "$v" ]]; then
        v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    fi
    basedir=$(_gui_open_basedir)
    mkdir -p "/etc/php/${v}/fpm/pool.d" /run/php
    cat > "/etc/php/${v}/fpm/pool.d/cipi-gui.conf" <<EOF
[cipi-gui]
user = www-data
group = www-data
listen = /run/php/cipi-gui.sock
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
EOF
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        [[ "$pv" == "$v" ]] && continue
        rm -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" 2>/dev/null || true
    done
    touch /var/log/cipi-gui-fpm-slow.log /var/log/cipi-gui-php-error.log 2>/dev/null || true
    chown www-data:adm /var/log/cipi-gui-fpm-slow.log /var/log/cipi-gui-php-error.log 2>/dev/null || true
}

_gui_create_nginx_vhost() {
    local domain="$1"
    cat > /etc/nginx/sites-available/cipi-gui <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root ${CIPI_GUI_ROOT}/public;
    index index.php;
    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/cipi-gui.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param HTTP_X_FORWARDED_PROTO \$scheme;
        fastcgi_param HTTPS \$https if_not_empty;
        include fastcgi_params;
        fastcgi_read_timeout 300s;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    location ~ /\\.(?!well-known).* {
        deny all;
    }
}
EOF
}

_gui_setup_cron() {
    cat > /etc/cron.d/cipi-gui <<EOF
# Cipi GUI — Laravel scheduler
* * * * * www-data /usr/bin/php ${CIPI_GUI_ROOT}/artisan schedule:run >> /dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/cipi-gui
}

# ── Install detection + removal ─────────────────────────────────

_gui_is_installed() {
    local pv
    [[ -f "${CIPI_GUI_ROOT}/artisan" ]] && return 0
    [[ -f "${CIPI_GUI_CONFIG}" ]] && return 0
    [[ -f /etc/nginx/sites-available/cipi-gui ]] && return 0
    [[ -f /etc/cron.d/cipi-gui ]] && return 0
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" ]] && return 0
    done
    return 1
}

# ── Commands ────────────────────────────────────────────────────

# cipi gui <domain> [--no-ssl] [--skip-dns-check]
# The DNS check first (a name that does not point here stops it before
# anything is installed), the admin account, the install, the certificate.
# cipi gui ssl stays for a certificate issued later.
gui_setup() {
    local domain="${1:-}"
    shift || true
    unset ARG_no_ssl ARG_skip_dns_check
    parse_args "$@"
    [[ -z "$domain" || "$domain" == --* ]] && { error "Usage: cipi gui <domain> [--no-ssl] [--skip-dns-check]"; exit 1; }
    validate_domain "$domain" || { error "Invalid domain '${domain}'"; exit 1; }

    local cur
    if cur=$(panel_domain gui) && [[ "$cur" != "$domain" ]]; then
        error "The GUI is already configured at ${cur}"
        echo -e "  ${DIM}Change domain: cipi gui move ${domain}${NC}"
        echo -e "  ${DIM}Start over:    cipi gui remove, then cipi gui ${domain}${NC}"
        exit 1
    fi
    panel_domain_check "$domain" gui || exit 1
    # The certificate is requested at the end of this command: a name that
    # does not point here yet stops it now, with nothing installed.
    [[ "${ARG_no_ssl:-}" == "true" ]] || panel_dns_check "$domain" || exit 1

    _gui_cd_safe

    echo ""; info "Configuring Cipi GUI at ${domain}..."; echo ""

    mkdir -p "${CIPI_CONFIG}"
    echo "{\"domain\": \"${domain}\"}" | vault_write gui.json
    success "Config saved"

    # The www-data sudoers whitelist: written by the panels themselves since
    # 5.8.6, no longer by setup.sh on every server.
    _panel_sudoers_ensure
    success "Sudoers whitelist for www-data ready"

    if [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]]; then
        if [[ ! -t 0 && ! -r /dev/tty ]]; then
            error "GUI first install requires an interactive terminal (admin email and password)"
            exit 1
        fi
        _gui_prompt_admin_credentials
    fi

    _gui_ensure_laravel_app
    ensure_cipi_gui_permissions

    if [[ -f "${CIPI_GUI_ROOT}/.env" ]]; then
        sed -i "s|^APP_URL=.*|APP_URL=https://${domain}|" "${CIPI_GUI_ROOT}/.env"
    fi
    _gui_ensure_log_stack_env
    _gui_ensure_session_driver_env
    _gui_apply_sqlite_pragmas

    step "PHP-FPM pool..."
    local gui_php
    gui_php=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    _gui_create_fpm_pool "$gui_php"
    reload_php_fpm "$gui_php"
    success "PHP-FPM pool (cipi-gui on PHP ${gui_php})"

    step "Nginx vhost..."
    _gui_create_nginx_vhost "$domain"
    ln -sf /etc/nginx/sites-available/cipi-gui /etc/nginx/sites-enabled/cipi-gui
    reload_nginx
    success "Nginx → ${domain}"

    step "Scheduler cron..."
    _gui_setup_cron
    success "Cron (schedule:run)"

    log_action "GUI CONFIGURED: $domain"

    local ssl_ok=false
    if [[ "${ARG_no_ssl:-}" != "true" ]]; then
        echo ""
        _gui_ssl_issue "$domain" && ssl_ok=true
    fi
    local scheme=https
    [[ "$ssl_ok" == "true" ]] || scheme=http

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e " ${GREEN}${BOLD}Cipi GUI configured${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e " Domain:  ${CYAN}${scheme}://${domain}${NC}"
    echo -e " Login:   ${CYAN}${scheme}://${domain}/login${NC}"
    [[ -n "${_GUI_ADMIN_EMAIL:-}" ]] && echo -e " Admin:   ${CYAN}${_GUI_ADMIN_EMAIL}${NC}  ${DIM}(the password you just set)${NC}"
    if [[ "$ssl_ok" != "true" ]]; then
        echo ""
        if [[ "${ARG_no_ssl:-}" == "true" ]]; then
            echo -e " ${YELLOW}No certificate (--no-ssl).${NC} When ${domain} points here: ${CYAN}cipi gui ssl${NC}"
        else
            echo -e " ${YELLOW}No certificate yet.${NC} Fix what is reported above, then: ${CYAN}cipi gui ssl${NC}"
        fi
    fi
    echo ""
    # The panel manages servers through their API: the first thing to do in
    # it is to connect one, with a token from that server.
    local api_dom
    if api_dom=$(panel_domain api); then
        echo -e " ${BOLD}Next:${NC}  sign in, then Connections → Add this server:"
        echo -e "         URL ${CYAN}https://${api_dom}${NC} and a token from ${CYAN}cipi api token create${NC}"
    else
        echo -e " ${BOLD}Next:${NC}  on each server to manage: ${CYAN}cipi api <domain>${NC} (it creates the token),"
        echo -e "         then sign in and add it under Connections."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    unset _GUI_ADMIN_PASSWORD
    [[ "$ssl_ok" == "true" || "${ARG_no_ssl:-}" == "true" ]] || exit 1
}

# Request (or re-install) the certificate of the GUI domain and switch the
# vhost to HTTPS. Returns 1 when certbot fails; the DNS check is the caller's.
_gui_ssl_issue() {
    local domain="$1"
    step "Installing SSL for ${domain}..."
    # Interactive certbot only as a fallback with a terminal (e.g. no ACME
    # account yet); `cipi gui move` and scripts get a plain failure.
    if certbot --nginx -d "${domain}" --cert-name "${domain}" --non-interactive --agree-tos --redirect 2>/dev/null \
        || { [[ -t 0 ]] && certbot --nginx -d "${domain}" --cert-name "${domain}"; }; then
        reload_nginx
        log_action "GUI SSL INSTALLED: $domain"
        success "SSL installed for ${domain}"
        return 0
    fi
    error "SSL failed for ${domain}. Check: the name points here, port 80 is open, no Let's Encrypt rate limit."
    echo -e "  ${DIM}Then: cipi gui ssl${NC}"
    return 1
}

# cipi gui ssl [--skip-dns-check]
gui_ssl() {
    unset ARG_skip_dns_check
    parse_args "$@"
    [[ ! -f "${CIPI_GUI_CONFIG}" ]] && { error "GUI not configured. Run: cipi gui <domain>"; exit 1; }
    local domain
    domain=$(vault_read gui.json | jq -r '.domain')
    [[ -z "$domain" || "$domain" == "null" ]] && { error "Domain not found in config."; exit 1; }
    panel_dns_check "$domain" || exit 1
    _gui_ssl_issue "$domain" || exit 1
}

# Hostname the GUI has on the Cloudflare tunnel (empty when it is not on it).
_gui_zt_domain() {
    [[ -f "${CIPI_CONFIG}/zt.json" ]] || return 0
    vault_read zt.json 2>/dev/null | jq -r '.gui.domain // empty' 2>/dev/null || true
}

# The tunnel route, DNS record and Access app are tied to the old hostname.
_gui_require_off_tunnel() {
    local zd; zd=$(_gui_zt_domain)
    [[ -z "$zd" ]] && return 0
    error "The GUI (${zd}) is routed through Cloudflare Zero Trust"
    echo -e "  ${DIM}First: cipi zt hostname remove --gui${NC}"
    [[ "${1:-}" == move ]] && echo -e "  ${DIM}After the move: cipi zt hostname add --gui (and cipi zt access enable --gui)${NC}"
    return 1
}

_gui_set_app_url() {
    local envf="${CIPI_GUI_ROOT}/.env"
    [[ -f "$envf" ]] || return 0
    sed -i "s|^APP_URL=.*|APP_URL=https://${1}|" "$envf"
    chown www-data:www-data "$envf" 2>/dev/null || true
    chmod 640 "$envf" 2>/dev/null || true
}

# Same panel, admins, 2FA and saved connections on a new domain. The old
# certificate is deleted and one is issued for the new domain (--no-ssl skips
# it), since a vhost rewritten from scratch no longer carries certbot's lines.
gui_move() {
    local new="${1:-}"
    shift || true
    unset ARG_no_ssl ARG_skip_dns_check
    parse_args "$@"
    [[ -z "$new" || "$new" == --* ]] && { error "Usage: cipi gui move <new-domain> [--no-ssl] [--skip-dns-check]"; exit 1; }
    validate_domain "$new" || { error "Invalid domain '${new}'"; exit 1; }
    [[ -f "${CIPI_GUI_CONFIG}" && -f "${CIPI_GUI_ROOT}/artisan" ]] \
        || { error "GUI not configured. Run: cipi gui <domain>"; exit 1; }

    local old cfg
    old=$(panel_domain gui) || old=""
    [[ "$new" == "$old" ]] && { info "The GUI is already at ${new}"; return 0; }
    panel_domain_check "$new" gui || exit 1
    _gui_require_off_tunnel move || exit 1
    # The new name must already point here, or the move ends on http://
    # with the old certificate gone. --no-ssl is a move staged on purpose.
    [[ "${ARG_no_ssl:-}" == "true" ]] || panel_dns_check "$new" || exit 1
    cfg=$(vault_read gui.json | jq -c --arg d "$new" '.domain = $d') && [[ -n "$cfg" ]] \
        || { error "Cannot read ${CIPI_GUI_CONFIG}"; exit 1; }

    _gui_cd_safe
    echo ""; info "Moving Cipi GUI: ${old:-?} → ${new}"; echo ""

    # Nginx first: a config that fails `nginx -t` puts the old vhost back and
    # leaves the panel where it was.
    step "Nginx vhost..."
    local vhost=/etc/nginx/sites-available/cipi-gui saved
    saved=$(mktemp) || { error "mktemp failed"; exit 1; }
    [[ -f "$vhost" ]] && cp -p "$vhost" "$saved"
    _gui_create_nginx_vhost "$new"
    ln -sf "$vhost" /etc/nginx/sites-enabled/cipi-gui
    if ! reload_nginx; then
        [[ -s "$saved" ]] && cp -p "$saved" "$vhost"
        rm -f "$saved"
        reload_nginx || true
        error "Nginx rejected the new vhost — the GUI is still at ${old}"
        exit 1
    fi
    rm -f "$saved"
    success "Nginx → ${new}"

    echo "$cfg" | vault_write gui.json
    _gui_set_app_url "$new"
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan optimize:clear >/dev/null 2>&1) || true
    success "Config and APP_URL → https://${new}"

    if [[ -n "$old" ]]; then
        step "Old certificate (${old})..."
        panel_cert_delete "$old" gui
    fi

    local ssl_ok=false
    if [[ "${ARG_no_ssl:-}" != "true" ]]; then
        _gui_ssl_issue "$new" && ssl_ok=true
    fi

    log_action "GUI MOVED: ${old:-?} → ${new}"
    local scheme=https
    [[ "$ssl_ok" == "true" ]] || scheme=http
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e " ${GREEN}${BOLD}Cipi GUI moved${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e " Login:   ${CYAN}${scheme}://${new}/login${NC}"
    if [[ "$ssl_ok" != "true" ]]; then
        echo ""
        echo -e " ${YELLOW}No certificate yet.${NC} Point ${new} at this server, then: cipi gui ssl"
    fi
    echo ""
    echo -e " Admins sign in again: sessions belong to the old domain."
    echo -e " Managed servers need no change: their API IP whitelist is by IP, not domain."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

gui_update() {
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && { error "Laravel GUI app not found."; exit 1; }
    step "Updating cipi/gui (composer, migrate, theme)..."
    _gui_update_package
    ensure_cipi_gui_permissions
    _gui_ensure_log_stack_env
    _gui_ensure_session_driver_env
    _gui_apply_sqlite_pragmas
    local gui_php
    gui_php=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    _gui_create_fpm_pool "$gui_php"
    _gui_setup_cron
    reload_php_fpm "$gui_php"
    success "GUI updated — hard-refresh the browser (Cmd+Shift+R)"
}

gui_refresh_theme() {
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && { error "Laravel GUI app not found."; exit 1; }
    ensure_cipi_gui_permissions
    _gui_refresh_theme || {
        error "cipi:gui-refresh-theme not available — run: cipi gui update"
        exit 1
    }
    success "GUI theme refreshed — hard-refresh the browser (Cmd+Shift+R)"
}

gui_upgrade() {
    [[ ! -f "${CIPI_GUI_CONFIG}" ]] && { error "GUI not configured."; exit 1; }
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && { error "Laravel GUI app not found."; exit 1; }

    _gui_cd_safe
    export COMPOSER_ALLOW_SUPERUSER=1

    # mktemp, not a name built from the clock (see _gui_new_build_dir).
    local backup_dir build_dir
    backup_dir=$(mktemp -d /var/tmp/cipi-gui-backup.XXXXXXXX) && [[ -n "$backup_dir" && -d "$backup_dir" ]] || {
        error "Cannot create a backup directory under /var/tmp"
        exit 1
    }
    chmod 700 "$backup_dir"
    [[ -f "${CIPI_GUI_ROOT}/.env" ]] && cp "${CIPI_GUI_ROOT}/.env" "${backup_dir}/.env"
    [[ -f "${CIPI_GUI_ROOT}/database/database.sqlite" ]] && cp "${CIPI_GUI_ROOT}/database/database.sqlite" "${backup_dir}/database.sqlite"

    build_dir=$(_gui_new_build_dir) || exit 1
    composer create-project laravel/laravel "$build_dir" --no-interaction --prefer-dist || {
        rm -rf "$build_dir" 2>/dev/null || true
        exit 1
    }

    step "Installing cipi/gui from GitHub..."
    _gui_require_package "$build_dir" || {
        rm -rf "$build_dir" >/dev/null || true
        error "Failed to install cipi/gui from ${CIPI_GUI_REPO}"
        exit 1
    }

    [[ -f "${backup_dir}/.env" ]] && cp "${backup_dir}/.env" "${build_dir}/.env"
    [[ -f "${backup_dir}/database.sqlite" ]] && cp "${backup_dir}/database.sqlite" "${build_dir}/database/database.sqlite"

    _gui_clear_host_routes "$build_dir"
    (cd "$build_dir" && php artisan vendor:publish --tag=cipi-gui-config --force)
    (cd "$build_dir" && php artisan migrate --force)

    _gui_cd_safe
    rm -rf "${CIPI_GUI_ROOT}.old" 2>/dev/null
    mv "${CIPI_GUI_ROOT}" "${CIPI_GUI_ROOT}.old" 2>/dev/null || true
    chmod 755 "$build_dir"  # private (0700) only while it was being built
    mv "$build_dir" "${CIPI_GUI_ROOT}"
    rm -rf "$backup_dir" 2>/dev/null || true
    chown -R www-data:www-data "${CIPI_GUI_ROOT}"
    _gui_ensure_vendor_copy "${CIPI_GUI_ROOT}" || true
    ensure_cipi_gui_permissions
    _gui_ensure_log_stack_env
    _gui_ensure_session_driver_env
    _gui_apply_sqlite_pragmas
    local gui_php pv
    gui_php=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        if [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" ]]; then
            gui_php="$pv"
            break
        fi
    done
    _gui_create_fpm_pool "$gui_php"
    _gui_setup_cron
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan optimize:clear 2>/dev/null) || true
    reload_php_fpm "$gui_php"
    success "GUI upgraded (old: ${CIPI_GUI_ROOT}.old)"
}

gui_status() {
    [[ ! -f "${CIPI_GUI_CONFIG}" ]] && { error "GUI not configured."; exit 1; }
    local domain
    domain=$(vault_read gui.json | jq -r '.domain')
    echo ""
    echo -e "${BOLD}Cipi GUI Status${NC}"
    echo -e "  Domain:  ${CYAN}https://${domain}${NC}"
    if [[ -n "$domain" && "$domain" != "null" ]]; then
        if domain_is_used_by_other_app "$domain"; then
            echo -e "  ${YELLOW}Shares its domain with app '${DOMAIN_USED_BY_APP}' — nginx serves only one of them.${NC}"
            echo -e "  ${DIM}Give the GUI a subdomain of its own: cipi gui move <domain>${NC}"
        elif domain_is_used_by_panel "$domain" gui; then
            echo -e "  ${YELLOW}Shares its domain with ${DOMAIN_USED_BY_PANEL} — nginx serves only one of them.${NC}"
            echo -e "  ${DIM}Give the GUI a subdomain of its own: cipi gui move <domain>${NC}"
        fi
    fi
    echo -e "  Root:    ${CIPI_GUI_ROOT}"
    [[ -f "${CIPI_GUI_ROOT}/artisan" ]] \
        && echo -e "  Laravel: $(cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan --version 2>/dev/null)" \
        || echo -e "  Laravel: ${RED}not installed${NC}"
    [[ -f "${CIPI_GUI_ROOT}/artisan" ]] \
        && echo -e "  Package: $(cd "${CIPI_GUI_ROOT}" && composer show cipi/gui 2>/dev/null | sed -n 's/^[[:space:]]*versions[[:space:]]*:[[:space:]]*//p' | head -1)"
    echo ""
}

gui_fix_permissions() {
    _gui_repair_runtime || exit 1
    success "GUI permissions and runtime repaired"
}

gui_remove() {
    parse_args "$@"

    if ! _gui_is_installed; then
        info "GUI is not installed — nothing to remove"
        return 0
    fi

    local domain=""
    if [[ -f "${CIPI_GUI_CONFIG}" ]]; then
        domain=$(vault_read gui.json 2>/dev/null | jq -r '.domain // empty' 2>/dev/null) || domain=""
        [[ "$domain" == "null" ]] && domain=""
    fi

    _gui_require_off_tunnel || exit 1

    if [[ "${ARG_force:-}" != "true" ]]; then
        echo ""
        warn "Will remove the Cipi GUI panel and all related config"
        [[ -n "$domain" ]] && echo -e "  ${DIM}Domain: ${domain}${NC}"
        confirm "Remove GUI?" || { info "Cancelled"; return; }
    fi

    step "Nginx..."
    rm -f /etc/nginx/sites-enabled/cipi-gui /etc/nginx/sites-available/cipi-gui
    reload_nginx 2>/dev/null || true

    step "PHP-FPM..."
    local pv
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        if [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" ]]; then
            rm -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf"
            reload_php_fpm "$pv" 2>/dev/null || true
        fi
    done
    rm -f /run/php/cipi-gui.sock 2>/dev/null || true

    step "Cron..."
    rm -f /etc/cron.d/cipi-gui

    if [[ -n "$domain" ]]; then
        step "SSL..."
        panel_cert_delete "$domain" gui
    fi

    step "Application..."
    rm -rf "${CIPI_GUI_ROOT:?}" "${CIPI_GUI_ROOT:?}.old" /tmp/cipi-gui-build /var/tmp/cipi-gui-build.* \
        /var/tmp/cipi-gui-backup-[0-9]* /var/tmp/cipi-gui-backup.* 2>/dev/null || true

    step "Config..."
    rm -f "${CIPI_GUI_CONFIG:?}" 2>/dev/null || true

    rm -f /var/log/cipi-gui-fpm-slow.log /var/log/cipi-gui-php-error.log 2>/dev/null || true

    # Kept while the API is still installed, removed with the last panel.
    step "Sudoers..."
    _panel_sudoers_ensure

    log_action "GUI REMOVED${domain:+: $domain}"
    success "GUI removed"
    echo -e "  ${DIM}Reinstall with: cipi gui <domain>${NC}"
}

# Reset primary admin (email/name/password + clear 2FA). Works with any cipi/gui version.
_gui_reset_primary_admin() {
    local email="${1:-}" password="$2" name="${3:-}"
    local workdir="${CIPI_GUI_ROOT}/storage/app"
    local payload="${workdir}/cipi-reset-$$.json"
    local runner="${CIPI_LIB}/gui-reset-admin.php"
    local rc=0

    [[ -f "$runner" ]] || { error "Missing ${runner}"; return 1; }

    mkdir -p "$workdir"
    ensure_cipi_gui_permissions

    jq -n \
        --arg email "$email" \
        --arg password "$password" \
        --arg name "$name" \
        '{
            email: (if ($email | length) > 0 then $email else null end),
            password: $password,
            name: (if ($name | length) > 0 then $name else null end)
        }' > "$payload"
    chown www-data:www-data "$payload"
    chmod 600 "$payload"

    if ! (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php "$runner" "$payload" "${CIPI_GUI_ROOT}"); then
        rc=1
    fi
    rm -f "$payload"
    return "$rc"
}

gui_reset_user() {
    [[ ! -f "${CIPI_GUI_ROOT}/artisan" ]] && {
        error "Laravel GUI app not found. Run: cipi gui <domain>"
        exit 1
    }

    unset ARG_email ARG_password ARG_name
    parse_args "$@"

    local email="${ARG_email:-}" password="" err
    if [[ -n "$email" ]] && ! _gui_validate_admin_email "$email"; then
        error "Invalid email address"
        exit 1
    fi
    _gui_resolve_admin_password password "${ARG_password:-}" || exit 1

    step "Resetting GUI admin user..."
    ensure_cipi_gui_permissions

    # Always use lib/gui-reset-admin.php — cipi/gui's artisan --reset double-hashes
    # passwords on Laravel 12+ (User model "hashed" cast) and may target the wrong email.
    if ! _gui_reset_primary_admin "$email" "$password" "${ARG_name:-}"; then
        error "Failed to reset GUI admin user"
        exit 1
    fi

    log_action "GUI ADMIN USER RESET"
    success "GUI admin user reset (2FA disabled — re-enable from Settings after login)"
    unset password
}

# ── SINGLE SIGN-ON (cipi gui sso) ─────────────────────────────
# The panel signs people in over OpenID Connect when its .env names an
# issuer (cipi/gui 4.0.2+): Microsoft Entra ID, Google Workspace, Okta,
# Keycloak, Authentik. The panel's .env is Cipi's to write, so the
# configuration lives here, and so does the break-glass: `cipi gui sso only
# off` or `cipi gui sso disable` brings password sign-in back.

GUI_SSO_KEYS="CIPI_GUI_SSO_ISSUER CIPI_GUI_SSO_CLIENT_ID CIPI_GUI_SSO_CLIENT_SECRET CIPI_GUI_SSO_LABEL CIPI_GUI_SSO_DOMAINS CIPI_GUI_SSO_ONLY CIPI_GUI_SSO_SCOPES"

# KEY=value in the panel .env: replaced when present, appended otherwise.
# The value is double-quoted, so a secret with # or spaces survives Laravel's
# parser; a " inside it is escaped.
_gui_env_set() {
    local envf="${CIPI_GUI_ROOT}/.env" key="$1" val="${2//\"/\\\"}" tmp
    [[ -f "$envf" ]] || return 1
    tmp=$(mktemp) || return 1
    if grep -q "^${key}=" "$envf"; then
        awk -v k="$key" -v v="$val" 'index($0, k"=") == 1 { print k "=\"" v "\""; next } { print }' "$envf" > "$tmp"
    else
        cat "$envf" > "$tmp"
        printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    fi
    cat "$tmp" > "$envf" && rm -f "$tmp"
}

_gui_env_unset() {
    local envf="${CIPI_GUI_ROOT}/.env" key="$1" tmp
    [[ -f "$envf" ]] || return 0
    tmp=$(mktemp) || return 1
    grep -v "^${key}=" "$envf" > "$tmp" || true
    cat "$tmp" > "$envf" && rm -f "$tmp"
}

# The value of KEY in the panel .env, without the quotes Laravel accepts.
_gui_env_get() {
    local envf="${CIPI_GUI_ROOT}/.env" line
    [[ -f "$envf" ]] || return 0
    line=$(grep "^${1}=" "$envf" | tail -1 | cut -d= -f2-) || true
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "${line//\\\"/\"}"
}

# The panel reads the new .env once its config cache is gone; the migration
# that adds users.sso_subject (cipi/gui 4.0.2) is idempotent, so it runs
# here too for a panel updated before the column existed.
_gui_sso_apply() {
    chown www-data:www-data "${CIPI_GUI_ROOT}/.env" 2>/dev/null || true
    chmod 640 "${CIPI_GUI_ROOT}/.env" 2>/dev/null || true
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan optimize:clear >/dev/null 2>&1) || true
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan migrate --force >/dev/null 2>&1) || true
}

# Forget the identities linked so far (users.sso_subject). An identity's
# `sub` is per provider, and Entra ID's is pairwise per app registration:
# after a new issuer or client id every linked account would be refused as
# "linked to another identity". Everyone links again at the next sign-in.
_gui_sso_reset_links() {
    (cd "${CIPI_GUI_ROOT}" && sudo -u www-data php artisan tinker --no-interaction \
        --execute="DB::table('users')->whereNotNull('sso_subject')->update(['sso_subject' => null]);" >/dev/null 2>&1) || true
}

_gui_sso_redirect_uri() {
    local d; d=$(panel_domain gui) || d="<gui-domain>"
    printf 'https://%s/auth/sso/callback' "$d"
}

# The button text the panel derives from the issuer when none is given.
_gui_sso_default_label() {
    case "$1" in
        *login.microsoftonline.com*) echo "Microsoft Entra ID" ;;
        *accounts.google.com*)       echo "Google" ;;
        *okta.com*)                  echo "Okta" ;;
        *)                           echo "SSO" ;;
    esac
}

_gui_sso_require_app() {
    [[ -f "${CIPI_GUI_ROOT}/artisan" && -f "${CIPI_GUI_ROOT}/.env" ]] \
        || { error "GUI not configured. Run: cipi gui <domain>"; exit 1; }
}

# cipi gui sso set --issuer=URL --client-id=ID [--client-secret=SECRET] [--label=TEXT] [--domains=a.com,b.com] [--only] [--scopes=...]
gui_sso_set() {
    _gui_sso_require_app
    unset ARG_issuer ARG_client_id ARG_client_secret ARG_label ARG_domains ARG_only ARG_scopes
    parse_args "$@"
    local issuer="${ARG_issuer:-}" cid="${ARG_client_id:-}" secret="${ARG_client_secret:-}"
    [[ -n "$issuer" && -n "$cid" ]] || {
        error "Usage: cipi gui sso set --issuer=<url> --client-id=<id> [--client-secret=<secret>] [--label=<text>] [--domains=<a.com,b.com>] [--only] [--scopes=<list>]"
        echo -e "  ${DIM}Entra ID: --issuer=https://login.microsoftonline.com/<tenant-id>/v2.0  (the tenant id, not common)${NC}"
        echo -e "  ${DIM}Google:   --issuer=https://accounts.google.com${NC}"
        exit 1
    }
    issuer="${issuer%/}"
    [[ "$issuer" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]]*)?$ ]] || { error "The issuer must be an https:// URL (the one whose /.well-known/openid-configuration answers)"; exit 1; }
    if [[ -n "${ARG_domains:-}" ]]; then
        local d
        for d in ${ARG_domains//,/ }; do
            validate_domain "$d" || { error "Invalid domain in --domains: '${d}'"; exit 1; }
        done
    fi
    if [[ -z "$secret" ]]; then
        secret=$(_gui_env_get CIPI_GUI_SSO_CLIENT_SECRET)
        if [[ -z "$secret" ]]; then
            if [[ -t 0 || -r /dev/tty ]]; then
                _gui_read_password "Client secret" secret
            fi
            [[ -n "$secret" ]] || { error "A client secret is needed: --client-secret=<secret>, or type it at the prompt"; exit 1; }
        fi
    fi

    local prev_issuer prev_cid relink=false
    prev_issuer=$(_gui_env_get CIPI_GUI_SSO_ISSUER); prev_cid=$(_gui_env_get CIPI_GUI_SSO_CLIENT_ID)
    [[ -n "$prev_issuer" && ( "$prev_issuer" != "$issuer" || "$prev_cid" != "$cid" ) ]] && relink=true

    step "Writing the SSO settings to the panel .env..."
    _gui_env_set CIPI_GUI_SSO_ISSUER "$issuer" || { error "Cannot write ${CIPI_GUI_ROOT}/.env"; exit 1; }
    _gui_env_set CIPI_GUI_SSO_CLIENT_ID "$cid"
    _gui_env_set CIPI_GUI_SSO_CLIENT_SECRET "$secret"
    if [[ -n "${ARG_label:-}" ]]; then _gui_env_set CIPI_GUI_SSO_LABEL "$ARG_label"; else _gui_env_unset CIPI_GUI_SSO_LABEL; fi
    if [[ -n "${ARG_domains:-}" ]]; then _gui_env_set CIPI_GUI_SSO_DOMAINS "${ARG_domains// /}"; else _gui_env_unset CIPI_GUI_SSO_DOMAINS; fi
    if [[ -n "${ARG_scopes:-}" ]]; then _gui_env_set CIPI_GUI_SSO_SCOPES "$ARG_scopes"; else _gui_env_unset CIPI_GUI_SSO_SCOPES; fi
    [[ "${ARG_only:-}" == "true" ]] && _gui_env_set CIPI_GUI_SSO_ONLY true
    _gui_sso_apply
    unset secret
    if [[ "$relink" == true ]]; then
        _gui_sso_reset_links
        info "New provider or client id: the identities linked so far were forgotten — everyone links again at the next sign-in"
    fi

    log_action "GUI SSO SET: issuer=${issuer}"
    cipi_notify \
        "Cipi GUI single sign-on configured on $(hostname)" \
        "The panel signs in over OpenID Connect.\n\nServer: $(hostname)\nIssuer: ${issuer}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        gui_sso
    success "Single sign-on: $(_gui_env_get CIPI_GUI_SSO_LABEL | grep . || _gui_sso_default_label "$issuer") (${issuer})"
    echo ""
    gui_sso_status
    local gv; gv=$(_gui_pkg_version "${CIPI_GUI_ROOT}/vendor/cipi/gui")
    if [[ -n "$gv" && "$(printf '%s\n4.0.2\n' "$gv" | sort -V | head -1)" != "4.0.2" ]]; then
        warn "The panel runs cipi/gui ${gv}: single sign-on needs 4.0.2 or later — run: cipi gui update"
    fi
}

gui_sso_status() {
    _gui_sso_require_app
    local issuer cid label domains only scopes secret
    issuer=$(_gui_env_get CIPI_GUI_SSO_ISSUER); cid=$(_gui_env_get CIPI_GUI_SSO_CLIENT_ID)
    secret=$(_gui_env_get CIPI_GUI_SSO_CLIENT_SECRET); label=$(_gui_env_get CIPI_GUI_SSO_LABEL)
    domains=$(_gui_env_get CIPI_GUI_SSO_DOMAINS); only=$(_gui_env_get CIPI_GUI_SSO_ONLY); scopes=$(_gui_env_get CIPI_GUI_SSO_SCOPES)
    echo -e "${BOLD}Cipi GUI single sign-on${NC}"
    if [[ -z "$issuer" ]]; then
        echo -e "  Status:        ${DIM}off${NC} — password sign-in only"
        echo -e "  ${DIM}Turn on: cipi gui sso set --issuer=<url> --client-id=<id> --client-secret=<secret>${NC}"
        echo ""
        return 0
    fi
    echo -e "  Status:        ${GREEN}on${NC} (OpenID Connect)"
    echo -e "  Button:        ${CYAN}Sign in with ${label:-$(_gui_sso_default_label "$issuer")}${NC}"
    echo -e "  Issuer:        ${CYAN}${issuer}${NC}"
    echo -e "  Client ID:     ${CYAN}${cid:-?}${NC}"
    echo -e "  Client secret: ${CYAN}$([[ -n "$secret" ]] && printf '%s' "${secret:0:4}…" || echo "missing")${NC}"
    echo -e "  Scopes:        ${CYAN}${scopes:-openid email profile}${NC}"
    echo -e "  Redirect URI:  ${CYAN}$(_gui_sso_redirect_uri)${NC}  ${DIM}(register this at the identity provider)${NC}"
    if [[ -n "$domains" ]]; then
        echo -e "  New accounts:  ${CYAN}${domains}${NC}  ${DIM}(first sign-in from these domains creates a user with no access — grant it in Team)${NC}"
    else
        echo -e "  New accounts:  ${DIM}none — only people who already have an account (invite link, cipi gui reset-user)${NC}"
    fi
    if [[ "$only" == "true" ]]; then
        echo -e "  Password:      ${RED}off for everyone${NC}  ${DIM}(break-glass: cipi gui sso only off)${NC}"
    else
        echo -e "  Password:      ${GREEN}still accepted${NC}  ${DIM}(SSO only: cipi gui sso only on)${NC}"
    fi
    echo ""
}

# cipi gui sso only on|off — password sign-in off for everyone, or back.
gui_sso_only() {
    _gui_sso_require_app
    case "${1:-}" in
        on)
            [[ -n "$(_gui_env_get CIPI_GUI_SSO_ISSUER)" ]] || { error "Single sign-on is not configured: cipi gui sso set … first"; exit 1; }
            _gui_env_set CIPI_GUI_SSO_ONLY true
            _gui_sso_apply
            log_action "GUI SSO ONLY: on"
            success "Password sign-in is off for everyone — the SSO button only"
            echo -e "  ${DIM}Locked out? From the server: cipi gui sso only off${NC}" ;;
        off)
            _gui_env_unset CIPI_GUI_SSO_ONLY
            _gui_sso_apply
            log_action "GUI SSO ONLY: off"
            success "Password sign-in accepted again (single sign-on stays on)" ;;
        *) error "Usage: cipi gui sso only on|off"; exit 1 ;;
    esac
}

gui_sso_disable() {
    _gui_sso_require_app
    [[ -n "$(_gui_env_get CIPI_GUI_SSO_ISSUER)" ]] || { info "Single sign-on is already off"; return 0; }
    local k
    for k in $GUI_SSO_KEYS; do _gui_env_unset "$k"; done
    _gui_sso_apply
    log_action "GUI SSO DISABLED"
    cipi_notify \
        "Cipi GUI single sign-on disabled on $(hostname)" \
        "The panel is back to password sign-in.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        gui_sso
    success "Single sign-on off — password sign-in for everyone; accounts and their SSO links are kept"
}

gui_sso_command() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        set|configure) gui_sso_set "$@" ;;
        status|show)   gui_sso_status ;;
        only)          gui_sso_only "$@" ;;
        disable|off)   gui_sso_disable ;;
        *)
            error "Usage: cipi gui sso set --issuer=<url> --client-id=<id> --client-secret=<secret> [--label=] [--domains=] [--only]"
            echo "       cipi gui sso status | only on|off | disable"
            exit 1 ;;
    esac
}

gui_command() {
    local sub="${1:-}"
    shift || true

    case "$sub" in
        "")
            error "Usage: cipi gui <domain> [--no-ssl] [--skip-dns-check]"
            echo "       cipi gui ssl | move <domain> [--no-ssl] | update | upgrade | status | fix-permissions | repair"
            echo "       cipi gui refresh-theme"
            echo "       cipi gui remove [--force] | uninstall [--force]"
            echo "       cipi gui reset-user [--email=] [--password=] [--name=]"
            echo "       cipi gui sso set|status|only on|off|disable"
            exit 1
            ;;
        ssl) gui_ssl "$@" ;;
        move) gui_move "$@" ;;
        update) gui_update ;;
        upgrade) gui_upgrade ;;
        status) gui_status ;;
        fix-permissions|repair) gui_fix_permissions ;;
        refresh-theme) gui_refresh_theme ;;
        remove|uninstall) gui_remove "$@" ;;
        reset-user|reset-password) gui_reset_user "$@" ;;
        sso) gui_sso_command "$@" ;;
        *)
            validate_domain "$sub" && gui_setup "$sub" "$@" || exit 1
            ;;
    esac
}
