#!/bin/bash
#############################################
# Cipi — API & MCP Server Management
#############################################

readonly CIPI_API_ROOT="/opt/cipi/api"
readonly CIPI_API_CONFIG="${CIPI_CONFIG}/api.json"

# ability|description — keep aligned with https://cipi.sh/docs/advanced#cipi-api
_api_ability_lines() {
    cat <<'EOF'
apps-view|Read apps
apps-create|Create apps
apps-edit|Edit apps
apps-delete|Delete apps
deploy-manage|Deploy, rollback, unlock
ssl-manage|SSL certificates
aliases-view|Read aliases
aliases-create|Add aliases
aliases-delete|Remove aliases
dbs-view|List databases
dbs-create|Create databases
dbs-delete|Delete databases
dbs-manage|Backup, restore, DB password
mcp-access|MCP server
EOF
}

_api_token_abilities_default() {
    _api_ability_lines | cut -d'|' -f1 | paste -sd, -
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

    # Ensure Laravel API app exists
    _api_ensure_laravel_app

    ensure_cipi_api_permissions

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

    # Queue worker (systemd)
    step "Queue worker..."
    _api_setup_queue_worker
    success "Queue worker (cipi-queue)"

    log_action "API CONFIGURED: $domain"
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

_api_update_package() {
    local pkg_dir="/opt/cipi/cipi-api"
    [[ -d "${CIPI_LIB}/../cipi-api" ]] && pkg_dir="${CIPI_LIB}/../cipi-api"
    if [[ -d "$pkg_dir" ]]; then
        (cd "${CIPI_API_ROOT}" && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
    fi
    (cd "${CIPI_API_ROOT}" && composer update cipi/api --no-interaction 2>/dev/null) || true
    chown -R www-data:www-data "${CIPI_API_ROOT}" 2>/dev/null || true
    (cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
    (cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
    success "cipi-api package updated"
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
    cat > /etc/systemd/system/cipi-queue.service <<SYSTEMD
[Unit]
Description=Cipi API Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=${CIPI_API_ROOT}
ExecStart=/usr/bin/php artisan queue:work database --sleep=3 --tries=1 --timeout=600 --queue=default
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

_api_create_fpm_pool() {
    cat > /etc/php/8.5/fpm/pool.d/cipi-api.conf <<POOL
[cipi-api]
user = www-data
group = www-data
listen = /run/php/cipi-api.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500
request_terminate_timeout = 300
php_admin_value[open_basedir] = ${CIPI_API_ROOT}/:/tmp/:/etc/cipi/:/proc/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/nginx/cipi-api-php-error.log
php_admin_flag[log_errors] = on
POOL
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
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/cipi-api.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
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

    echo ""; info "Updating API (composer update)..."; echo ""

    ensure_cipi_api_permissions

    # Stop queue worker during update
    systemctl stop cipi-queue 2>/dev/null || true

    # Update local package reference
    local pkg_dir="/opt/cipi/cipi-api"
    [[ -d "${CIPI_LIB}/../cipi-api" ]] && pkg_dir="${CIPI_LIB}/../cipi-api"
    if [[ -d "$pkg_dir" ]]; then
        (cd "${CIPI_API_ROOT}" && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
    fi

    # Update all packages (Laravel framework + cipi-api + dependencies)
    step "Composer update..."
    (cd "${CIPI_API_ROOT}" && composer update --no-interaction 2>/dev/null) || {
        error "Composer update failed. Try: cipi api upgrade"
        systemctl start cipi-queue 2>/dev/null || true
        exit 1
    }
    success "Packages updated"

    # Re-publish assets and run migrations
    step "Assets & migrations..."
    chown -R www-data:www-data "${CIPI_API_ROOT}" 2>/dev/null || true
    (cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
    (cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
    success "Assets published, migrations applied"

    # Restart services
    systemctl restart cipi-queue 2>/dev/null || true
    reload_php_fpm "8.5"

    # Show versions
    _api_show_versions

    log_action "API UPDATED"
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
    [[ -f /tmp/cipi-api-build/routes/web.php ]] && \
        sed -i "s/view('welcome')/view('cipi::welcome')/g" /tmp/cipi-api-build/routes/web.php
    success "Migrations & assets"

    # 7. Swap in the new build
    step "Swapping..."
    rm -rf "${CIPI_API_ROOT}.old" 2>/dev/null
    mv "${CIPI_API_ROOT}" "${CIPI_API_ROOT}.old" 2>/dev/null || true
    mv /tmp/cipi-api-build "${CIPI_API_ROOT}"
    chown -R www-data:www-data "${CIPI_API_ROOT}"
    success "App replaced"

    # 8. Restart services
    systemctl restart cipi-queue 2>/dev/null || true
    reload_php_fpm "8.5"

    # 9. Show result
    _api_show_versions

    log_action "API UPGRADED (full rebuild)"
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

    local domain; domain=$(vault_read api.json | jq -r '.domain' 2>/dev/null)

    echo ""
    echo -e "${BOLD}Cipi API Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Domain:     ${CYAN}https://${domain}${NC}"

    _api_show_versions

    # Queue worker status
    local queue_status
    if systemctl is-active cipi-queue &>/dev/null; then
        queue_status="${GREEN}running${NC}"
    else
        queue_status="${RED}stopped${NC}"
    fi
    echo -e "  Queue:      ${queue_status}"

    # Pending jobs (HOME=/tmp avoids psysh writing to /var/www/.config)
    local pending
    pending=$(cd "${CIPI_API_ROOT}" && sudo -u www-data env HOME=/tmp php artisan tinker --execute="echo \CipiApi\Models\CipiJob::whereIn('status',['pending','running'])->count();" 2>/dev/null || echo "?")
    echo -e "  Jobs:       ${CYAN}${pending} pending${NC}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_api_show_versions() {
    local laravel_ver cipi_api_ver
    laravel_ver=$(cd "${CIPI_API_ROOT}" && sudo -u www-data php artisan --version 2>/dev/null | grep -oP '[\d.]+' || echo "unknown")
    cipi_api_ver=$(cd "${CIPI_API_ROOT}" && composer show cipi/api 2>/dev/null | grep -oP 'versions\s*:\s*\K.*' || echo "dev")
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

# ── ROUTER ─────────────────────────────────────────────────────

api_fix_permissions() {
    [[ ! -f "${CIPI_API_ROOT}/artisan" ]] && { error "Laravel API app not found at ${CIPI_API_ROOT}"; exit 1; }
    ensure_cipi_api_permissions
    success "Panel API writable paths (${CIPI_API_ROOT}/storage, database, bootstrap/cache) → www-data"
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
        *)
            if validate_domain "$sub" 2>/dev/null; then
                api_setup "$sub"
            else
                error "Unknown: $sub"; echo "Use: <domain> | ssl | update | upgrade | status | fix-permissions | token list|create|revoke"; exit 1
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
