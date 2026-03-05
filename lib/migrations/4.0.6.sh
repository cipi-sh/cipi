#!/bin/bash
#############################################
# Cipi Migration 4.0.6 — API prerequisites
# - Sudoers rule for www-data to run cipi
# - Dedicated PHP-FPM pool for Cipi API
# - Queue worker (systemd) for async jobs
# - Migrate from overlay to cipi-api package
#############################################

set -e

CIPI_API_ROOT="/opt/cipi/api"

# 1. Sudoers
if [[ -f /etc/sudoers.d/cipi-api ]]; then
    echo "API sudoers already present — skip"
else
    echo 'www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi *' > /etc/sudoers.d/cipi-api
    chmod 440 /etc/sudoers.d/cipi-api
    echo "Added /etc/sudoers.d/cipi-api"
fi

# 2. PHP-FPM pool (only if API is already installed)
if [[ -d "$CIPI_API_ROOT" ]] && [[ ! -f /etc/php/8.4/fpm/pool.d/cipi-api.conf ]]; then
    cat > /etc/php/8.4/fpm/pool.d/cipi-api.conf <<'POOL'
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
php_admin_value[open_basedir] = /opt/cipi/api/:/tmp/:/etc/cipi/:/proc/
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /var/log/nginx/cipi-api-php-error.log
php_admin_flag[log_errors] = on
POOL
    systemctl restart php8.4-fpm 2>/dev/null || true
    echo "Created PHP-FPM pool cipi-api"

    if [[ -f /etc/nginx/sites-available/cipi-api ]]; then
        sed -i 's|fastcgi_pass unix:/run/php/php8.4-fpm.sock;|fastcgi_pass unix:/run/php/cipi-api.sock;|' /etc/nginx/sites-available/cipi-api
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
        echo "Updated Nginx vhost to use cipi-api socket"
    fi
else
    echo "PHP-FPM pool cipi-api: skip (API not installed or pool exists)"
fi

# 3. Migrate from overlay to cipi-api package + setup queue worker
if [[ -d "$CIPI_API_ROOT" ]] && [[ -f "${CIPI_API_ROOT}/artisan" ]]; then
    pkg_dir="/opt/cipi/cipi-api"

    # Install cipi-api package if not already present
    if ! (cd "$CIPI_API_ROOT" && composer show andreapollastri/cipi-api 2>/dev/null) >/dev/null 2>&1; then
        if [[ -d "$pkg_dir" ]]; then
            (cd "$CIPI_API_ROOT" && composer config repositories.cipi-api path "$pkg_dir" 2>/dev/null) || true
            (cd "$CIPI_API_ROOT" && composer require andreapollastri/cipi-api:@dev --no-interaction 2>/dev/null) || true
        else
            (cd "$CIPI_API_ROOT" && composer require andreapollastri/cipi-api --no-interaction 2>/dev/null) || true
        fi
        echo "Installed cipi-api package"
    else
        (cd "$CIPI_API_ROOT" && composer update andreapollastri/cipi-api --no-interaction 2>/dev/null) || true
        echo "Updated cipi-api package"
    fi

    # Patch User model for HasApiTokens
    user_model="${CIPI_API_ROOT}/app/Models/User.php"
    if [[ -f "$user_model" ]] && ! grep -q 'HasApiTokens' "$user_model"; then
        sed -i '/^use Illuminate\\Foundation\\Auth\\User as Authenticatable;/a use Laravel\\Sanctum\\HasApiTokens;' "$user_model"
        sed -i 's/use HasFactory, Notifiable;/use HasApiTokens, HasFactory, Notifiable;/' "$user_model"
        echo "Patched User model with HasApiTokens"
    fi

    # Configure queue and run migrations
    sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=database|" "${CIPI_API_ROOT}/.env"
    (cd "$CIPI_API_ROOT" && php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
    (cd "$CIPI_API_ROOT" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
    (cd "$CIPI_API_ROOT" && sudo -u www-data php artisan cipi:seed-user 2>/dev/null) || true
    echo "Database migrations and assets published"

    # Remove old overlay files that are now in the package
    rm -f "${CIPI_API_ROOT}/routes/api.php" 2>/dev/null
    rm -f "${CIPI_API_ROOT}/routes/web.php" 2>/dev/null
    rm -f "${CIPI_API_ROOT}/routes/ai.php" 2>/dev/null
    rm -rf "${CIPI_API_ROOT}/app/Http/Controllers/Api" 2>/dev/null
    rm -rf "${CIPI_API_ROOT}/app/Services" 2>/dev/null
    rm -rf "${CIPI_API_ROOT}/app/Jobs" 2>/dev/null
    rm -rf "${CIPI_API_ROOT}/app/Mcp" 2>/dev/null
    rm -rf "${CIPI_API_ROOT}/app/Console/Commands/Cipi*" 2>/dev/null
    rm -f "${CIPI_API_ROOT}/welcome.html" 2>/dev/null
    rm -rf /opt/cipi/api-overlay 2>/dev/null
    echo "Cleaned up old overlay files"

    # Queue worker systemd service
    if [[ ! -f /etc/systemd/system/cipi-queue.service ]]; then
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
        systemctl start cipi-queue 2>/dev/null
        echo "Queue worker (cipi-queue) installed and started"
    else
        systemctl restart cipi-queue 2>/dev/null || true
        echo "Queue worker (cipi-queue) restarted"
    fi

    chown -R www-data:www-data "${CIPI_API_ROOT}"
else
    echo "API migration: skip (API not installed)"
fi

# 4. Allow www-data to read apps.json (for API GET /apps, /aliases)
if [[ -f /etc/cipi/api.json ]] && [[ -f /etc/cipi/apps.json ]]; then
    chmod 750 /etc/cipi 2>/dev/null || true
    chgrp www-data /etc/cipi 2>/dev/null || true
    chmod 640 /etc/cipi/apps.json 2>/dev/null || true
    chgrp www-data /etc/cipi/apps.json 2>/dev/null || true
    echo "Configured apps.json access for API (www-data can read)"
fi
