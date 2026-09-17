#!/bin/bash
#############################################
# Cipi — API & MCP Server Management
#############################################

# When sourced inside migrations, CIPI_API_* may already be readonly — only assign when unset.
if [[ -z "${CIPI_API_ROOT:-}" ]]; then
    readonly CIPI_API_ROOT="/opt/cipi/api"
fi
if [[ -z "${CIPI_API_CONFIG:-}" ]]; then
    readonly CIPI_API_CONFIG="${CIPI_CONFIG}/api.json"
fi
if [[ -z "${CIPI_API_IP_WHITELIST:-}" ]]; then
    readonly CIPI_API_IP_WHITELIST="${CIPI_CONFIG}/api-ip-whitelist"
fi
if [[ -z "${CIPI_API_REPO:-}" ]]; then
    readonly CIPI_API_REPO="https://github.com/cipi-sh/api"
fi
if [[ -z "${CIPI_API_BRANCH:-}" ]]; then
    readonly CIPI_API_BRANCH="main"
fi

# Composer VCS repository for cipi/api (https://github.com/cipi-sh/api).
_api_composer_prepare_github() {
    if declare -f _cipi_composer_prepare_github >/dev/null 2>&1; then
        _cipi_composer_prepare_github "$@"
        return
    fi
    # Self-update may source this file before common.sh is reloaded (v5.0.7 → 5.0.8).
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

# Stop queue (and force-kill if stop hangs) before composer/migrate so panel
# SQLite is not locked forever by cipi-queue.
_api_stop_queue_for_update() {
    if ! systemctl is-active --quiet cipi-queue 2>/dev/null; then
        return 0
    fi
    if declare -f _cipi_run_timed >/dev/null 2>&1; then
        _cipi_run_timed 45 systemctl stop cipi-queue 2>/dev/null || true
    else
        _api_timeout 45 systemctl stop cipi-queue 2>/dev/null || true
    fi
    if systemctl is-active --quiet cipi-queue 2>/dev/null; then
        systemctl kill -s SIGKILL cipi-queue 2>/dev/null || true
    fi
}

_api_composer_vcs_repo() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    _api_composer_prepare_github "$dir"
    (cd "$dir" && composer config repositories.cipi-api \
        "{\"type\":\"vcs\",\"url\":\"${CIPI_API_REPO}\"}" 2>/dev/null) || true
}

# ability|description — sourced from the API package (token-abilities.txt / artisan)
_api_ability_lines() {
    local f src out=""
    for f in \
        "${CIPI_API_ROOT}/token-abilities.txt" \
        "${CIPI_API_ROOT}/vendor/cipi/api/token-abilities.txt" \
        "/opt/cipi/cipi-api/token-abilities.txt"; do
        if [[ -f "$f" ]]; then
            cat "$f"
            return
        fi
    done
    if [[ -d "${CIPI_API_ROOT}" && -f "${CIPI_API_ROOT}/artisan" ]]; then
        out=$(cd "${CIPI_API_ROOT}" && _api_timeout 15 sudo -u www-data php artisan cipi:token-abilities 2>/dev/null) || true
    fi
    if [[ -n "$out" ]]; then
        echo "$out"
        return
    fi
    cat <<'EOF'
apps-view|Read apps
apps-create|Create apps
apps-edit|Edit apps
apps-delete|Delete apps
apps-suspend|Suspend / unsuspend apps
apps-basicauth|HTTP Basic Auth
deploy-manage|Deploy, rollback, unlock
ssl-manage|SSL certificates
aliases-view|Read aliases
aliases-create|Add aliases
aliases-delete|Remove aliases
dbs-view|List databases
dbs-create|Create databases
dbs-delete|Delete databases
dbs-manage|Backup, restore, DB password
status-view|Server status
mcp-access|MCP server
EOF
}

_api_sync_token_abilities_file() {
    local dest="${CIPI_API_ROOT}/token-abilities.txt"
    local src=""
    for src in \
        "${CIPI_API_ROOT}/vendor/cipi/api/token-abilities.txt" \
        "/opt/cipi/cipi-api/token-abilities.txt"; do
        if [[ -f "$src" ]]; then
            cp "$src" "$dest"
            chown www-data:www-data "$dest" 2>/dev/null || true
            return 0
        fi
    done
    if [[ -d "${CIPI_API_ROOT}" && -f "${CIPI_API_ROOT}/artisan" ]]; then
        (cd "${CIPI_API_ROOT}" && _api_timeout 15 sudo -u www-data php artisan cipi:token-abilities > "$dest" 2>/dev/null) \
            && chown www-data:www-data "$dest" 2>/dev/null \
            && return 0
    fi
    return 1
}

_api_token_abilities_default() {
    _api_ability_lines | cut -d'|' -f1 | paste -sd, -
}

# Run $@ with a wall-clock limit when GNU `timeout` exists (prevents hung `cipi api status`).
_api_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Apply SQLite pragmas needed by the panel API:
# - WAL: many concurrent readers + 1 writer (FPM children + cipi-queue + artisan)
# - busy_timeout: 15s instead of Laravel's default ~5s; eliminates the
#   "database is locked" 500s under bursty traffic without user-visible delay
# - synchronous=NORMAL: pairs with WAL; durable on commit, faster on writes
# Idempotent: PRAGMAs are settings, not schema changes.
_api_apply_sqlite_pragmas() {
    local db; db=$(_api_panel_sqlite_path 2>/dev/null) || return 0
    [[ -z "$db" || ! -f "$db" ]] && return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    sudo -u www-data sqlite3 "$db" <<'SQL' 2>/dev/null || true
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=15000;
SQL
}

# Force LOG_STACK=single,stderr so:
# - "single" keeps the human-readable laravel.log
# - "stderr" mirrors errors to FPM stdout/stderr → caught by
#   catch_workers_output and visible in journalctl when a worker is killed
#   mid-request (the case where laravel.log alone is not enough).
# Idempotent: replaces the line in .env or appends it.
_api_ensure_log_stack_env() {
    local envf="${CIPI_API_ROOT}/.env"
    [[ -f "$envf" ]] || return 0
    if grep -q '^LOG_STACK=' "$envf" 2>/dev/null; then
        sed -i 's|^LOG_STACK=.*|LOG_STACK=single,stderr|' "$envf"
    else
        echo 'LOG_STACK=single,stderr' >> "$envf"
    fi
    if grep -q '^LOG_CHANNEL=' "$envf" 2>/dev/null; then
        sed -i 's|^LOG_CHANNEL=.*|LOG_CHANNEL=stack|' "$envf"
    else
        echo 'LOG_CHANNEL=stack' >> "$envf"
    fi
    chown www-data:www-data "$envf" 2>/dev/null || true
    chmod 640 "$envf" 2>/dev/null || true
}

# PsySH (artisan tinker) writes under www-data's home; ensure the dir exists to avoid slow/failed first runs.
_api_ensure_psysh_home() {
    local h
    h=$(getent passwd www-data 2>/dev/null | cut -d: -f6)
    [[ -z "$h" || ! -d "$h" ]] && return 0
    mkdir -p "${h}/.config/psysh" 2>/dev/null || true
    chown -R www-data:www-data "${h}/.config" 2>/dev/null || true
}

# Package version from composer.lock — no php artisan / composer (avoids Laravel bootstrap hang on api status).
_api_lock_package_version() {
    local pkg="$1" lock="${CIPI_API_ROOT}/composer.lock"
    [[ -f "$lock" ]] && command -v jq >/dev/null 2>&1 || return 1
    jq -r --arg n "$pkg" '.packages[] | select(.name == $n) | .version' "$lock" 2>/dev/null | head -1
}

# What is actually installed: every locked package with its version and the
# exact dist/source reference, hashed. `composer require` rewrites the lock's
# content-hash even when it resolves to the same packages, so the lock file
# itself cannot tell "updated" from "already current" — this can.
_api_lock_fingerprint() {
    local lock="${CIPI_API_ROOT}/composer.lock"
    [[ -f "$lock" ]] && command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
    jq -r '[(.packages // [])[], (.["packages-dev"] // [])[]]
        | map("\(.name)@\(.version)#\(.dist.reference // .source.reference // "")")
        | sort | .[]' "$lock" 2>/dev/null | sha256sum | awk '{print $1}'
}

# Absolute path to panel SQLite DB from .env (default Laravel relative path).
_api_panel_sqlite_path() {
    local envf="${CIPI_API_ROOT}/.env" raw
    [[ -f "$envf" ]] || return 1
    grep -q '^DB_CONNECTION=sqlite' "$envf" 2>/dev/null || return 1
    raw=$(grep '^DB_DATABASE=' "$envf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')
    [[ -z "$raw" || "$raw" == "null" ]] && raw="database/database.sqlite"
    if [[ "$raw" =~ ^/ ]]; then
        echo "$raw"
    else
        echo "${CIPI_API_ROOT}/${raw}"
    fi
}

# Pending Cipi API jobs: direct sqlite3 when possible; tinker only as fallback (short timeout).
_api_pending_jobs_count() {
    local envf="${CIPI_API_ROOT}/.env" db c
    if [[ -f "$envf" ]] && grep -q '^DB_CONNECTION=sqlite' "$envf" 2>/dev/null; then
        db=$(_api_panel_sqlite_path) || true
        if [[ -n "$db" && -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
            c=$(sqlite3 "$db" "SELECT COUNT(*) FROM cipi_jobs WHERE status IN ('pending','running');" 2>/dev/null)
            [[ -n "$c" && "$c" =~ ^[0-9]+$ ]] && { echo "$c"; return; }
        fi
    fi
    c=$(cd "${CIPI_API_ROOT}" && _api_timeout 20 sudo -u www-data env HOME=/tmp php artisan tinker --execute="echo \CipiApi\Models\CipiJob::whereIn('status',['pending','running'])->count();" 2>/dev/null) || c="?"
    [[ -z "$c" ]] && c="?"
    echo "$c"
}

# Terminal checklist (no whiptail): toggle numbers, Enter to confirm. Default: all on.
# NOTE: This is often run inside $(...) for assignment; stdout is captured, so all UI must go to stderr.
#       Reads must use /dev/tty so input is not lost when stdin is not the TTY in a subshell.
_api_token_select_abilities() {
    local -a keys descs
    local k d
    while IFS='|' read -r k d; do
        [[ -z "$k" ]] && continue
        keys+=("$k")
        descs+=("$d")
    done < <(_api_ability_lines)

    local n=${#keys[@]}
    local -a sel=()
    local i
    for ((i = 0; i < n; i++)); do
        sel[i]=1
    done

    while true; do
        echo "" >&2
        echo -e "${BOLD}Token abilities${NC}  ${DIM}· toggle number(s) · ${BOLD}a${DIM}=all · ${BOLD}n${DIM}=none · ${BOLD}Enter${DIM}=confirm${NC}" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        for ((i = 0; i < n; i++)); do
            local mark
            if [[ ${sel[i]} -eq 1 ]]; then
                mark="${GREEN}✓${NC}"
            else
                mark="${DIM}·${NC}"
            fi
            printf "  %b  %2d  ${CYAN}%-18s${NC} %s\n" "$mark" "$((i + 1))" "${keys[i]}" "${descs[i]}" >&2
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        printf "${CYAN}›${NC} " >&2
        local choice=""
        if [[ -r /dev/tty ]]; then
            read -r choice </dev/tty || true
        else
            read -r choice || true
        fi
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$choice" ]] && break
        case "$choice" in
            a | all)
                for ((i = 0; i < n; i++)); do
                    sel[i]=1
                done
                ;;
            n | none)
                for ((i = 0; i < n; i++)); do
                    sel[i]=0
                done
                ;;
            *)
                local tok
                for tok in $choice; do
                    tok=${tok//,/}
                    [[ "$tok" =~ ^[0-9]+$ ]] || continue
                    local idx=$((tok - 1))
                    if ((idx >= 0 && idx < n)); then
                        sel[idx]=$((1 - sel[idx]))
                    fi
                done
                ;;
        esac
    done

    local out=()
    for ((i = 0; i < n; i++)); do
        [[ ${sel[i]} -eq 1 ]] && out+=("${keys[i]}")
    done
    if ((${#out[@]} == 0)); then
        error "Select at least one ability."
        return 1
    fi
    local IFS=,
    echo "${out[*]}"
}

# ── API SETUP (cipi api [domain]) ──────────────────────────────

api_setup() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && { error "Usage: cipi api <domain>"; exit 1; }
    validate_domain "$domain" || { error "Invalid domain '${domain}'"; exit 1; }

    echo ""; info "Configuring Cipi API at ${domain}..."; echo ""

    # Save config
    mkdir -p "${CIPI_CONFIG}"
    if [[ -f "${CIPI_API_CONFIG}" ]]; then
        local cur; cur=$(vault_read api.json | jq -r '.domain' 2>/dev/null)
        [[ -n "$cur" && "$cur" != "$domain" ]] && step "Updating domain: ${cur} → ${domain}"
    fi
    echo "{\"domain\": \"${domain}\"}" | vault_write api.json
    success "Config saved"

    # Default API IP whitelist (* = allow all) — readable by www-data
    _api_ipwl_ensure_file
    success "API IP whitelist ready (${CIPI_API_IP_WHITELIST})"

    # Ensure Laravel API app exists
    _api_ensure_laravel_app

    ensure_cipi_api_permissions
    _api_ensure_psysh_home

    # Allow www-data (PHP-FPM) to read apps.json for API endpoints
    step "Configuring apps.json access for API..."
    ensure_apps_json_api_access
    success "apps.json readable by API"

    # Update APP_URL and CIPI_APPS_JSON in Laravel .env
    if [[ -f "${CIPI_API_ROOT}/.env" ]]; then
        sed -i "s|^APP_URL=.*|APP_URL=https://${domain}|" "${CIPI_API_ROOT}/.env"
        grep -q '^CIPI_APPS_JSON=' "${CIPI_API_ROOT}/.env" 2>/dev/null \
            && sed -i "s|^CIPI_APPS_JSON=.*|CIPI_APPS_JSON=${CIPI_CONFIG}/apps-public.json|" "${CIPI_API_ROOT}/.env" \
            || echo "CIPI_APPS_JSON=${CIPI_CONFIG}/apps-public.json" >> "${CIPI_API_ROOT}/.env"
    fi
    _api_ensure_log_stack_env
    _api_ensure_session_driver_env
    _api_apply_sqlite_pragmas

    # PHP-FPM pool for API
    step "PHP-FPM pool..."
    _api_create_fpm_pool
    reload_php_fpm "8.5"
    success "PHP-FPM pool (cipi-api)"

    # Nginx vhost for API (no aliases)
    step "Nginx vhost..."
    _api_create_nginx_vhost "$domain"
    ln -sf /etc/nginx/sites-available/cipi-api /etc/nginx/sites-enabled/cipi-api
    reload_nginx
    success "Nginx → ${domain}"

    # Queue worker (systemd) + scheduler & maintenance crons
    step "Queue worker..."
    _api_setup_queue_worker
    success "Queue worker (cipi-queue)"
    step "Scheduler & maintenance cron..."
    _api_setup_cron
    success "Cron (schedule:run + daily maintenance)"

    log_action "API CONFIGURED: $domain"
    cipi_notify \
        "Cipi API configured: ${domain} on $(hostname)" \
        "The panel API was configured.\n\nServer: $(hostname)\nDomain: ${domain}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        api_configure
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}Cipi API configured${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Domain:     ${CYAN}https://${domain}${NC}"
    echo -e "  API:        ${CYAN}https://${domain}/api${NC}"
    echo -e "  Docs:       ${CYAN}https://${domain}/docs${NC}"
    echo -e "  MCP:        ${CYAN}https://${domain}/mcp${NC}"
    echo ""
    echo -e "  ${BOLD}Next:${NC} cipi api ssl  (to install SSL certificate)"
    echo -e "        cipi api token create  (to create API token)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_api_ensure_laravel_app() {
    if [[ ! -f "${CIPI_API_ROOT}/artisan" ]]; then
        step "Installing Laravel API app..."
        rm -rf /tmp/cipi-api-build 2>/dev/null

        # 1. Create fresh Laravel project
        (cd /tmp && composer create-project laravel/laravel cipi-api-build --no-interaction --prefer-dist 2>/dev/null) || {
            error "Failed to create Laravel app. Ensure composer is available."
            exit 1
        }

        # 2. Add path repository for cipi-api package (local or installed copy)
        local pkg_dir="/opt/cipi/cipi-api"
        [[ -d "${CIPI_LIB}/../cipi-api" ]] && pkg_dir="${CIPI_LIB}/../cipi-api"
        if [[ -d "$pkg_dir" ]]; then
            (cd /tmp/cipi-api-build && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
            (cd /tmp/cipi-api-build && composer require cipi/api:@dev --no-interaction 2>/dev/null) || true
        else
            (cd /tmp/cipi-api-build && composer require cipi/api --no-interaction 2>/dev/null) || true
        fi
        (cd /tmp/cipi-api-build && composer require laravel/mcp --no-interaction 2>/dev/null) || true

        # 3. Configure .env
        sed -i "s|^APP_ENV=.*|APP_ENV=production|" /tmp/cipi-api-build/.env
        sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" /tmp/cipi-api-build/.env
        sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=database|" /tmp/cipi-api-build/.env
        if grep -q '^LOG_CHANNEL=' /tmp/cipi-api-build/.env 2>/dev/null; then
            sed -i 's|^LOG_CHANNEL=.*|LOG_CHANNEL=stack|' /tmp/cipi-api-build/.env
        else
            echo 'LOG_CHANNEL=stack' >> /tmp/cipi-api-build/.env
        fi
        if grep -q '^LOG_STACK=' /tmp/cipi-api-build/.env 2>/dev/null; then
            sed -i 's|^LOG_STACK=.*|LOG_STACK=single,stderr|' /tmp/cipi-api-build/.env
        else
            echo 'LOG_STACK=single,stderr' >> /tmp/cipi-api-build/.env
        fi
        if grep -q '^SESSION_DRIVER=' /tmp/cipi-api-build/.env 2>/dev/null; then
            sed -i 's|^SESSION_DRIVER=.*|SESSION_DRIVER=array|' /tmp/cipi-api-build/.env
        else
            echo 'SESSION_DRIVER=array' >> /tmp/cipi-api-build/.env
        fi
        grep -q '^CIPI_APPS_JSON=' /tmp/cipi-api-build/.env 2>/dev/null \
            && sed -i "s|^CIPI_APPS_JSON=.*|CIPI_APPS_JSON=${CIPI_CONFIG}/apps-public.json|" /tmp/cipi-api-build/.env \
            || echo "CIPI_APPS_JSON=${CIPI_CONFIG}/apps-public.json" >> /tmp/cipi-api-build/.env

        # 4. Publish assets and run setup
        (cd /tmp/cipi-api-build && php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan key:generate --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan migrate --force 2>/dev/null) || true
        (cd /tmp/cipi-api-build && php artisan cipi:seed-user 2>/dev/null) || true

        # 5. Ensure User model has HasApiTokens trait
        _api_patch_user_model /tmp/cipi-api-build

        # 6. Replace default / route with cipi welcome
        [[ -f /tmp/cipi-api-build/routes/web.php ]] && \
            sed -i "s/view('welcome')/view('cipi::welcome')/g" /tmp/cipi-api-build/routes/web.php

        # 7. Move to final location
        rm -rf "${CIPI_API_ROOT}" 2>/dev/null
        mv /tmp/cipi-api-build "${CIPI_API_ROOT}"
        chown -R www-data:www-data "${CIPI_API_ROOT}"
        success "Laravel API app + cipi-api package"
    else
        step "Updating cipi-api package..."
        _api_update_package
    fi
}

# Soft-update cipi/api the same way `cipi api upgrade` installs it: Packagist
# dist zip (or local path). Never use a GitHub VCS repository here — that path
# made Composer clone/scan the whole repo and hung soft updates indefinitely
# while Packagist already had the current release.
_api_update_package() {
    local pkg_dir="/opt/cipi/cipi-api"
    local composer_rc=0
    [[ -d "${CIPI_LIB}/../cipi-api" ]] && pkg_dir="${CIPI_LIB}/../cipi-api"

    _api_stop_queue_for_update
    _api_composer_prepare_github "${CIPI_API_ROOT}"

    # Stale VCS entry from 5.0.8+ soft-updates overrides Packagist and hangs.
    (cd "${CIPI_API_ROOT}" && composer config --unset repositories.cipi-api 2>/dev/null) || true

    if [[ -d "$pkg_dir" ]]; then
        step "Composer path repo → ${pkg_dir}"
        (cd "${CIPI_API_ROOT}" && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
        step "Composer require cipi/api:@dev (timeout ${CIPI_COMPOSER_TIMEOUT:-600}s)..."
        if ! (cd "${CIPI_API_ROOT}" && composer require cipi/api:@dev --no-interaction --prefer-dist --no-ansi); then
            composer_rc=$?
            warn "Composer require cipi/api:@dev failed (exit ${composer_rc})"
        fi
    else
        step "Composer require cipi/api from Packagist (timeout ${CIPI_COMPOSER_TIMEOUT:-600}s)..."
        if ! (cd "${CIPI_API_ROOT}" && composer require cipi/api --no-interaction --prefer-dist --no-ansi); then
            composer_rc=$?
            warn "Composer require cipi/api failed (exit ${composer_rc})"
        fi
    fi

    step "Reclaiming API permissions & running migrations..."
    chown -R www-data:www-data "${CIPI_API_ROOT}" 2>/dev/null || true
    (cd "${CIPI_API_ROOT}" && _api_timeout 120 sudo -u www-data php artisan vendor:publish --tag=cipi-assets --force) || true
    (cd "${CIPI_API_ROOT}" && _api_timeout 180 sudo -u www-data php artisan migrate --force) || true
    _api_sync_token_abilities_file 2>/dev/null || true
    systemctl start cipi-queue 2>/dev/null || systemctl restart cipi-queue 2>/dev/null || true
    if [[ "$composer_rc" -ne 0 ]]; then
        return "$composer_rc"
    fi
    success "cipi-api package updated"
    return 0
}

_api_patch_user_model() {
    local base="$1"
    local user_model="${base}/app/Models/User.php"
    [[ ! -f "$user_model" ]] && return
    if ! grep -q 'HasApiTokens' "$user_model"; then
        sed -i '/^use Illuminate\\Foundation\\Auth\\User as Authenticatable;/a use Laravel\\Sanctum\\HasApiTokens;' "$user_model"
        sed -i 's/use HasFactory, Notifiable;/use HasApiTokens, HasFactory, Notifiable;/' "$user_model"
    fi
}

_api_setup_queue_worker() {
    # --max-time/--max-jobs recycle the worker periodically: PHP long-running
    # processes leak memory; without recycling, the queue degrades silently.
    cat > /etc/systemd/system/cipi-queue.service <<SYSTEMD
[Unit]
Description=Cipi API Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${CIPI_API_ROOT}
ExecStart=/usr/bin/php artisan queue:work database --sleep=3 --tries=1 --timeout=600 --queue=default --max-time=3600 --max-jobs=200 --rest=1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/cipi-queue.log
StandardError=append:/var/log/cipi-queue.log

[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable cipi-queue 2>/dev/null
    systemctl restart cipi-queue 2>/dev/null
}

# Wire the Laravel scheduler for /opt/cipi/api into system cron and lay down
# a daily maintenance cron. Without this, the cipi-api package's scheduled
# commands (cipi:prune-job-logs daily, cipi:record-server-metrics every
# minute) never fire on the panel app — only on user apps, which have their
# own per-user crontab. Consequences pre-4.5.1:
#  - storage/app/cipi-job-logs/{uuid}.log accumulates forever (one file per
#    deploy / artisan / MCP / sudo cipi call), eventually filling disk →
#    fopen() failures surface as opaque 500s on the panel
#  - cipi_jobs / failed_jobs rows accumulate forever in the panel SQLite
#  - WAL never gets a TRUNCATE checkpoint so database.sqlite-wal stays huge
# Idempotent: full file rewrite each time; no per-line dedup needed.
_api_setup_cron() {
    cat > /etc/cron.d/cipi-api <<CRON
# === CIPI API CRON ===
# Managed by 'cipi api'. Do not edit by hand — rewritten on each setup/update/upgrade.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Laravel scheduler — drives the cipi-api package's scheduled commands
# (cipi:prune-job-logs daily @ 03:30, cipi:record-server-metrics every minute).
# Goes to /dev/null because per-command output already lands in laravel.log.
* * * * * www-data /usr/bin/php ${CIPI_API_ROOT}/artisan schedule:run >> /dev/null 2>&1

# Daily maintenance @ 04:15 — keeps the panel SQLite small and snappy:
#  - prune Laravel failed_jobs older than 14 days
#  - prune cipi_jobs (completed/failed) older than 14 days
#  - prune the server-metrics table (cipi:record-server-metrics writes one
#    row/minute → ~1440/day; left unbounded it slows every dashboard query
#    until FPM workers hit request_terminate_timeout and 500)
#  - WAL checkpoint(TRUNCATE) so database.sqlite-wal doesn't grow unbounded
15 4 * * * www-data /usr/local/bin/cipi-api-maintain >> /var/log/cipi-api-maintain.log 2>&1

# Nightly soft update @ 04:30 — composer update + migrations (after cipi self-update @ 03:50).
30 4 * * * root /usr/local/bin/cipi-cron-notify api-update /usr/local/bin/cipi-api-update >> /var/log/cipi-api-update.log 2>&1
CRON
    chmod 644 /etc/cron.d/cipi-api

    # Maintenance helper kept out of the crontab itself so we can extend it
    # later without re-touching cron.d. Runs as www-data via cron.d above.
    cat > /usr/local/bin/cipi-api-maintain <<'MAINTAIN'
#!/bin/bash
# Cipi API daily maintenance — see /etc/cron.d/cipi-api.
set -u
API_ROOT="/opt/cipi/api"
DB_FILE=""
if [[ -f "${API_ROOT}/.env" ]] && grep -q '^DB_CONNECTION=sqlite' "${API_ROOT}/.env" 2>/dev/null; then
    raw=$(grep '^DB_DATABASE=' "${API_ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')
    [[ -z "$raw" || "$raw" == "null" ]] && raw="database/database.sqlite"
    if [[ "$raw" =~ ^/ ]]; then
        DB_FILE="$raw"
    else
        DB_FILE="${API_ROOT}/${raw}"
    fi
fi

echo "[$(date '+%F %T')] cipi-api-maintain start"

# Prune failed_jobs older than 14 days (built-in Laravel command).
if [[ -f "${API_ROOT}/artisan" ]]; then
    (cd "${API_ROOT}" && /usr/bin/php artisan queue:prune-failed --hours=336 2>&1) || true
fi

# Prune cipi_jobs older than 14 days (completed/failed only — never running/pending).
# Direct sqlite3 keeps this independent of the cipi-api package version.
if [[ -n "$DB_FILE" && -f "$DB_FILE" ]] && command -v sqlite3 >/dev/null 2>&1; then
    deleted=$(/usr/bin/sqlite3 "$DB_FILE" \
        "DELETE FROM cipi_jobs WHERE status IN ('completed','failed') AND created_at < datetime('now','-14 days'); SELECT changes();" 2>/dev/null)
    echo "  cipi_jobs pruned: ${deleted:-0}"

    # Prune the server-metrics table. cipi:record-server-metrics inserts one
    # row every minute; nothing in the package prunes it, so over weeks it
    # grows to hundreds of thousands of rows and every dashboard/server query
    # full-scans it until FPM hits request_terminate_timeout → opaque 500s.
    # Table/column names are discovered from the schema so this stays correct
    # across cipi-api package versions (mirrors the cipi_jobs approach).
    mtable=$(/usr/bin/sqlite3 "$DB_FILE" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%metric%' ORDER BY (name='cipi_server_metrics') DESC, length(name) LIMIT 1;" 2>/dev/null)
    if [[ -n "$mtable" ]]; then
        mcol=$(/usr/bin/sqlite3 "$DB_FILE" \
            "SELECT name FROM pragma_table_info('${mtable}') WHERE name IN ('created_at','recorded_at','timestamp','measured_at','created') ORDER BY (name='created_at') DESC LIMIT 1;" 2>/dev/null)
        if [[ -n "$mcol" ]]; then
            mdeleted=$(/usr/bin/sqlite3 "$DB_FILE" \
                "DELETE FROM \"${mtable}\" WHERE \"${mcol}\" < datetime('now','-14 days'); SELECT changes();" 2>/dev/null)
            echo "  ${mtable} pruned: ${mdeleted:-0}"
        else
            echo "  ${mtable}: no known timestamp column — skipped"
        fi
    fi

    # WAL checkpoint — reclaims space from database.sqlite-wal that 'PASSIVE'
    # checkpoints don't reclaim under concurrent FPM+queue writers.
    /usr/bin/sqlite3 "$DB_FILE" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    echo "  WAL checkpoint: ok"
fi

echo "[$(date '+%F %T')] cipi-api-maintain done"
MAINTAIN
    chmod 755 /usr/local/bin/cipi-api-maintain
    chown root:root /usr/local/bin/cipi-api-maintain

    cat > /usr/local/bin/cipi-api-update <<'UPDATE'
#!/bin/bash
# Cipi API nightly soft update (cipi api update) — see /etc/cron.d/cipi-api.
set -u

LOCK=/run/cipi-api-update.lock
exec 9>"$LOCK"
flock -n 9 || { echo "[$(date '+%F %T')] already running — skip"; exit 0; }

if [[ ! -f /etc/cipi/api.json ]]; then
    echo "[$(date '+%F %T')] API not configured — skip"
    exit 0
fi
if [[ ! -f /opt/cipi/api/artisan ]]; then
    echo "[$(date '+%F %T')] Panel API not installed — skip"
    exit 0
fi

echo "[$(date '+%F %T')] cipi-api-update start"
/usr/local/bin/cipi api update
rc=$?
if [[ $rc -eq 0 ]]; then
    echo "[$(date '+%F %T')] cipi-api-update done"
else
    echo "[$(date '+%F %T')] cipi-api-update failed (exit $rc)"
fi
exit $rc
UPDATE
    chmod 755 /usr/local/bin/cipi-api-update
    chown root:root /usr/local/bin/cipi-api-update

    # Logrotate for the maintenance log (don't grow forever).
    if [[ -d /etc/logrotate.d ]]; then
        cat > /etc/logrotate.d/cipi-api-maintain <<'LR'
/var/log/cipi-api-maintain.log {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
    copytruncate
}
LR
        cat > /etc/logrotate.d/cipi-api-update <<'LR'
/var/log/cipi-api-update.log {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
    copytruncate
}
LR
    fi
}

# The panel is token-only (Sanctum). The 'web' middleware group on Laravel's
# default welcome route still runs StartSession, which writes one file per
# anonymous hit under the 'file' driver — bots and uptime checks accumulate
# thousands over weeks until scandir() on the sessions dir stalls FPM
# workers past request_terminate_timeout, surfacing as 500s on '/'. Switching
# to the 'array' driver keeps sessions in-memory for the lifetime of the
# request and writes nothing to disk; CSRF for any future form would need to
# be revisited, but there are no stateful forms in the panel.
_api_ensure_session_driver_env() {
    local envf="${CIPI_API_ROOT}/.env"
    [[ -f "$envf" ]] || return 0
    if grep -q '^SESSION_DRIVER=' "$envf" 2>/dev/null; then
        sed -i 's|^SESSION_DRIVER=.*|SESSION_DRIVER=array|' "$envf"
    else
        echo 'SESSION_DRIVER=array' >> "$envf"
    fi
    chown www-data:www-data "$envf" 2>/dev/null || true
    chmod 640 "$envf" 2>/dev/null || true
}

_api_create_fpm_pool() {
    # Sized for a panel API that fans out to long sync ops (deploy, artisan,
    # MCP, sudo cipi …). Old defaults (max_children=10, no slowlog) led to
    # silent 500s when workers were SIGKILL'd at request_terminate_timeout
    # before Laravel could write to laravel.log.
    #
    # Optional $1 = PHP version (default: current system CLI, fallback 8.5).
    # `cipi php switch` has a twin writer in php.sh (_php_write_api_fpm_pool)
    # that also re-homes the pool and recreates /run/php/cipi-api.sock.
    local v="${1:-}" pv
    if [[ -z "$v" ]]; then
        v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")
    fi
    mkdir -p "/etc/php/${v}/fpm/pool.d" /run/php
    cat > "/etc/php/${v}/fpm/pool.d/cipi-api.conf" <<POOL
[cipi-api]
user = www-data
group = www-data
listen = /run/php/cipi-api.sock
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
php_admin_value[open_basedir] = ${CIPI_API_ROOT}/:/tmp/:/etc/cipi/:/proc/:/usr/local/bin/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/cipi-api-php-error.log
php_admin_flag[log_errors] = on
POOL
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        [[ "$pv" == "$v" ]] && continue
        rm -f "/etc/php/${pv}/fpm/pool.d/cipi-api.conf" 2>/dev/null || true
    done
    : > /var/log/cipi-api-fpm-slow.log 2>/dev/null || true
    : > /var/log/cipi-api-php-error.log 2>/dev/null || true
    chown www-data:adm /var/log/cipi-api-fpm-slow.log /var/log/cipi-api-php-error.log 2>/dev/null || true
    chmod 640 /var/log/cipi-api-fpm-slow.log /var/log/cipi-api-php-error.log 2>/dev/null || true
}

_api_create_nginx_vhost() {
    local domain="$1"
    cat > /etc/nginx/sites-available/cipi-api <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    root ${CIPI_API_ROOT}/public;
    index index.php;
    access_log /var/log/nginx/cipi-api-access.log;
    error_log /var/log/nginx/cipi-api-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    client_max_body_size 256M;
    location /api-docs {
        alias ${CIPI_API_ROOT}/public/api-docs;
        try_files \$uri =404;
    }
    # FPM status page (used by 'cipi api status' to report active/idle
    # workers, queue depth, slow requests). Local-only.
    location = /cipi-api-fpm-status {
        allow 127.0.0.1;
        allow ::1;
        deny all;
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$fastcgi_script_name;
        include fastcgi_params;
    }
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 60;
        fastcgi_buffers 16 32k;
        fastcgi_buffer_size 64k;
        fastcgi_busy_buffers_size 128k;
        fastcgi_intercept_errors off;
    }
    location ~ /\.(?!well-known) { deny all; }
    error_page 404 /index.php;
}
EOF
}

# ── API UPDATE (cipi api update) ───────────────────────────────

api_update() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    echo ""; info "Updating API (cipi/api via Packagist, same as upgrade)..."; echo ""

    ensure_cipi_api_permissions

    local fp_before ver_before
    fp_before=$(_api_lock_fingerprint)
    ver_before=$(_api_lock_package_version "cipi/api" 2>/dev/null || true)

    # Soft update = package bump only. Full Laravel rebuild: cipi api upgrade.
    if ! _api_update_package; then
        error "Composer update failed (timed out or error). Try: cipi api upgrade"
        systemctl start cipi-queue 2>/dev/null || true
        exit 1
    fi

    step "API runtime hardening..."
    _api_ensure_log_stack_env
    _api_ensure_session_driver_env
    _api_apply_sqlite_pragmas
    _api_setup_cron
    reload_php_fpm "8.5"

    _api_show_versions

    # The nightly cron runs this every day: only a change in the locked
    # packages is an update worth logging and announcing. An unreadable lock
    # (empty fingerprint) counts as a change rather than hiding a real one.
    local fp_after ver_after
    fp_after=$(_api_lock_fingerprint)
    if [[ -n "$fp_before" && "$fp_before" == "$fp_after" ]]; then
        echo ""; success "API already up to date — no package changed"; echo ""
        return 0
    fi
    ver_after=$(_api_lock_package_version "cipi/api" 2>/dev/null || true)

    log_action "API UPDATED: cipi/api ${ver_before:-?} → ${ver_after:-?}"
    cipi_notify \
        "Cipi API updated on $(hostname)" \
        "The panel API was updated.\n\nServer: $(hostname)\ncipi/api: ${ver_before:-?} → ${ver_after:-?}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        api_update
    echo ""; success "API updated successfully"; echo ""
}

# ── API UPGRADE (cipi api upgrade) ────────────────────────────

api_upgrade() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    local domain; domain=$(vault_read api.json | jq -r '.domain')

    echo ""
    echo -e "${YELLOW}${BOLD}Full rebuild: fresh Laravel + cipi-api package${NC}"
    echo -e "${YELLOW}Preserves: .env, database (SQLite), SSL, tokens${NC}"
    echo ""

    # Stop queue worker
    systemctl stop cipi-queue 2>/dev/null || true

    # 1. Backup critical data
    step "Backing up..."
    local backup_dir="/tmp/cipi-api-backup-$(date +%s)"
    mkdir -p "$backup_dir"
    [[ -f "${CIPI_API_ROOT}/.env" ]] && cp "${CIPI_API_ROOT}/.env" "${backup_dir}/.env"
    [[ -f "${CIPI_API_ROOT}/database/database.sqlite" ]] && cp "${CIPI_API_ROOT}/database/database.sqlite" "${backup_dir}/database.sqlite"
    success "Backup → $backup_dir"

    # 2. Build new Laravel project
    step "Creating fresh Laravel project..."
    rm -rf /tmp/cipi-api-build 2>/dev/null
    (cd /tmp && composer create-project laravel/laravel cipi-api-build --no-interaction --prefer-dist 2>/dev/null) || {
        error "Failed to create Laravel app."
        systemctl start cipi-queue 2>/dev/null || true
        exit 1
    }
    success "Fresh Laravel installed"

    # 3. Install cipi-api package
    step "Installing cipi-api package..."
    local pkg_dir="/opt/cipi/cipi-api"
    [[ -d "${CIPI_LIB}/../cipi-api" ]] && pkg_dir="${CIPI_LIB}/../cipi-api"
    if [[ -d "$pkg_dir" ]]; then
        (cd /tmp/cipi-api-build && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
        (cd /tmp/cipi-api-build && composer require cipi/api:@dev --no-interaction 2>/dev/null) || true
    else
        (cd /tmp/cipi-api-build && composer require cipi/api --no-interaction 2>/dev/null) || true
    fi
    (cd /tmp/cipi-api-build && composer require laravel/mcp --no-interaction 2>/dev/null) || true
    success "cipi-api package installed"

    # 4. Restore .env (keeps APP_KEY, DB credentials, QUEUE_CONNECTION)
    step "Restoring .env..."
    if [[ -f "${backup_dir}/.env" ]]; then
        cp "${backup_dir}/.env" /tmp/cipi-api-build/.env
    else
        sed -i "s|^APP_ENV=.*|APP_ENV=production|" /tmp/cipi-api-build/.env
        sed -i "s|^APP_DEBUG=.*|APP_DEBUG=false|" /tmp/cipi-api-build/.env
        sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=database|" /tmp/cipi-api-build/.env
        (cd /tmp/cipi-api-build && php artisan key:generate --force 2>/dev/null) || true
    fi
    if grep -q '^LOG_STACK=' /tmp/cipi-api-build/.env 2>/dev/null; then
        sed -i 's|^LOG_STACK=.*|LOG_STACK=single,stderr|' /tmp/cipi-api-build/.env
    else
        echo 'LOG_STACK=single,stderr' >> /tmp/cipi-api-build/.env
    fi
    success ".env restored"

    # 5. Restore database
    step "Restoring database..."
    if [[ -f "${backup_dir}/database.sqlite" ]]; then
        cp "${backup_dir}/database.sqlite" /tmp/cipi-api-build/database/database.sqlite
    fi
    success "Database restored"

    # 6. Patch User model, publish assets, run new migrations
    _api_patch_user_model /tmp/cipi-api-build
    (cd /tmp/cipi-api-build && php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
    (cd /tmp/cipi-api-build && php artisan migrate --force 2>/dev/null) || true
    (cd /tmp/cipi-api-build && php artisan cipi:seed-user 2>/dev/null) || true
    if [[ -f /tmp/cipi-api-build/vendor/cipi/api/token-abilities.txt ]]; then
        cp /tmp/cipi-api-build/vendor/cipi/api/token-abilities.txt /tmp/cipi-api-build/token-abilities.txt
    elif [[ -f /opt/cipi/cipi-api/token-abilities.txt ]]; then
        cp /opt/cipi/cipi-api/token-abilities.txt /tmp/cipi-api-build/token-abilities.txt
    fi
    [[ -f /tmp/cipi-api-build/routes/web.php ]] && \
        sed -i "s/view('welcome')/view('cipi::welcome')/g" /tmp/cipi-api-build/routes/web.php
    success "Migrations & assets"

    # 7. Swap in the new build
    step "Swapping..."
    rm -rf "${CIPI_API_ROOT}.old" 2>/dev/null
    mv "${CIPI_API_ROOT}" "${CIPI_API_ROOT}.old" 2>/dev/null || true
    mv /tmp/cipi-api-build "${CIPI_API_ROOT}"
    chown -R www-data:www-data "${CIPI_API_ROOT}"
    _api_sync_token_abilities_file 2>/dev/null || true
    _api_ensure_log_stack_env
    _api_ensure_session_driver_env
    _api_apply_sqlite_pragmas
    _api_setup_cron
    success "App replaced"

    # 8. Restart services
    systemctl restart cipi-queue 2>/dev/null || true
    reload_php_fpm "8.5"

    # 9. Show result
    _api_show_versions

    log_action "API UPGRADED (full rebuild)"
    cipi_notify \
        "Cipi API upgraded on $(hostname)" \
        "The panel API was fully rebuilt.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        api_upgrade
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}Upgrade complete${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Old version kept at: ${CYAN}${CIPI_API_ROOT}.old${NC}"
    echo -e "  Backup:              ${CYAN}${backup_dir}${NC}"
    echo ""
    echo -e "  Remove after testing:  ${DIM}rm -rf ${CIPI_API_ROOT}.old${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ── API STATUS (cipi api status) ──────────────────────────────

api_status() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    ensure_cipi_api_permissions
    _api_ensure_psysh_home

    local domain; domain=$(vault_read api.json | jq -r '.domain' 2>/dev/null)

    echo ""
    echo -e "${BOLD}Cipi API Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Domain:     ${CYAN}https://${domain}${NC}"

    # Queue first (no DB) so output is useful even if artisan is slow or stuck
    local queue_status
    if systemctl is-active cipi-queue &>/dev/null; then
        queue_status="${GREEN}running${NC}"
    else
        queue_status="${RED}stopped${NC}"
    fi
    echo -e "  Queue:      ${queue_status}"

    _api_show_versions

    local pending
    pending=$(_api_pending_jobs_count)
    echo -e "  Jobs:       ${CYAN}${pending} pending${NC}"

    _api_show_fpm_summary

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Read /cipi-api-fpm-status (local) via the unix socket and extract a 1-line
# summary: active/idle workers and listen queue. Falls back gracefully when
# the endpoint is not configured (older installs pre-4.5.0).
_api_show_fpm_summary() {
    command -v curl >/dev/null 2>&1 || return 0
    local domain status active idle queue slow_count
    domain=$(vault_read api.json | jq -r '.domain' 2>/dev/null)
    [[ -z "$domain" || "$domain" == "null" ]] && return 0
    status=$(_api_timeout 5 curl -sk --max-time 4 \
        --resolve "${domain}:443:127.0.0.1" \
        --resolve "${domain}:80:127.0.0.1" \
        "https://${domain}/cipi-api-fpm-status" 2>/dev/null) || status=""
    [[ -z "$status" ]] && status=$(_api_timeout 5 curl -s --max-time 4 \
        --resolve "${domain}:80:127.0.0.1" \
        "http://${domain}/cipi-api-fpm-status" 2>/dev/null) || true
    if [[ -n "$status" ]] && echo "$status" | grep -q '^pool:'; then
        active=$(echo "$status" | awk -F: '/^active processes:/   {gsub(/ /,"",$2); print $2}')
        idle=$(echo   "$status" | awk -F: '/^idle processes:/     {gsub(/ /,"",$2); print $2}')
        queue=$(echo  "$status" | awk -F: '/^listen queue:/       {gsub(/ /,"",$2); print $2}')
        echo -e "  Workers:    ${CYAN}${active:-?} active · ${idle:-?} idle · queue ${queue:-0}${NC}"
    fi
    if [[ -f /var/log/cipi-api-fpm-slow.log ]]; then
        slow_count=$(grep -c '^\[' /var/log/cipi-api-fpm-slow.log 2>/dev/null || echo 0)
        if [[ -n "$slow_count" && "$slow_count" -gt 0 ]]; then
            echo -e "  Slowlog:    ${YELLOW}${slow_count} slow request(s)${NC} ${DIM}/var/log/cipi-api-fpm-slow.log${NC}"
        fi
    fi
}

_api_show_versions() {
    local laravel_ver cipi_api_ver
    laravel_ver=$(_api_lock_package_version "laravel/framework")
    laravel_ver="${laravel_ver#v}"
    [[ -z "$laravel_ver" ]] && laravel_ver=$(_api_timeout 12 bash -c "cd \"${CIPI_API_ROOT}\" && sudo -u www-data env HOME=/tmp php artisan --version 2>/dev/null" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$laravel_ver" ]] && laravel_ver="unknown"

    cipi_api_ver=$(_api_lock_package_version "cipi/api")
    [[ -z "$cipi_api_ver" ]] && cipi_api_ver=$(_api_timeout 12 bash -c "cd \"${CIPI_API_ROOT}\" && composer show cipi/api 2>/dev/null" | sed -n 's/^[[:space:]]*versions[[:space:]]*:[[:space:]]*//p' | head -1)
    cipi_api_ver="${cipi_api_ver#v}"
    [[ -z "$cipi_api_ver" ]] && cipi_api_ver="dev"
    echo -e "  Laravel:    ${CYAN}${laravel_ver}${NC}"
    echo -e "  cipi-api:   ${CYAN}${cipi_api_ver}${NC}"
}

# ── API SSL (cipi api ssl) ─────────────────────────────────────

api_ssl() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    local domain; domain=$(vault_read api.json | jq -r '.domain')
    [[ -z "$domain" || "$domain" == "null" ]] && { error "No domain in api.json"; exit 1; }

    echo ""
    step "Installing SSL for ${domain}..."
    echo ""

    if certbot --nginx -d "${domain}" \
        --cert-name "${domain}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect 2>&1; then
        nginx -t 2>&1 && systemctl reload nginx 2>/dev/null || true
        log_action "API SSL INSTALLED: $domain"
        cipi_notify \
            "Cipi API SSL installed: ${domain} on $(hostname)" \
            "SSL was installed for the panel API.\n\nServer: $(hostname)\nDomain: ${domain}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            api_ssl
        echo ""; success "SSL installed for ${domain}"; echo ""
    else
        echo ""; error "SSL failed. Check DNS, port 80, and domain."; exit 1
    fi
}

# ── TOKEN LIST ─────────────────────────────────────────────────

api_token_list() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    ensure_cipi_api_permissions

    echo -e "\n${BOLD}API Tokens${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    sudo -u www-data php "${CIPI_API_ROOT}/artisan" cipi:token-list 2>/dev/null || {
        echo "  No tokens or run: cipi api token create"
    }
    echo ""
}

# ── TOKEN CREATE ───────────────────────────────────────────────

api_token_create() {
    [[ ! -f "${CIPI_API_CONFIG}" ]] && { error "API not configured. Run: cipi api <domain>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    echo ""; info "Create API token"; echo ""

    # Name (slug)
    local name=""
    while true; do
        read_input "Token name (slug: a-z, 0-9, hyphens)" "" name
        if [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]]; then
            break
        fi
        error "Invalid slug. Use lowercase letters, numbers, hyphens only."
    done

    # Abilities (terminal checklist; non-TTY / pipes → all abilities)
    local abilities_str
    if [[ -t 0 ]]; then
        abilities_str=$(_api_token_select_abilities) || exit 1
    else
        abilities_str=$(_api_token_abilities_default)
    fi

    # Expiry date (YYYY-MM-DD, empty = no expiry)
    local expiry=""
    read_input "Expiry date (YYYY-MM-DD, empty = never)" "" expiry
    if [[ -n "$expiry" ]]; then
        if ! date -d "$expiry" &>/dev/null; then
            error "Invalid date format. Use YYYY-MM-DD"; exit 1
        fi
    fi

    ensure_cipi_api_permissions

    echo ""
    step "Creating token..."
    local out rc
    out=$(cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan cipi:token-create --name="$name" --abilities="$abilities_str" --expires-at="${expiry}" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo ""; success "Token created"
        echo ""; echo "$out"; echo ""
        echo -e "${YELLOW}${BOLD}⚠ Save the token — it will not be shown again${NC}"
        echo ""
    else
        error "$out"; exit 1
    fi
}

# ── TOKEN REVOKE ───────────────────────────────────────────────

api_token_revoke() {
    local name="${1:-}"
    [[ -z "$name" ]] && { error "Usage: cipi api token revoke <name>"; exit 1; }
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found."; exit 1; }

    ensure_cipi_api_permissions

    local out rc
    out=$(cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan cipi:token-revoke --name="$name" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        success "Token '${name}' revoked"
    else
        error "Failed to revoke: $out"; exit 1
    fi
}

# ── IP WHITELIST ───────────────────────────────────────────────
# Plain file (not vault): www-data must read it on every API/MCP request.
# Missing file or "*" = allow all (default / safe for upgrades).

_api_ipwl_ensure_file() {
    mkdir -p "${CIPI_CONFIG}"
    if [[ ! -f "${CIPI_API_IP_WHITELIST}" ]]; then
        printf '%s\n' '*' > "${CIPI_API_IP_WHITELIST}"
        chmod 644 "${CIPI_API_IP_WHITELIST}" 2>/dev/null || true
    fi
}

# Returns 0 if entry is * / valid IPv4 / IPv6 / CIDR.
_api_ipwl_valid_entry() {
    local e="${1:-}"
    [[ -z "$e" ]] && return 1
    [[ "$e" == "*" ]] && return 0
    if command -v php >/dev/null 2>&1; then
        php -r '
$e = $argv[1];
if ($e === "*") { exit(0); }
if (str_contains($e, "/")) {
    [$ip, $prefix] = explode("/", $e, 2);
    if (!ctype_digit($prefix) && !(is_string($prefix) && preg_match("/^\d+$/", $prefix))) { exit(1); }
    $prefix = (int) $prefix;
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) { exit($prefix >= 0 && $prefix <= 32 ? 0 : 1); }
    if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) { exit($prefix >= 0 && $prefix <= 128 ? 0 : 1); }
    exit(1);
}
exit(filter_var($e, FILTER_VALIDATE_IP) ? 0 : 1);
' "$e" 2>/dev/null
        return $?
    fi
    # Fallback without PHP: IPv4 (+ optional /0-32) only
    if [[ "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; then
        return 0
    fi
    # Loose IPv6 (hex + : + optional /prefix)
    if [[ "$e" =~ ^[0-9a-fA-F:]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]] && [[ "$e" == *:* ]]; then
        return 0
    fi
    return 1
}

# Print normalized entries (no comments/blanks), one per line.
_api_ipwl_entries() {
    _api_ipwl_ensure_file
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "${CIPI_API_IP_WHITELIST}"
}

_api_ipwl_is_allow_all() {
    local e has=false
    while IFS= read -r e; do
        has=true
        [[ "$e" == "*" ]] && return 0
    done < <(_api_ipwl_entries)
    # Missing / empty → allow all (safe default)
    [[ "$has" == "false" ]] && return 0
    return 1
}

_api_ipwl_write() {
    local -a entries=("$@")
    local tmp
    tmp=$(mktemp)
    {
        echo "# Cipi API IP whitelist — managed by: cipi api ip-whitelist"
        echo "# * = allow all | otherwise one IPv4/IPv6 or CIDR per line"
        if [[ ${#entries[@]} -eq 0 ]]; then
            echo '*'
        else
            local e
            for e in "${entries[@]}"; do
                echo "$e"
            done
        fi
    } > "$tmp"
    mv -f "$tmp" "${CIPI_API_IP_WHITELIST}"
    chmod 644 "${CIPI_API_IP_WHITELIST}" 2>/dev/null || true
}

_api_ipwl_public_ip_hint() {
    local ip=""
    ip=$(curl -s --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || true
    if [[ -n "$ip" ]] && _api_ipwl_valid_entry "$ip"; then
        echo "$ip"
    fi
}

api_ip_whitelist_show() {
    parse_args "$@"
    _api_ipwl_ensure_file

    local -a entries=()
    local e
    while IFS= read -r e; do
        entries+=("$e")
    done < <(_api_ipwl_entries)

    local allow_all=false
    _api_ipwl_is_allow_all && allow_all=true

    if [[ "${ARG_json:-}" == "true" ]]; then
        local json_entries
        if [[ "$allow_all" == "true" ]]; then
            json_entries='["*"]'
        else
            json_entries=$(printf '%s\n' "${entries[@]}" | jq -R . | jq -s .)
        fi
        jq -n \
            --argjson allow_all "$allow_all" \
            --argjson entries "$json_entries" \
            --arg file "${CIPI_API_IP_WHITELIST}" \
            '{allow_all:$allow_all, entries:$entries, file:$file}'
        return 0
    fi

    echo ""
    echo -e "${BOLD}API IP whitelist${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  File: ${DIM}${CIPI_API_IP_WHITELIST}${NC}"
    if [[ "$allow_all" == "true" ]]; then
        echo -e "  Mode: ${GREEN}allow all (*)${NC}"
    else
        echo -e "  Mode: ${YELLOW}restricted${NC} (${#entries[@]} entr$([[ ${#entries[@]} -eq 1 ]] && echo y || echo ies))"
        local i=0
        for e in "${entries[@]}"; do
            (( i++ )) || true
            echo -e "    ${CYAN}${i}${NC}  ${e}"
        done
    fi
    echo ""
    echo -e "  ${DIM}Add:    cipi api ip-whitelist add <ip|cidr>${NC}"
    echo -e "  ${DIM}Remove: cipi api ip-whitelist remove <ip|cidr>${NC}"
    echo -e "  ${DIM}Reset:  cipi api ip-whitelist allow-all${NC}"
    local hint
    hint=$(_api_ipwl_public_ip_hint)
    if [[ -n "$hint" ]]; then
        echo -e "  ${DIM}This server public IP (often needed for same-host GUI): ${hint}${NC}"
    fi
    echo ""
}

api_ip_whitelist_add() {
    parse_args "$@"
    _api_ipwl_ensure_file

    local -a to_add=()
    local a
    for a in "$@"; do
        [[ "$a" == --* ]] && continue
        to_add+=("$a")
    done
    if [[ -n "${ARG_ips:-}" ]]; then
        IFS=',' read -r -a _extra <<< "${ARG_ips}"
        local x
        for x in "${_extra[@]}"; do
            x="$(echo "$x" | tr -d '[:space:]')"
            [[ -n "$x" ]] && to_add+=("$x")
        done
    fi
    [[ ${#to_add[@]} -eq 0 ]] && { error "Usage: cipi api ip-whitelist add <ip|cidr> [...] [--ips=a,b]"; exit 1; }

    local -a current=()
    local allow_all=false
    _api_ipwl_is_allow_all && allow_all=true

    if [[ "$allow_all" == "false" ]]; then
        while IFS= read -r e; do
            current+=("$e")
        done < <(_api_ipwl_entries)
    fi

    local added=0
    for a in "${to_add[@]}"; do
        a="$(echo "$a" | tr -d '[:space:]')"
        [[ -z "$a" ]] && continue
        if ! _api_ipwl_valid_entry "$a"; then
            error "Invalid IP or CIDR: ${a}"; exit 1
        fi
        if [[ "$a" == "*" ]]; then
            _api_ipwl_write '*'
            log_action "API IP WHITELIST: allow-all"
            success "Whitelist set to allow all (*)"
            return 0
        fi
        local exists=false
        local c
        for c in "${current[@]}"; do
            [[ "$c" == "$a" ]] && exists=true && break
        done
        if [[ "$exists" == "false" ]]; then
            current+=("$a")
            (( added++ )) || true
        fi
    done

    if [[ ${#current[@]} -eq 0 ]]; then
        _api_ipwl_write '*'
    else
        _api_ipwl_write "${current[@]}"
    fi
    log_action "API IP WHITELIST ADD: ${to_add[*]}"
    if [[ "$allow_all" == "true" && $added -gt 0 ]]; then
        warn "Switched from allow-all (*) to restricted mode."
        warn "Include the GUI server IP and any operator IPs, or you may lock yourself out."
        warn "Escape hatch on the server: cipi api ip-whitelist allow-all"
    fi
    success "Added ${added} entr$([[ $added -eq 1 ]] && echo y || echo ies)"
    api_ip_whitelist_show
}

api_ip_whitelist_remove() {
    parse_args "$@"
    _api_ipwl_ensure_file

    local -a to_remove=()
    local a
    for a in "$@"; do
        [[ "$a" == --* ]] && continue
        to_remove+=("$a")
    done
    if [[ -n "${ARG_ips:-}" ]]; then
        IFS=',' read -r -a _extra <<< "${ARG_ips}"
        local x
        for x in "${_extra[@]}"; do
            x="$(echo "$x" | tr -d '[:space:]')"
            [[ -n "$x" ]] && to_remove+=("$x")
        done
    fi
    [[ ${#to_remove[@]} -eq 0 ]] && { error "Usage: cipi api ip-whitelist remove <ip|cidr> [...] [--ips=a,b]"; exit 1; }

    if _api_ipwl_is_allow_all; then
        warn "Already allow-all (*); nothing to remove."
        exit 0
    fi

    local -a current=() next=()
    while IFS= read -r e; do
        current+=("$e")
    done < <(_api_ipwl_entries)

    local removed=0
    local c r skip
    for c in "${current[@]}"; do
        skip=false
        for r in "${to_remove[@]}"; do
            r="$(echo "$r" | tr -d '[:space:]')"
            if [[ "$c" == "$r" ]]; then
                skip=true
                (( removed++ )) || true
                break
            fi
        done
        [[ "$skip" == "false" ]] && next+=("$c")
    done

    if [[ ${#next[@]} -eq 0 ]]; then
        _api_ipwl_write '*'
        log_action "API IP WHITELIST: allow-all (last entry removed)"
        success "Last entry removed — whitelist reset to allow all (*)"
    else
        _api_ipwl_write "${next[@]}"
        log_action "API IP WHITELIST REMOVE: ${to_remove[*]}"
        success "Removed ${removed} entr$([[ $removed -eq 1 ]] && echo y || echo ies)"
    fi
    api_ip_whitelist_show
}

api_ip_whitelist_set() {
    parse_args "$@"
    _api_ipwl_ensure_file

    if [[ "${ARG_allow_all:-}" == "true" ]]; then
        api_ip_whitelist_allow_all
        return 0
    fi

    local -a entries=()
    if [[ -n "${ARG_ips:-}" ]]; then
        IFS=',' read -r -a _raw <<< "${ARG_ips}"
        local x
        for x in "${_raw[@]}"; do
            x="$(echo "$x" | tr -d '[:space:]')"
            [[ -n "$x" ]] && entries+=("$x")
        done
    else
        # Positional IPs
        local a
        for a in "$@"; do
            [[ "$a" == --* ]] && continue
            entries+=("$a")
        done
    fi

    # Interactive multiline when nothing provided and TTY
    if [[ ${#entries[@]} -eq 0 ]]; then
        if [[ ! -t 0 ]]; then
            error "Usage: cipi api ip-whitelist set --ips=1.2.3.4,10.0.0.0/8 | --allow-all"
            exit 1
        fi
        echo ""
        echo -e "${BOLD}Set API IP whitelist${NC}"
        echo -e "${DIM}Paste one IP or CIDR per line. Use * alone for allow all.${NC}"
        echo -e "${DIM}Empty line to finish.${NC}"
        local hint
        hint=$(_api_ipwl_public_ip_hint)
        [[ -n "$hint" ]] && echo -e "${DIM}Hint — this server public IP: ${hint}${NC}"
        echo ""
        local line
        while true; do
            read -r line || break
            line="${line%%#*}"
            line="$(echo "$line" | tr -d '[:space:]')"
            [[ -z "$line" ]] && break
            entries+=("$line")
        done
    fi

    [[ ${#entries[@]} -eq 0 ]] && { error "No entries provided"; exit 1; }

    local e
    for e in "${entries[@]}"; do
        if ! _api_ipwl_valid_entry "$e"; then
            error "Invalid IP or CIDR: ${e}"; exit 1
        fi
    done

    # If * is present, allow-all wins
    for e in "${entries[@]}"; do
        if [[ "$e" == "*" ]]; then
            _api_ipwl_write '*'
            log_action "API IP WHITELIST: allow-all"
            success "Whitelist set to allow all (*)"
            api_ip_whitelist_show
            return 0
        fi
    done

    # Deduplicate preserving order
    local -a unique=()
    local u seen
    for e in "${entries[@]}"; do
        seen=false
        for u in "${unique[@]}"; do
            [[ "$u" == "$e" ]] && seen=true && break
        done
        [[ "$seen" == "false" ]] && unique+=("$e")
    done

    _api_ipwl_write "${unique[@]}"
    log_action "API IP WHITELIST SET: ${unique[*]}"
    warn "Restricted mode — clients not on this list get HTTP 403."
    warn "Escape hatch: cipi api ip-whitelist allow-all"
    success "Whitelist updated (${#unique[@]} entries)"
    api_ip_whitelist_show
}

api_ip_whitelist_allow_all() {
    _api_ipwl_ensure_file
    _api_ipwl_write '*'
    log_action "API IP WHITELIST: allow-all"
    success "Whitelist set to allow all (*)"
    api_ip_whitelist_show
}

_api_ip_whitelist_command() {
    local sub="${1:-show}"; shift || true
    case "$sub" in
        ""|show|list|status) api_ip_whitelist_show "$@" ;;
        add)                 api_ip_whitelist_add "$@" ;;
        remove|rm|delete)    api_ip_whitelist_remove "$@" ;;
        set|replace)         api_ip_whitelist_set "$@" ;;
        allow-all|reset|clear) api_ip_whitelist_allow_all "$@" ;;
        *)
            error "Usage: cipi api ip-whitelist show|add|remove|set|allow-all"
            exit 1
            ;;
    esac
}

# ── ROUTER ─────────────────────────────────────────────────────

api_fix_permissions() {
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found at ${CIPI_API_ROOT}"; exit 1; }
    ensure_cipi_api_permissions
    _api_ensure_psysh_home
    success "Panel API storage/database/bootstrap/cache + .env → www-data; psysh config dir ready"
}

api_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        "")      error "Usage: cipi api <domain>"; exit 1 ;;
        ssl)     api_ssl ;;
        update)  api_update ;;
        upgrade) api_upgrade ;;
        status)  api_status ;;
        fix-permissions|fixperms) api_fix_permissions ;;
        token)   _api_token_command "$@" ;;
        ip-whitelist|ipwhitelist|whitelist) _api_ip_whitelist_command "$@" ;;
        *)
            if validate_domain "$sub" 2>/dev/null; then
                api_setup "$sub"
            else
                error "Unknown: $sub"; echo "Use: <domain> | ssl | update | upgrade | status | fix-permissions | token list|create|revoke | ip-whitelist"; exit 1
            fi ;;
    esac
}

_api_token_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        list)   api_token_list ;;
        create) api_token_create ;;
        revoke) api_token_revoke "$@" ;;
        *)      error "Usage: cipi api token list|create|revoke <name>"; exit 1 ;;
    esac
}
